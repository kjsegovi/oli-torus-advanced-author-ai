defmodule Oli.OpenStax.CourseImport.RichSourceTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    Lesson,
    RichSource,
    Run,
    SourceAsset,
    SourceBlock,
    SourceSection,
    Unit
  }

  alias Oli.OpenStax.CourseImport.Worker.OutlineWorker
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax rich source")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/sample-book"
      )

    {:ok, author: author, project: project, run: run}
  end

  test "persists semantic blocks and assets while keeping the run snapshot compact", %{
    run: run
  } do
    snapshot = source_snapshot()

    assert {:ok, %{sections: 1, blocks: 3, assets: 1}} =
             RichSource.persist_snapshot(run.id, snapshot)

    assert Repo.aggregate(
             from(section in SourceSection, where: section.run_id == ^run.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(block in SourceBlock, where: block.run_id == ^run.id),
             :count
           ) == 3

    assert Repo.aggregate(
             from(asset in SourceAsset, where: asset.run_id == ^run.id),
             :count
           ) == 1

    compact = RichSource.compact_snapshot(snapshot)
    compact_section = get_in(compact, ["chapters", Access.at(0), "sections", Access.at(0)])

    refute Map.has_key?(compact_section, "content_blocks")
    refute Map.has_key?(compact_section, "media")
    refute Map.has_key?(compact_section, "excerpt")

    assert {:ok, hydrated} = RichSource.load_snapshot(run.id, compact)
    hydrated_section = get_in(hydrated, ["chapters", Access.at(0), "sections", Access.at(0)])

    assert Enum.map(hydrated_section["source_blocks"], & &1["kind"]) == [
             "paragraph",
             "worked_example",
             "paragraph"
           ]

    assert Enum.map(hydrated_section["source_blocks"], & &1["id"]) == [
             "block-core",
             "block-example",
             "block-example-step"
           ]

    assert hydrated_section["source_word_count"] == 61
    assert hydrated_section["source_coverage"] == %{"complete" => true}
    assert [media] = hydrated_section["source_media"]
    assert media["source_url"] == "https://assets.openstax.org/figures/sample.png"
  end

  test "keeps a callout's complete body alongside its normalized persisted label", %{run: run} do
    callout_body =
      "Targeted advertising combines browsing history with computational models, raising questions about consent, transparency, and responsible data use."

    snapshot =
      source_snapshot()
      |> put_in(
        ["chapters", Access.at(0), "sections", Access.at(0), "content_blocks"],
        [
          %{
            "id" => "targeted-advertising",
            "order" => 1,
            "kind" => "callout",
            "heading_path" => ["Data Science"],
            "callout_type" => "global_issue",
            "title" => "Global Issues in Technology",
            "subtitle" => "Targeted Advertising",
            "text" => callout_body,
            "ast" => [
              %{"type" => "p", "children" => [%{"text" => callout_body}]}
            ],
            "source_locator" => %{"css" => "#targeted-advertising"},
            "blocks" => [
              %{
                "id" => "targeted-advertising-body",
                "kind" => "paragraph",
                "text" => callout_body,
                "heading_path" => ["Data Science", "Targeted Advertising"]
              }
            ]
          }
        ]
      )
      |> put_in(["chapters", Access.at(0), "sections", Access.at(0), "media"], [])

    assert {:ok, %{blocks: 2}} = RichSource.persist_snapshot(run.id, snapshot)

    assert {:ok, hydrated} =
             RichSource.load_snapshot(run.id, RichSource.compact_snapshot(snapshot))

    callout =
      hydrated
      |> get_in(["chapters", Access.at(0), "sections", Access.at(0), "source_blocks"])
      |> Enum.find(&(&1["id"] == "targeted-advertising"))

    assert callout["text"] ==
             "Global Issues in Technology Targeted Advertising callout"

    assert get_in(callout, ["metadata", "semantic_payload", "callout_type"]) ==
             "global_issue"

    assert get_in(callout, ["metadata", "semantic_payload", "subtitle"]) ==
             "Targeted Advertising"

    assert callout["callout_body"] == callout_body

    assert get_in(callout, ["ast", Access.at(0), "children", Access.at(0), "text"]) ==
             callout_body
  end

  test "links lesson evidence to ordered blocks and loads only that lesson corpus", %{
    run: run
  } do
    assert {:ok, _counts} = RichSource.persist_snapshot(run.id, source_snapshot())

    unit =
      %Unit{}
      |> Unit.changeset(%{
        run_id: run.id,
        unit_name: "Unit 1",
        order: 1
      })
      |> Repo.insert!()

    lesson =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        title: "Section 1",
        order: 1,
        source_sections: ["https://openstax.org/books/sample-book/pages/1-1-section"],
        source_evidence_links: [
          "https://openstax.org/books/sample-book/pages/1-1-section"
        ],
        source_coverage: %{"objective_coverage" => "complete"}
      })
      |> Repo.insert!()

    assert {:ok, 3} = RichSource.link_lessons(run.id)
    assert {:ok, corpus} = RichSource.load_lesson_corpus(lesson.id)

    assert Enum.map(corpus["source_blocks"], & &1["order"]) == [1, 2, 3]
    assert length(corpus["source_sections"]) == 1
    assert length(corpus["source_media"]) == 1
    assert corpus["source_word_count"] == 61
    assert corpus["source_coverage"]["linked_block_count"] == 3
    assert corpus["source_coverage"]["objective_coverage"] == "complete"

    assert {:ok, wrapped} = CourseImport.load_lesson_source_corpus(lesson.id)
    assert wrapped["source_blocks"] == corpus["source_blocks"]
  end

  test "links two fragments of one source URL only to their exact blocks and media", %{
    run: run
  } do
    assert {:ok, _counts} = RichSource.persist_snapshot(run.id, source_snapshot())

    unit =
      %Unit{}
      |> Unit.changeset(%{
        run_id: run.id,
        unit_name: "Unit 1",
        order: 1
      })
      |> Repo.insert!()

    source_url = "https://openstax.org/books/sample-book/pages/1-1-section"

    first =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        title: "Section 1 — Part 1",
        order: 1,
        source_sections: [source_url],
        source_evidence_links: [source_url],
        source_word_count: 20,
        source_coverage: %{
          "source_block_ids" => ["block-core"],
          "source_media_ids" => []
        }
      })
      |> Repo.insert!()

    second =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        title: "Section 1 — Part 2",
        order: 2,
        source_sections: [source_url],
        source_evidence_links: [source_url],
        source_word_count: 41,
        source_coverage: %{
          "source_block_ids" => ["block-example", "block-example-step"],
          "source_media_ids" => ["media-sample"]
        }
      })
      |> Repo.insert!()

    assert {:ok, 3} = RichSource.link_lessons(run.id)
    assert {:ok, first_corpus} = RichSource.load_lesson_corpus(first.id)
    assert {:ok, second_corpus} = RichSource.load_lesson_corpus(second.id)

    assert Enum.map(first_corpus["source_blocks"], & &1["id"]) == ["block-core"]

    assert Enum.map(second_corpus["source_blocks"], & &1["id"]) == [
             "block-example",
             "block-example-step"
           ]

    assert first_corpus["source_media"] == []
    assert Enum.map(second_corpus["source_media"], & &1["id"]) == ["media-sample"]

    assert first_corpus["source_coverage"]["linked_source_block_ids"] == ["block-core"]
    assert first_corpus["source_coverage"]["linked_source_media_ids"] == []

    assert second_corpus["source_coverage"]["linked_source_block_ids"] == [
             "block-example",
             "block-example-step"
           ]

    assert second_corpus["source_coverage"]["linked_source_media_ids"] == ["media-sample"]
  end

  test "new staging and needs-attention states satisfy schema and database constraints", %{
    run: run
  } do
    assert {:ok, staging_run} =
             run
             |> Run.update_changeset(%{status: :staging_media})
             |> Repo.update()

    unit =
      %Unit{}
      |> Unit.changeset(%{run_id: run.id, unit_name: "Unit 1", order: 1})
      |> Repo.insert!()

    assert {:ok, lesson} =
             %Lesson{}
             |> Lesson.changeset(%{
               run_id: run.id,
               unit_id: unit.id,
               title: "Needs media review",
               order: 1,
               status: "needs_attention"
             })
             |> Repo.insert()

    assert staging_run.status == :staging_media
    assert lesson.status == "needs_attention"
  end

  test "outline worker resumes rich planning from the compact durable checkpoint", %{run: run} do
    snapshot =
      update_in(
        source_snapshot(),
        ["chapters", Access.at(0), "sections", Access.at(0)],
        &Map.put(&1, "media", [])
      )

    assert {:ok, %{assets: 0}} = RichSource.persist_snapshot(run.id, snapshot)
    compact = RichSource.compact_snapshot(snapshot)

    assert {:ok, _run} =
             run
             |> Run.update_changeset(%{
               status: :planning_outline,
               source_schema_version: 3,
               preflight_snapshot: compact,
               scope_manifest: %{"selected_chapter_ids" => ["chapter-1"]}
             })
             |> Repo.update()

    assert :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    assert {:ok, resumed} = CourseImport.fetch_run(run.id)
    assert resumed.status == :awaiting_outline_approval
  end

  defp source_snapshot do
    %{
      "book_slug" => "sample-book",
      "title" => "Sample Book",
      "ingested_at" => "2026-07-30T12:00:00Z",
      "license" => %{"license" => "CC BY 4.0"},
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "Chapter 1",
          "order" => 1,
          "sections" => [
            %{
              "title" => "Section 1",
              "url" => "https://openstax.org/books/sample-book/pages/1-1-section",
              "order" => 1,
              "excerpt" => "This full fallback body must not remain on the run checkpoint.",
              "learning_objectives" => ["Explain the sample concept"],
              "word_count" => 61,
              "coverage" => %{"complete" => true},
              "content_blocks" => [
                %{
                  "id" => "block-core",
                  "order" => 1,
                  "kind" => "paragraph",
                  "heading_path" => ["Section 1", "Core idea"],
                  "text" =>
                    "The sample concept begins with a source-grounded explanation that learners can connect to the section objective.",
                  "source_locator" => %{"css" => "#core-idea"},
                  "token_estimate" => 22
                },
                %{
                  "id" => "block-example",
                  "order" => 2,
                  "kind" => "worked_example",
                  "heading_path" => ["Section 1", "Example"],
                  "text" =>
                    "A worked sample applies the concept, records each reasoning step, and checks the result against the source.",
                  "source_locator" => %{"css" => "#example"},
                  "token_estimate" => 24,
                  "blocks" => [
                    %{
                      "id" => "block-example-step",
                      "kind" => "paragraph",
                      "text" => "The worked example begins by identifying the known values.",
                      "heading_path" => ["Section 1", "Example"]
                    }
                  ]
                }
              ],
              "media" => [
                %{
                  "id" => "media-sample",
                  "src" => "https://assets.openstax.org/figures/sample.png",
                  "source_block_id" => "block-example",
                  "alt" => "Sample concept diagram",
                  "caption" => "A source-grounded sample diagram",
                  "mime_type" => "image/png"
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
