defmodule Oli.OpenStax.CourseImport.Checks do
  @moduledoc """
  Deterministic quality gates for the only supported OpenStax lesson contracts:
  Basic and Advanced schema 7.

  This module intentionally contains no legacy schema dispatch or fallback.
  """

  alias Oli.OpenStax.CourseImport.{AdvancedPlanV7, BasicPlanV7}

  @check_types [:source_fidelity, :pedagogy_assessment, :torus_accessibility]
  @current_contracts [{"basic", 7}, {"advanced", 7}]
  @advanced_activity_types ~w(multiple_choice dropdown slider number_input short_answer reflection)

  @type result :: %{
          required(:check_type) => String.t(),
          required(:status) => String.t(),
          required(:findings) => map(),
          required(:repair_plan) => map() | nil
        }

  @spec run(map(), map()) :: [result()]
  def run(
        lesson,
        %{
          "content_payload" => %{
            "schema_version" => schema,
            "authoring_mode" => mode
          }
        } = plan
      )
      when is_map(lesson) and {mode, schema} in @current_contracts do
    Enum.map(@check_types, &run_check(&1, lesson, plan))
  end

  def run(_lesson, _plan) do
    Enum.map(@check_types, fn check_type ->
      result(
        check_type,
        ["Only the Basic and Advanced schema 7 lesson contracts are supported"],
        %{
          "supported_contracts" => [
            %{"authoring_mode" => "basic", "schema_version" => 7},
            %{"authoring_mode" => "advanced", "schema_version" => 7}
          ]
        }
      )
    end)
  end

  @spec passed?([result()]) :: boolean()
  def passed?(results) when is_list(results),
    do: results != [] and Enum.all?(results, &(&1.status == "passed"))

  defp run_check(:source_fidelity, lesson, %{"content_payload" => content}) do
    available_ids =
      lesson
      |> BasicPlanV7.source_blocks()
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    groups = content_maps(content, "content_groups")
    grouped_ids = Enum.flat_map(groups, &List.wrap(&1["source_block_ids"]))
    grouped_set = MapSet.new(grouped_ids)
    duplicate_ids = (grouped_ids -- Enum.uniq(grouped_ids)) |> Enum.uniq()
    coverage = content["coverage_manifest"] || %{}

    missing_ast =
      groups
      |> Enum.flat_map(&content_maps(&1, "source_blocks"))
      |> Enum.filter(&(not is_list(&1["ast"]) or &1["ast"] == []))
      |> Enum.map(& &1["id"])

    declared_available = MapSet.new(List.wrap(coverage["available_source_block_ids"]))
    declared_included = MapSet.new(List.wrap(coverage["included_source_block_ids"]))

    failures =
      []
      |> maybe_add(available_ids == MapSet.new(), "The lesson has no extracted source AST")
      |> maybe_add(
        grouped_set != available_ids,
        "Every extracted source block must appear in exactly one content group"
      )
      |> maybe_add(duplicate_ids != [], "A source block appears in more than one content group")
      |> maybe_add(missing_ast != [], "Every content block must retain its Torus-safe AST")
      |> maybe_add(
        coverage["strategy"] != "exact_ast_coverage",
        "Current OpenStax schemas require exact AST coverage"
      )
      |> maybe_add(coverage["complete"] != true, "Source coverage must be explicitly complete")
      |> maybe_add(
        declared_available != available_ids or declared_included != available_ids,
        "The coverage manifest must match the exact extracted source block set"
      )
      |> maybe_add(
        List.wrap(coverage["missing_source_block_ids"]) != [],
        "The coverage manifest reports missing source blocks"
      )
      |> maybe_add(
        List.wrap(coverage["duplicate_source_block_ids"]) != [],
        "The coverage manifest reports duplicate source blocks"
      )

    evaluation = %{
      "strategy" => "exact_ast_coverage",
      "available_block_count" => MapSet.size(available_ids),
      "covered_block_count" => MapSet.size(grouped_set),
      "missing_ast_block_ids" => missing_ast,
      "missing_block_ids" => MapSet.difference(available_ids, grouped_set) |> MapSet.to_list(),
      "unknown_block_ids" => MapSet.difference(grouped_set, available_ids) |> MapSet.to_list(),
      "duplicate_block_ids" => duplicate_ids
    }

    case failures do
      [] ->
        %{
          check_type: "source_fidelity",
          status: "passed",
          findings: %{"issues" => [], "evaluation" => %{"coverage" => evaluation}},
          repair_plan: nil
        }

      failures ->
        %{
          check_type: "source_fidelity",
          status: "failed",
          findings: %{
            "issues" => Enum.reverse(failures),
            "evaluation" => %{"coverage" => evaluation}
          },
          repair_plan: %{"rerun_current_source_pipeline" => true}
        }
    end
  end

  defp run_check(
         :pedagogy_assessment,
         _lesson,
         %{"content_payload" => %{"schema_version" => 7, "authoring_mode" => "basic"} = content} =
           plan
       ) do
    objectives = List.wrap(content["learning_objectives"])
    groups = content_maps(content, "content_groups")
    slots = content_maps(content, "question_slots")
    questions = questions(plan)
    slot_placements = slots |> Enum.map(& &1["placement_after_section_id"]) |> MapSet.new()
    quality = quality_gate(plan)

    failures =
      []
      |> maybe_add(
        content["authoring_mode"] != "basic",
        "Schema 7 Basic content must use Basic Author mode"
      )
      |> maybe_add(
        objectives == [] or Enum.any?(objectives, &(not present?(&1))),
        "Preserve at least one source-faithful learning objective"
      )
      |> maybe_add(
        groups == [] or
          Enum.any?(
            groups,
            &(not present?(&1["title"]) or List.wrap(&1["source_block_ids"]) == [])
          ),
        "Every Basic content group needs a descriptive heading and source blocks"
      )
      |> maybe_add(length(questions) > 10, "Limit Basic formative questions to ten")
      |> maybe_add(
        slots == [] and questions != [],
        "Do not insert checkpoints when the architect identified no genuine boundary"
      )
      |> maybe_add(
        Enum.any?(
          questions,
          &(not MapSet.member?(slot_placements, &1["placement_after_section_id"]))
        ),
        "Place every Basic question in an architect-approved question slot"
      )
      |> maybe_add(
        Enum.any?(questions, &invalid_basic_question?/1),
        "Every Basic question must have a valid response contract"
      )
      |> quality_failures(quality, "Basic v7")

    result(:pedagogy_assessment, failures, %{
      "organization" => "content_groups",
      "fixed_section_quota" => false,
      "fixed_word_quota" => false,
      "fixed_question_quota" => false,
      "critic_confidence_threshold" => 0.9
    })
  end

  defp run_check(
         :pedagogy_assessment,
         _lesson,
         %{
           "content_payload" => %{"schema_version" => 7, "authoring_mode" => "advanced"} = content
         } = plan
       ) do
    blueprint = content["experience_blueprint"] || %{}
    activities = content_maps(blueprint, "activities")
    stages = content_maps(blueprint, "stages")
    duration = get_in(blueprint, ["duration_manifest", "total_minutes"])
    stage_activity_ids = stage_references(stages, "activity")
    activity_ids = Enum.map(activities, & &1["id"])

    failures =
      []
      |> maybe_add(
        not AdvancedPlanV7.valid?(content),
        "The Advanced schema 7 experience blueprint is incomplete"
      )
      |> maybe_add(duration not in 45..75, "Advanced duration must be an honest 45–75 minutes")
      |> maybe_add(stages == [], "Advanced lessons require a coherent stage flow")
      |> maybe_add(activities == [], "Advanced lessons require substantive learner work")
      |> maybe_add(
        stage_activity_ids != activity_ids,
        "Every Advanced activity must be referenced exactly once in stage order"
      )
      |> maybe_add(
        length(activity_ids) != length(Enum.uniq(activity_ids)),
        "Advanced activity ids must be unique"
      )
      |> maybe_add(
        Enum.any?(activities, &invalid_advanced_activity?/1),
        "Every Advanced activity must have a complete source-grounded response contract"
      )
      |> maybe_add(
        List.wrap(get_in(plan, ["questions_payload", "items"])) != [],
        "Advanced schema 7 activities must exist only inside experience_blueprint"
      )
      |> quality_failures(quality_gate(plan), "Advanced v7")

    result(:pedagogy_assessment, failures, %{
      "organization" => "experience_blueprint",
      "duration_minutes" => duration,
      "fixed_screen_quota" => false,
      "activity_count" => length(activities),
      "critic_confidence_threshold" => 0.9
    })
  end

  defp run_check(:torus_accessibility, _lesson, %{"content_payload" => content} = plan) do
    mode = content["authoring_mode"]
    media = all_media(content)
    activities = get_in(content, ["experience_blueprint", "activities"]) |> List.wrap()

    failures =
      []
      |> maybe_add(not present?(content["title"]), "Add a descriptive lesson title")
      |> maybe_add(
        not present?(get_in(content, ["orientation", "overview"])),
        "Add a compact source-faithful orientation"
      )
      |> maybe_add(
        Enum.any?(
          media,
          &(not present?(&1["source_media_id"] || &1["id"]) or
              not present?(&1["alt"] || &1["alt_text"]))
        ),
        "Every retained figure needs a server-issued id and useful source or critic-approved alt text"
      )
      |> maybe_add(
        Enum.any?(
          media,
          &(&1["required"] == true and &1["rights_status"] in ["blocked", "conflicted"])
        ),
        "Required media cannot have blocked or conflicted rights"
      )
      |> maybe_add(
        mode == "basic" and duplicate_ids?(questions(plan)),
        "Give each Basic question a stable unique id"
      )
      |> maybe_add(
        mode == "advanced" and
          Enum.any?(activities, &(not present?(&1["hint"]) or &1["allow_not_sure"] != true)),
        "Every Advanced activity needs an accessible Not sure path and hint"
      )
      |> maybe_add(
        mode == "advanced" and
          Enum.any?(activities, &(not present?(&1["incorrect_feedback"]))),
        "Every Advanced interaction needs a default incorrect response"
      )

    result(:torus_accessibility, failures, %{
      "supported_contract" => if(mode == "advanced", do: "advanced_v7", else: "basic_v7"),
      "required_feedback_paths" => ["correct", "default_incorrect", "not_sure"],
      "regression" => "could_not_find_incorrect_response"
    })
  end

  defp quality_failures(failures, quality, label) do
    failures
    |> maybe_add(
      quality["approved"] != true,
      "The #{label} critics must explicitly approve the lesson"
    )
    |> maybe_add(
      numeric_value(quality["confidence"]) < 0.9,
      "The #{label} critic confidence must be at least 0.90"
    )
    |> maybe_add(
      List.wrap(quality["hard_blockers"]) != [],
      "Resolve every #{label} hard blocker before approval"
    )
    |> maybe_add(
      List.wrap(quality["repairs"]) != [],
      "Resolve every #{label} repair finding before approval"
    )
  end

  defp invalid_basic_question?(%{"type" => "multiple_choice"} = question) do
    choices = List.wrap(question["choices"])
    correct_id = question["correct_choice_id"]

    length(choices) not in 2..6 or not present?(correct_id) or
      Enum.count(choices, &(&1["correct"] == true or &1["id"] == correct_id)) != 1 or
      Enum.any?(choices, &(not is_map(&1) or not present?(&1["text"])))
  end

  defp invalid_basic_question?(%{"type" => "short_answer"} = question) do
    question["response_kind"] not in [nil, "reflection", "application"] or
      normalize_strings(question["answer_keywords"]) == []
  end

  defp invalid_basic_question?(_question), do: true

  defp invalid_advanced_activity?(activity) when is_map(activity) do
    type = activity["interaction_type"]
    choices = List.wrap(activity["choices"])

    common_invalid? =
      not present?(activity["id"]) or type not in @advanced_activity_types or
        not present?(activity["context"]) or not present?(activity["prompt"]) or
        not is_map(activity["response_contract"]) or
        List.wrap(activity["objective_ids"]) == [] or
        List.wrap(activity["evidence_block_ids"]) == [] or
        not present?(activity["remediation_content_group_id"]) or
        not present?(activity["correct_feedback"]) or
        not present?(activity["incorrect_feedback"]) or activity["allow_not_sure"] != true or
        not present?(activity["hint"])

    response_invalid? =
      case type do
        choice_type when choice_type in ["multiple_choice", "dropdown"] ->
          length(choices) not in 2..6 or Enum.count(choices, &(&1["correct"] == true)) != 1 or
            Enum.any?(choices, fn choice ->
              not is_map(choice) or not present?(choice["id"]) or not present?(choice["text"]) or
                (choice["correct"] != true and not present?(choice["feedback"]))
            end)

        "number_input" ->
          not is_number(activity["correct_response"])

        "slider" ->
          config = activity["configuration"] || %{}

          not is_number(activity["correct_response"]) or not is_number(config["min"]) or
            not is_number(config["max"]) or not is_number(config["step"]) or
            config["min"] >= config["max"] or config["step"] <= 0 or
            activity["correct_response"] < config["min"] or
            activity["correct_response"] > config["max"]

        _ ->
          false
      end

    common_invalid? or response_invalid?
  end

  defp invalid_advanced_activity?(_activity), do: true

  defp stage_references(stages, kind) do
    stages
    |> Enum.flat_map(&List.wrap(&1["items"]))
    |> Enum.filter(&(&1["kind"] == kind))
    |> Enum.map(& &1["ref_id"])
  end

  defp all_media(content) do
    content_maps(content, "media") ++
      (content
       |> content_maps("content_groups")
       |> Enum.flat_map(&content_maps(&1, "media")))
  end

  defp content_maps(map, key) when is_map(map) do
    map
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp questions(%{"questions_payload" => %{"items" => items}}) when is_list(items), do: items
  defp questions(_plan), do: []

  defp quality_gate(plan) do
    metadata = plan["generation_metadata"] || plan[:generation_metadata] || %{}
    metadata["quality_gate"] || metadata[:quality_gate] || %{}
  end

  defp duplicate_ids?(items) do
    ids = items |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    length(ids) != length(Enum.uniq(ids))
  end

  defp normalize_strings(values),
    do: values |> List.wrap() |> Enum.filter(&present?/1) |> Enum.uniq()

  defp numeric_value(value) when is_integer(value) or is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp numeric_value(_value), do: 0.0

  defp result(check_type, [], _repair_plan) do
    %{
      check_type: Atom.to_string(check_type),
      status: "passed",
      findings: %{"issues" => []},
      repair_plan: nil
    }
  end

  defp result(check_type, failures, repair_plan) do
    %{
      check_type: Atom.to_string(check_type),
      status: "failed",
      findings: %{"issues" => Enum.reverse(failures)},
      repair_plan: repair_plan
    }
  end

  defp maybe_add(items, true, message), do: [message | items]
  defp maybe_add(items, false, _message), do: items

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
