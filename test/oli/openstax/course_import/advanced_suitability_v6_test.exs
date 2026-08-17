defmodule Oli.OpenStax.CourseImport.AdvancedSuitabilityV6Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AdvancedSuitabilityV6
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

  defp block(id, kind, text),
    do: %{
      "id" => id,
      "kind" => kind,
      "text" => text,
      "ast" => [%{"type" => "p", "children" => [%{"text" => text}]}]
    }
end
