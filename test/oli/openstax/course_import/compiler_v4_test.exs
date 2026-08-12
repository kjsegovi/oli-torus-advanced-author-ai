defmodule Oli.OpenStax.CourseImport.CompilerV4Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Compiler, Lesson, LessonPlan, Unit}

  test "legacy plans compile without enrichment payload mutations" do
    {legacy_content, run} = legacy_run()

    assert {:ok, compiled} = Compiler.dry_run(run)

    [compiled_unit] = compiled["units"]
    [compiled_lesson] = compiled_unit["lessons"]

    assert compiled_lesson["content_payload"] == legacy_content
    refute Map.has_key?(compiled_lesson["content_payload"], "curated_enrichments")
  end

  test "v4 compilation rejects persisted content schema downgrade or type mutation" do
    {_legacy_content, run} = legacy_run()

    for invalid_version <- [3, "4"] do
      run =
        run
        |> Map.put(:plan_schema_version, 4)
        |> update_in(
          [:units, Access.at(0), Access.key(:lessons), Access.at(0), Access.key(:plans)],
          fn [
               plan
             ] ->
            [
              %{
                plan
                | content_payload:
                    Map.put(plan.content_payload, "schema_version", invalid_version)
              }
            ]
          end
        )

      assert {:error,
              {:unit_compile_failed, "legacy-unit",
               {:lesson_artifact_invalid, "legacy-lesson", :plan_schema_version_mismatch}}} =
               Compiler.dry_run(run)
    end
  end

  test "v5 compilation accepts Basic schema v5 lesson payloads" do
    run = v5_basic_run()

    assert {:ok, compiled} = Compiler.dry_run(run)

    [compiled_unit] = compiled["units"]
    [compiled_lesson] = compiled_unit["lessons"]

    assert compiled_lesson["mode"] == "basic"
    assert compiled_lesson["content_payload"]["schema_version"] == 5
  end

  test "v5 compilation rejects a Basic lesson persisted with schema v4" do
    run =
      update_in(
        v5_basic_run(),
        [:units, Access.at(0), Access.key(:lessons), Access.at(0), Access.key(:plans)],
        fn [plan] ->
          [%{plan | content_payload: Map.put(plan.content_payload, "schema_version", 4)}]
        end
      )

    assert {:error,
            {:unit_compile_failed, "v5-unit",
             {:lesson_artifact_invalid, "v5-basic-lesson", :plan_schema_version_mismatch}}} =
             Compiler.dry_run(run)
  end

  defp legacy_run do
    legacy_content = %{
      "schema_version" => 3,
      "objective" => "Apply the source concept",
      "learning_objectives" => ["Apply the source concept"],
      "narrative" => "A source-grounded narrative.",
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-topic"
      ]
    }

    questions = [
      %{"prompt" => "Explain the concept.", "type" => "short_answer"},
      %{"prompt" => "Apply the concept.", "type" => "short_answer"}
    ]

    plan = %LessonPlan{
      version: 1,
      content_payload: legacy_content,
      questions_payload: %{"items" => questions},
      approved_by_user: true
    }

    lesson = %Lesson{
      id: "legacy-lesson",
      run_id: "legacy-run",
      unit_id: "legacy-unit",
      order: 1,
      title: "Legacy lesson",
      plan_mode: "basic",
      status: "approved",
      selected: true,
      source_evidence_links: [],
      plans: [plan]
    }

    unit = %Unit{
      id: "legacy-unit",
      run_id: "legacy-run",
      order: 1,
      unit_name: "Legacy unit",
      selected: true,
      lessons: [lesson],
      assessment_payload: %{
        "title" => "Legacy assessment",
        "authoring_mode" => "basic",
        "questions" => questions,
        "source_evidence_links" => []
      }
    }

    {legacy_content,
     %{
       id: "legacy-run",
       plan_schema_version: 3,
       units: [unit],
       enrichment_proposals: []
     }}
  end

  defp v5_basic_run do
    content = %{
      "schema_version" => 5,
      "authoring_mode" => "basic",
      "title" => "The Nature of Astronomy",
      "orientation" => %{
        "overview" => "Astronomy builds an evidence-based history of an evolving universe."
      },
      "learning_objectives" => [
        "Explain how new observations can refine astronomy's account of cosmic history."
      ],
      "content_groups" => [
        %{
          "id" => "nature-of-astronomy",
          "title" => "An evolving account of the universe",
          "instructional_purpose" => "concept",
          "transition" => "Begin with what astronomers observe and explain.",
          "source_block_ids" => ["source-paragraph"],
          "source_blocks" => [
            %{
              "id" => "source-paragraph",
              "kind" => "paragraph",
              "ast" => [
                %{
                  "type" => "p",
                  "children" => [
                    %{
                      "text" =>
                        "New instruments can deepen astronomy's account of how the universe changes over time."
                    }
                  ]
                }
              ]
            }
          ]
        }
      ],
      "synthesis" => "Astronomy uses new evidence to refine its account of an evolving universe.",
      "attribution" => %{
        "provider" => "OpenStax",
        "source_url" =>
          "https://openstax.org/books/astronomy-2e/pages/1-1-the-nature-of-astronomy"
      }
    }

    questions = [
      %{
        "id" => "q1",
        "prompt" => "What can new observations change?",
        "type" => "multiple_choice",
        "placement_after_section_id" => "nature-of-astronomy",
        "choices" => [
          %{"id" => "correct", "text" => "Astronomy's account", "correct" => true},
          %{"id" => "incorrect", "text" => "The past itself", "correct" => false}
        ],
        "correct_choice_id" => "correct"
      }
    ]

    plan = %LessonPlan{
      version: 1,
      content_payload: content,
      questions_payload: %{"items" => questions},
      approved_by_user: true
    }

    lesson = %Lesson{
      id: "v5-basic-lesson",
      run_id: "v5-run",
      unit_id: "v5-unit",
      order: 1,
      title: "1.1 The Nature of Astronomy",
      plan_mode: "basic",
      status: "approved",
      selected: true,
      source_evidence_links: [],
      plans: [plan]
    }

    unit = %Unit{
      id: "v5-unit",
      run_id: "v5-run",
      order: 1,
      unit_name: "Chapter 1",
      selected: true,
      lessons: [lesson],
      assessment_payload: %{
        "title" => "Chapter 1 assessment",
        "authoring_mode" => "basic",
        "questions" => [
          %{"prompt" => "Explain the central idea.", "type" => "short_answer"}
        ],
        "source_evidence_links" => []
      }
    }

    %{
      id: "v5-run",
      plan_schema_version: 5,
      units: [unit],
      enrichment_proposals: []
    }
  end
end
