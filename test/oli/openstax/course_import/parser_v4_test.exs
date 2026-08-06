defmodule Oli.OpenStax.CourseImport.ParserV4Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Parser

  test "schema v4 keeps every source section in its own lesson while v3 remains bundled" do
    sections = Enum.map(1..3, &light_section/1)
    snapshot = snapshot(sections)

    assert {:ok, %{"units" => [%{"lessons" => legacy_lessons}]}} =
             Parser.build_outline(snapshot)

    assert Enum.map(legacy_lessons, &length(&1["source_sections"])) == [2, 1]

    assert {:ok, %{"units" => [%{"lessons" => refined_lessons}]}} =
             Parser.build_outline(snapshot, plan_schema_version: 4)

    assert Enum.map(refined_lessons, & &1["source_sections"]) ==
             Enum.map(sections, &[&1["url"]])

    assert Enum.all?(refined_lessons, fn lesson ->
             lesson["source_coverage"]["policy"] == "full_substantive_source" and
               lesson["source_coverage"]["section_count"] == 1
           end)
  end

  test "schema v4 splits only an exceptional section and accounts for every fragment block" do
    url = "https://openstax.org/books/sample/pages/1-1-exceptional"

    blocks =
      1..11
      |> Enum.flat_map(fn index ->
        [
          %{
            "id" => "heading-#{index}",
            "kind" => "heading",
            "level" => 3,
            "text" => "Topic #{index}"
          },
          %{
            "id" => "paragraph-#{index}",
            "kind" => "paragraph",
            "text" => String.duplicate("evidence application model ", 100)
          }
        ]
      end)

    section = %{
      "title" => "1.1 Exceptional section",
      "url" => url,
      "order" => 1,
      "word_count" => 3_300,
      "learning_objectives" => ["Analyze the model", "Apply the evidence"],
      "content_blocks" => blocks,
      "coverage" => %{"complete" => true},
      "media" => []
    }

    assert {:ok, %{"units" => [%{"lessons" => lessons}]}} =
             Parser.build_outline(snapshot([section]), plan_schema_version: 4)

    assert length(lessons) > 1
    assert Enum.all?(lessons, &(&1["source_sections"] == [url]))
    assert Enum.all?(lessons, &(length(&1["source_coverage"]["source_fragments"]) == 1))

    retained_ids =
      lessons
      |> Enum.flat_map(& &1["source_coverage"]["source_block_ids"])
      |> MapSet.new()

    assert retained_ids == MapSet.new(Enum.map(blocks, & &1["id"]))
  end

  test "schema v4 distinguishes substantive blocks from deterministic omissions" do
    section =
      light_section(1)
      |> Map.put("content_blocks", [
        %{"id" => "content", "kind" => "paragraph", "text" => "Substantive evidence."},
        %{"id" => "nav", "kind" => "navigation", "text" => "Next"},
        %{"id" => "duplicate", "kind" => "duplicated_boilerplate", "text" => "OpenStax"}
      ])

    assert {:ok, %{"units" => [%{"lessons" => [lesson]}]}} =
             Parser.build_outline(snapshot([section]), plan_schema_version: 4)

    coverage = lesson["source_coverage"]
    assert coverage["substantive_block_ids"] == ["content"]
    assert coverage["deterministically_omittable_block_ids"] == ["nav", "duplicate"]
  end

  defp light_section(index) do
    %{
      "title" => "1.#{index} Light section",
      "url" => "https://openstax.org/books/sample/pages/1-#{index}-light-section",
      "order" => index,
      "word_count" => 120,
      "learning_objectives" => ["Explain topic #{index}"],
      "content_blocks" => [
        %{
          "id" => "paragraph-#{index}",
          "kind" => "paragraph",
          "text" => "Evidence for topic #{index}."
        }
      ],
      "coverage" => %{"complete" => true},
      "media" => []
    }
  end

  defp snapshot(sections) do
    %{
      "book_slug" => "sample",
      "title" => "Sample",
      "chapters" => [
        %{"id" => "chapter-1", "title" => "Chapter 1", "selected" => true, "sections" => sections}
      ]
    }
  end
end
