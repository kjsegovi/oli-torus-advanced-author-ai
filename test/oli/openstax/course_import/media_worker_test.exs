defmodule Oli.OpenStax.CourseImport.MediaWorkerTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    Lesson,
    LessonPlan,
    RichSource,
    Run,
    SourceAsset,
    Unit
  }

  alias Oli.OpenStax.CourseImport.Worker.MediaWorker
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  defmodule HTTPClient do
    def reset(responses) do
      Process.put({__MODULE__, :responses}, responses)
      Process.put({__MODULE__, :calls}, [])
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def get(url, _headers, _opts) do
      Process.put({__MODULE__, :calls}, [url | Process.get({__MODULE__, :calls}, [])])
      Map.fetch!(Process.get({__MODULE__, :responses}, %{}), url)
    end
  end

  defmodule PersistingMediaLibrary do
    def add(project_slug, file_name, bytes) do
      project = Oli.Repo.get_by!(Oli.Authoring.Course.Project, slug: project_slug)

      %Oli.Authoring.MediaLibrary.MediaItem{}
      |> Oli.Authoring.MediaLibrary.MediaItem.changeset(%{
        url: "https://media.example/#{file_name}",
        file_name: file_name,
        mime_type: "image/png",
        file_size: byte_size(bytes),
        md5_hash: Base.encode16(:crypto.hash(:md5, bytes), case: :lower),
        deleted: false,
        project_id: project.id
      })
      |> Oli.Repo.insert()
    end
  end

  setup do
    old_media_options =
      Application.get_env(:oli, :openstax_course_import_media_options, [])

    Application.put_env(
      :oli,
      :openstax_course_import_media_options,
      http_client: HTTPClient,
      media_library: PersistingMediaLibrary
    )

    on_exit(fn ->
      Application.put_env(
        :oli,
        :openstax_course_import_media_options,
        old_media_options
      )
    end)

    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax selected media worker")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/sample-book"
      )

    {:ok, run: run, project: project, root: root, author: author}
  end

  test "media staging uses a dedicated queue with a whole-course timeout budget" do
    job_changeset = MediaWorker.new(%{"run_id" => Ecto.UUID.generate()})

    assert Ecto.Changeset.get_field(job_changeset, :queue) == "course_import_media"
    assert MediaWorker.timeout(%Oban.Job{}) == :timer.hours(7)
  end

  test "dry-run selects media, worker stages it, and final compile uses MediaLibrary URLs", %{
    run: run,
    project: project,
    author: author
  } do
    source_url = "https://assets.openstax.org/figures/selected.png"

    png =
      <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", 32::32, 32::32, 8, 6, 0,
        0, 0, 0::32, "selected">>

    assert {:ok, %{assets: 1}} =
             RichSource.persist_snapshot(run.id, source_snapshot(source_url))

    asset = Repo.get_by!(SourceAsset, run_id: run.id)
    create_approved_plan(run, asset)

    run
    |> Run.update_changeset(%{
      status: :compiling,
      source_schema_version: 2,
      plan_schema_version: 3
    })
    |> Repo.update!()

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [{"content-type", "image/png"}],
           body: png
         }}
    })

    assert {:ok, staging} = CourseImport.start_apply(project, run.id, author)
    assert staging.status == :staging_media

    assert get_in(staging.result, ["compile_checkpoint", "required_media_ids"]) == [
             asset.source_key
           ]

    assert :ok = perform_job(MediaWorker, %{"run_id" => run.id})
    assert HTTPClient.calls() == [source_url]

    assert {:ok, applying} = CourseImport.fetch_run(run.id)
    assert applying.status == :applying
    assert applying.progress["counts"]["assets_staged"] == 1

    assert Enum.any?(
             get_in(applying.progress, ["timing", "stage_history"]),
             &(&1["stage"] == "staging_media")
           )

    [compiled_lesson] =
      applying.result["dry_run"]["units"]
      |> List.first()
      |> Map.fetch!("lessons")

    assert inspect(compiled_lesson["page_content_template"]) =~ "https://media.example/"
    refute inspect(compiled_lesson["page_content_template"]) =~ source_url
  end

  defp create_approved_plan(run, asset) do
    unit =
      %Unit{}
      |> Unit.changeset(%{
        run_id: run.id,
        unit_name: "Unit 1",
        order: 1,
        status: "approved",
        assessment_payload: %{
          "title" => "Unit 1 assessment",
          "authoring_mode" => "basic",
          "questions" => questions()
        }
      })
      |> Repo.insert!()

    lesson =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        order: 1,
        title: "Media lesson",
        plan_mode: "basic",
        status: "approved",
        last_plan_version: 1,
        selected: true
      })
      |> Repo.insert!()

    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 1,
      content_payload: %{
        "title" => "Media lesson",
        "objective" => "Interpret the selected diagram",
        "narrative" =>
          "Use the diagram and source-grounded explanation to compare the represented ideas.",
        "instructional_sections" => [
          %{
            "id" => "section-1",
            "title" => "Read the diagram",
            "explanation" =>
              "The diagram provides evidence that students can connect to the lesson objective."
          }
        ],
        "media" => [
          %{
            "source_media_id" => asset.source_key,
            "alt" => asset.alt_text,
            "caption" => "Selected OpenStax diagram"
          }
        ]
      },
      questions_payload: %{"items" => questions()},
      checks_snapshot: %{
        "status" => "passed",
        "results" => [
          %{
            "check_type" => "source_fidelity",
            "status" => "passed",
            "findings" => %{},
            "repair_plan" => nil
          }
        ]
      },
      created_by: "ai",
      approved_by_user: true,
      approved_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp questions do
    [
      %{"id" => "q1", "type" => "short_answer", "prompt" => "Explain the diagram."},
      %{"id" => "q2", "type" => "short_answer", "prompt" => "Apply the main idea."}
    ]
  end

  defp source_snapshot(source_url) do
    %{
      "book_slug" => "sample-book",
      "title" => "Sample Book",
      "license" => %{"license" => "CC BY-NC-SA 4.0"},
      "chapters" => [
        %{
          "id" => "chapter-1",
          "order" => 1,
          "sections" => [
            %{
              "title" => "Media section",
              "url" => "https://openstax.org/books/sample-book/pages/1-1-media",
              "content_blocks" => [
                %{
                  "id" => "block-1",
                  "kind" => "paragraph",
                  "text" => "A source-grounded explanation accompanies the selected diagram."
                }
              ],
              "media" => [
                %{
                  "id" => "media-1",
                  "source_block_id" => "block-1",
                  "src" => source_url,
                  "alt" => "A diagram comparing two ideas"
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
