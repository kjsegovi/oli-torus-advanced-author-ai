defmodule Oli.OpenStax.CourseImport.AdvancedPlanV7Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{AdvancedPlanV7, AdvancedSuitabilityV7, Checks}
  alias Oli.OpenStax.CourseImport.V7Fixture, as: Fixture

  test "routes structural and short narrative sources to Basic" do
    refute AdvancedSuitabilityV7.advanced?(%{
             "title" => "Chapter Outline",
             "source_blocks" => [block("outline", "paragraph", "A short outline of the chapter.")]
           })

    refute AdvancedSuitabilityV7.advanced?(%{
             "title" => "1.3 The Laws of Nature",
             "source_blocks" => [
               block(
                 "law",
                 "paragraph",
                 "A scientific law describes a regular pattern in nature."
               )
             ]
           })
  end

  test "builds one complete v7 blueprint and single-sources its reviewed activities" do
    lesson = lesson()
    assert AdvancedSuitabilityV7.advanced?(lesson)

    assert {:ok, architecture} =
             AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    assert architecture["schema_version"] == 7
    assert architecture["coverage_manifest"]["complete"]

    assert {:ok, content} =
             AdvancedPlanV7.attach_activities(architecture, activity_candidate(), lesson)

    assert AdvancedPlanV7.valid?(content)

    assert get_in(content, ["experience_blueprint", "duration_manifest", "total_minutes"]) in 45..75

    assert get_in(content, [
             "experience_blueprint",
             "duration_manifest",
             "instructional_guidance_minutes"
           ]) > 0

    assert get_in(content, [
             "experience_blueprint",
             "duration_manifest",
             "synthesis_minutes"
           ]) == 0

    assert get_in(content, [
             "experience_blueprint",
             "duration_manifest",
             "synthesis_accounting"
           ]) == "included_in_activity_slots"

    assert length(get_in(content, ["experience_blueprint", "activities"])) == 4

    assert get_in(content, [
             "experience_blueprint",
             "stages",
             Access.at(0),
             "native_follow_up_activity_id"
           ]) == "activity-3"

    assert content
           |> get_in(["experience_blueprint", "stages", Access.at(0), "guidance"])
           |> Enum.map(& &1["kind"]) ==
             ~w(prediction observation interpretation transfer synthesis)

    assert Enum.all?(
             get_in(content, ["experience_blueprint", "activities"]),
             &is_map(&1["response_contract"])
           )

    stage_activity_ids =
      content
      |> get_in(["experience_blueprint", "stages"])
      |> Enum.flat_map(& &1["items"])
      |> Enum.filter(&(&1["kind"] == "activity"))
      |> Enum.map(& &1["ref_id"])

    assert stage_activity_ids == ~w(activity-1 activity-2 activity-3 activity-4)
  end

  test "reconstructs editable architecture and activity candidates from a realized plan" do
    lesson = lesson()

    assert {:ok, architecture} =
             AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    assert {:ok, content} =
             AdvancedPlanV7.attach_activities(architecture, activity_candidate(), lesson)

    architecture_repair = AdvancedPlanV7.architecture_repair_candidate(content)
    activity_repair = AdvancedPlanV7.activity_repair_candidate(content)

    repaired_stage_items =
      architecture_repair
      |> get_in(["experience_blueprint", "stages"])
      |> Enum.flat_map(& &1["items"])

    assert Enum.any?(repaired_stage_items, &(&1["kind"] == "activity_slot"))
    refute Enum.any?(repaired_stage_items, &(&1["kind"] == "activity"))

    assert activity_repair["activities"] ==
             get_in(content, ["experience_blueprint", "activities"])

    assert {:ok, rebuilt_architecture} =
             AdvancedPlanV7.build_architecture(architecture_repair, lesson, 1)

    assert {:ok, rebuilt_content} =
             AdvancedPlanV7.attach_activities(rebuilt_architecture, activity_repair, lesson)

    assert AdvancedPlanV7.valid?(rebuilt_content)
  end

  test "blocks the exact missing default incorrect-response regression" do
    lesson = lesson()
    {:ok, architecture} = AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    candidate =
      update_in(activity_candidate(), ["activities"], fn [first | rest] ->
        [Map.delete(first, "incorrect_feedback") | rest]
      end)

    assert {:error, findings} = AdvancedPlanV7.attach_activities(architecture, candidate, lesson)
    assert Enum.any?(findings, &(&1["code"] == "missing_activity_feedback"))
  end

  test "keeps remediation linkage owned by the approved activity slot" do
    lesson = lesson()
    {:ok, architecture} = AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    candidate =
      put_in(
        activity_candidate(),
        ["activities", Access.at(0), "remediation_content_group_id"],
        "writer-overridden-group"
      )

    assert {:ok, content} = AdvancedPlanV7.attach_activities(architecture, candidate, lesson)

    [activity | _] = get_in(content, ["experience_blueprint", "activities"])
    [path | _] = get_in(content, ["experience_blueprint", "remediation_paths"])

    assert activity["remediation_content_group_id"] == "evidence-group"

    assert path == %{
             "from_activity_id" => "activity-1",
             "to_content_group_id" => "evidence-group"
           }
  end

  test "normalizes observed activity-writer aliases before deterministic validation" do
    lesson = lesson()
    {:ok, architecture} = AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    candidate =
      update_in(activity_candidate(), ["activities"], fn activities ->
        activities
        |> Enum.with_index()
        |> Enum.map(fn {activity, index} ->
          default_incorrect_feedback = activity["incorrect_feedback"]

          activity =
            activity
            |> Map.delete("incorrect_feedback")
            |> Map.put("default_incorrect_feedback", default_incorrect_feedback)
            |> Map.update!("choices", fn choices ->
              Enum.map(choices, fn choice ->
                choice
                |> Map.put("is_correct", choice["correct"])
                |> Map.delete("correct")
                |> then(fn normalized ->
                  case normalized["feedback"] do
                    nil ->
                      normalized

                    feedback ->
                      normalized
                      |> Map.delete("feedback")
                      |> Map.put("incorrect_feedback", feedback)
                  end
                end)
              end)
            end)

          if rem(index, 2) == 0 do
            activity
          else
            choices = activity["choices"]
            correct_choice = Enum.find(choices, &(&1["is_correct"] == true))

            activity
            |> Map.delete("choices")
            |> Map.put("response_contract", %{
              "type" => "single_choice",
              "choices" => choices,
              "correct_response" => correct_choice["id"]
            })
          end
        end)
      end)

    assert {:ok, content} = AdvancedPlanV7.attach_activities(architecture, candidate, lesson)

    assert Enum.all?(content["experience_blueprint"]["activities"], fn activity ->
             is_binary(activity["incorrect_feedback"]) and
               Enum.count(activity["choices"], &(&1["correct"] == true)) == 1 and
               is_binary(activity["response_contract"]["correct_choice_id"])
           end)
  end

  test "marks reflection and short-answer contracts as completion reviewed" do
    lesson = lesson()
    {:ok, architecture} = AdvancedPlanV7.build_architecture(architecture_candidate(), lesson, 1)

    candidate =
      update_in(activity_candidate(), ["activities"], fn [first, second | rest] ->
        second =
          second
          |> Map.put("interaction_type", "short_answer")
          |> Map.delete("choices")
          |> Map.put("configuration", %{"minimum_length" => 40})

        [first, second | rest]
      end)

    assert {:ok, content} = AdvancedPlanV7.attach_activities(architecture, candidate, lesson)
    [_first, second | _] = get_in(content, ["experience_blueprint", "activities"])

    assert second["response_contract"] == %{
             "kind" => "text",
             "minimum_length" => 40,
             "must_contain" => "",
             "scoring" => "completion",
             "semantic_evaluation" => "author_review"
           }
  end

  test "requires source-grounded connective guidance and rejects renderer instructions" do
    lesson = lesson()

    missing_guidance =
      architecture_candidate()
      |> put_in(["experience_blueprint", "stages", Access.at(0), "guidance"], [])

    assert {:error, findings} =
             AdvancedPlanV7.build_architecture(missing_guidance, lesson, 1)

    assert Enum.any?(findings, &(&1["code"] == "incomplete_instructional_guidance"))

    raw_renderer_instruction =
      architecture_candidate()
      |> put_in(
        ["experience_blueprint", "stages", Access.at(0), "rules"],
        [%{"navigation" => "next"}]
      )

    assert {:error, findings} =
             AdvancedPlanV7.build_architecture(raw_renderer_instruction, lesson, 1)

    assert Enum.any?(findings, &(&1["code"] == "forbidden_advanced_authoring_material"))
  end

  test "normalizes observed architect aliases without inventing activity-slot content" do
    lesson = lesson()

    candidate =
      update_in(architecture_candidate(), ["experience_blueprint", "activity_slots"], fn slots ->
        slots
        |> Enum.with_index()
        |> Enum.map(fn {slot, index} ->
          purpose = slot["purpose"]
          recommended_types = slot["recommended_types"]

          slot
          |> Map.drop(["stage_id", "purpose", "recommended_types"])
          |> Map.put("prompt", purpose)
          |> Map.put(
            if(rem(index, 2) == 0,
              do: "recommended_interaction_type",
              else: "recommended_activity_types"
            ),
            if(rem(index, 2) == 0, do: hd(recommended_types), else: recommended_types)
          )
        end)
      end)

    assert {:ok, architecture} = AdvancedPlanV7.build_architecture(candidate, lesson, 1)

    assert Enum.all?(architecture["experience_blueprint"]["activity_slots"], fn slot ->
             slot["stage_id"] in ["investigation", "synthesis-stage"] and
               is_binary(slot["purpose"]) and
               slot["recommended_types"] == ["multiple_choice"]
           end)
  end

  test "publishes the exact activity-slot generation contract" do
    slot_schema =
      AdvancedPlanV7.prompt_contract(lesson())["experience_blueprint_schema"]["activity_slots"]
      |> List.first()

    assert Map.keys(slot_schema) |> Enum.sort() ==
             ~w(estimated_minutes evidence_block_ids id objective_ids purpose recommended_types remediation_content_group_id stage_id)

    assert slot_schema["recommended_types"] ==
             ~w(multiple_choice dropdown slider number_input short_answer reflection)
  end

  test "current checks reject every legacy content contract" do
    results =
      Checks.run(lesson(), %{
        "content_payload" => %{"schema_version" => 4, "authoring_mode" => "advanced"}
      })

    refute Checks.passed?(results)
    assert Enum.all?(results, &(&1.status == "failed"))
  end

  defdelegate lesson(), to: Fixture
  defdelegate architecture_candidate(), to: Fixture
  defdelegate activity_candidate(), to: Fixture

  defp block(id, kind, text) do
    %{
      "id" => id,
      "kind" => kind,
      "text" => text,
      "ast" => [%{"type" => "p", "children" => [%{"text" => text}]}]
    }
  end
end
