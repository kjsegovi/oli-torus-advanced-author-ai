defmodule Oli.OpenStax.CourseImport.Chemistry2eV4GoldenTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Checks, FullSource, Parser, Planner}

  @book_slug "chemistry-2e"
  @book_title "Chemistry 2e"
  @chapter_url "https://openstax.org/books/chemistry-2e/pages/1-introduction"
  @sparse_url "https://openstax.org/books/chemistry-2e/pages/1-1-chemistry-in-context"
  @media_url "https://openstax.org/books/chemistry-2e/pages/1-2-phases-and-classification-of-matter"
  @exceptional_url "https://openstax.org/books/chemistry-2e/pages/1-4-measurements"

  test "Chemistry 2e sparse, media-rich, and exceptional sections retain the v4 golden shape" do
    snapshot = chemistry_snapshot()

    assert {:ok, %{"units" => [%{"lessons" => lessons}]}} =
             Parser.build_outline(snapshot, plan_schema_version: 4)

    grouped_by_source = Enum.group_by(lessons, &List.first(&1["source_sections"]))

    assert length(grouped_by_source[@sparse_url]) == 1
    assert length(grouped_by_source[@media_url]) == 1
    assert length(grouped_by_source[@exceptional_url]) == 3
    assert length(lessons) == 5

    assert Enum.all?(lessons, fn lesson ->
             length(lesson["source_sections"]) == 1 and
               lesson["source_coverage"]["policy"] == "full_substantive_source" and
               lesson["source_coverage"]["complete"] == true
           end)

    source_ids =
      snapshot["chapters"]
      |> hd()
      |> Map.fetch!("sections")
      |> Enum.flat_map(&Enum.map(&1["content_blocks"], fn block -> block["id"] end))
      |> MapSet.new()

    imported_ids =
      lessons
      |> Enum.flat_map(& &1["source_coverage"]["source_block_ids"])
      |> MapSet.new()

    assert imported_ids == source_ids

    media_lesson = grouped_by_source[@media_url] |> List.first()
    assert media_lesson["source_coverage"]["media_count"] == 2

    assert Enum.map(media_lesson["source_media"], & &1["id"]) == [
             "chemistry-states-of-matter",
             "chemistry-mixture-classification"
           ]

    exceptional_fragments = grouped_by_source[@exceptional_url]

    assert Enum.map(exceptional_fragments, &get_in(&1, ["source_coverage", "source_fragments"]))
           |> Enum.all?(&(length(&1) == 1))

    plans =
      lessons
      |> Enum.with_index(1)
      |> Enum.map(fn {lesson, index} ->
        {mode, plan} = Planner.build_lesson_plan(lesson, index, plan_schema_version: 4)

        assert get_in(plan, ["content_payload", "schema_version"]) == 4

        assert get_in(plan, ["content_payload", "coverage_manifest", "policy"]) ==
                 "full_substantive_source"

        assert get_in(plan, ["content_payload", "coverage_manifest", "unaccounted_block_ids"]) ==
                 []

        rendered_instruction =
          plan
          |> get_in(["content_payload", "instructional_sections"])
          |> Enum.map_join(" ", &"#{&1["heading"]} #{&1["explanation"]}")
          |> FullSource.normalized_text()

        substantive_ids =
          lesson["source_coverage"]["substantive_block_ids"]
          |> MapSet.new()

        assert Enum.all?(lesson["source_blocks"], fn block ->
                 source_text = FullSource.normalized_text(block["text"])

                 not MapSet.member?(substantive_ids, block["id"]) or source_text == "" or
                   String.contains?(rendered_instruction, source_text)
               end)

        assert Checks.passed?(Checks.run(lesson, plan))
        {mode, plan}
      end)

    assert Enum.any?(plans, fn {mode, _plan} -> mode == "basic" end)
    assert Enum.any?(plans, fn {mode, _plan} -> mode == "advanced" end)
  end

  defp chemistry_snapshot do
    %{
      "book_slug" => @book_slug,
      "title" => @book_title,
      "license" => %{"code" => "CC BY 4.0"},
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "1 Essential Ideas",
          "order" => 1,
          "selected" => true,
          "url" => @chapter_url,
          "sections" => [sparse_section(), media_rich_section(), exceptional_section()]
        }
      ]
    }
  end

  defp sparse_section do
    %{
      "title" => "1.1 Chemistry in Context",
      "url" => @sparse_url,
      "order" => 1,
      "word_count" => 94,
      "learning_objectives" => [
        "Describe chemistry as the study of matter and its changes."
      ],
      "content_blocks" => [
        block(
          "chemistry-context-objective",
          "objectives",
          "Describe chemistry as the study of matter and its changes."
        ),
        block("chemistry-context-heading", "heading", "Matter", %{"level" => 2}),
        block(
          "chemistry-context-paragraph",
          "paragraph",
          "Chemistry examines matter, its properties, and the transformations that connect observations to explanations."
        ),
        block("chemistry-observation-heading", "heading", "Observation", %{"level" => 3}),
        block(
          "chemistry-observation-paragraph",
          "paragraph",
          "Macroscopic observations provide evidence that chemists use to describe materials and changes."
        ),
        block("chemistry-model-heading", "heading", "Models", %{"level" => 3}),
        block(
          "chemistry-model-paragraph",
          "paragraph",
          "Particle-level models connect visible properties with explanations about composition and structure."
        ),
        block("chemistry-context-decision-heading", "heading", "Application", %{
          "level" => 3
        }),
        block(
          "chemistry-context-decision-paragraph",
          "paragraph",
          "Evidence about matter supports decisions about materials, processes, safety, and environmental change."
        ),
        block("chemistry-context-navigation", "navigation", "Next section")
      ],
      "coverage" => %{"complete" => true},
      "media" => []
    }
  end

  defp media_rich_section do
    %{
      "title" => "1.2 Phases and Classification of Matter",
      "url" => @media_url,
      "order" => 2,
      "word_count" => 720,
      "learning_objectives" => [
        "Identify the phases of matter.",
        "Classify matter as a pure substance or mixture."
      ],
      "content_blocks" => [
        block(
          "chemistry-matter-objectives",
          "objectives",
          "Identify the phases of matter. Classify matter as a pure substance or mixture."
        ),
        block("chemistry-matter-heading", "heading", "States and particle arrangements", %{
          "level" => 2
        }),
        block(
          "chemistry-matter-paragraph",
          "paragraph",
          repeated_text(
            "Particles, energy, spacing, and motion provide evidence for distinguishing solid, liquid, gas, and plasma states",
            36
          )
        ),
        block("chemistry-states-evidence-heading", "heading", "Phase comparison evidence", %{
          "level" => 3
        }),
        block(
          "chemistry-states-figure",
          "figure",
          "Particle diagrams compare the spacing and motion associated with common states of matter."
        ),
        block("chemistry-mixtures-heading", "heading", "Substances and mixtures", %{"level" => 2}),
        block(
          "chemistry-mixtures-paragraph",
          "paragraph",
          repeated_text(
            "A pure substance has a fixed composition, while a mixture contains components whose proportions can vary",
            34
          )
        ),
        block(
          "chemistry-mixtures-evidence-heading",
          "heading",
          "Classification evidence",
          %{"level" => 3}
        ),
        block(
          "chemistry-mixtures-figure",
          "figure",
          "A classification diagram distinguishes elements, compounds, homogeneous mixtures, and heterogeneous mixtures."
        )
      ],
      "coverage" => %{"complete" => true},
      "media" => [
        media(
          "chemistry-states-of-matter",
          "chemistry-states-figure",
          "Particle diagrams for solid, liquid, and gas"
        ),
        media(
          "chemistry-mixture-classification",
          "chemistry-mixtures-figure",
          "Matter classification tree"
        )
      ]
    }
  end

  defp exceptional_section do
    chunks =
      1..12
      |> Enum.flat_map(fn index ->
        [
          block(
            "chemistry-measurement-heading-#{index}",
            "heading",
            "Measurement boundary #{index}",
            %{"level" => 3}
          ),
          block(
            "chemistry-measurement-paragraph-#{index}",
            "paragraph",
            repeated_text(
              "A measured quantity joins a numerical value, unit, uncertainty, and evidence appropriate to the instrument and decision",
              22
            )
          )
        ]
      end)

    %{
      "title" => "1.4 Measurements",
      "url" => @exceptional_url,
      "order" => 4,
      "word_count" => 3_600,
      "learning_objectives" => [
        "Express measured quantities with appropriate units.",
        "Use uncertainty and significant figures when interpreting measurements."
      ],
      "content_blocks" =>
        [
          block(
            "chemistry-measurement-objectives",
            "objectives",
            "Express measured quantities with appropriate units. Use uncertainty and significant figures when interpreting measurements."
          )
        ] ++ chunks,
      "coverage" => %{"complete" => true},
      "media" => []
    }
  end

  defp block(id, kind, text, extra \\ %{}) do
    Map.merge(%{"id" => id, "kind" => kind, "text" => text}, extra)
  end

  defp media(id, source_block_id, alt) do
    %{
      "id" => id,
      "source_block_id" => source_block_id,
      "src" => "https://openstax.org/apps/archive/20240814.158841/resources/#{id}.jpg",
      "alt" => alt,
      "caption" => alt,
      "credit" => "OpenStax, CC BY 4.0",
      "rights_status" => "approved"
    }
  end

  defp repeated_text(sentence, count),
    do: List.duplicate(sentence <> ".", count) |> Enum.join(" ")
end
