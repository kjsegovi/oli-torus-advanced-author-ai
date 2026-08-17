defmodule Oli.OpenStax.CourseImport.AdvancedPlanV6 do
  @moduledoc """
  Schema 6 contract for source-faithful Advanced Author Explorations.

  Source AST hydration remains deterministic. Models may organize source block
  ids, stages, and activity slots, but may not rewrite source content or author
  Torus rules.
  """

  alias Oli.OpenStax.CourseImport.BasicPlanV5

  @schema_version 6
  @roles ~w(orientation prediction investigation evidence interpretation transfer synthesis)
  @required_roles ~w(orientation prediction interpretation transfer synthesis)
  @activity_types ~w(multiple_choice dropdown slider number_input short_answer reflection)
  @minimum_minutes 45
  @maximum_minutes 75

  @type finding :: %{required(String.t()) => term()}

  @spec build_architecture(map(), map(), pos_integer()) :: {:ok, map()} | {:error, [finding()]}
  def build_architecture(candidate, lesson, lesson_index)
      when is_map(candidate) and is_map(lesson) and is_integer(lesson_index) and lesson_index > 0 do
    candidate = candidate_content(candidate)
    base_candidate = Map.put(candidate, "question_slots", [])

    with {:ok, base} <- BasicPlanV5.build(base_candidate, lesson, lesson_index),
         {:ok, blueprint} <-
           normalize_architecture(candidate["experience_blueprint"], base, lesson) do
      {:ok,
       base
       |> Map.put("schema_version", @schema_version)
       |> Map.put("authoring_mode", "advanced")
       |> Map.put("question_slots", [])
       |> Map.put("experience_blueprint", blueprint)
       |> Map.put("advanced_v6_contract", %{
         "source_ast_authority" => "deterministic_extractor",
         "rule_authority" => "deterministic_compiler",
         "activity_authority" => "reviewed_activity_writer",
         "minimum_minutes" => @minimum_minutes,
         "maximum_minutes" => @maximum_minutes
       })}
    end
  end

  def build_architecture(_candidate, _lesson, _lesson_index),
    do: {:error, [finding("invalid_advanced_candidate", "$", "Return one JSON object.")]}

  @spec attach_activities(map(), map(), map()) :: {:ok, map()} | {:error, [finding()]}
  def attach_activities(content, candidate, lesson)
      when is_map(content) and is_map(candidate) and is_map(lesson) do
    candidate = candidate_content(candidate)
    blueprint = content["experience_blueprint"] || %{}
    slots = List.wrap(blueprint["activity_slots"])

    activities =
      (candidate["activities"] || candidate["adaptive_activities"])
      |> normalize_maps()
      |> Enum.map(&put_response_contract/1)

    findings = validate_activities(activities, slots, content, lesson)

    case findings do
      [] ->
        activity_by_slot = Map.new(activities, &{&1["slot_id"], &1})

        stages =
          blueprint
          |> Map.get("stages", [])
          |> Enum.map(fn stage ->
            items =
              stage
              |> Map.get("items", [])
              |> Enum.map(fn
                %{"kind" => "activity_slot", "ref_id" => slot_id} ->
                  activity = Map.fetch!(activity_by_slot, slot_id)
                  %{"kind" => "activity", "ref_id" => activity["id"]}

                item ->
                  item
              end)

            Map.put(stage, "items", items)
          end)

        duration = duration_manifest(content, slots)

        remediation_paths =
          Enum.map(activities, fn activity ->
            %{
              "from_activity_id" => activity["id"],
              "to_content_group_id" => activity["remediation_content_group_id"]
            }
          end)

        {:ok,
         Map.put(
           content,
           "experience_blueprint",
           blueprint
           |> Map.put("stages", stages)
           |> Map.put("activities", activities)
           |> Map.put("duration_manifest", duration)
           |> Map.put("estimated_minutes", duration["total_minutes"])
           |> Map.put("remediation_paths", remediation_paths)
         )}

      findings ->
        {:error, findings}
    end
  end

  def attach_activities(_content, _candidate, _lesson),
    do: {:error, [finding("invalid_activity_candidate", "$", "Return one activity set.")]}

  @spec prompt_contract(map()) :: map()
  def prompt_contract(lesson) do
    BasicPlanV5.prompt_contract(lesson)
    |> Map.put("schema_version", @schema_version)
    |> Map.put("allowed_stage_roles", @roles)
    |> Map.put("required_experience_roles", @required_roles)
    |> Map.put("allowed_activity_types", @activity_types)
    |> Map.put("duration_range_minutes", [@minimum_minutes, @maximum_minutes])
  end

  @spec valid?(map()) :: boolean()
  def valid?(%{"schema_version" => @schema_version, "authoring_mode" => "advanced"} = content) do
    blueprint = content["experience_blueprint"] || %{}

    is_binary(blueprint["driving_question"]) and List.wrap(blueprint["stages"]) != [] and
      List.wrap(blueprint["activities"]) != [] and
      get_in(blueprint, ["duration_manifest", "total_minutes"]) in @minimum_minutes..@maximum_minutes
  end

  def valid?(_content), do: false

  defp normalize_architecture(raw, base, lesson) when is_map(raw) do
    groups = List.wrap(base["content_groups"])
    group_ids = groups |> Enum.map(& &1["id"]) |> MapSet.new()

    objective_ids =
      base |> Map.get("objective_catalog", []) |> Enum.map(& &1["id"]) |> MapSet.new()

    source_ids = BasicPlanV5.source_blocks(lesson) |> Enum.map(& &1["id"]) |> MapSet.new()
    stages = normalize_stages(raw["stages"])
    slots = normalize_slots(raw["activity_slots"])

    findings =
      []
      |> maybe_finding(
        not present?(raw["driving_question"]),
        "missing_driving_question",
        "$",
        "Add one source-grounded driving question."
      )
      |> Kernel.++(validate_stages(stages, group_ids, slots))
      |> Kernel.++(validate_slots(slots, group_ids, objective_ids, source_ids))
      |> Kernel.++(validate_group_stage_coverage(stages, group_ids))

    case findings do
      [] ->
        duration = duration_manifest(base, slots)

        if duration["total_minutes"] in @minimum_minutes..@maximum_minutes do
          {:ok,
           %{
             "driving_question" => String.trim(raw["driving_question"]),
             "stages" => stages,
             "activity_slots" => slots,
             "activities" => [],
             "enrichment_references" => [],
             "duration_manifest" => duration,
             "estimated_minutes" => duration["total_minutes"],
             "remediation_paths" => []
           }}
        else
          {:error,
           [
             finding(
               "advanced_duration_out_of_range",
               "$.experience_blueprint",
               "The deterministic experience estimate is #{duration["total_minutes"]} minutes; Advanced requires 45–75 without padding."
             )
           ]}
        end

      findings ->
        {:error, findings}
    end
  end

  defp normalize_architecture(_raw, _base, _lesson),
    do:
      {:error,
       [
         finding(
           "missing_experience_blueprint",
           "$.experience_blueprint",
           "Return a complete Advanced experience blueprint."
         )
       ]}

  defp normalize_stages(values) do
    values
    |> normalize_maps()
    |> Enum.with_index(1)
    |> Enum.map(fn {stage, index} ->
      %{
        "id" => present(stage["id"]) || "stage-#{index}",
        "title" => present(stage["title"]) || "Exploration stage #{index}",
        "purpose" => present(stage["purpose"]) || "Advance the central investigation.",
        "roles" => normalize_strings(stage["roles"] || [stage["role"]]),
        "items" =>
          stage["items"]
          |> normalize_maps()
          |> Enum.map(&Map.take(&1, ~w(kind ref_id)))
      }
    end)
  end

  defp normalize_slots(values) do
    values
    |> normalize_maps()
    |> Enum.with_index(1)
    |> Enum.map(fn {slot, index} ->
      %{
        "id" => present(slot["id"]) || "activity-slot-#{index}",
        "stage_id" => present(slot["stage_id"]),
        "purpose" => present(slot["purpose"]),
        "objective_ids" => normalize_strings(slot["objective_ids"]),
        "evidence_block_ids" => normalize_strings(slot["evidence_block_ids"]),
        "recommended_types" => normalize_strings(slot["recommended_types"]),
        "remediation_content_group_id" => present(slot["remediation_content_group_id"]),
        "estimated_minutes" => numeric_minutes(slot["estimated_minutes"])
      }
    end)
  end

  defp validate_stages(stages, group_ids, slots) do
    stage_ids = Enum.map(stages, & &1["id"])
    slot_ids = slots |> Enum.map(& &1["id"]) |> MapSet.new()
    roles = stages |> Enum.flat_map(& &1["roles"]) |> MapSet.new()

    []
    |> maybe_finding(
      stages == [],
      "missing_stages",
      "$.experience_blueprint.stages",
      "Add a coherent sequence of Exploration stages."
    )
    |> maybe_finding(
      length(stage_ids) != length(Enum.uniq(stage_ids)),
      "duplicate_stage_ids",
      "$.experience_blueprint.stages",
      "Give each stage a stable unique id."
    )
    |> maybe_finding(
      not Enum.all?(@required_roles, &MapSet.member?(roles, &1)),
      "incomplete_experience_arc",
      "$.experience_blueprint.stages",
      "Cover orientation, prediction, interpretation, transfer, and synthesis across the stage sequence."
    )
    |> Kernel.++(
      stages
      |> Enum.with_index()
      |> Enum.flat_map(fn {stage, index} ->
        path = "$.experience_blueprint.stages[#{index}]"

        []
        |> maybe_finding(
          stage["roles"] == [] or Enum.any?(stage["roles"], &(&1 not in @roles)),
          "invalid_stage_roles",
          path,
          "Use only supported Advanced stage roles."
        )
        |> maybe_finding(
          stage["items"] == [],
          "empty_stage",
          path,
          "Every stage needs source content or an activity."
        )
        |> Kernel.++(
          Enum.flat_map(stage["items"], fn item ->
            case item do
              %{"kind" => "content_group", "ref_id" => id} ->
                if MapSet.member?(group_ids, id),
                  do: [],
                  else: [
                    finding(
                      "unknown_content_group",
                      path,
                      "Stage references an unknown content group."
                    )
                  ]

              %{"kind" => "activity_slot", "ref_id" => id} ->
                if MapSet.member?(slot_ids, id),
                  do: [],
                  else: [
                    finding(
                      "unknown_activity_slot",
                      path,
                      "Stage references an unknown activity slot."
                    )
                  ]

              _ ->
                [
                  finding(
                    "invalid_stage_item",
                    path,
                    "Stage items must reference a content group or activity slot."
                  )
                ]
            end
          end)
        )
      end)
    )
  end

  defp validate_slots(slots, group_ids, objective_ids, source_ids) do
    slot_ids = Enum.map(slots, & &1["id"])

    []
    |> maybe_finding(
      slots == [],
      "missing_activity_slots",
      "$.experience_blueprint.activity_slots",
      "A full Exploration needs source-grounded learner activity."
    )
    |> maybe_finding(
      length(slot_ids) != length(Enum.uniq(slot_ids)),
      "duplicate_activity_slot_ids",
      "$.experience_blueprint.activity_slots",
      "Give each activity slot a stable unique id."
    )
    |> Kernel.++(
      slots
      |> Enum.with_index()
      |> Enum.flat_map(fn {slot, index} ->
        path = "$.experience_blueprint.activity_slots[#{index}]"

        []
        |> maybe_finding(
          not present?(slot["purpose"]),
          "missing_activity_purpose",
          path,
          "Describe the learner work performed in this slot."
        )
        |> maybe_finding(
          slot["objective_ids"] == [] or
            Enum.any?(slot["objective_ids"], &(not MapSet.member?(objective_ids, &1))),
          "invalid_activity_objectives",
          path,
          "Map the slot only to server-issued objective ids."
        )
        |> maybe_finding(
          slot["evidence_block_ids"] == [] or
            Enum.any?(slot["evidence_block_ids"], &(not MapSet.member?(source_ids, &1))),
          "invalid_activity_evidence",
          path,
          "Cite source blocks that directly support this activity."
        )
        |> maybe_finding(
          slot["recommended_types"] == [] or
            Enum.any?(slot["recommended_types"], &(&1 not in @activity_types)),
          "invalid_activity_types",
          path,
          "Recommend only supported interaction types."
        )
        |> maybe_finding(
          not MapSet.member?(group_ids, slot["remediation_content_group_id"]),
          "invalid_remediation_group",
          path,
          "Remediation must return to an existing content group."
        )
        |> maybe_finding(
          slot["estimated_minutes"] not in 4..20,
          "invalid_activity_duration",
          path,
          "Estimate 4–20 minutes of genuine learner work for the slot."
        )
      end)
    )
  end

  defp validate_group_stage_coverage(stages, group_ids) do
    references =
      stages
      |> Enum.flat_map(& &1["items"])
      |> Enum.filter(&(&1["kind"] == "content_group"))
      |> Enum.map(& &1["ref_id"])

    referenced = MapSet.new(references)

    []
    |> maybe_finding(
      length(references) != length(Enum.uniq(references)),
      "duplicate_content_group_reference",
      "$.experience_blueprint.stages",
      "Reference each source content group exactly once."
    )
    |> maybe_finding(
      referenced != group_ids,
      "incomplete_content_group_reference",
      "$.experience_blueprint.stages",
      "Place every source content group exactly once in the Exploration."
    )
  end

  defp validate_activities(activities, slots, content, lesson) do
    slot_ids = slots |> Enum.map(& &1["id"]) |> MapSet.new()
    group_ids = content |> Map.get("content_groups", []) |> Enum.map(& &1["id"]) |> MapSet.new()

    objective_ids =
      content |> Map.get("objective_catalog", []) |> Enum.map(& &1["id"]) |> MapSet.new()

    source_ids = BasicPlanV5.source_blocks(lesson) |> Enum.map(& &1["id"]) |> MapSet.new()
    ids = Enum.map(activities, & &1["id"])
    activity_slots = Enum.map(activities, & &1["slot_id"])

    []
    |> maybe_finding(
      length(activities) != MapSet.size(slot_ids),
      "incomplete_activity_set",
      "$.activities",
      "Create exactly one reviewed activity for every approved slot."
    )
    |> maybe_finding(
      length(ids) != length(Enum.uniq(ids)),
      "duplicate_activity_ids",
      "$.activities",
      "Give each activity a stable unique id."
    )
    |> maybe_finding(
      MapSet.new(activity_slots) != slot_ids,
      "invalid_activity_slot_mapping",
      "$.activities",
      "Fill every approved activity slot exactly once."
    )
    |> Kernel.++(
      activities
      |> Enum.with_index()
      |> Enum.flat_map(fn {activity, index} ->
        path = "$.activities[#{index}]"
        type = activity["interaction_type"]
        choices = normalize_maps(activity["choices"])
        correct_choices = Enum.count(choices, &(&1["correct"] == true))

        []
        |> maybe_finding(
          not present?(activity["id"]) or not MapSet.member?(slot_ids, activity["slot_id"]),
          "invalid_activity_identity",
          path,
          "Use stable ids and an approved slot id."
        )
        |> maybe_finding(
          type not in @activity_types,
          "unsupported_activity_type",
          path,
          "Use a supported Advanced interaction type."
        )
        |> maybe_finding(
          not present?(activity["context"]) or not present?(activity["prompt"]),
          "context_free_activity",
          path,
          "Provide substantive source-grounded context before the prompt."
        )
        |> maybe_finding(
          List.wrap(activity["objective_ids"]) == [] or
            Enum.any?(
              List.wrap(activity["objective_ids"]),
              &(not MapSet.member?(objective_ids, &1))
            ),
          "invalid_activity_objectives",
          path,
          "Map the activity only to server-issued objective ids."
        )
        |> maybe_finding(
          List.wrap(activity["evidence_block_ids"]) == [] or
            Enum.any?(
              List.wrap(activity["evidence_block_ids"]),
              &(not MapSet.member?(source_ids, &1))
            ),
          "invalid_activity_evidence",
          path,
          "Cite evidence that directly answers the activity."
        )
        |> maybe_finding(
          not MapSet.member?(group_ids, activity["remediation_content_group_id"]),
          "invalid_activity_remediation",
          path,
          "Remediation must target an existing content group."
        )
        |> maybe_finding(
          not present?(activity["correct_feedback"]) or
            not present?(activity["incorrect_feedback"]),
          "missing_activity_feedback",
          path,
          "Every scorable path needs correct and default incorrect feedback."
        )
        |> maybe_finding(
          activity["allow_not_sure"] != true or not present?(activity["hint"]),
          "missing_not_sure_support",
          path,
          "Provide a Not sure path with a useful hint."
        )
        |> maybe_finding(
          type in ~w(multiple_choice dropdown) and
            (length(choices) not in 2..6 or correct_choices != 1 or
               Enum.any?(
                 choices,
                 &(not present?(&1["text"]) or
                     (&1["correct"] != true and not present?(&1["feedback"])))
               )),
          "invalid_choice_contract",
          path,
          "Choice activities need one correct option and feedback for every incorrect option."
        )
        |> maybe_finding(
          type in ~w(slider number_input) and not numeric_response?(activity),
          "invalid_numeric_contract",
          path,
          "Numeric activities need a valid correct response and bounds where applicable."
        )
      end)
    )
  end

  defp duration_manifest(content, slots) do
    words =
      content
      |> Map.get("content_groups", [])
      |> Enum.flat_map(&List.wrap(&1["source_blocks"]))
      |> Enum.map_join(" ", &to_string(&1["text"] || ""))
      |> String.split(~r/\s+/u, trim: true)
      |> length()

    reading = ceil_div(words, 180)
    media = content |> Map.get("media", []) |> List.wrap() |> length()
    media_analysis = min(media * 3, 15)

    learner_work =
      slots |> Enum.map(& &1["estimated_minutes"]) |> Enum.filter(&is_integer/1) |> Enum.sum()

    synthesis = 6
    total = reading + media_analysis + learner_work + synthesis

    %{
      "reading_minutes" => reading,
      "media_analysis_minutes" => media_analysis,
      "learner_work_minutes" => learner_work,
      "synthesis_minutes" => synthesis,
      "total_minutes" => total,
      "range" => [@minimum_minutes, @maximum_minutes],
      "strategy" => "deterministic_source_and_activity_estimate"
    }
  end

  defp normalize_maps(values),
    do: values |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.map(&stringify_map/1)

  defp normalize_strings(values) do
    values
    |> List.wrap()
    |> Enum.map(&present/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp numeric_minutes(value) when is_integer(value), do: value
  defp numeric_minutes(value) when is_float(value), do: round(value)

  defp numeric_minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp numeric_minutes(_value), do: 0

  defp numeric_response?(%{"interaction_type" => "number_input"} = activity),
    do: is_number(activity["correct_response"])

  defp numeric_response?(%{"interaction_type" => "slider"} = activity) do
    configuration = activity["configuration"] || %{}
    minimum = configuration["min"]
    maximum = configuration["max"]
    step = configuration["step"]

    is_number(activity["correct_response"]) and is_number(minimum) and is_number(maximum) and
      is_number(step) and minimum < maximum and step > 0 and
      activity["correct_response"] >= minimum and activity["correct_response"] <= maximum
  end

  defp numeric_response?(_activity), do: true

  defp put_response_contract(%{"interaction_type" => type} = activity)
       when type in ["multiple_choice", "dropdown"] do
    choices = normalize_maps(activity["choices"])
    correct = Enum.find(choices, &(&1["correct"] == true))

    Map.put(activity, "response_contract", %{
      "kind" => "single_choice",
      "correct_choice_id" => correct && correct["id"],
      "choice_ids" => Enum.map(choices, & &1["id"])
    })
  end

  defp put_response_contract(%{"interaction_type" => "slider"} = activity) do
    configuration = activity["configuration"] || %{}

    Map.put(activity, "response_contract", %{
      "kind" => "numeric_range",
      "correct_response" => activity["correct_response"],
      "min" => configuration["min"],
      "max" => configuration["max"],
      "step" => configuration["step"]
    })
  end

  defp put_response_contract(%{"interaction_type" => "number_input"} = activity) do
    Map.put(activity, "response_contract", %{
      "kind" => "numeric",
      "correct_response" => activity["correct_response"],
      "units" => get_in(activity, ["configuration", "units"])
    })
  end

  defp put_response_contract(%{"interaction_type" => type} = activity)
       when type in ["short_answer", "reflection"] do
    Map.put(activity, "response_contract", %{
      "kind" => "text",
      "minimum_length" =>
        get_in(activity, ["configuration", "minimum_length"]) || activity["minimum_length"] || 40,
      "must_contain" =>
        get_in(activity, ["configuration", "must_contain"]) || activity["must_contain"] || ""
    })
  end

  defp put_response_contract(activity),
    do: Map.put(activity, "response_contract", %{"kind" => "unsupported"})

  defp candidate_content(%{"content_payload" => %{} = content}), do: content
  defp candidate_content(candidate), do: stringify_map(candidate)

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_map(value), do: stringify_map(value)
  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp maybe_finding(findings, true, code, path, message),
    do: findings ++ [finding(code, path, message)]

  defp maybe_finding(findings, false, _code, _path, _message), do: findings

  defp finding(code, path, message) do
    %{
      "severity" => "hard_blocker",
      "code" => code,
      "path" => path,
      "message" => message
    }
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(nil), do: nil
  defp present(value) when is_atom(value), do: value |> Atom.to_string() |> present()
  defp present(_value), do: nil

  defp present?(value), do: not is_nil(present(value))

  defp ceil_div(value, divisor), do: div(max(value, 0) + divisor - 1, divisor)
end
