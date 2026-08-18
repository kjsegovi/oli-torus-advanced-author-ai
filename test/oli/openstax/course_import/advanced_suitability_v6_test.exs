defmodule Oli.OpenStax.CourseImport.AdvancedSuitabilityV6Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AdvancedSuitabilityV6
  alias Oli.OpenStax.CourseImport.SimulationPilotCorpus
  alias Oli.OpenStax.CourseImport.V6Fixture, as: Fixture

  test "routes Chapter Outline to Basic regardless of length" do
    lesson = %{
      "title" => "Chapter Outline",
      "source_blocks" => [
        block(
          "outline",
          "paragraph",
          String.duplicate("Compare data, calculate a ratio, and interpret a model. ", 250)
        ),
        block("question", "exercise", "First calculate the value, then compare the models.")
      ]
    }

    assert %{"candidate" => false, "mode" => "basic"} =
             AdvancedSuitabilityV6.assess(lesson)
  end

  test "routes 1.3 The Laws of Nature to Basic when it provides exposition only" do
    lesson = %{
      "title" => "1.3 The Laws of Nature",
      "source_blocks" => [
        block(
          "laws",
          "paragraph",
          String.duplicate(
            "Scientific laws summarize observed patterns and remain open to revision. ",
            180
          )
        )
      ]
    }

    assert %{
             "candidate" => false,
             "mode" => "basic",
             "affordances" => []
           } = AdvancedSuitabilityV6.assess(lesson)
  end

  test "selects the quantitative evidence-rich Chemistry fixture for Advanced v6" do
    assessment = AdvancedSuitabilityV6.assess(Fixture.lesson())

    assert assessment["candidate"]
    assert assessment["mode"] == "advanced"
    assert assessment["maximum_supported_minutes"] in 45..75
    assert "quantitative_investigation" in assessment["affordances"]
    assert assessment["evidence_block_ids"] != []
  end

  test "calibrates two evidence-rich golden lessons in every supported domain" do
    golden_lessons = SimulationPilotCorpus.golden_lessons()

    assert golden_lessons
           |> Enum.frequencies_by(& &1["domain"])
           |> Map.values()
           |> Enum.all?(&(&1 == 2))

    for lesson <- golden_lessons do
      domain = lesson["domain"]
      title = lesson["title"]
      assessment = AdvancedSuitabilityV6.assess(lesson)

      assert assessment["candidate"], "expected #{domain} golden lesson #{title} to qualify"
      assert assessment["mode"] == "advanced"
      assert assessment["expected_depth_minutes"] in 45..75
      assert "quantitative_investigation" in assessment["affordances"]
      assert "evidence_analysis" in assessment["affordances"]
      assert "multi_step_problem" in assessment["affordances"]
      assert assessment["evidence_block_ids"] == lesson["expected_evidence_block_ids"]

      assert Enum.all?(lesson["source_blocks"], fn block ->
               get_in(block, ["source_locator", "url"]) == lesson["source_url"]
             end)
    end
  end

  defp block(id, kind, text),
    do: %{
      "id" => id,
      "kind" => kind,
      "text" => text,
      "ast" => [%{"type" => "p", "children" => [%{"text" => text}]}]
    }
end
