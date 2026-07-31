defmodule Oli.OpenStax.CourseImport.PlannerTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{AuthoringCompiler, Planner}

  test "selects a bounded mix of pedagogically suitable Advanced lessons" do
    lesson = %{
      "title" => "Choosing and testing search strategies",
      "source_sections" => [
        "https://openstax.org/books/sample-book/pages/4-1-search-strategies"
      ],
      "source_evidence_links" => [
        "https://openstax.org/books/sample-book/pages/4-1-search-strategies"
      ],
      "source_objectives" => [
        "Compare search strategies and select one for a constrained problem",
        "Predict how the selected strategy behaves as the input changes"
      ],
      "source_blocks" => [
        %{
          "id" => "search-objectives",
          "kind" => "objectives",
          "text" =>
            "Compare search strategies, select an option, and predict how input changes the result."
        },
        %{
          "id" => "search-heading",
          "kind" => "heading",
          "text" => "Choosing a strategy"
        },
        %{
          "id" => "search-decision",
          "kind" => "paragraph",
          "heading_path" => ["Choosing a strategy"],
          "text" =>
            "A search decision compares alternative strategies against constraints. The input order and expected output determine which option is appropriate."
        },
        %{
          "id" => "search-exercise",
          "kind" => "exercise",
          "heading_path" => ["Choosing a strategy"],
          "text" =>
            "Choose a strategy for a sorted input. A common error is to ignore the sorted order and select a method that tests every item."
        },
        %{
          "id" => "search-model-heading",
          "kind" => "heading",
          "text" => "Predicting the effort"
        },
        %{
          "id" => "search-model",
          "kind" => "paragraph",
          "heading_path" => ["Predicting the effort"],
          "text" =>
            "A model predicts how the number of comparisons changes with the input. Testing the prediction helps diagnose an incorrect strategy."
        }
      ]
    }

    first = Planner.authoring_mode_recommendation(lesson, 1)
    second = Planner.authoring_mode_recommendation(lesson, 2)
    fourth = Planner.authoring_mode_recommendation(lesson, 4)

    assert first["candidate"]
    assert first["mode"] == "advanced"
    assert "misconception_knowledge_check" in first["recommended_interactions"]
    assert second["candidate"]
    assert second["mode"] == "basic"
    assert fourth["mode"] == "advanced"

    assert {"advanced", plan} = Planner.build_lesson_plan(lesson, 1)

    content = plan["content_payload"]
    [screen] = content["advanced_blueprint"]["screens"]
    [path] = content["advanced_blueprint"]["remediation_paths"]

    assert screen["kind"] in ["decision", "exploration"]
    assert screen["interaction_type"] == "multiple_choice"
    assert screen["evidence_block_ids"] != []
    assert path["from_question_id"] == screen["id"]
    assert path["to_section_id"] == screen["remediation_section_id"]

    assert Enum.all?(Enum.reject(screen["choices"], & &1["correct"]), fn choice ->
             is_binary(choice["feedback"]) and choice["feedback"] != ""
           end)

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               lesson["title"],
               content,
               plan["questions_payload"],
               "planner-generated-adaptive-lesson"
             )

    assert compiled["page_content_template"]["advancedAuthoring"]
    assert Enum.all?(compiled["activities"], &(&1["activity_type_slug"] == "oli_adaptive"))

    assert Enum.any?(compiled["activities"], fn activity ->
             activity["model"]["authoring"]["rules"]
             |> List.wrap()
             |> Enum.any?(fn rule ->
               rule["name"] == "incorrect-max-attempt" and
                 rule
                 |> get_in(["event", "params", "actions"])
                 |> List.wrap()
                 |> Enum.any?(fn action ->
                   action["type"] == "navigation" and
                     get_in(action, ["params", "target"]) not in [nil, "next"]
                 end)
             end)
           end)
  end

  test "keeps straightforward descriptive source lessons in Basic Author" do
    lesson = %{
      "title" => "What a computer is",
      "source_objectives" => ["Define a computer"],
      "source_blocks" => [
        %{
          "id" => "computer-definition",
          "kind" => "paragraph",
          "text" => "A computer processes information by following stored instructions."
        }
      ]
    }

    recommendation = Planner.authoring_mode_recommendation(lesson, 1)

    refute recommendation["candidate"]
    assert recommendation["mode"] == "basic"
    assert {"basic", plan} = Planner.build_lesson_plan(lesson, 1)
    assert plan["content_payload"]["advanced_blueprint"] == %{}
  end

  test "gives each substantial three-lesson window a visible Advanced knowledge-check slot" do
    source_blocks =
      Enum.flat_map(1..4, fn index ->
        [
          %{
            "id" => "heading-#{index}",
            "kind" => "heading",
            "text" => "Core idea #{index}"
          },
          %{
            "id" => "paragraph-#{index}",
            "kind" => "paragraph",
            "heading_path" => ["Core idea #{index}"],
            "text" =>
              "The source explains core idea #{index} with enough evidence for learners to distinguish a supported answer from a plausible distractor."
          }
        ]
      end)

    lesson = %{
      "title" => "Substantial structured lesson",
      "source_objectives" => ["Explain the four core ideas"],
      "source_word_count" => 900,
      "source_blocks" => source_blocks
    }

    first = Planner.authoring_mode_recommendation(lesson, 1)
    second = Planner.authoring_mode_recommendation(lesson, 2)
    third = Planner.authoring_mode_recommendation(lesson, 3)
    fourth = Planner.authoring_mode_recommendation(lesson, 4)

    assert first["strategy"] == "pedagogical_mix_v2"
    assert first["candidate"]
    assert first["mode"] == "advanced"
    assert "source_grounded_knowledge_check" in first["signals"]
    assert "misconception_knowledge_check" in first["recommended_interactions"]
    assert second["mode"] == "basic"
    assert third["mode"] == "basic"
    assert fourth["mode"] == "advanced"

    assert {"advanced", plan} = Planner.build_lesson_plan(lesson, 1)
    assert [_screen] = plan["content_payload"]["advanced_blueprint"]["screens"]
    assert [_path] = plan["content_payload"]["advanced_blueprint"]["remediation_paths"]
  end

  test "maps conceptual-question evidence to instruction and uses it for the unit assessment" do
    lessons = [
      %{
        "title" => "Discovery and Invention",
        "source_sections" => [
          "https://openstax.org/books/sample-book/pages/1-1-discovery-and-invention"
        ],
        "source_evidence_links" => [
          "https://openstax.org/books/sample-book/pages/1-1-discovery-and-invention"
        ],
        "source_objectives" => ["Differentiate discovery from invention"],
        "source_blocks" => [
          %{
            "id" => "instruction-discovery",
            "kind" => "paragraph",
            "text" =>
              "Discovery identifies an existing phenomenon, while invention creates a new process or artifact."
          }
        ]
      },
      %{
        "title" => "Data and Information Science",
        "source_sections" => [
          "https://openstax.org/books/sample-book/pages/1-2-data-and-information"
        ],
        "source_evidence_links" => [
          "https://openstax.org/books/sample-book/pages/1-2-data-and-information"
        ],
        "source_objectives" => [
          "Explain how computer science shapes data science and information science"
        ],
        "source_blocks" => [
          %{
            "id" => "instruction-data",
            "kind" => "paragraph",
            "text" =>
              "Computer science provides computational methods that shape data science and information science."
          }
        ]
      }
    ]

    unit = %{
      "unit_name" => "Foundations",
      "assessment_evidence" => [
        %{
          "id" => "openstax-question-discovery",
          "prompt" => "How do discovery and invention differ?",
          "order" => 1,
          "source_url" => "https://openstax.org/books/sample-book/pages/1-conceptual-questions",
          "source_block_ids" => ["conceptual-block-1"],
          "related_section_slugs" => ["1-1-discovery-and-invention"]
        },
        %{
          "id" => "openstax-question-data",
          "prompt" => "How does computer science shape data science and information science?",
          "order" => 2,
          "source_url" => "https://openstax.org/books/sample-book/pages/1-conceptual-questions",
          "source_block_ids" => ["conceptual-block-2"],
          "related_section_slugs" => ["1-2-data-and-information"]
        }
      ]
    }

    assessment = Planner.build_unit_assessment(unit, lessons)

    assert Enum.map(assessment["questions"], & &1["id"]) == [
             "openstax-question-discovery",
             "openstax-question-data"
           ]

    assert Enum.map(assessment["questions"], & &1["prompt"]) == [
             "How do discovery and invention differ?",
             "How does computer science shape data science and information science?"
           ]

    [discovery, data] = assessment["assessment_evidence"]

    assert discovery["mapped_source_sections"] == [
             "https://openstax.org/books/sample-book/pages/1-1-discovery-and-invention"
           ]

    assert discovery["instruction_evidence_block_ids"] == ["instruction-discovery"]

    assert data["mapped_source_sections"] == [
             "https://openstax.org/books/sample-book/pages/1-2-data-and-information"
           ]

    assert data["instruction_evidence_block_ids"] == ["instruction-data"]

    conceptual_url =
      "https://openstax.org/books/sample-book/pages/1-conceptual-questions"

    assert conceptual_url in assessment["source_evidence_links"]
    assert Enum.all?(assessment["questions"], &(conceptual_url in &1["source_evidence_links"]))
  end

  test "preserves the legacy generated unit assessment when no conceptual evidence exists" do
    lessons = [
      %{
        "title" => "Algorithms",
        "source_sections" => ["https://openstax.org/books/sample-book/pages/1-1-algorithms"],
        "source_evidence_links" => [
          "https://openstax.org/books/sample-book/pages/1-1-algorithms"
        ],
        "source_objectives" => ["Explain an algorithm"]
      }
    ]

    assessment = Planner.build_unit_assessment(%{"unit_name" => "Foundations"}, lessons)

    assert Enum.map(assessment["questions"], & &1["id"]) == ["unit-q1", "unit-q2"]
    assert assessment["assessment_evidence"] == []
  end

  test "preserves persisted callout metadata and builds several source-grounded worked cases" do
    source_blocks =
      Enum.flat_map(1..4, fn index ->
        [
          %{
            "id" => "heading-#{index}",
            "kind" => "heading",
            "text" => "Disciplinary area #{index}",
            "heading_path" => ["Disciplinary area #{index}"]
          },
          %{
            "id" => "paragraph-#{index}",
            "kind" => "paragraph",
            "text" =>
              "Disciplinary area #{index} applies computing evidence to a practical problem and explains the constraints that shape a responsible decision.",
            "heading_path" => ["Disciplinary area #{index}"]
          }
        ]
      end)

    callout_body =
      "Targeted advertising combines browsing evidence with computational models, which raises questions about consent, transparency, and responsible use."

    lesson = %{
      "title" => "Computing across disciplines",
      "source_sections" => [
        "https://openstax.org/books/sample-book/pages/1-2-computing-across-disciplines"
      ],
      "source_evidence_links" => [
        "https://openstax.org/books/sample-book/pages/1-2-computing-across-disciplines"
      ],
      "source_objectives" => [
        "Compare computing across disciplines",
        "Evaluate responsible uses of data"
      ],
      "source_word_count" => 1_300,
      "source_blocks" =>
        source_blocks ++
          [
            %{
              "id" => "targeted-advertising",
              "kind" => "callout",
              "text" => "Global Issues in Technology Targeted Advertising",
              "metadata" => %{
                "semantic_payload" => %{
                  "callout_type" => "global_issue",
                  "title" => "Global Issues in Technology",
                  "subtitle" => "Targeted Advertising",
                  "callout_body" => callout_body
                }
              }
            }
          ]
    }

    {"basic", plan} = Planner.build_lesson_plan(lesson, 2)
    content = plan["content_payload"]

    assert [
             %{
               "type" => "global_issue",
               "title" => "Targeted Advertising",
               "body" => ^callout_body,
               "evidence_block_ids" => ["targeted-advertising"]
             }
           ] = content["callouts"]

    assert length(content["worked_examples"]) == 3

    assert Enum.all?(content["worked_examples"], fn example ->
             example["evidence_block_ids"] != [] and
               String.contains?(example["scenario"], "applies computing evidence")
           end)
  end
end
