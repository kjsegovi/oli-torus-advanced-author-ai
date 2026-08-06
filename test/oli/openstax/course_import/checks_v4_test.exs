defmodule Oli.OpenStax.CourseImport.ChecksV4Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Checks, Planner}

  test "v4 checker reports full substantive coverage and validates refined contracts" do
    lesson = lesson()
    {"advanced", plan} = Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    results = Checks.run(lesson, plan)
    source = Enum.find(results, &(&1.check_type == "source_fidelity"))
    pedagogy = Enum.find(results, &(&1.check_type == "pedagogy_assessment"))

    assert get_in(source, [:findings, "evaluation", "coverage", "uncovered_substantive_block_ids"]) ==
             []

    refute Enum.any?(pedagogy.findings["issues"], &String.contains?(&1, "Schema v4 question"))
    refute Enum.any?(pedagogy.findings["issues"], &String.contains?(&1, "two to four"))
  end

  test "v4 checker rejects missing question placement and unacknowledged exclusions" do
    lesson = lesson()
    {"advanced", plan} = Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    plan =
      plan
      |> update_in(["questions_payload", "items"], fn [first | rest] ->
        [Map.delete(first, "placement") | rest]
      end)
      |> put_in(
        ["content_payload", "coverage_manifest", "excluded_blocks"],
        [%{"id" => "paragraph-1", "reason" => "Condense this section"}]
      )

    results = Checks.run(lesson, plan)
    source_issues = result_issues(results, "source_fidelity")
    pedagogy_issues = result_issues(results, "pedagogy_assessment")

    assert Enum.any?(source_issues, &String.contains?(&1, "explicit author acknowledgement"))
    assert Enum.any?(pedagogy_issues, &String.contains?(&1, "stable valid placement"))
  end

  test "v4 checker requires the Advanced interaction arc" do
    lesson = lesson()
    {"advanced", plan} = Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    [screen | _] = get_in(plan, ["content_payload", "advanced_blueprint", "screens"])

    plan =
      plan
      |> put_in(["content_payload", "advanced_blueprint", "screens"], [screen])
      |> put_in(
        ["content_payload", "advanced_blueprint", "remediation_paths"],
        [
          %{
            "from_question_id" => screen["id"],
            "to_section_id" => screen["remediation_section_id"]
          }
        ]
      )

    issues = result_issues(Checks.run(lesson, plan), "pedagogy_assessment")
    assert Enum.any?(issues, &String.contains?(&1, "two to four meaningful interactions"))
    assert Enum.any?(issues, &String.contains?(&1, "must cover prediction or decision"))
  end

  test "v4 checker rejects a cited block whose full learner-facing text was removed" do
    lesson = lesson()
    {"advanced", plan} = Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    plan =
      update_in(plan, ["content_payload", "instructional_sections"], fn sections ->
        Enum.map(sections, fn section ->
          if "paragraph-2" in List.wrap(section["evidence_block_ids"]) do
            Map.put(section, "explanation", "A compressed reference to the evidence.")
          else
            section
          end
        end)
      end)

    results = Checks.run(lesson, plan)
    source = Enum.find(results, &(&1.check_type == "source_fidelity"))
    coverage = get_in(source, [:findings, "evaluation", "coverage"])

    assert "paragraph-2" in coverage["missing_full_text_block_ids"]

    assert Enum.any?(
             source.findings["issues"],
             &String.contains?(&1, "full learner-facing text")
           )
  end

  test "v4 checker does not accept a substantive paragraph mislabeled as navigation" do
    lesson = lesson()
    {"advanced", plan} = Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    plan =
      plan
      |> update_in(["content_payload", "instructional_sections"], fn sections ->
        Enum.map(sections, fn section ->
          if "paragraph-2" in List.wrap(section["evidence_block_ids"]) do
            Map.put(section, "explanation", "A compressed reference to the evidence.")
          else
            section
          end
        end)
      end)
      |> put_in(
        ["content_payload", "coverage_manifest", "excluded_blocks"],
        [
          %{
            "id" => "paragraph-2",
            "reason" => "Navigation is omitted",
            "reason_code" => "navigation",
            "author_acknowledged" => false
          }
        ]
      )

    source =
      Checks.run(lesson, plan)
      |> Enum.find(&(&1.check_type == "source_fidelity"))

    coverage = get_in(source, [:findings, "evaluation", "coverage"])
    assert "paragraph-2" in coverage["missing_full_text_block_ids"]
    assert coverage["excluded_blocks"] == []

    assert Enum.any?(
             source.findings["issues"],
             &String.contains?(&1, "explicit author acknowledgement")
           )
  end

  defp result_issues(results, type) do
    results
    |> Enum.find(&(&1.check_type == type))
    |> Map.fetch!(:findings)
    |> Map.fetch!("issues")
  end

  defp lesson do
    objectives = ["Analyze the evidence model", "Apply the model to a decision"]

    blocks = [
      %{"id" => "objectives", "kind" => "objectives", "text" => Enum.join(objectives, " ")},
      %{"id" => "heading-1", "kind" => "heading", "text" => "Prediction"},
      paragraph("paragraph-1", "prediction evidence model decision"),
      %{"id" => "heading-2", "kind" => "heading", "text" => "Evidence"},
      paragraph("paragraph-2", "evidence exploration variable output"),
      %{"id" => "heading-3", "kind" => "heading", "text" => "Interpretation"},
      paragraph("paragraph-3", "interpret compare evidence explanation"),
      %{"id" => "heading-4", "kind" => "heading", "text" => "Transfer"},
      paragraph("paragraph-4", "apply decision transfer scenario")
    ]

    ids = Enum.map(blocks, & &1["id"])

    %{
      "title" => "Evidence models",
      "source_sections" => ["https://openstax.org/books/sample/pages/1-1-evidence-models"],
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-evidence-models"
      ],
      "source_objectives" => objectives,
      "source_blocks" => blocks,
      "source_media" => [],
      "source_word_count" => 900,
      "source_coverage" => %{
        "source_block_ids" => ids,
        "substantive_block_ids" => ids,
        "deterministically_omittable_block_ids" => []
      }
    }
  end

  defp paragraph(id, terms) do
    %{"id" => id, "kind" => "paragraph", "text" => String.duplicate("#{terms}. ", 55)}
  end
end
