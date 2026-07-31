defmodule Oli.GoogleSlides.ImportWorkflow.GenerationAtomicityTest do
  use Oli.DataCase, async: false

  import Oli.Factory

  alias Oli.GoogleSlides.{Credentials, ImportRun}
  alias Oli.GoogleSlides.ImportRuns.PubSub
  alias Oli.GoogleSlides.ImportWorkflow.{Generation, LessonApplier}
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  defmodule CredentialsStub do
    def get_credentials_map(_project_id), do: {:ok, %{"stub" => true}}
  end

  defmodule SlidesClientStub do
    def fetch_access_token(_credentials), do: {:ok, "access-token"}

    def fetch_presentation_json(_presentation_url, _access_token, _credentials),
      do: {:ok, %{"presentationId" => "presentation-1"}}
  end

  defmodule ParserStub do
    alias Oli.GoogleSlides.PresentationParser.Slide

    def parse(_presentation_json, _opts) do
      slides =
        Process.get(:generation_parser_slides, [
          %Slide{
            index: 1,
            object_id: "slide-1",
            title: "Slide 1",
            title_from_placeholder: true,
            paragraphs: [],
            list_items: [],
            content_blocks: [],
            images: [],
            raw_elements: [],
            notes_text: ""
          }
        ])

      {:ok, slides, []}
    end
  end

  defmodule SnapshotStub do
    def build(_presentation_json, _slides, _presentation_url) do
      %{"presentation" => %{"fingerprint" => "source-fingerprint"}}
    end
  end

  defmodule ProvenanceStub do
    def validate(_lesson_plan, _source_snapshot), do: :ok
  end

  defmodule FidelityStub do
    def validate(_lesson_plan, _source_snapshot) do
      Process.get(:generation_fidelity_result, :ok)
    end
  end

  defmodule MediaIngestorStub do
    def ingest_images(_images, _project_slug, _access_token) do
      Process.get(:generation_media_ingestor_result, {:ok, %{}, []})
    end
  end

  defmodule CompilerStub do
    alias Oli.GoogleSlides.ImportRun
    alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
    alias Oli.Repo

    def compile(_lesson_plan, _media_urls, _opts) do
      unless Process.get(:generation_compiler_action_complete, false) do
        Process.put(:generation_compiler_action_complete, true)
        run_compiler_action(Process.get(:generation_compiler_action))
      end

      {:ok, %{compiled: true}}
    end

    defp run_compiler_action({:append_concurrent_child, project, author, resource_id, child_id}) do
      container = AuthoringResolver.from_resource_id(project.slug, resource_id)

      {:ok, _revision} =
        ChangeTracker.track_revision(project.slug, container, %{
          children: (container.children || []) ++ [child_id],
          author_id: author.id
        })
    end

    defp run_compiler_action({:cancel, run_id}) do
      run = Repo.get!(ImportRun, run_id)

      run
      |> ImportRun.update_changeset(%{
        status: :cancelled,
        finished_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end

    defp run_compiler_action(_action), do: :ok
  end

  defmodule ApplierStub do
    alias Oli.Publishing.ChangeTracker
    alias Oli.Repo
    alias Oli.Resources.Revision

    def apply(project, container, author, _compiled, _lesson_plan) do
      send(self(), {:applier_called, container.id, container.children || []})
      imported_child_id = Process.get(:generation_imported_child_id)

      {:ok, container_revision} =
        ChangeTracker.track_revision(project.slug, container, %{
          children: (container.children || []) ++ [imported_child_id],
          author_id: author.id
        })

      page_revision =
        case Process.get(:generation_applier_result, :valid) do
          :valid ->
            container_revision

          :invalid_result_revision ->
            %Revision{
              id: -1,
              resource_id: container_revision.resource_id,
              slug: "missing-result-revision",
              title: "Missing result revision"
            }
        end

      {:ok,
       %{
         page_revision: page_revision,
         container_revision: container_revision,
         activities: [],
         objectives: []
       }}
    end

    def broadcast(_result, project_slug) do
      send(self(), {:course_broadcast, project_slug, Repo.in_transaction?()})
      :ok
    end
  end

  setup do
    seed = Seeder.base_project_with_resource2()
    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:google_slides_import, seed.project)
    Credentials.upsert!(seed.project.id, service_account_json())

    previous_config = Application.get_env(:oli, :google_slides_ai_import)

    Application.put_env(
      :oli,
      :google_slides_ai_import,
      slides_client: SlidesClientStub,
      credentials: CredentialsStub,
      presentation_parser: ParserStub,
      source_snapshot: SnapshotStub,
      media_ingestor: MediaIngestorStub,
      lesson_compiler: CompilerStub,
      lesson_applier: ApplierStub,
      provenance_validator: ProvenanceStub,
      fidelity_validator: FidelityStub
    )

    on_exit(fn ->
      restore_application_env(:oli, :google_slides_ai_import, previous_config)
    end)

    Process.delete(:generation_compiler_action)
    Process.delete(:generation_compiler_action_complete)
    Process.delete(:generation_applier_result)
    Process.delete(:generation_fidelity_result)
    Process.delete(:generation_parser_slides)
    Process.delete(:generation_media_ingestor_result)

    imported_child = insert(:resource)
    Process.put(:generation_imported_child_id, imported_child.id)

    run = generating_run(seed)

    {:ok, seed: seed, run: run, imported_child_id: imported_child.id}
  end

  test "preserves a newer target-container revision and completes the run atomically", %{
    seed: seed,
    run: run,
    imported_child_id: imported_child_id
  } do
    concurrent_child = insert(:resource)

    Process.put(
      :generation_compiler_action,
      {:append_concurrent_child, seed.project, seed.author, seed.container.resource.id,
       concurrent_child.id}
    )

    :ok = PubSub.subscribe(run.id)

    assert {:ok, completed_run} = Generation.perform(run.id)
    assert completed_run.status == :completed

    assert_receive {:applier_called, _container_revision_id, children}
    assert concurrent_child.id in children

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert concurrent_child.id in latest.children
    assert imported_child_id in latest.children
    assert completed_run.result_revision_id == latest.id
    assert_receive {:course_broadcast, project_slug, false}
    assert project_slug == seed.project.slug

    assert_receive {:google_slides_import_run_updated, %{run_id: run_id, status: :completed}}

    assert run_id == run.id
  end

  test "rolls back course writes when completing the run fails", %{seed: seed, run: run} do
    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    Process.put(:generation_applier_result, :invalid_result_revision)

    assert {:error, %Ecto.Changeset{}} = Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :generating
    refute_received {:course_broadcast, _project_slug, _in_transaction?}
  end

  test "a cancellation observed at the final lock prevents all course writes", %{
    seed: seed,
    run: run
  } do
    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    Process.put(:generation_compiler_action, {:cancel, run.id})

    assert {:error, :cancelled} = Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :cancelled
    refute_received {:applier_called, _revision_id, _children}
    refute_received {:course_broadcast, _project_slug, _in_transaction?}
  end

  test "fidelity validation fails permanently before any course write", %{seed: seed, run: run} do
    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    errors = [
      %{
        "path" => "lesson.screens[0]",
        "code" => "unresolved_source_element",
        "message" => "a source element has no reviewed disposition"
      }
    ]

    Process.put(:generation_fidelity_result, {:error, errors})

    assert {:error, {:invalid_source_fidelity, ^errors}} = Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :generating
    refute_received {:applier_called, _revision_id, _children}
    refute_received {:course_broadcast, _project_slug, _in_transaction?}
  end

  test "missing source image aborts before any course write", %{seed: seed, run: run} do
    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    run = put_generation_plan(run, media_plan("image", "image-1"))

    assert {:error, {:source_media_not_found, ["image-1"]}} = Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :generating
    refute_received {:applier_called, _revision_id, _children}
  end

  test "a partial image-ingest result aborts instead of omitting the image", %{
    seed: seed,
    run: run
  } do
    alias Oli.GoogleSlides.PresentationParser.{ImageRef, Slide}

    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    image = %ImageRef{
      object_id: "image-1",
      content_url: "https://temporary.example/image.png"
    }

    Process.put(:generation_parser_slides, [
      %Slide{
        index: 1,
        object_id: "slide-1",
        title: "Slide 1",
        title_from_placeholder: true,
        paragraphs: [],
        list_items: [],
        content_blocks: [%{type: "image", ref: image}],
        images: [image],
        raw_elements: [],
        notes_text: ""
      }
    ])

    Process.put(
      :generation_media_ingestor_result,
      {:ok, %{}, [%{"code" => "media_upload_failed"}]}
    )

    run = put_generation_plan(run, media_plan("image", "image-1"))

    assert {:error, {:source_media_ingest_failed, ["image-1"]}} =
             Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :generating
    refute_received {:applier_called, _revision_id, _children}
  end

  test "missing linked video aborts before any course write", %{seed: seed, run: run} do
    original =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    run = put_generation_plan(run, media_plan("video", "video-1"))

    assert {:error, {:source_media_not_found, ["video-1"]}} = Generation.perform(run.id)

    latest =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest.id == original.id
    assert Repo.get!(ImportRun, run.id).status == :generating
    refute_received {:applier_called, _revision_id, _children}
  end

  test "retrying after completion is idempotent", %{seed: seed, run: run} do
    assert {:ok, first_result} = Generation.perform(run.id)

    latest_after_first =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert_receive {:applier_called, _revision_id, _children}
    assert_receive {:course_broadcast, _project_slug, false}

    assert {:ok, second_result} = Generation.perform(run.id)
    assert second_result.id == first_result.id
    assert second_result.result_revision_id == first_result.result_revision_id

    latest_after_retry =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest_after_retry.id == latest_after_first.id
    refute_received {:applier_called, _revision_id, _children}
    refute_received {:course_broadcast, _project_slug, _in_transaction?}
  end

  test "the real applier creates the adaptive activity and page in the caller transaction", %{
    seed: seed
  } do
    container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    compiled = %{
      title: "Imported lesson",
      activities: [
        %{
          key: "screen-1",
          title: "Imported screen",
          objective_keys: [],
          content: %{
            "custom" => %{},
            "authoring" => %{
              "parts" => [],
              "rules" => [],
              "variablesRequiredForEvaluation" => [],
              "activitiesRequiredForEvaluation" => []
            },
            "partsLayout" => []
          }
        }
      ],
      page_content: %{
        "advancedDelivery" => true,
        "advancedAuthoring" => true,
        "model" => [
          %{
            "id" => "deck-1",
            "type" => "group",
            "layout" => "deck",
            "children" => []
          }
        ]
      }
    }

    lesson_plan = %{"objectives" => %{"mapped" => [], "proposed" => []}}

    assert {:ok, {:ok, result}} =
             Repo.transaction(fn ->
               LessonApplier.apply(
                 seed.project,
                 container,
                 seed.author,
                 compiled,
                 lesson_plan
               )
             end)

    assert [%{slug: activity_slug}] = result.activities
    assert result.page_revision.title == "Imported lesson"
    assert result.page_revision.resource_id in result.container_revision.children

    assert [
             %{
               "children" => [
                 %{
                   "type" => "activity-reference",
                   "activitySlug" => ^activity_slug
                 }
               ]
             }
           ] = result.page_revision.content["model"]

    latest_container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest_container.id == result.container_revision.id
    assert result.page_revision.resource_id in latest_container.children
  end

  test "the real applier creates ordered sibling lessons with one container revision", %{
    seed: seed
  } do
    container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    compiled = [
      compiled_lesson("First imported lesson"),
      compiled_lesson("Second imported lesson")
    ]

    import_plan = %{
      "kind" => "google_slides_lesson_plan_set",
      "schemaVersion" => 1,
      "lessons" => [empty_objective_plan(), empty_objective_plan()]
    }

    assert {:ok, {:ok, result}} =
             Repo.transaction(fn ->
               LessonApplier.apply_many(
                 seed.project,
                 container,
                 seed.author,
                 compiled,
                 import_plan
               )
             end)

    assert Enum.map(result.page_revisions, & &1.title) == [
             "First imported lesson",
             "Second imported lesson"
           ]

    generated_ids = Enum.map(result.page_revisions, & &1.resource_id)
    assert Enum.take(result.container_revision.children, -2) == generated_ids

    latest_container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest_container.id == result.container_revision.id
    assert Enum.take(latest_container.children, -2) == generated_ids
  end

  test "a later sibling lesson failure rolls back every generated resource", %{seed: seed} do
    container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    invalid_second =
      compiled_lesson("Invalid second lesson")
      |> put_in([:page_content, "model"], [])

    import_plan = %{
      "kind" => "google_slides_lesson_plan_set",
      "schemaVersion" => 1,
      "lessons" => [empty_objective_plan(), empty_objective_plan()]
    }

    assert {:error, :invalid_compiled_page_model} =
             Repo.transaction(fn ->
               case LessonApplier.apply_many(
                      seed.project,
                      container,
                      seed.author,
                      [compiled_lesson("First imported lesson"), invalid_second],
                      import_plan
                    ) do
                 {:ok, result} -> result
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    latest_container =
      AuthoringResolver.from_resource_id(seed.project.slug, seed.container.resource.id)

    assert latest_container.id == container.id
  end

  defp generating_run(seed) do
    now = DateTime.utc_now()

    {:ok, run} =
      %ImportRun{}
      |> ImportRun.create_changeset(%{
        project_id: seed.project.id,
        author_id: seed.author.id,
        target_container_resource_id: seed.container.resource.id,
        presentation_url: "https://docs.google.com/presentation/d/presentation-1/edit",
        analysis_started_at: now
      })
      |> Repo.insert()

    run
    |> ImportRun.update_changeset(%{
      status: :generating,
      lesson_plan: %{"lesson" => %{"screens" => []}},
      presentation_fingerprint: "source-fingerprint",
      plan_version: 1,
      approved_plan_version: 1,
      approved_by_author_id: seed.author.id,
      approved_at: now,
      generation_started_at: now
    })
    |> Repo.update!()
  end

  defp put_generation_plan(run, plan) do
    run
    |> ImportRun.update_changeset(%{lesson_plan: plan})
    |> Repo.update!()
  end

  defp media_plan(kind, object_id) do
    %{
      "lesson" => %{
        "screens" => [
          %{
            "parts" => [
              %{
                "kind" => kind,
                "content" => %{"sourceObjectId" => object_id}
              }
            ]
          }
        ]
      }
    }
  end

  defp compiled_lesson(title) do
    %{
      title: title,
      runtime_ai_enabled: false,
      activities: [],
      page_content: %{
        "advancedDelivery" => true,
        "advancedAuthoring" => true,
        "model" => [
          %{
            "id" => "deck-#{String.replace(title, " ", "-")}",
            "type" => "group",
            "layout" => "deck",
            "children" => []
          }
        ]
      }
    }
  end

  defp empty_objective_plan,
    do: %{"objectives" => %{"mapped" => [], "proposed" => []}}

  defp service_account_json do
    Jason.encode!(%{
      "type" => "service_account",
      "project_id" => "test-project",
      "private_key_id" => "key-id",
      "private_key" => "not-used-by-the-test",
      "client_email" => "slides@test-project.iam.gserviceaccount.com",
      "client_id" => "123",
      "auth_uri" => "https://accounts.google.com/o/oauth2/auth",
      "token_uri" => "https://oauth2.googleapis.com/token",
      "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs",
      "client_x509_cert_url" => "https://www.googleapis.com/robot/v1/metadata/x509/slides"
    })
  end

  defp restore_application_env(application, key, nil),
    do: Application.delete_env(application, key)

  defp restore_application_env(application, key, value),
    do: Application.put_env(application, key, value)
end
