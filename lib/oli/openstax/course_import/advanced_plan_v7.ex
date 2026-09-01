defmodule Oli.OpenStax.CourseImport.AdvancedPlanV7 do
  @moduledoc """
  Schema 7 contract for source-faithful Advanced Author Explorations.

  Source AST hydration remains deterministic. Models may organize source block
  ids and author source-grounded connective guidance around those immutable
  blocks, stages, and activity slots. They may not rewrite source content or
  author Torus rules, navigation targets, or URLs.
  """

  alias Oli.OpenStax.CourseImport.{BasicPlanV7, ImportContract}

  @schema_version ImportContract.content_schema_version("advanced")
  @roles ~w(orientation prediction investigation observation evidence interpretation transfer synthesis)
  @required_roles ~w(orientation prediction interpretation transfer synthesis)
  @guidance_kinds ~w(prediction observation interpretation transfer synthesis)
  @presentation_patterns ~w(
    guided_reading predict_observe_explain evidence_comparison worked_analysis
    transfer_challenge synthesis_discussion
  )
  @activity_types ~w(multiple_choice dropdown slider number_input short_answer reflection)
  @minimum_minutes 45
  @maximum_minutes 75

  @type finding :: %{required(String.t()) => term()}

  @spec build_architecture(map(), map(), pos_integer()) :: {:ok, map()} | {:error, [finding()]}
  def build_architecture(candidate, lesson, lesson_index)
      when is_map(candidate) and is_map(lesson) and is_integer(lesson_index) and lesson_index > 0 do
    candidate = candidate_content(candidate)
    base_candidate = Map.put(candidate, "question_slots", [])

    with {:ok, base} <- BasicPlanV7.build(base_candidate, lesson, lesson_index),
         {:ok, blueprint} <-
           normalize_architecture(candidate["experience_blueprint"], base, lesson) do
      {:ok,
       base
       |> Map.put("schema_version", @schema_version)
       |> Map.put("authoring_mode", "advanced")
       |> Map.put("question_slots", [])
       |> Map.put("experience_blueprint", blueprint)
       |> Map.put("advanced_v7_contract", %{
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
      |> Enum.map(&normalize_activity_contract/1)
      |> Enum.map(&put_response_contract/1)
      |> apply_slot_remediation_targets(slots)

    branch_sets = List.wrap(blueprint["branch_sets"])

    findings =
      validate_activities(activities, slots, content, lesson) ++
        validate_realized_branch_sets(branch_sets, activities)

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

            native_follow_up_activity_id =
              case stage["native_follow_up_slot_id"] do
                slot_id when is_binary(slot_id) ->
                  activity_by_slot |> Map.get(slot_id, %{}) |> Map.get("id")

                _ ->
                  nil
              end

            stage
            |> Map.put("items", items)
            |> Map.put("native_follow_up_activity_id", native_follow_up_activity_id)
          end)

        duration = duration_manifest(content, slots)

        remediation_paths =
          Enum.map(activities, fn activity ->
            %{
              "from_activity_id" => activity["id"],
              "to_content_group_id" => activity["remediation_content_group_id"]
            }
          end)

        realized_branch_sets = realize_branch_sets(branch_sets, activities)

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
           |> Map.put("branch_sets", realized_branch_sets)
         )}

      findings ->
        {:error, findings}
    end
  end

  def attach_activities(_content, _candidate, _lesson),
    do: {:error, [finding("invalid_activity_candidate", "$", "Return one activity set.")]}

  defp apply_slot_remediation_targets(activities, slots) do
    remediation_by_slot =
      Map.new(slots, &{&1["id"], &1["remediation_content_group_id"]})

    Enum.map(activities, fn activity ->
      case Map.fetch(remediation_by_slot, activity["slot_id"]) do
        {:ok, remediation_content_group_id} ->
          Map.put(activity, "remediation_content_group_id", remediation_content_group_id)

        :error ->
          activity
      end
    end)
  end

  @doc "Returns the compact model-owned architecture candidate for a persisted v7 plan."
  @spec architecture_repair_candidate(map()) :: map()
  def architecture_repair_candidate(content) when is_map(content) do
    blueprint = content["experience_blueprint"] || %{}

    activity_slots_by_id =
      blueprint
      |> Map.get("activities", [])
      |> List.wrap()
      |> Map.new(&{&1["id"], &1["slot_id"]})

    stages =
      blueprint
      |> Map.get("stages", [])
      |> List.wrap()
      |> Enum.map(fn stage ->
        items =
          stage
          |> Map.get("items", [])
          |> List.wrap()
          |> Enum.map(fn
            %{"kind" => "activity", "ref_id" => activity_id} = item ->
              case Map.get(activity_slots_by_id, activity_id) do
                slot_id when is_binary(slot_id) ->
                  %{"kind" => "activity_slot", "ref_id" => slot_id}

                _ ->
                  item
              end

            item ->
              Map.take(item, ~w(kind ref_id))
          end)

        stage
        |> Map.take(
          ~w(id title purpose roles presentation_pattern introduction guidance native_follow_up_slot_id)
        )
        |> Map.put("items", items)
      end)

    slots =
      blueprint
      |> Map.get("activity_slots", [])
      |> List.wrap()
      |> Enum.map(
        &Map.take(
          &1,
          ~w(id stage_id purpose objective_ids evidence_block_ids recommended_types remediation_content_group_id estimated_minutes)
        )
      )

    content
    |> BasicPlanV7.repair_candidate()
    |> Map.put("question_slots", [])
    |> Map.put("experience_blueprint", %{
      "driving_question" => blueprint["driving_question"],
      "stages" => stages,
      "activity_slots" => slots,
      "branch_sets" =>
        blueprint
        |> Map.get("branch_sets", [])
        |> List.wrap()
        |> Enum.map(&Map.drop(&1, ["decision_activity_id"]))
    })
  end

  def architecture_repair_candidate(_content), do: %{}

  @doc "Returns the exact model-owned activity set for a persisted v7 plan."
  @spec activity_repair_candidate(map()) :: map()
  def activity_repair_candidate(content) when is_map(content) do
    %{
      "activities" =>
        content
        |> get_in(["experience_blueprint", "activities"])
        |> List.wrap()
    }
  end

  def activity_repair_candidate(_content), do: %{}

  @spec prompt_contract(map()) :: map()
  def prompt_contract(lesson) do
    BasicPlanV7.prompt_contract(lesson)
    |> Map.put("schema_version", @schema_version)
    |> Map.put("allowed_stage_roles", @roles)
    |> Map.put("required_experience_roles", @required_roles)
    |> Map.put("required_guidance_kinds", @guidance_kinds)
    |> Map.put("allowed_presentation_patterns", @presentation_patterns)
    |> Map.put("connective_material_contract", %{
      "stage_introduction" =>
        "Model-authored transition with body and source evidence block ids; source blocks remain immutable.",
      "guidance" =>
        "Prediction, observation, interpretation, transfer, and synthesis prompts with source evidence block ids.",
      "forbidden" => ["raw Torus rules", "navigation targets", "URLs"]
    })
    |> Map.put("allowed_activity_types", @activity_types)
    |> Map.put("experience_blueprint_schema", %{
      "driving_question" => "string",
      "stages" => [
        %{
          "id" => "string",
          "title" => "string",
          "purpose" => "string",
          "roles" => @roles,
          "presentation_pattern" => "one allowed_presentation_patterns value",
          "introduction" => %{
            "heading" => "string",
            "body" => "string",
            "evidence_block_ids" => ["source block id"]
          },
          "guidance" => [
            %{
              "kind" => "one required_guidance_kinds value",
              "heading" => "string",
              "body" => "string",
              "evidence_block_ids" => ["source block id"]
            }
          ],
          "native_follow_up_slot_id" => "activity slot id from this stage",
          "items" => [%{"kind" => "content_group|activity_slot", "ref_id" => "string"}]
        }
      ],
      "activity_slots" => [
        %{
          "id" => "string",
          "stage_id" => "stage id containing this activity_slot item",
          "purpose" => "learner work performed in this slot",
          "objective_ids" => ["server-issued objective id"],
          "evidence_block_ids" => ["source block id"],
          "recommended_types" => @activity_types,
          "remediation_content_group_id" => "content group id",
          "estimated_minutes" => "integer from 4 through 20"
        }
      ],
      "branch_sets" => [
        %{
          "id" => "string",
          "decision_activity_slot_id" => "multiple_choice or dropdown activity slot id",
          "objective_ids" => ["server-issued objective id"],
          "rejoin_stage_id" => "shared later stage id",
          "pathways" => [
            %{
              "choice_id" => "choice id the activity writer must preserve",
              "label" => "learner-facing pathway label",
              "target_content_group_id" => "content group shown for this choice",
              "feedback" => "source-grounded transition into the pathway",
              "evidence_block_ids" => ["source block id"]
            }
          ]
        }
      ]
    })
    |> Map.put("duration_range_minutes", [@minimum_minutes, @maximum_minutes])
  end

  @spec valid?(map()) :: boolean()
  def valid?(%{"schema_version" => @schema_version, "authoring_mode" => "advanced"} = content) do
    blueprint = content["experience_blueprint"] || %{}

    is_binary(blueprint["driving_question"]) and rich_stages?(blueprint["stages"]) and
      List.wrap(blueprint["activities"]) != [] and
      List.wrap(blueprint["branch_sets"]) != [] and
      get_in(blueprint, ["duration_manifest", "total_minutes"]) in @minimum_minutes..@maximum_minutes
  end

  def valid?(_content), do: false

  defp normalize_architecture(raw, base, lesson) when is_map(raw) do
    groups = List.wrap(base["content_groups"])
    group_ids = groups |> Enum.map(& &1["id"]) |> MapSet.new()

    objective_ids =
      base |> Map.get("objective_catalog", []) |> Enum.map(& &1["id"]) |> MapSet.new()

    source_ids = BasicPlanV7.source_blocks(lesson) |> Enum.map(& &1["id"]) |> MapSet.new()
    stages = normalize_stages(raw["stages"])
    slots = normalize_slots(raw["activity_slots"], stages)
    branch_sets = normalize_branch_sets(raw["branch_sets"])
    duration = duration_manifest(base, slots, stages)

    findings =
      []
      |> maybe_finding(
        not present?(raw["driving_question"]),
        "missing_driving_question",
        "$",
        "Add one source-grounded driving question."
      )
      |> maybe_finding(
        contains_forbidden_authoring_material?(raw),
        "forbidden_advanced_authoring_material",
        "$.experience_blueprint",
        "Use only high-level instructional intent; do not author rules, navigation targets, or URLs."
      )
      |> Kernel.++(validate_stages(stages, group_ids, slots, source_ids))
      |> Kernel.++(validate_slots(slots, group_ids, objective_ids, source_ids))
      |> Kernel.++(
        validate_branch_sets(branch_sets, slots, stages, group_ids, objective_ids, source_ids)
      )
      |> Kernel.++(validate_group_stage_coverage(stages, group_ids))
      |> maybe_finding(
        duration["total_minutes"] not in @minimum_minutes..@maximum_minutes,
        "advanced_duration_out_of_range",
        "$.experience_blueprint",
        "The deterministic experience estimate is #{duration["total_minutes"]} minutes; Advanced requires 45–75 without padding."
      )

    case findings do
      [] ->
        {:ok,
         %{
           "driving_question" => String.trim(raw["driving_question"]),
           "stages" => stages,
           "activity_slots" => slots,
           "branch_sets" => branch_sets,
           "activities" => [],
           "enrichment_references" => [],
           "duration_manifest" => duration,
           "estimated_minutes" => duration["total_minutes"],
           "remediation_paths" => []
         }}

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
      guidance = normalize_guidance(stage["guidance"])

      %{
        "id" => present(stage["id"]) || "stage-#{index}",
        "title" => present(stage["title"]) || "Exploration stage #{index}",
        "purpose" => present(stage["purpose"]) || "Advance the central investigation.",
        "roles" => normalize_strings(stage["roles"] || [stage["role"]]),
        "presentation_pattern" => present(stage["presentation_pattern"]),
        "introduction" => normalize_stage_introduction(stage["introduction"]),
        "guidance" => guidance,
        "native_follow_up_slot_id" => present(stage["native_follow_up_slot_id"]),
        "items" =>
          stage["items"]
          |> normalize_maps()
          |> Enum.map(&Map.take(&1, ~w(kind ref_id)))
      }
    end)
  end

  defp normalize_stage_introduction(value) when is_map(value) do
    value = stringify_map(value)

    %{
      "heading" => present(value["heading"]) || "Prepare to investigate",
      "body" => present(value["body"] || value["text"]),
      "evidence_block_ids" => normalize_strings(value["evidence_block_ids"])
    }
  end

  defp normalize_stage_introduction(_value),
    do: %{"heading" => nil, "body" => nil, "evidence_block_ids" => []}

  defp normalize_guidance(values) do
    values
    |> normalize_maps()
    |> Enum.map(fn guidance ->
      kind = present(guidance["kind"])

      %{
        "kind" => kind,
        "heading" => present(guidance["heading"]) || guidance_heading(kind),
        "body" => present(guidance["body"] || guidance["prompt"] || guidance["text"]),
        "evidence_block_ids" => normalize_strings(guidance["evidence_block_ids"])
      }
    end)
    |> Enum.sort_by(fn guidance ->
      Enum.find_index(@guidance_kinds, &(&1 == guidance["kind"])) || length(@guidance_kinds)
    end)
  end

  defp normalize_slots(values, stages) do
    inferred_stage_ids =
      Map.new(
        for stage <- stages,
            item <- stage["items"],
            item["kind"] == "activity_slot",
            is_binary(item["ref_id"]),
            do: {item["ref_id"], stage["id"]}
      )

    values
    |> normalize_maps()
    |> Enum.with_index(1)
    |> Enum.map(fn {slot, index} ->
      id = present(slot["id"]) || "activity-slot-#{index}"

      %{
        "id" => id,
        "stage_id" => present(slot["stage_id"]) || inferred_stage_ids[id],
        "purpose" => present(slot["purpose"] || slot["instructional_purpose"] || slot["prompt"]),
        "objective_ids" => normalize_strings(slot["objective_ids"]),
        "evidence_block_ids" => normalize_strings(slot["evidence_block_ids"]),
        "recommended_types" =>
          normalize_strings(
            slot["recommended_types"] || slot["recommended_activity_types"] ||
              slot["recommended_interaction_type"]
          ),
        "remediation_content_group_id" => present(slot["remediation_content_group_id"]),
        "estimated_minutes" => numeric_minutes(slot["estimated_minutes"])
      }
    end)
  end

  defp normalize_branch_sets(values) do
    values
    |> normalize_maps()
    |> Enum.with_index(1)
    |> Enum.map(fn {branch_set, index} ->
      %{
        "id" => present(branch_set["id"]) || "branch-set-#{index}",
        "decision_activity_slot_id" => present(branch_set["decision_activity_slot_id"]),
        "objective_ids" => normalize_strings(branch_set["objective_ids"]),
        "rejoin_stage_id" => present(branch_set["rejoin_stage_id"]),
        "pathways" =>
          branch_set
          |> Map.get("pathways", [])
          |> normalize_maps()
          |> Enum.map(fn pathway ->
            %{
              "choice_id" => present(pathway["choice_id"]),
              "label" => present(pathway["label"]),
              "target_content_group_id" => present(pathway["target_content_group_id"]),
              "feedback" => present(pathway["feedback"]),
              "evidence_block_ids" => normalize_strings(pathway["evidence_block_ids"])
            }
          end)
      }
    end)
  end

  defp validate_branch_sets(branch_sets, slots, stages, group_ids, objective_ids, source_ids) do
    slot_by_id = Map.new(slots, &{&1["id"], &1})
    stage_ids = stages |> Enum.map(& &1["id"]) |> MapSet.new()
    ids = Enum.map(branch_sets, & &1["id"])

    []
    |> maybe_finding(
      branch_sets == [],
      "missing_exploratory_branch",
      "$.experience_blueprint.branch_sets",
      "Add at least one answer-driven branch with two to four distinct pathways and a shared rejoin stage."
    )
    |> maybe_finding(
      length(ids) != length(Enum.uniq(ids)),
      "duplicate_branch_set_ids",
      "$.experience_blueprint.branch_sets",
      "Give every branch set a stable unique id."
    )
    |> Kernel.++(
      branch_sets
      |> Enum.with_index()
      |> Enum.flat_map(fn {branch_set, index} ->
        path = "$.experience_blueprint.branch_sets[#{index}]"
        slot = slot_by_id[branch_set["decision_activity_slot_id"]]
        pathways = branch_set["pathways"]
        choice_ids = Enum.map(pathways, & &1["choice_id"])
        target_ids = Enum.map(pathways, & &1["target_content_group_id"])

        []
        |> maybe_finding(
          is_nil(slot) or
            Enum.all?(
              List.wrap(slot && slot["recommended_types"]),
              &(&1 not in ["multiple_choice", "dropdown"])
            ),
          "invalid_branch_decision_slot",
          path,
          "Branch from an existing multiple-choice or dropdown activity slot."
        )
        |> maybe_finding(
          branch_set["objective_ids"] == [] or
            Enum.any?(branch_set["objective_ids"], &(not MapSet.member?(objective_ids, &1))),
          "invalid_branch_objectives",
          path,
          "Map the branch only to server-issued objective ids."
        )
        |> maybe_finding(
          not MapSet.member?(stage_ids, branch_set["rejoin_stage_id"]),
          "invalid_branch_rejoin_stage",
          path,
          "Choose an existing shared stage where all pathways rejoin."
        )
        |> maybe_finding(
          length(pathways) not in 2..4,
          "invalid_branch_pathway_count",
          path,
          "Create two to four meaningful pathways."
        )
        |> maybe_finding(
          Enum.any?(pathways, fn pathway ->
            not present?(pathway["choice_id"]) or not present?(pathway["label"]) or
              not present?(pathway["feedback"])
          end),
          "incomplete_branch_pathway",
          path,
          "Each pathway needs a choice id, learner-facing label, and transition feedback."
        )
        |> maybe_finding(
          length(choice_ids) != length(Enum.uniq(choice_ids)),
          "duplicate_branch_choice_ids",
          path,
          "Give each pathway a distinct choice id."
        )
        |> maybe_finding(
          length(target_ids) != length(Enum.uniq(target_ids)) or
            Enum.any?(target_ids, &(not MapSet.member?(group_ids, &1))),
          "invalid_branch_targets",
          path,
          "Send each pathway to a distinct existing content group."
        )
        |> maybe_finding(
          Enum.any?(pathways, fn pathway ->
            pathway["evidence_block_ids"] == [] or
              Enum.any?(
                pathway["evidence_block_ids"],
                &(not MapSet.member?(source_ids, &1))
              )
          end),
          "invalid_branch_evidence",
          path,
          "Ground every pathway in supplied source block ids."
        )
      end)
    )
  end

  defp validate_realized_branch_sets(branch_sets, activities) do
    activities_by_slot = Map.new(activities, &{&1["slot_id"], &1})

    branch_sets
    |> Enum.with_index()
    |> Enum.flat_map(fn {branch_set, index} ->
      activity = activities_by_slot[branch_set["decision_activity_slot_id"]]

      activity_choice_ids =
        activity
        |> then(&(&1 && &1["choices"]))
        |> normalize_maps()
        |> Enum.map(& &1["id"])
        |> Enum.filter(&is_binary/1)

      pathway_choice_ids = branch_set["pathways"] |> List.wrap() |> Enum.map(& &1["choice_id"])

      []
      |> maybe_finding(
        is_nil(activity) or activity["interaction_type"] not in ["multiple_choice", "dropdown"],
        "branch_activity_not_realized",
        "$.experience_blueprint.branch_sets[#{index}]",
        "Realize the branch decision slot as multiple choice or dropdown."
      )
      |> maybe_finding(
        MapSet.new(activity_choice_ids) != MapSet.new(pathway_choice_ids),
        "branch_choice_contract_mismatch",
        "$.experience_blueprint.branch_sets[#{index}]",
        "Use exactly the approved pathway choice ids in the realized decision activity."
      )
    end)
  end

  defp realize_branch_sets(branch_sets, activities) do
    activity_id_by_slot = Map.new(activities, &{&1["slot_id"], &1["id"]})

    Enum.map(branch_sets, fn branch_set ->
      Map.put(
        branch_set,
        "decision_activity_id",
        activity_id_by_slot[branch_set["decision_activity_slot_id"]]
      )
    end)
  end

  defp validate_stages(stages, group_ids, slots, source_ids) do
    stage_ids = Enum.map(stages, & &1["id"])
    slot_ids = slots |> Enum.map(& &1["id"]) |> MapSet.new()
    slot_stage_ids = Map.new(slots, &{&1["id"], &1["stage_id"]})
    roles = stages |> Enum.flat_map(& &1["roles"]) |> MapSet.new()
    guidance_kinds = stages |> Enum.flat_map(& &1["guidance"]) |> Enum.map(& &1["kind"])

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
    |> maybe_finding(
      not Enum.all?(@guidance_kinds, &(&1 in guidance_kinds)),
      "incomplete_instructional_guidance",
      "$.experience_blueprint.stages",
      "Author source-grounded prediction, observation, interpretation, transfer, and synthesis guidance across the experience."
    )
    |> Kernel.++(
      stages
      |> Enum.with_index()
      |> Enum.flat_map(fn {stage, index} ->
        path = "$.experience_blueprint.stages[#{index}]"
        introduction = stage["introduction"] || %{}

        stage_slot_ids =
          stage["items"]
          |> Enum.filter(&(&1["kind"] == "activity_slot"))
          |> Enum.map(& &1["ref_id"])

        follow_up_slot_id = stage["native_follow_up_slot_id"]

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
        |> maybe_finding(
          stage["presentation_pattern"] not in @presentation_patterns,
          "invalid_presentation_pattern",
          path,
          "Choose one supported high-level presentation pattern."
        )
        |> maybe_finding(
          not present?(introduction["body"]),
          "missing_stage_introduction",
          path,
          "Author a compact source-grounded transition into this stage."
        )
        |> maybe_finding(
          introduction["evidence_block_ids"] == [] or
            Enum.any?(
              introduction["evidence_block_ids"],
              &(not MapSet.member?(source_ids, &1))
            ),
          "invalid_stage_introduction_evidence",
          path,
          "Ground the stage introduction in supplied source block ids."
        )
        |> maybe_finding(
          stage_slot_ids != [] and
            (follow_up_slot_id not in stage_slot_ids or
               slot_stage_ids[follow_up_slot_id] != stage["id"]),
          "invalid_native_follow_up_slot",
          path,
          "Choose one activity slot in this stage as the explicit native follow-up."
        )
        |> maybe_finding(
          stage_slot_ids == [] and not is_nil(follow_up_slot_id),
          "orphan_native_follow_up_slot",
          path,
          "A stage without activity slots cannot declare a native follow-up."
        )
        |> Kernel.++(validate_stage_guidance(stage["guidance"], source_ids, path))
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
                if MapSet.member?(slot_ids, id) and slot_stage_ids[id] == stage["id"],
                  do: [],
                  else: [
                    finding(
                      "invalid_stage_activity_slot",
                      path,
                      "Stage must reference an activity slot assigned to that stage."
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

  defp validate_stage_guidance(guidance, source_ids, path) do
    kinds = Enum.map(guidance, & &1["kind"])

    []
    |> maybe_finding(
      length(kinds) != length(Enum.uniq(kinds)),
      "duplicate_stage_guidance",
      path,
      "Author each guidance kind at most once per stage."
    )
    |> Kernel.++(
      guidance
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        guidance_path = "#{path}.guidance[#{index}]"

        []
        |> maybe_finding(
          item["kind"] not in @guidance_kinds,
          "invalid_guidance_kind",
          guidance_path,
          "Use only supported instructional guidance kinds."
        )
        |> maybe_finding(
          not present?(item["body"]),
          "missing_guidance_body",
          guidance_path,
          "Author a substantive learner-facing prompt."
        )
        |> maybe_finding(
          item["evidence_block_ids"] == [] or
            Enum.any?(item["evidence_block_ids"], &(not MapSet.member?(source_ids, &1))),
          "invalid_guidance_evidence",
          guidance_path,
          "Ground guidance in supplied source block ids."
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

    source_ids = BasicPlanV7.source_blocks(lesson) |> Enum.map(& &1["id"]) |> MapSet.new()
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

  defp duration_manifest(content, slots),
    do: duration_manifest(content, slots, get_in(content, ["experience_blueprint", "stages"]))

  defp duration_manifest(content, slots, stages) do
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

    connective_words =
      stages
      |> List.wrap()
      |> Enum.flat_map(fn stage ->
        [get_in(stage, ["introduction", "body"])] ++
          Enum.map(List.wrap(stage["guidance"]), & &1["body"])
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.split(~r/\s+/u, trim: true)
      |> length()

    instructional_guidance = ceil_div(connective_words, 180)
    synthesis_in_learner_work? = synthesis_activity_slot?(slots, stages)
    synthesis = if synthesis_in_learner_work?, do: 0, else: 6
    total = reading + media_analysis + instructional_guidance + learner_work + synthesis

    %{
      "reading_minutes" => reading,
      "media_analysis_minutes" => media_analysis,
      "instructional_guidance_minutes" => instructional_guidance,
      "learner_work_minutes" => learner_work,
      "synthesis_minutes" => synthesis,
      "synthesis_accounting" =>
        if(synthesis_in_learner_work?,
          do: "included_in_activity_slots",
          else: "separate_instructional_allowance"
        ),
      "total_minutes" => total,
      "range" => [@minimum_minutes, @maximum_minutes],
      "strategy" => "deterministic_source_guidance_and_activity_estimate"
    }
  end

  defp synthesis_activity_slot?(slots, stages) do
    synthesis_stage_ids =
      stages
      |> List.wrap()
      |> Enum.filter(&("synthesis" in List.wrap(&1["roles"])))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    Enum.any?(slots, &MapSet.member?(synthesis_stage_ids, &1["stage_id"]))
  end

  defp rich_stages?(values) do
    stages = List.wrap(values)
    guidance_kinds = stages |> Enum.flat_map(&List.wrap(&1["guidance"])) |> Enum.map(& &1["kind"])

    stages != [] and
      Enum.all?(stages, fn stage ->
        present?(get_in(stage, ["introduction", "body"])) and
          stage["presentation_pattern"] in @presentation_patterns
      end) and Enum.all?(@guidance_kinds, &(&1 in guidance_kinds))
  end

  defp guidance_heading("prediction"), do: "Predict before you inspect"
  defp guidance_heading("observation"), do: "Observe and record"
  defp guidance_heading("interpretation"), do: "Interpret the evidence"
  defp guidance_heading("transfer"), do: "Transfer the relationship"
  defp guidance_heading("synthesis"), do: "Synthesize your explanation"
  defp guidance_heading(_kind), do: "Investigate the evidence"

  defp contains_forbidden_authoring_material?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      to_string(key) in ~w(
        rule rules navigation navigation_target target sequence_id url href src artifact_url
      ) or contains_forbidden_authoring_material?(item)
    end)
  end

  defp contains_forbidden_authoring_material?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_authoring_material?/1)

  defp contains_forbidden_authoring_material?(value) when is_binary(value),
    do: Regex.match?(~r/https?:\/\//i, value)

  defp contains_forbidden_authoring_material?(_value), do: false

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

  defp normalize_activity_contract(activity) do
    response_contract =
      case activity["response_contract"] do
        value when is_map(value) -> stringify_map(value)
        _ -> %{}
      end

    correct_choice_id =
      response_contract["correct_choice_id"] || response_contract["correct_response"]

    choices =
      (activity["choices"] || response_contract["choices"])
      |> normalize_maps()
      |> Enum.map(&normalize_choice_contract(&1, correct_choice_id))

    activity
    |> Map.put("choices", choices)
    |> put_first_present("correct_feedback", [
      activity["correct_feedback"],
      response_contract["correct_feedback"]
    ])
    |> put_first_present("incorrect_feedback", [
      activity["incorrect_feedback"],
      activity["default_incorrect_feedback"],
      response_contract["incorrect_feedback"],
      response_contract["default_incorrect_feedback"]
    ])
    |> put_first_non_nil("correct_response", [
      activity["correct_response"],
      response_contract["correct_response"]
    ])
  end

  defp normalize_choice_contract(choice, correct_choice_id) do
    correct =
      cond do
        is_boolean(choice["correct"]) -> choice["correct"]
        is_boolean(choice["is_correct"]) -> choice["is_correct"]
        is_binary(correct_choice_id) -> choice["id"] == correct_choice_id
        true -> nil
      end

    choice
    |> Map.put("correct", correct)
    |> put_first_present("feedback", [choice["feedback"], choice["incorrect_feedback"]])
  end

  defp put_first_present(map, key, values) do
    case Enum.find_value(values, &present/1) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp put_first_non_nil(map, key, values) do
    case Enum.find(values, &(not is_nil(&1))) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

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
      "scoring" => "completion",
      "semantic_evaluation" => "author_review",
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
