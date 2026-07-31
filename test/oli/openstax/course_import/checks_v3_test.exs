defmodule Oli.OpenStax.CourseImport.ChecksV3Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Checks

  @source "https://openstax.org/books/sample-book/pages/1-2-applications"

  test "rejects invalid Advanced targets, response contracts, feedback, and evidence" do
    lesson = rich_lesson()

    plan =
      rich_plan("advanced")
      |> put_in(["content_payload", "advanced_blueprint"], %{
        "screens" => [
          %{
            "id" => "source-context",
            "kind" => "content",
            "title" => "How binary search uses order",
            "body" =>
              "Binary search uses the sorted order to repeatedly halve the candidate set.",
            "placement_after_section_id" => "models",
            "evidence_block_ids" => ["search"]
          },
          %{
            "id" => "choose",
            "kind" => "decision",
            "prompt" => "Choose a search strategy.",
            "interaction_type" => "dropdown",
            "choices" => [
              %{"id" => "linear", "text" => "Linear", "correct" => false},
              %{"id" => "binary", "text" => "Binary", "correct" => true}
            ],
            "placement_after_section_id" => "missing-section",
            "evidence_block_ids" => ["invented-block"]
          },
          %{
            "id" => "predict",
            "kind" => "exploration",
            "prompt" => "Predict the number of halvings.",
            "interaction_type" => "slider",
            "configuration" => %{"min" => 8, "max" => 2, "step" => 0, "correct" => 12},
            "evidence_block_ids" => ["search"]
          },
          %{
            "id" => "calculate",
            "kind" => "check",
            "prompt" => "Calculate the number of halvings.",
            "interaction_type" => "number_input",
            "correct_response" => "not-a-number",
            "evidence_block_ids" => ["search"]
          }
        ],
        "remediation_paths" => [
          %{"from_question_id" => "missing-screen", "to_section_id" => "missing-section"}
        ]
      })

    %{findings: %{"issues" => issues}} =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "pedagogy_assessment"))

    assert "Advanced screen \"choose\" points to a missing placement section" in issues
    assert "Advanced screen \"choose\" must cite only valid source block ids" in issues

    assert "Every incorrect choice on Advanced screen \"choose\" needs option-specific feedback" in issues

    assert "Advanced slider \"predict\" needs numeric bounds with min less than max" in issues
    assert "Advanced slider \"predict\" needs a positive step" in issues
    assert "Advanced slider \"predict\" needs a correct value within its bounds" in issues

    assert "Advanced slider \"predict\" needs targeted incorrect feedback or remediation" in issues

    assert "Advanced numeric input \"calculate\" needs a numeric correct value" in issues

    assert "Advanced numeric input \"calculate\" needs targeted incorrect feedback or remediation" in issues

    assert "Every Advanced remediation path must reference an existing screen and instructional section" in issues
  end

  test "grounds hooks, transfer prompts, and Advanced screen claims" do
    lesson = %{
      source_sections: [@source],
      source_blocks: [
        %{
          "id" => "search",
          "kind" => "heading",
          "text" => "Binary search repeatedly halves a sorted collection of candidate values."
        }
      ]
    }

    plan =
      rich_plan("advanced")
      |> put_in(
        ["content_payload", "opening_hook"],
        "Mitochondria manufacture chlorophyll inside flowering leaves."
      )
      |> put_in(
        ["content_payload", "why_this_matters"],
        "Ocean currents determine volcanic mineral composition."
      )
      |> put_in(["content_payload", "curiosity_prompts"], [
        %{
          "id" => "curiosity",
          "prompt" => "Predict how chloroplast membranes absorb sunlight.",
          "evidence_block_ids" => ["search"]
        }
      ])
      |> put_in(["content_payload", "application_problems"], [
        %{
          "id" => "application",
          "prompt" => "Design a volcanic eruption forecast from ocean salinity.",
          "evidence_block_ids" => ["search"]
        }
      ])
      |> put_in(["content_payload", "advanced_blueprint"], %{
        "screens" => [
          %{
            "id" => "decision",
            "kind" => "decision",
            "prompt" => "Choose which enzyme produces flower pigments.",
            "interaction_type" => "multiple_choice",
            "choices" => [
              %{
                "id" => "a",
                "text" => "Chlorophyll enzyme",
                "correct" => false,
                "feedback" => "Review plant membranes."
              },
              %{"id" => "b", "text" => "Mitochondrial enzyme", "correct" => true}
            ],
            "evidence_block_ids" => ["search"]
          }
        ],
        "remediation_paths" => [
          %{"from_question_id" => "decision", "to_section_id" => "models"}
        ]
      })

    %{status: "failed", findings: %{"issues" => issues}} =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "source_fidelity"))

    assert Enum.any?(issues, &String.starts_with?(&1, "Opening hook is not grounded"))
    assert Enum.any?(issues, &String.starts_with?(&1, "Why this matters is not grounded"))
    assert Enum.any?(issues, &String.starts_with?(&1, "Curiosity prompt is not grounded"))
    assert Enum.any?(issues, &String.starts_with?(&1, "Application problem is not grounded"))
    assert Enum.any?(issues, &String.starts_with?(&1, "Advanced screen is not grounded"))
  end

  test "accepts a grounded Advanced decision with valid feedback and remediation targets" do
    plan =
      rich_plan("advanced")
      |> put_in(["content_payload", "advanced_blueprint"], %{
        "screens" => [
          %{
            "id" => "choose",
            "kind" => "decision",
            "prompt" => "Which search strategy halves the sorted candidate set?",
            "interaction_type" => "dropdown",
            "choices" => [
              %{
                "id" => "linear",
                "text" => "Linear search",
                "correct" => false,
                "feedback" => "Linear search checks each candidate instead of halving the set."
              },
              %{
                "id" => "binary",
                "text" => "Binary search",
                "correct" => true,
                "feedback" => "Binary search halves the sorted candidate set."
              }
            ],
            "placement_after_section_id" => "models",
            "evidence_block_ids" => ["search"]
          }
        ],
        "remediation_paths" => [
          %{"from_question_id" => "choose", "to_section_id" => "models"}
        ]
      })

    %{findings: %{"issues" => issues}} =
      Checks.run(rich_lesson(), plan)
      |> Enum.find(&(&1.check_type == "pedagogy_assessment"))

    refute Enum.any?(issues, &String.contains?(&1, "Advanced"))
  end

  test "preserves all four source objectives in instruction and assessment" do
    source_objectives = [
      "Describe computing in science",
      "Compare discovery and invention",
      "Explain computational models",
      "Evaluate interdisciplinary applications"
    ]

    lesson =
      rich_lesson()
      |> Map.put(:source_objectives, source_objectives)
      |> Map.update!(:source_blocks, fn blocks ->
        [
          %{
            "id" => "objectives",
            "kind" => "objectives",
            "text" => Enum.join(source_objectives, " ")
          }
          | Enum.reject(blocks, &(&1["id"] == "objectives"))
        ]
      end)

    plan =
      rich_plan("basic")
      |> put_in(["content_payload", "learning_objectives"], Enum.take(source_objectives, 3))
      |> put_in(["questions_payload", "items"], [
        rich_question("q1", Enum.take(source_objectives, 3))
      ])

    %{findings: %{"issues" => issues}} =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "pedagogy_assessment"))

    assert "Preserve every source learning objective in the lesson plan and formative assessment mapping" in issues
  end

  test "requires selected V3 media to come from the lesson inventory with approved rights" do
    lesson =
      rich_lesson()
      |> Map.put(:source_media, [
        %{
          "id" => "approved-figure",
          "rights_status" => "approved"
        },
        %{
          "id" => "review-figure",
          "rights_status" => "requires_review"
        }
      ])

    plan =
      rich_plan("basic")
      |> put_in(["content_payload", "media"], [
        figure("unknown-figure", "approved"),
        figure("review-figure", "approved"),
        figure("approved-figure", nil)
      ])

    %{findings: %{"issues" => issues}} =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "torus_accessibility"))

    assert "Every V3 selected figure must use a source_media_id issued for this lesson" in issues
    assert "Every V3 selected figure must have approved source rights" in issues
  end

  test "accepts approved inventory media and safe V3 question ids" do
    lesson =
      rich_lesson()
      |> Map.put(:source_media, [
        %{"id" => "figure-1", "rights_status" => "approved"}
      ])

    plan =
      rich_plan("basic")
      |> put_in(["content_payload", "media"], [figure("figure-1", "approved")])
      |> put_in(
        ["questions_payload", "items"],
        [rich_question("checkpoint_1-followup", ["Compare two search strategies"])]
      )

    %{findings: %{"issues" => issues}} =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "torus_accessibility"))

    refute Enum.any?(issues, &String.contains?(&1, "V3 selected figure"))
    refute Enum.any?(issues, &String.contains?(&1, "question ids"))
  end

  test "rejects unsafe or oversized V3 question ids but preserves legacy compatibility" do
    unsafe_ids = ["question 1<script>", String.duplicate("q", 65)]

    v3_plan =
      rich_plan("basic")
      |> put_in(
        ["questions_payload", "items"],
        Enum.map(unsafe_ids, &rich_question(&1, ["Compare two search strategies"]))
      )

    %{findings: %{"issues" => v3_issues}} =
      Checks.run(rich_lesson(), v3_plan)
      |> Enum.find(&(&1.check_type == "torus_accessibility"))

    assert "Use question ids containing only letters, digits, underscores, or hyphens and at most 64 characters" in v3_issues

    legacy_plan = put_in(v3_plan, ["content_payload", "schema_version"], 2)

    %{findings: %{"issues" => legacy_issues}} =
      Checks.run(rich_lesson(), legacy_plan)
      |> Enum.find(&(&1.check_type == "torus_accessibility"))

    refute "Use question ids containing only letters, digits, underscores, or hyphens and at most 64 characters" in legacy_issues
  end

  test "does not apply V3 blueprint contracts to legacy Advanced plans" do
    plan = %{
      "content_payload" => %{
        "schema_version" => 2,
        "title" => "Computer science",
        "narrative" => "Computer science studies algorithms.",
        "learning_objectives" => ["Explain algorithms"],
        "authoring_mode" => "advanced",
        "source_evidence_links" => [@source]
      },
      "questions_payload" => %{"items" => []}
    }

    %{findings: %{"issues" => issues}} =
      Checks.run(%{source_sections: [@source], plan_mode: "advanced"}, plan)
      |> Enum.find(&(&1.check_type == "pedagogy_assessment"))

    refute Enum.any?(issues, &String.contains?(&1, "Advanced"))
  end

  defp rich_lesson do
    %{
      source_sections: [@source],
      source_objectives: ["Compare two search strategies"],
      source_blocks: [
        %{
          "id" => "objectives",
          "kind" => "objectives",
          "text" => "Compare two search strategies"
        },
        %{
          "id" => "search",
          "kind" => "heading",
          "text" =>
            "Binary search halves a sorted candidate set while linear search checks each item."
        }
      ],
      source_word_count: 1_200,
      plan_mode: "advanced"
    }
  end

  defp rich_plan(mode) do
    %{
      "content_payload" => %{
        "schema_version" => 3,
        "title" => "Search strategies",
        "narrative" => "Binary search halves a sorted collection.",
        "opening_hook" => "How can a sorted collection reduce search effort?",
        "why_this_matters" => "Search strategies affect the effort needed to find values.",
        "authoring_mode" => mode,
        "learning_objectives" => ["Compare two search strategies"],
        "source_evidence_links" => [@source],
        "instructional_sections" => [
          %{
            "id" => "models",
            "heading" => "Models",
            "explanation" => String.duplicate("Binary search halves a sorted set. ", 160),
            "evidence_block_ids" => ["objectives", "search"]
          }
        ],
        "worked_examples" => [],
        "curiosity_prompts" => [],
        "application_problems" => [],
        "key_takeaways" => []
      },
      "questions_payload" => %{
        "items" => [rich_question("q1", ["Compare two search strategies"])]
      }
    }
  end

  defp rich_question(id, objective_ids) do
    %{
      "id" => id,
      "prompt" => "How does binary search reduce candidates?",
      "type" => "short_answer",
      "response_kind" => "application",
      "answer_keywords" => ["halves"],
      "objective_ids" => objective_ids,
      "evidence_block_ids" => ["search"],
      "source_evidence_links" => [@source]
    }
  end

  defp figure(source_media_id, rights_status) do
    %{
      "source_media_id" => source_media_id,
      "alt" => "A sorted list divided into progressively smaller candidate sets",
      "caption" => "Binary search halves the remaining candidates.",
      "credit" => "OpenStax",
      "rights_status" => rights_status,
      "evidence_block_ids" => ["search"]
    }
  end
end
