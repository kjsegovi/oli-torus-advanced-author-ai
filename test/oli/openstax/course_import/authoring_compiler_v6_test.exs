defmodule Oli.OpenStax.CourseImport.AuthoringCompilerV6Test do
  use ExUnit.Case, async: true

  alias Oli.Activities.Model
  alias Oli.OpenStax.CourseImport.{AdvancedPlanV6, AuthoringCompiler, BasicPlanV5}
  alias Oli.OpenStax.CourseImport.V6Fixture, as: Fixture

  @proposal_id "00000000-0000-4000-8000-000000000006"
  @artifact_hash String.duplicate("c", 64)

  test "compiles every schema 6 activity once with a default incorrect response" do
    lesson = Fixture.lesson()

    {:ok, architecture} =
      AdvancedPlanV6.build_architecture(
        Fixture.architecture_candidate(),
        lesson,
        1
      )

    {:ok, content} =
      AdvancedPlanV6.attach_activities(
        architecture,
        Fixture.activity_candidate(),
        lesson
      )

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               content["title"],
               content,
               %{"items" => []},
               "advanced-v6",
               media_urls: %{
                 "figure-1" => "https://example.edu/figure-1.png",
                 "figure-2" => "https://example.edu/figure-2.png",
                 "figure-3" => "https://example.edu/figure-3.png"
               }
             )

    assert compiled["mode"] == "advanced"
    assert Enum.all?(compiled["activities"], &match?({:ok, _}, Model.parse(&1["model"])))

    encoded = Jason.encode!(compiled)
    page_template_encoded = Jason.encode!(compiled["page_content_template"])

    Enum.each(~w(activity-1 activity-2 activity-3 activity-4), fn id ->
      assert occurrences(page_template_encoded, id) == 1
    end)

    assert encoded =~ "incorrectFeedback"
    assert encoded =~ "Not sure?"

    compiled["activities"]
    |> Enum.filter(&String.contains?(&1["key"], ":blueprint:activity-"))
    |> Enum.each(fn activity ->
      assert has_default_incorrect_response?(activity["model"])
    end)
  end

  test "compiles rich stages and immutable source blocks into coherent multi-part screens" do
    content = rich_content()

    assert {:ok, compiled} = compile(content, "rich-advanced-v6")

    stage =
      Enum.find(compiled["activities"], &(&1["key"] == "rich-advanced-v6:v6:stage:investigation"))

    evidence =
      Enum.find(
        compiled["activities"],
        &(&1["key"] == "rich-advanced-v6:v6:group:evidence-group")
      )

    assert length(get_in(stage, ["model", "partsLayout"])) == 13
    assert length(get_in(evidence, ["model", "partsLayout"])) == 4

    stage_text = Jason.encode!(stage["model"])
    evidence_text = Jason.encode!(evidence["model"])

    assert stage_text =~ "Commit to a prediction"
    assert stage_text =~ "Record what the evidence shows"
    assert stage_text =~ "Test a changed condition"
    assert evidence_text =~ "Analyze quantitative data"
    assert evidence_text =~ "First calculate the predicted value"

    refute Enum.any?(compiled["activities"], &String.contains?(&1["key"], ":block:"))
  end

  test "places an approved simulation on the architect-selected native follow-up" do
    content =
      rich_content()
      |> put_in(
        ["experience_blueprint", "enrichment_references"],
        [%{"proposal_id" => @proposal_id, "stage_id" => "investigation"}]
      )
      |> update_in(["experience_blueprint", "activities"], fn activities ->
        Enum.map(activities, fn
          %{"id" => "activity-1"} = activity ->
            Map.put(activity, "enrichment_proposal_id", @proposal_id)

          activity ->
            activity
        end)
      end)

    assert {:ok, compiled} =
             compile(content, "explicit-simulation-follow-up",
               simulation_artifact_resolver: fn @proposal_id -> {:ok, simulation_artifact()} end,
               simulation_artifact_url_resolver: fn _artifact ->
                 {:ok, "https://media.example.edu/bundles/#{@artifact_hash}/index.html"}
               end,
               generated_simulation_origins: ["https://media.example.edu"],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )

    first = Enum.find(compiled["activities"], &String.ends_with?(&1["key"], ":activity-1"))
    selected = Enum.find(compiled["activities"], &String.ends_with?(&1["key"], ":activity-3"))

    refute Jason.encode!(first["model"]) =~ "generated_simulation"
    assert Jason.encode!(selected["model"]) =~ "generated_simulation"
    assert Jason.encode!(selected["model"]) =~ @proposal_id
  end

  test "rejects legacy and mixed schema combinations at compilation" do
    assert {:error, {:unsupported_openstax_content_contract, "advanced", 4}} =
             AuthoringCompiler.compile(
               "advanced",
               "Legacy",
               %{"schema_version" => 4, "authoring_mode" => "advanced"},
               %{"items" => []},
               "legacy"
             )

    assert {:error, {:unsupported_openstax_content_contract, "basic", 6}} =
             AuthoringCompiler.compile(
               "basic",
               "Mixed",
               %{"schema_version" => 6, "authoring_mode" => "basic"},
               %{"items" => []},
               "mixed"
             )
  end

  test "Basic schema 5 multiple choice also compiles a default incorrect response" do
    candidate =
      Fixture.architecture_candidate()
      |> Map.delete("experience_blueprint")
      |> Map.put("question_slots", [
        %{
          "placement_after_group_id" => "evidence-group",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["evidence"],
          "recommended_types" => ["multiple_choice"]
        }
      ])

    assert {:ok, content} = BasicPlanV5.build(candidate, Fixture.lesson(), 1)

    question = %{
      "id" => "basic-check",
      "type" => "multiple_choice",
      "prompt" => "Which response uses the evidence?",
      "choices" => [
        %{
          "id" => "uses-evidence",
          "text" => "Compare prediction and measurement",
          "correct" => true
        },
        %{
          "id" => "ignores-evidence",
          "text" => "Ignore the measurement",
          "correct" => false,
          "feedback" => "The conclusion must use the observed measurement."
        }
      ],
      "correct_choice_id" => "uses-evidence",
      "placement_after_section_id" => "evidence-group",
      "objective_ids" => ["objective-1"],
      "evidence_block_ids" => ["evidence"],
      "allow_not_sure" => true,
      "hint" => "Compare the predicted and observed values.",
      "feedback" => %{
        "correct" => "Correct.",
        "incorrect" => "Revisit the evidence group."
      }
    }

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "basic",
               content["title"],
               content,
               %{"items" => [question]},
               "basic-v5-incorrect-response",
               media_urls: %{
                 "figure-1" => "https://example.edu/figure-1.png",
                 "figure-2" => "https://example.edu/figure-2.png",
                 "figure-3" => "https://example.edu/figure-3.png"
               }
             )

    assert [activity] = compiled["activities"]
    assert {:ok, _model} = Model.parse(activity["model"])
    assert has_default_incorrect_response?(activity["model"])
  end

  test "compiles every schema 6 interaction type with complete response rules" do
    types = ~w(multiple_choice dropdown slider number_input short_answer reflection)

    slots =
      types
      |> Enum.with_index(1)
      |> Enum.map(fn {type, index} ->
        %{
          "id" => "type-slot-#{index}",
          "stage_id" => "investigation",
          "purpose" => "Use #{type} to interpret the source evidence.",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["evidence", "investigation"],
          "recommended_types" => [type],
          "remediation_content_group_id" => "evidence-group",
          "estimated_minutes" => 7
        }
      end)

    architecture_candidate =
      Fixture.architecture_candidate()
      |> put_in(["experience_blueprint", "activity_slots"], slots)
      |> put_in(
        ["experience_blueprint", "stages", Access.at(0), "native_follow_up_slot_id"],
        "type-slot-3"
      )
      |> put_in(
        ["experience_blueprint", "stages", Access.at(0), "items"],
        [%{"kind" => "content_group", "ref_id" => "evidence-group"}] ++
          Enum.map(1..length(types), fn index ->
            %{"kind" => "activity_slot", "ref_id" => "type-slot-#{index}"}
          end)
      )

    activities =
      types
      |> Enum.with_index(1)
      |> Enum.map(fn {type, index} ->
        %{
          "id" => "type-activity-#{index}",
          "slot_id" => "type-slot-#{index}",
          "context" => "The source evidence supplies the values and explanation needed here.",
          "prompt" => "Respond using the evidence with the #{type} interaction.",
          "interaction_type" => type,
          "correct_feedback" => "The response uses the relevant source evidence.",
          "incorrect_feedback" => "Compare the response with the evidence and try again.",
          "allow_not_sure" => true,
          "hint" => "Return to the evidence group and identify the predicted relationship.",
          "remediation_content_group_id" => "evidence-group",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["evidence", "investigation"]
        }
        |> activity_response(type)
      end)

    assert {:ok, architecture} =
             AdvancedPlanV6.build_architecture(architecture_candidate, Fixture.lesson(), 1)

    assert {:ok, content} =
             AdvancedPlanV6.attach_activities(
               architecture,
               %{"activities" => activities},
               Fixture.lesson()
             )

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               content["title"],
               content,
               %{"items" => []},
               "all-interaction-types",
               media_urls: %{
                 "figure-1" => "https://example.edu/figure-1.png",
                 "figure-2" => "https://example.edu/figure-2.png",
                 "figure-3" => "https://example.edu/figure-3.png"
               }
             )

    scorable =
      Enum.filter(compiled["activities"], &String.contains?(&1["key"], ":type-activity-"))

    assert length(scorable) == length(types)
    assert Enum.all?(scorable, &match?({:ok, _}, Model.parse(&1["model"])))
    assert Enum.all?(scorable, &has_default_incorrect_response?(&1["model"]))
  end

  defp occurrences(text, pattern), do: length(String.split(text, pattern)) - 1

  defp rich_content do
    {:ok, architecture} =
      AdvancedPlanV6.build_architecture(Fixture.architecture_candidate(), Fixture.lesson(), 1)

    {:ok, content} =
      AdvancedPlanV6.attach_activities(
        architecture,
        Fixture.activity_candidate(),
        Fixture.lesson()
      )

    content
  end

  defp compile(content, stable_key, extra_opts \\ []) do
    AuthoringCompiler.compile(
      "advanced",
      content["title"],
      content,
      %{"items" => []},
      stable_key,
      [
        media_urls: %{
          "figure-1" => "https://example.edu/figure-1.png",
          "figure-2" => "https://example.edu/figure-2.png",
          "figure-3" => "https://example.edu/figure-3.png"
        }
      ] ++ extra_opts
    )
  end

  defp simulation_artifact do
    %{
      id: "artifact-explicit-follow-up",
      proposal_id: @proposal_id,
      status: "approved",
      version: 1,
      content_hash: @artifact_hash,
      storage_provider: "local",
      storage_state: "promoted",
      storage_key: "bundles/#{@artifact_hash}/index.html",
      storage_origin: "https://media.example.edu",
      manifest: %{"entrypoint" => "index.html"},
      capi_manifest: %{"inputs" => [], "outputs" => []},
      accessibility_metadata: %{
        "title" => "Evidence model",
        "description" => "Change a value and observe the model response."
      },
      validation_payload: %{"status" => "passed"}
    }
  end

  defp has_default_incorrect_response?(value) when is_map(value) do
    default_incorrect_here? =
      (Map.get(value, "default") == true or Map.get(value, "rule") == "input like {.*}") and
        (Map.get(value, "correct") == false or Map.get(value, "score") == 0) and
        feedback_present?(value)

    default_incorrect_here? or Enum.any?(Map.values(value), &has_default_incorrect_response?/1)
  end

  defp has_default_incorrect_response?(value) when is_list(value),
    do: Enum.any?(value, &has_default_incorrect_response?/1)

  defp has_default_incorrect_response?(_value), do: false

  defp feedback_present?(value) do
    encoded = Jason.encode!(value)
    encoded =~ "feedback" or encoded =~ "incorrectFeedback"
  end

  defp activity_response(activity, type) when type in ["multiple_choice", "dropdown"] do
    Map.put(activity, "choices", [
      %{"id" => "supported", "text" => "Supported", "correct" => true},
      %{
        "id" => "unsupported",
        "text" => "Unsupported",
        "correct" => false,
        "feedback" => "This option conflicts with the source evidence."
      }
    ])
  end

  defp activity_response(activity, "slider") do
    activity
    |> Map.put("correct_response", 5)
    |> Map.put("configuration", %{"min" => 0, "max" => 10, "step" => 1})
  end

  defp activity_response(activity, "number_input"), do: Map.put(activity, "correct_response", 5)

  defp activity_response(activity, type) when type in ["short_answer", "reflection"] do
    Map.put(activity, "configuration", %{"minimum_length" => 20})
  end
end
