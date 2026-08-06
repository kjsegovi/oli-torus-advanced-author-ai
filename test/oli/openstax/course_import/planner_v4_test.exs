defmodule Oli.OpenStax.CourseImport.PlannerV4Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{AIPlanner, Planner}

  test "deterministic v4 plans preserve full coverage and add refined contracts" do
    lesson = rich_lesson()

    assert {"advanced", payload} =
             Planner.build_lesson_plan(lesson, 1, plan_schema_version: 4)

    content = payload["content_payload"]
    questions = payload["questions_payload"]["items"]
    blueprint = content["advanced_blueprint"]

    assert content["schema_version"] == 4
    assert content["coverage_manifest"]["policy"] == "full_substantive_source"
    assert content["coverage_manifest"]["unaccounted_block_ids"] == []

    rendered_instruction =
      content["instructional_sections"]
      |> Enum.map_join(" ", &"#{&1["heading"]} #{&1["explanation"]}")

    assert Enum.all?(lesson["source_blocks"], fn block ->
             source_text = Oli.OpenStax.CourseImport.FullSource.normalized_text(block["text"])
             rendered = Oli.OpenStax.CourseImport.FullSource.normalized_text(rendered_instruction)
             source_text == "" or String.contains?(rendered, source_text)
           end)

    assert Enum.all?(questions, fn question ->
             is_binary(question["hint"]) and is_list(question["media_ids"]) and
               is_boolean(question["allow_not_sure"]) and is_map(question["placement"]) and
               is_list(question["evidence_refs"])
           end)

    assert length(blueprint["screens"]) == 4

    assert Enum.map(blueprint["screens"], & &1["role"]) ==
             ["prediction", "evidence", "interpretation", "transfer"]

    assert length(blueprint["remediation_paths"]) == 4
    proposals = payload["enrichment_proposals"]

    assert length(proposals) in 1..3

    assert Enum.all?(proposals, fn proposal ->
             proposal["kind"] in ~w(generated_simulation existing_simulation external_resource) and
               is_map(proposal["research_evidence"]) and
               proposal["metadata"]["research_query"] == proposal["research_query"]
           end)
  end

  test "legacy planner arity remains schema v3 without v4-only fields" do
    assert {"advanced", payload} = Planner.build_lesson_plan(rich_lesson(), 1)

    assert payload["content_payload"]["schema_version"] == 3
    refute Map.has_key?(payload, "enrichment_proposals")

    [question | _] = payload["questions_payload"]["items"]
    refute Map.has_key?(question, "placement")
    refute Map.has_key?(question, "allow_not_sure")
    assert length(payload["content_payload"]["advanced_blueprint"]["screens"]) == 1
  end

  test "AI planner returns v4 proposals separately from persisted lesson JSON" do
    assert {:ok, result} =
             AIPlanner.plan(rich_lesson(), 1,
               plan_schema_version: 4,
               service_config_loader: fn -> {:error, :not_configured} end
             )

    assert result.payload["content_payload"]["schema_version"] == 4
    refute Map.has_key?(result.payload, "enrichment_proposals")
    assert length(result.enrichment_proposals) in 1..3
  end

  defp rich_lesson do
    objectives = ["Analyze the evidence model", "Apply the model to a decision"]

    blocks = [
      %{"id" => "objectives", "kind" => "objectives", "text" => Enum.join(objectives, " ")},
      %{"id" => "heading-1", "kind" => "heading", "text" => "Model orientation"},
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
    %{
      "id" => id,
      "kind" => "paragraph",
      "text" => String.duplicate("#{terms}. ", 55)
    }
  end
end
