defmodule Oli.GoogleSlides.ImportWorkflow.FidelityValidator do
  @moduledoc """
  Reconciles the bounded Google Slides source inventory with a semantic lesson plan.

  The AI planner can reference source objects from concrete lesson parts and
  interactions, but it cannot decide that an object should be omitted. Omission
  decisions are retained only when `AnswerResolver` has marked them as trusted
  author answers.

  Reconciliation is pure and deterministic. It is used after analysis to build
  the review ledger, and `validate/2` can be called again immediately before
  generation to reject a stale or incomplete ledger.
  """

  alias Oli.GoogleSlides.AI.LessonPlan

  @blocker_code "source_inventory_unaccounted"
  @omission_warning_code "source_inventory_author_omitted"
  @colors_warning_key "source_colors_not_imported:lesson:layout"

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Rebuilds `sourceCoverage`, removes stale fidelity blockers, and creates one
  author blocker for each meaningful source object that is neither referenced
  by a concrete lesson element nor omitted by a trusted author answer.

  Container/group entries are accounted through their meaningful descendants.
  They remain in the ledger for review, but never create an impossible
  standalone inclusion blocker.
  """
  @spec reconcile(map(), map()) :: result()
  def reconcile(plan, snapshot) when is_map(plan) and is_map(snapshot) do
    with :ok <- ensure_inventory_complete(snapshot),
         {:ok, inventory} <- inventory(snapshot),
         {:ok, normalized_plan} <- LessonPlan.validate(plan) do
      trusted_omissions = trusted_omissions(normalized_plan)
      targets_by_object_id = targets_by_object_id(normalized_plan)

      coverage =
        inventory
        |> build_coverage(targets_by_object_id, trusted_omissions)
        |> account_for_containers(inventory)

      reconciled =
        normalized_plan
        |> enforce_default_colorless_layout()
        |> remove_generated_blockers()
        |> remove_stale_omission_warnings(coverage)
        |> Map.put("sourceCoverage", coverage)
        |> add_coverage_blockers(coverage)
        |> add_colors_not_imported_warning()

      finalize_or_validate(reconciled)
    end
  end

  def reconcile(_plan, _snapshot), do: {:error, :invalid_fidelity_input}

  @doc """
  Verifies that a persisted, approved plan still has the exact deterministic
  source-coverage ledger and colorless layout implied by the current snapshot.
  """
  @spec validate(map(), map()) :: :ok | {:error, [map()]}
  def validate(plan, snapshot) when is_map(plan) and is_map(snapshot) do
    case reconcile(plan, snapshot) do
      {:ok, reconciled} ->
        unaccounted =
          reconciled["sourceCoverage"]
          |> List.wrap()
          |> Enum.filter(&(&1["status"] == "unaccounted"))
          |> Enum.map(& &1["inventoryId"])

        cond do
          unaccounted != [] ->
            {:error,
             Enum.map(unaccounted, fn inventory_id ->
               error(
                 "sourceCoverage.#{inventory_id}",
                 "unaccounted_source_element",
                 "source element #{inventory_id} is not included or explicitly omitted by the author"
               )
             end)}

          plan["sourceCoverage"] != reconciled["sourceCoverage"] ->
            {:error,
             [
               error(
                 "sourceCoverage",
                 "stale_source_coverage",
                 "source coverage does not match the current source inventory and lesson elements"
               )
             ]}

          current_layout(plan) != current_layout(reconciled) ->
            {:error,
             [
               error(
                 "lesson.layout",
                 "source_colors_not_sanitized",
                 "the Slides import must use torus-default and omit color-bearing style declarations"
               )
             ]}

          true ->
            :ok
        end

      {:error, errors} when is_list(errors) ->
        {:error, errors}

      {:error, reason} ->
        {:error, fidelity_errors(reason)}
    end
  end

  def validate(_plan, _snapshot) do
    {:error, [error("sourceSnapshot", "invalid_source_snapshot", "source snapshot is invalid")]}
  end

  defp inventory(snapshot) do
    case snapshot["slides"] do
      slides when is_list(slides) ->
        entries =
          slides
          |> Enum.flat_map(fn
            slide when is_map(slide) ->
              slide
              |> Map.get("sourceInventory", [])
              |> List.wrap()
              |> Enum.map(&inherit_slide_id(&1, slide["objectId"]))

            _slide ->
              []
          end)
          |> Enum.filter(&coverage_candidate?/1)

        with :ok <- validate_inventory_entries(entries),
             :ok <- validate_unique_inventory_ids(entries),
             :ok <- validate_unique_object_ids(entries) do
          {:ok, entries}
        end

      _slides ->
        {:error, :invalid_source_inventory}
    end
  end

  defp inherit_slide_id(entry, slide_id) when is_map(entry) do
    case present_string?(entry["slideId"]) do
      true -> entry
      false -> Map.put(entry, "slideId", slide_id)
    end
  end

  defp inherit_slide_id(entry, _slide_id), do: entry

  defp coverage_candidate?(entry) when is_map(entry) do
    container?(entry) or
      (entry["meaningful"] != false and entry["decorative"] != true)
  end

  defp coverage_candidate?(_entry), do: false

  defp validate_inventory_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      cond do
        not is_map(entry) ->
          {:halt, {:error, {:invalid_source_inventory, index, :not_an_object}}}

        not present_string?(entry["inventoryId"]) ->
          {:halt, {:error, {:invalid_source_inventory, index, :missing_inventory_id}}}

        not present_string?(entry["slideId"]) ->
          {:halt, {:error, {:invalid_source_inventory, index, :missing_slide_id}}}

        not present_string?(entry["objectId"]) ->
          {:halt, {:error, {:invalid_source_inventory, index, :missing_object_id}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_unique_inventory_ids(entries) do
    ids = Enum.map(entries, & &1["inventoryId"])

    case length(ids) == MapSet.size(MapSet.new(ids)) do
      true -> :ok
      false -> {:error, :duplicate_source_inventory_id}
    end
  end

  defp validate_unique_object_ids(entries) do
    ids = Enum.map(entries, & &1["objectId"])

    case length(ids) == MapSet.size(MapSet.new(ids)) do
      true -> :ok
      false -> {:error, :duplicate_source_object_id}
    end
  end

  defp ensure_inventory_complete(snapshot) do
    case snapshot["inventoryAccounting"] do
      %{"omitted" => 0} ->
        :ok

      %{"omitted" => count} when is_integer(count) and count > 0 ->
        {:error, {:source_inventory_exceeds_limits, count}}

      _other ->
        {:error, :invalid_inventory_accounting}
    end
  end

  defp trusted_omissions(plan) do
    plan
    |> Map.get("sourceCoverage", [])
    |> List.wrap()
    |> Enum.reduce(MapSet.new(), fn
      %{
        "inventoryId" => inventory_id,
        "status" => "author_omitted",
        "decisionSource" => "author_answer"
      },
      acc
      when is_binary(inventory_id) ->
        MapSet.put(acc, inventory_id)

      _entry, acc ->
        acc
    end)
  end

  defp targets_by_object_id(plan) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      screen, acc when is_map(screen) ->
        screen_key = screen["key"]

        acc
        |> collect_screen_title_targets(screen["sourceRefs"], screen_key)
        |> collect_part_targets(screen["parts"], screen_key)
        |> collect_interaction_targets(screen["interactions"], screen_key)

      _screen, acc ->
        acc
    end)
    |> Map.new(fn {object_id, targets} ->
      {object_id, Enum.reverse(targets) |> Enum.uniq()}
    end)
  end

  defp collect_screen_title_targets(acc, refs, screen_key) do
    target = %{
      "kind" => "screen_title",
      "screenKey" => screen_key,
      "key" => screen_key
    }

    put_targets(acc, object_ids_from_refs(refs), target)
  end

  defp collect_part_targets(acc, parts, screen_key) do
    parts
    |> List.wrap()
    |> Enum.reduce(acc, fn
      part, nested_acc when is_map(part) ->
        target = %{
          "kind" => "part",
          "screenKey" => screen_key,
          "key" => part["key"]
        }

        object_ids =
          object_ids_from_refs(part["sourceRefs"]) ++
            object_ids_from_content(part["content"])

        put_targets(nested_acc, object_ids, target)

      _part, nested_acc ->
        nested_acc
    end)
  end

  defp collect_interaction_targets(acc, interactions, screen_key) do
    interactions
    |> List.wrap()
    |> Enum.reduce(acc, fn
      interaction, nested_acc when is_map(interaction) ->
        target = %{
          "kind" => "interaction",
          "screenKey" => screen_key,
          "key" => interaction["key"]
        }

        object_ids =
          object_ids_from_refs(interaction["sourceEvidence"]) ++
            object_ids_from_refs(interaction["correctResponseEvidence"])

        put_targets(nested_acc, object_ids, target)

      _interaction, nested_acc ->
        nested_acc
    end)
  end

  defp object_ids_from_refs(refs) do
    refs
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"objectId" => object_id} when is_binary(object_id) and object_id != "" ->
        [object_id]

      _ref ->
        []
    end)
  end

  defp object_ids_from_content(%{"sourceObjectId" => object_id})
       when is_binary(object_id) and object_id != "",
       do: [object_id]

  defp object_ids_from_content(_content), do: []

  defp put_targets(acc, object_ids, target) do
    object_ids
    |> Enum.uniq()
    |> Enum.reduce(acc, fn object_id, nested_acc ->
      Map.update(nested_acc, object_id, [target], &[target | &1])
    end)
  end

  defp build_coverage(inventory, targets_by_object_id, trusted_omissions) do
    Enum.map(inventory, fn entry ->
      raw_targets =
        targets_by_object_id
        |> Map.get(entry["objectId"], [])

      targets =
        raw_targets
        |> eligible_targets(entry)

      inventory_id = entry["inventoryId"]
      unsupported_reference? = unsupported?(entry) and raw_targets != []

      {status, decision_source} =
        cond do
          targets != [] ->
            {"included", nil}

          unsupported_reference? ->
            {"unaccounted", nil}

          MapSet.member?(trusted_omissions, inventory_id) ->
            {"author_omitted", "author_answer"}

          container?(entry) ->
            {"unaccounted", nil}

          true ->
            {"unaccounted", nil}
        end

      entry
      |> coverage_metadata()
      |> Map.put("status", status)
      |> Map.put("targets", if(unsupported_reference?, do: raw_targets, else: targets))
      |> put_present("decisionSource", decision_source)
    end)
  end

  defp eligible_targets(targets, entry) do
    cond do
      unsupported?(entry) ->
        Enum.filter(targets, &preservation_fallback_target?/1)

      title_placeholder?(entry) ->
        targets

      true ->
        Enum.reject(targets, &(&1["kind"] == "screen_title"))
    end
  end

  defp unsupported?(entry),
    do: entry["suggestedDisposition"] == "unsupported" or entry["fidelity"] == "unsupported"

  defp preservation_fallback_target?(%{"kind" => "part", "key" => key})
       when is_binary(key),
       do: String.starts_with?(key, "preserved-source-")

  defp preservation_fallback_target?(_target), do: false

  defp title_placeholder?(entry) do
    placeholder_type =
      case entry["summary"] do
        summary when is_map(summary) -> summary["placeholderType"]
        _summary -> nil
      end

    placeholder_type =
      placeholder_type || entry["placeholderType"]

    placeholder_type in ["TITLE", "CENTERED_TITLE", "title", "centered_title"]
  end

  defp coverage_metadata(entry) do
    entry
    |> Map.take([
      "inventoryId",
      "slideId",
      "objectId",
      "objectIdSource",
      "parentObjectId",
      "depth",
      "order",
      "path",
      "sourceType",
      "suggestedDisposition",
      "fidelity",
      "reviewRequired",
      "summary",
      "geometry"
    ])
  end

  defp account_for_containers(coverage, inventory) do
    coverage_by_id = Map.new(coverage, &{&1["inventoryId"], &1})
    entries_by_id = Map.new(inventory, &{&1["inventoryId"], &1})
    children_by_parent = Enum.group_by(inventory, & &1["parentObjectId"])

    Enum.map(coverage, fn entry ->
      source_entry = Map.fetch!(entries_by_id, entry["inventoryId"])

      case container?(source_entry) do
        true ->
          descendants =
            descendant_ids(source_entry["objectId"], children_by_parent, MapSet.new())

          descendant_coverage =
            descendants
            |> Enum.map(&Map.get(coverage_by_id, &1))
            |> Enum.reject(&is_nil/1)

          targets =
            descendant_coverage
            |> Enum.flat_map(&(&1["targets"] || []))
            |> Enum.uniq()

          leaf_coverage =
            Enum.reject(descendant_coverage, &container_coverage?/1)

          status =
            case Enum.any?(leaf_coverage, &(&1["status"] == "unaccounted")) do
              true -> "unaccounted"
              false -> "included"
            end

          entry
          |> Map.put("status", status)
          |> Map.put("targets", targets)
          |> Map.put("coverageMode", "descendants")
          |> Map.put("appliedDisposition", "decomposed_children")

        false ->
          entry
      end
    end)
  end

  defp descendant_ids(parent_object_id, children_by_parent, visited) do
    children =
      children_by_parent
      |> Map.get(parent_object_id, [])
      |> Enum.reject(&MapSet.member?(visited, &1["inventoryId"]))

    Enum.flat_map(children, fn child ->
      visited = MapSet.put(visited, child["inventoryId"])

      [child["inventoryId"] | descendant_ids(child["objectId"], children_by_parent, visited)]
    end)
  end

  defp container?(entry) when is_map(entry) do
    entry["container"] == true or entry["sourceType"] == "group"
  end

  defp container?(_entry), do: false

  defp remove_generated_blockers(plan) do
    Map.update(plan, "blockers", [], fn blockers ->
      Enum.reject(List.wrap(blockers), &(&1["code"] == @blocker_code))
    end)
  end

  defp remove_stale_omission_warnings(plan, coverage) do
    omitted_targets =
      coverage
      |> Enum.filter(&(&1["status"] == "author_omitted"))
      |> MapSet.new(&"inventory:#{&1["inventoryId"]}")

    Map.update(plan, "warnings", [], fn warnings ->
      Enum.reject(List.wrap(warnings), fn warning ->
        warning["code"] == @omission_warning_code and
          not MapSet.member?(omitted_targets, warning["target"])
      end)
    end)
  end

  defp add_coverage_blockers(plan, coverage) do
    coverage
    |> Enum.reject(&container_coverage?/1)
    |> Enum.filter(&(&1["status"] == "unaccounted"))
    |> Enum.reduce(plan, fn entry, acc ->
      inventory_id = entry["inventoryId"]

      LessonPlan.put_blocker(acc, %{
        "key" => "#{@blocker_code}:inventory:#{inventory_id}",
        "code" => @blocker_code,
        "target" => "inventory:#{inventory_id}",
        "message" => "Should this slide content be kept in the imported lesson?",
        "sourceRefs" => [coverage_source_ref(entry)],
        "details" =>
          Map.take(entry, [
            "inventoryId",
            "slideId",
            "objectId",
            "sourceType",
            "summary",
            "geometry",
            "suggestedDisposition",
            "fidelity",
            "reviewRequired"
          ])
      })
    end)
  end

  defp container_coverage?(entry) do
    entry["coverageMode"] == "descendants" or entry["sourceType"] == "group"
  end

  defp coverage_label(entry) do
    case entry["summary"] do
      summary when is_binary(summary) and summary != "" ->
        summary

      %{"text" => text} when is_binary(text) and text != "" ->
        text

      %{"label" => label} when is_binary(label) and label != "" ->
        label

      _summary ->
        "the #{entry["sourceType"] || "source"} element"
    end
  end

  defp coverage_source_ref(entry) do
    %{
      "slideId" => entry["slideId"],
      "objectId" => entry["objectId"],
      "evidence" => coverage_label(entry)
    }
  end

  defp enforce_default_colorless_layout(plan) do
    layout = current_layout(plan)
    style_rules = sanitize_style_rules(layout["styleRules"])

    updated_layout =
      layout
      |> Map.put("styleProfile", "torus-default")
      |> Map.put("styleRules", style_rules)

    plan
    |> put_in(["lesson", "layout"], updated_layout)
    |> Map.update("blockers", [], fn blockers ->
      Enum.reject(List.wrap(blockers), &(&1["code"] == "style_profile_confirmation"))
    end)
  end

  defp sanitize_style_rules(rules) do
    rules
    |> List.wrap()
    |> Enum.flat_map(fn
      rule when is_map(rule) ->
        declarations =
          rule
          |> Map.get("declarations", %{})
          |> case do
            values when is_map(values) ->
              Map.reject(values, fn {property, _value} ->
                color_property?(property)
              end)

            _values ->
              %{}
          end

        case map_size(declarations) do
          0 -> []
          _count -> [Map.put(rule, "declarations", declarations)]
        end

      _rule ->
        []
    end)
  end

  defp color_property?(property) do
    normalized =
      property
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized == "color" or String.ends_with?(normalized, "-color")
  end

  defp add_colors_not_imported_warning(plan) do
    LessonPlan.put_warning(plan, %{
      "key" => @colors_warning_key,
      "code" => "source_colors_not_imported",
      "target" => "lesson:layout",
      "message" =>
        "Slide theme, text, border, and background colors were intentionally not imported; Torus defaults will be used.",
      "sourceRefs" => []
    })
  end

  defp finalize_or_validate(plan) do
    case plan["blockers"] do
      [] ->
        plan
        |> Map.put("status", "draft")
        |> LessonPlan.finalize()

      blockers when is_list(blockers) ->
        plan
        |> Map.put("status", "draft")
        |> LessonPlan.validate()

      _blockers ->
        {:error, :invalid_lesson_plan_blockers}
    end
  end

  defp current_layout(plan) do
    get_in(plan, ["lesson", "layout"]) || %{}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp fidelity_errors({:source_inventory_exceeds_limits, count}) do
    [
      error(
        "sourceSnapshot.inventoryAccounting.omitted",
        "source_inventory_truncated",
        "#{count} source inventory elements were omitted by snapshot limits"
      )
    ]
  end

  defp fidelity_errors({:invalid_source_inventory, index, reason}) do
    [
      error(
        "sourceSnapshot.sourceInventory[#{index}]",
        "invalid_source_inventory",
        "source inventory entry is invalid: #{reason}"
      )
    ]
  end

  defp fidelity_errors(:duplicate_source_inventory_id) do
    [
      error(
        "sourceSnapshot.sourceInventory",
        "duplicate_source_inventory_id",
        "source inventory identifiers must be unique"
      )
    ]
  end

  defp fidelity_errors(:duplicate_source_object_id) do
    [
      error(
        "sourceSnapshot.sourceInventory",
        "duplicate_source_object_id",
        "source inventory object identifiers must be unique"
      )
    ]
  end

  defp fidelity_errors(:invalid_source_inventory) do
    [
      error(
        "sourceSnapshot.slides",
        "invalid_source_inventory",
        "source snapshot slides and inventories are invalid"
      )
    ]
  end

  defp fidelity_errors(:invalid_inventory_accounting) do
    [
      error(
        "sourceSnapshot.inventoryAccounting",
        "invalid_inventory_accounting",
        "source inventory accounting is invalid"
      )
    ]
  end

  defp fidelity_errors(_reason) do
    [error("sourceCoverage", "invalid_source_fidelity", "source fidelity validation failed")]
  end

  defp error(path, code, message) do
    %{"path" => path, "code" => code, "message" => message}
  end
end
