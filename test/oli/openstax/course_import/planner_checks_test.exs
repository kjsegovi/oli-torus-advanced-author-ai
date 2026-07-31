defmodule Oli.OpenStax.CourseImport.PlannerChecksTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Checks, Planner}

  test "lesson plans include substantive instruction, examples, evidence, and formative questions" do
    lesson = %{
      "title" => "1.1 Computer Science",
      "source_excerpt" => """
      ## Computer science foundations
      Computer science studies algorithms, data, computing systems, and the ways people
      use those systems to solve problems. It connects mathematical reasoning with the
      design of hardware and software, then evaluates whether a proposed solution behaves
      as intended. Computer scientists describe a problem precisely, represent the relevant
      information, and compare possible computational approaches before selecting one.

      ## Algorithms and problems
      Algorithms give finite, ordered, and unambiguous steps for solving computational
      problems. A useful algorithm identifies its inputs, explains how each operation
      transforms those inputs, and specifies the expected output. Designers trace the steps
      with examples, test edge cases, and compare the result with the original problem.
      Those checks reveal whether the procedure is correct, efficient enough for its
      context, and understandable to another person who must apply or revise it.
      """,
      "source_sections" => [
        "https://openstax.org/books/sample-book/pages/1-1-computer-science"
      ],
      "source_evidence_links" => [
        "https://openstax.org/books/sample-book/pages/1-1-computer-science"
      ],
      "source_objectives" => ["Define computer science"]
    }

    {mode, plan} = Planner.build_lesson_plan(lesson, 1)

    assert mode in ["basic", "advanced"]
    assert plan["content_payload"]["narrative"] != ""
    assert plan["content_payload"]["learning_objectives"] == ["Define computer science"]
    assert length(plan["content_payload"]["instructional_sections"]) >= 2
    assert length(plan["content_payload"]["worked_examples"]) >= 1
    assert length(plan["content_payload"]["key_takeaways"]) >= 3
    assert length(plan["questions_payload"]["items"]) in 2..4

    assert Enum.all?(
             plan["questions_payload"]["items"],
             &(length(&1["answer_keywords"]) >= 1 and is_binary(&1["remediation"]))
           )

    results =
      Checks.run(
        %{
          title: lesson["title"],
          source_excerpt: lesson["source_excerpt"],
          source_sections: lesson["source_sections"],
          source_evidence_links: lesson["source_evidence_links"],
          source_objectives: lesson["source_objectives"],
          plan_mode: mode
        },
        plan
      )

    assert Checks.passed?(results)

    assert Enum.map(results, & &1.check_type) == [
             "source_fidelity",
             "pedagogy_assessment",
             "torus_accessibility"
           ]
  end

  test "failed checks return actionable repair data" do
    results =
      Checks.run(
        %{source_sections: [], source_evidence_links: [], plan_mode: "unsupported"},
        %{"content_payload" => %{}, "questions_payload" => %{"items" => []}}
      )

    refute Checks.passed?(results)
    assert Enum.all?(results, &(&1.status == "failed"))
    assert Enum.all?(results, &(is_map(&1.repair_plan) and map_size(&1.repair_plan) > 0))
  end

  test "checks reject malformed supported question contracts" do
    source = "https://openstax.org/books/sample-book/pages/1-1-computer-science"

    plan = %{
      "content_payload" => %{
        "title" => "Computer Science",
        "narrative" => "A source-grounded explanation.",
        "learning_objectives" => ["Explain computer science"],
        "authoring_mode" => "basic",
        "source_evidence_links" => [source]
      },
      "questions_payload" => %{
        "items" => [
          %{
            "prompt" => "Choose an answer.",
            "type" => "multiple_choice",
            "source_evidence_links" => [source]
          },
          %{
            "prompt" => "Explain your answer.",
            "type" => "short_answer",
            "source_evidence_links" => [source]
          }
        ]
      }
    }

    results = Checks.run(%{source_sections: [source], plan_mode: "basic"}, plan)

    refute Checks.passed?(results)

    assert %{status: "failed", findings: %{"issues" => issues}} =
             Enum.find(results, &(&1.check_type == "pedagogy_assessment"))

    assert "Every formative question must have a valid supported response contract" in issues
  end

  test "source fidelity repair preserves the rich draft for reviewer attention" do
    lesson = %{
      title: "Computer Science",
      source_excerpt: "Computer science studies algorithms, data, and computing systems.",
      source_objectives: ["Explain how algorithms solve computational problems"],
      source_sections: ["https://openstax.org/books/sample-book/pages/1-1-computer-science"],
      source_evidence_links: [
        "https://openstax.org/books/sample-book/pages/1-1-computer-science"
      ],
      plan_mode: "basic"
    }

    plan = %{
      "content_payload" => %{
        "title" => "Computer Science",
        "learning_objectives" => ["Describe photosynthesis in flowering plants"],
        "narrative" => "Mitochondria produce chlorophyll for plant cells.",
        "authoring_mode" => "basic",
        "source_evidence_links" => lesson.source_sections
      },
      "questions_payload" => %{
        "items" => [
          %{
            "prompt" => "How do chloroplasts capture sunlight?",
            "type" => "short_answer",
            "source_evidence_links" => lesson.source_sections
          },
          %{
            "prompt" => "Why is photosynthesis important for leaves?",
            "type" => "short_answer",
            "source_evidence_links" => lesson.source_sections
          }
        ]
      }
    }

    source_check =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "source_fidelity"))

    assert source_check.status == "failed"
    assert source_check.findings["evaluation"]["strategy"] == "deterministic_semantic_grounding"

    assert source_check.findings["evaluation"]["cited_source_sections"] == lesson.source_sections
    assert length(source_check.findings["evaluation"]["unsupported_claims"]) >= 2
    assert source_check.repair_plan["reground_to_source"]

    repaired =
      Planner.repair_lesson_plan(
        plan,
        %{"source_fidelity" => source_check.repair_plan},
        %{
          "title" => lesson.title,
          "source_excerpt" => lesson.source_excerpt,
          "source_objectives" => lesson.source_objectives,
          "source_evidence_links" => lesson.source_evidence_links
        }
      )

    repaired_source_check =
      Checks.run(lesson, repaired)
      |> Enum.find(&(&1.check_type == "source_fidelity"))

    assert repaired_source_check.status == "failed"
    assert repaired["content_payload"]["narrative"] == plan["content_payload"]["narrative"]

    assert Enum.map(repaired["questions_payload"]["items"], & &1["prompt"]) ==
             Enum.map(plan["questions_payload"]["items"], & &1["prompt"])

    refute Enum.any?(
             repaired["questions_payload"]["items"],
             &String.starts_with?(&1["id"] || "", "repair-q")
           )
  end
end
