defmodule Oli.OpenStax.CourseImportTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.Authoring.Course
  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.Worker.{
    ApplyWorker,
    LessonPlannerWorker,
    OutlineWorker,
    PreflightWorker
  }

  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  defmodule DeterministicLessonPlanner do
    def plan(lesson, index, opts) do
      {plan_mode, payload} =
        Oli.OpenStax.CourseImport.Planner.build_lesson_plan(lesson, index, opts)

      {:ok,
       %{
         plan_mode: plan_mode,
         payload: payload,
         enrichment_proposals: [],
         created_by: "system",
         metadata: %{strategy: :deterministic_test}
       }}
    end
  end

  defmodule HTTPClient do
    def get("https://openstax.org/details/books/sample-book", _headers, _opts) do
      {:ok,
       %{
         status_code: 200,
         body: """
         <html><main><h1>Sample Book</h1>
           <a href="/books/sample-book/pages/1-introduction">Ch. 1 Introduction</a>
           <a href="/books/sample-book/pages/1-1-first-topic">1.1 First Topic</a>
           <a href="/books/sample-book/pages/1-2-second-topic">1.2 Second Topic</a>
           <a href="/books/sample-book/pages/2-introduction">Ch. 2 Introduction</a>
           <a href="/books/sample-book/pages/2-1-third-topic">2.1 Third Topic</a>
         </main></html>
         """
       }}
    end

    def get(url, _headers, _opts) do
      title =
        url
        |> URI.parse()
        |> Map.fetch!(:path)
        |> String.split("/")
        |> List.last()
        |> String.replace("-", " ")

      {:ok,
       %{
         status_code: 200,
         body:
           if(String.ends_with?(title, "introduction"),
             do: introduction_html(title),
             else: rich_section_html(title)
           )
       }}
    end

    defp introduction_html(title) do
      """
      <html><main>
        <h1>#{title}</h1>
        <div data-book-content="true">
          <p>This chapter introduction previews the evidence, models, constraints, and applications developed in the numbered sections.</p>
        </div>
      </main></html>
      """
    end

    defp rich_section_html(title) do
      paragraph = fn focus ->
        String.duplicate(
          "#{title} develops #{focus} through evidence, models, constraints, and examples. " <>
            "Learners compare explanations, identify the relevant conditions, apply the model " <>
            "to a concrete decision, and evaluate whether the conclusion follows from the evidence. " <>
            "A careful analysis distinguishes observations from assumptions and explains how a " <>
            "change in context can alter the result. ",
          4
        )
      end

      """
      <html><main>
        <h1>#{title}</h1>
        <div data-book-content="true">
          <div class="learning-objectives">
            <ul>
              <li>Explain the evidence and central model in #{title}</li>
              <li>Compare the major explanations presented in #{title}</li>
              <li>Apply the constraints from #{title} to a new situation</li>
              <li>Evaluate a decision using evidence from #{title}</li>
            </ul>
          </div>
          <h2>Evidence and observations</h2>
          <p>#{paragraph.("evidence and observations")}</p>
          <h2>Models and explanations</h2>
          <p>#{paragraph.("models and explanations")}</p>
          <h2>Constraints and tradeoffs</h2>
          <p>#{paragraph.("constraints and tradeoffs")}</p>
          <h2>Applications and decisions</h2>
          <p>#{paragraph.("applications and decisions")}</p>
        </div>
      </main></html>
      """
    end
  end

  defmodule TimeoutHTTPClient do
    def get(_url, _headers, _opts) do
      Process.sleep(100)
      {:error, :unavailable}
    end
  end

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax import project")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    previous_options =
      Application.get_env(:oli, :openstax_course_import_source_options)

    previous_lesson_planner =
      Application.get_env(:oli, :openstax_course_import_lesson_planner)

    previous_test_conveniences =
      Application.get_env(:oli, :openstax_course_import_test_conveniences_enabled)

    Application.put_env(:oli, :openstax_course_import_test_conveniences_enabled, false)

    Application.put_env(
      :oli,
      :openstax_course_import_source_options,
      http_client: HTTPClient
    )

    Application.put_env(
      :oli,
      :openstax_course_import_lesson_planner,
      DeterministicLessonPlanner
    )

    on_exit(fn ->
      if is_nil(previous_options) do
        Application.delete_env(:oli, :openstax_course_import_source_options)
      else
        Application.put_env(
          :oli,
          :openstax_course_import_source_options,
          previous_options
        )
      end

      if is_nil(previous_lesson_planner) do
        Application.delete_env(:oli, :openstax_course_import_lesson_planner)
      else
        Application.put_env(
          :oli,
          :openstax_course_import_lesson_planner,
          previous_lesson_planner
        )
      end

      if is_nil(previous_test_conveniences) do
        Application.delete_env(:oli, :openstax_course_import_test_conveniences_enabled)
      else
        Application.put_env(
          :oli,
          :openstax_course_import_test_conveniences_enabled,
          previous_test_conveniences
        )
      end
    end)

    {:ok, author: author, project: project, root: root}
  end

  test "local conveniences enable the authorized importer without persisting a project flag", %{
    author: author
  } do
    %{project: project} = project_fixture(author, "Unflagged local OpenStax import")
    previous_env = Application.get_env(:oli, :env)

    on_exit(fn -> Application.put_env(:oli, :env, previous_env) end)

    assert ScopedFeatureFlags.list_project_features(project) == []
    refute CourseImport.available?(project, author)

    Application.put_env(:oli, :openstax_course_import_test_conveniences_enabled, true)

    assert CourseImport.available?(project, author)
    assert ScopedFeatureFlags.list_project_features(project) == []

    Application.put_env(:oli, :env, :prod)
    refute CourseImport.test_conveniences_enabled?()
    refute CourseImport.available?(project, author)
    Application.put_env(:oli, :env, :test)
  end

  test "Basic v5 is unconditionally enabled only in local development", %{
    project: project
  } do
    previous_env = Application.get_env(:oli, :env)
    previous_v5 = Application.get_env(:oli, :openstax_basic_pages_v5_enabled)

    on_exit(fn ->
      Application.put_env(:oli, :env, previous_env)
      Application.put_env(:oli, :openstax_basic_pages_v5_enabled, previous_v5)
    end)

    Application.put_env(:oli, :openstax_basic_pages_v5_enabled, false)
    Application.put_env(:oli, :env, :dev)
    assert CourseImport.basic_v5_enabled?(project)

    Application.put_env(:oli, :env, :prod)
    refute CourseImport.basic_v5_enabled?(project)
  end

  test "new imports persist only the rich source and Basic v5 write contract", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert run.source_schema_version == 3
    assert run.plan_schema_version == 5
  end

  test "initial chapter selection follows the convenience mode and retries preserve stored choices",
       %{
         author: author,
         project: production_project,
         root: production_root
       } do
    snapshot = %{
      "book_slug" => "sample-book",
      "title" => "Sample Book",
      "chapters" => [
        %{"id" => "chapter-1", "title" => "Chapter 1"},
        %{"id" => "chapter-2", "title" => "Chapter 2"}
      ]
    }

    assert {:ok, production_run} =
             CourseImport.start_import(
               production_project,
               production_root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:ok, production_run} =
             CourseImport.persist_scope_snapshot(production_run.id, snapshot)

    assert production_run.scope_manifest["selected_chapter_ids"] == ["chapter-1", "chapter-2"]
    assert Enum.all?(production_run.scope_manifest["chapters"], & &1["selected"])

    %{project: local_project, resource_revision: local_root} =
      project_fixture(author, "Local convenience chapter scope")

    Application.put_env(:oli, :openstax_course_import_test_conveniences_enabled, true)

    assert {:ok, local_run} =
             CourseImport.start_import(
               local_project,
               local_root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:ok, local_run} = CourseImport.persist_scope_snapshot(local_run.id, snapshot)
    assert local_run.scope_manifest["selected_chapter_ids"] == []
    refute Enum.any?(local_run.scope_manifest["chapters"], & &1["selected"])

    stored_manifest = %{
      local_run.scope_manifest
      | "selected_chapter_ids" => ["chapter-2"],
        "chapters" =>
          Enum.map(local_run.scope_manifest["chapters"], fn chapter ->
            Map.put(chapter, "selected", chapter["id"] == "chapter-2")
          end)
    }

    local_run
    |> Ecto.Changeset.change(scope_manifest: stored_manifest)
    |> Repo.update!()

    assert {:ok, retried_run} = CourseImport.persist_scope_snapshot(local_run.id, snapshot)
    assert retried_run.scope_manifest["selected_chapter_ids"] == ["chapter-2"]

    refute Enum.find(retried_run.scope_manifest["chapters"], &(&1["id"] == "chapter-1"))[
             "selected"
           ]

    assert Enum.find(retried_run.scope_manifest["chapters"], &(&1["id"] == "chapter-2"))[
             "selected"
           ]
  end

  test "progress checkpoints retain timing samples for adaptive estimates", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    total = fn completed ->
      [
        %{
          "label" => "Preflight items checked",
          "completed" => completed,
          "total" => 2
        }
      ]
    end

    item_started_at = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.to_iso8601()

    assert {:ok, _run} =
             CourseImport.set_progress(
               run.id,
               %{
                 "stage_totals" => total.(0),
                 "work_state" => "running",
                 "current_item" => %{
                   "kind" => "preflight_check",
                   "started_at" => item_started_at
                 }
               },
               :preflighting
             )

    # A nested operation may publish counts while the same item is running.
    # The eventual duration must still use current_item.started_at rather than
    # this intermediate checkpoint's timestamp.
    assert {:ok, _run} =
             CourseImport.set_progress(
               run.id,
               %{"counts" => %{"records_checked" => 1}},
               :preflighting
             )

    assert {:ok, updated} =
             CourseImport.set_progress(
               run.id,
               %{
                 "stage_totals" => total.(1),
                 "work_state" => "running",
                 "current_item" => nil
               },
               :preflighting
             )

    assert [duration] = get_in(updated.progress, ["timing", "item_durations_seconds"])
    assert is_number(duration)
    assert duration >= 29
    assert updated.progress["work_state"] == "running"
  end

  test "chapter scope, outline, lesson checks, explicit approvals, and atomic apply are resumable",
       %{author: author, project: project, root: root} do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    run = legacy_test_run(run)

    assert run.status == :preflighting
    assert run.progress["work_state"] == "queued"
    assert get_in(run.progress, ["timing", "stage_started_at"])
    assert get_in(run.progress, ["timing", "last_progress_at"])

    assert {:ok, checkpoint} =
             CourseImport.get_run_checkpoint(project, author, run.id)

    assert %Ecto.Association.NotLoaded{} = checkpoint.units
    assert :ok = perform_job(PreflightWorker, %{"run_id" => run.id})

    assert {:ok, scoped_run} = CourseImport.get_run(project, author, run.id)
    assert scoped_run.status == :awaiting_scope
    assert length(scoped_run.scope_manifest["chapters"]) == 2

    assert {:ok, ingesting} =
             CourseImport.update_scope(run.id, author, ["chapter-1"])

    assert ingesting.status == :ingesting
    assert :ok = perform_job(OutlineWorker, %{"run_id" => run.id})

    assert {:ok, outline_run} = CourseImport.get_run(project, author, run.id)
    assert outline_run.status == :awaiting_outline_approval
    assert length(outline_run.units) == 1
    assert length(hd(outline_run.units).lessons) == 2
    assert hd(outline_run.units).assessment_payload["questions"] != []

    use_serial_lesson_planner(run.id)
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    assert planning.status == :planning_lessons
    assert planning.progress["stage"] == "planning_lessons"
    assert planning.progress["work_state"] == "queued"
    assert get_in(planning.progress, ["timing", "stage_started_at"])
    assert :ok = perform_job(LessonPlannerWorker, %{"run_id" => run.id})

    assert {:ok, review_run} = CourseImport.get_run(project, author, run.id)
    assert review_run.status == :awaiting_lesson_approval
    assert review_run.progress["stage"] == "awaiting_lesson_approval"

    assert Enum.any?(
             get_in(review_run.progress, ["timing", "stage_history"]),
             &(&1["stage"] == "planning_lessons" and is_integer(&1["duration_seconds"]))
           )

    lessons = Enum.flat_map(review_run.units, & &1.lessons)

    failed_lesson_checks =
      Enum.flat_map(lessons, fn lesson ->
        latest = List.first(lesson.plans)

        if latest.checks_snapshot["status"] == "passed" and
             length(latest.questions_payload["items"]) in 4..6 do
          []
        else
          [
            %{
              lesson: lesson.title,
              status: latest.checks_snapshot["status"],
              results: latest.checks_snapshot["results"],
              question_count: length(latest.questions_payload["items"])
            }
          ]
        end
      end)

    assert failed_lesson_checks == []

    [edited_lesson, adaptive_lesson | _] = lessons
    old_version = edited_lesson.last_plan_version
    original_plan = List.first(edited_lesson.plans)

    revised_narrative =
      original_plan.content_payload["narrative"] <>
        "\n\n" <>
        hd(original_plan.content_payload["instructional_sections"])["explanation"]

    assert {:ok, edited} =
             CourseImport.update_lesson_plan(
               edited_lesson.id,
               author,
               %{
                 "content_payload" => %{"narrative" => revised_narrative}
               },
               edited_lesson.plan_mode
             )

    latest_edited_plan = Enum.max_by(edited.plans, & &1.version)

    assert edited.last_plan_version > old_version
    assert latest_edited_plan.content_payload["narrative"] == revised_narrative
    assert latest_edited_plan.questions_payload == original_plan.questions_payload
    assert latest_edited_plan.checks_snapshot["status"] == "passed"
    refute latest_edited_plan.approved_by_user

    assert {:ok, adaptive} =
             CourseImport.update_lesson_plan(
               adaptive_lesson.id,
               author,
               %{"content_payload" => %{}},
               "advanced"
             )

    latest_adaptive_plan = Enum.max_by(adaptive.plans, & &1.version)

    assert latest_adaptive_plan.checks_snapshot["status"] == "passed",
           inspect(latest_adaptive_plan.checks_snapshot["results"],
             pretty: true,
             limit: :infinity
           )

    assert adaptive.plan_mode == "advanced"

    assert [
             %{
               "kind" => "decision",
               "interaction_type" => "multiple_choice",
               "choices" => [_correct, _incorrect]
             }
           ] = latest_adaptive_plan.content_payload["advanced_blueprint"]["screens"]

    refute latest_adaptive_plan.approved_by_user

    Enum.each(lessons, fn lesson ->
      assert {:ok, _lesson} = CourseImport.approve_lesson(run.id, lesson.id, author)
    end)

    assert {:ok, compiled_run} = CourseImport.get_run(project, author, run.id)
    assert compiled_run.status == :compiling

    # This is the same durable checkpoint a closed browser or an email resume
    # link retrieves.
    assert {:ok, resumed} = CourseImport.load_run_details(run.id, author)
    assert resumed.status == :compiling

    assert {:ok, applying} = CourseImport.start_apply(project, run.id, author)
    assert applying.status == :applying
    assert :ok = perform_job(ApplyWorker, %{"run_id" => run.id})

    assert {:ok, completed} = CourseImport.get_run(project, author, run.id)
    assert completed.status == :completed
    assert completed.result["units_applied"] == 1
    assert completed.result["lessons_applied"] == 2
    assert completed.result["unit_assessments_applied"] == 1

    latest_root = AuthoringResolver.root_container(project.slug)
    assert length(latest_root.children) == 1

    unit =
      AuthoringResolver.from_resource_id(
        project.slug,
        hd(completed.result["unit_resource_ids"])
      )

    assert %{"version" => "0.1.0", "model" => model} = unit.content
    assert is_list(model)

    persisted_lessons =
      Enum.map(completed.result["lesson_resource_ids"], fn resource_id ->
        AuthoringResolver.from_resource_id(project.slug, resource_id)
      end)

    persisted_advanced_lesson =
      Enum.find(persisted_lessons, &(&1.title == adaptive_lesson.title))

    assert persisted_advanced_lesson.content["advancedAuthoring"]
    assert persisted_advanced_lesson.content["advancedDelivery"]
    refute persisted_advanced_lesson.graded

    assert [
             %{
               "type" => "group",
               "layout" => "deck",
               "children" => advanced_sequence
             }
           ] = persisted_advanced_lesson.content["model"]

    assert length(advanced_sequence) > 1
    assert Enum.all?(advanced_sequence, &is_integer(&1["activity_id"]))

    adaptive_registration = Oli.Activities.get_registration_by_slug("oli_adaptive")

    persisted_adaptive_activities =
      Enum.map(advanced_sequence, fn %{"activity_id" => activity_id} ->
        AuthoringResolver.from_resource_id(project.slug, activity_id)
      end)

    assert Enum.all?(
             persisted_adaptive_activities,
             &(&1.activity_type_id == adaptive_registration.id)
           )

    assert Enum.any?(persisted_adaptive_activities, fn activity ->
             Enum.any?(activity.content["partsLayout"], &(&1["type"] == "janus-mcq"))
           end)

    assert Enum.any?(persisted_adaptive_activities, fn activity ->
             Enum.any?(activity.content["authoring"]["rules"], fn rule ->
               rule["name"] == "incorrect-max-attempt" and
                 Enum.any?(get_in(rule, ["event", "params", "actions"]), fn action ->
                   action["type"] == "navigation" and
                     get_in(action, ["params", "target"]) not in [nil, "next"]
                 end)
             end)
           end)

    attributed_project = Course.get_project!(project.id)
    assert attributed_project.attributes.license.license_type == :cc_by
    assert attributed_project.attributes.license.source_provider == "OpenStax"
    assert attributed_project.attributes.license.source_url == run.source_url
  end

  test "invalid source is persisted as an actionable terminal run", %{
    author: author,
    project: project,
    root: root
  } do
    for invalid_url <- [
          "https://example.com/details/books/not-openstax",
          "not a url"
        ] do
      assert {:ok, run} =
               CourseImport.start_import(
                 project,
                 root,
                 author,
                 invalid_url
               )

      assert run.status == :failed
      assert run.source_url == invalid_url
      assert run.error["phase"] == "validation"
      assert run.error["recoverable"] == false
      assert run.error["message"] =~ "https://openstax.org/details/books"
    end
  end

  test "an active course import blocks concurrent root curriculum mutations", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, _run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    {:ok, %{resource: page, revision: page_revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Concurrent page",
        author_id: author.id,
        resource_type_id: Oli.Resources.ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, page_revision)

    current_root = AuthoringResolver.root_container(project.slug)

    assert {:error, :course_import_in_progress} =
             ChangeTracker.track_revision(project.slug, current_root, %{
               children: [page.id],
               author_id: author.id
             })
  end

  test "media staging blocks concurrent root curriculum mutations", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:ok, staging_run} =
             run
             |> CourseImport.Run.update_changeset(%{status: :staging_media})
             |> Repo.update()

    assert staging_run.status == :staging_media

    {:ok, %{resource: page, revision: page_revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Concurrent page during media staging",
        author_id: author.id,
        resource_type_id: Oli.Resources.ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, page_revision)

    current_root = AuthoringResolver.root_container(project.slug)

    assert {:error, :course_import_in_progress} =
             ChangeTracker.track_revision(project.slug, current_root, %{
               children: [page.id],
               author_id: author.id
             })
  end

  test "lesson planning jobs use the dedicated AI queue" do
    job_changeset = LessonPlannerWorker.new(%{"run_id" => Ecto.UUID.generate()})

    assert Ecto.Changeset.get_field(job_changeset, :queue) == "course_import_ai"
  end

  test "terminal preflight timeouts release the active-import and root-change guards", %{
    author: author,
    project: project,
    root: root
  } do
    Application.put_env(
      :oli,
      :openstax_course_import_source_options,
      http_client: TimeoutHTTPClient,
      discovery_fetch_task_timeout: 10
    )

    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:discard, :discovery_fetch_timeout} =
             perform_job(PreflightWorker, %{"run_id" => run.id}, attempt: 4)

    assert {:ok, %CourseImport.Run{status: :failed} = failed} = CourseImport.fetch_run(run.id)
    assert failed.error["phase"] == "preflight"
    assert failed.error["reason"] =~ "discovery_fetch_timeout"

    # A terminal preflight failure no longer occupies the partial unique index
    # used for the active import lock.
    assert {:ok, replacement} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/replacement-book"
             )

    assert {:ok, _cancelled} = CourseImport.cancel_run(replacement.id, author)

    # The same terminal status also releases ChangeTracker's root ownership
    # guard, allowing normal authoring to resume.
    {:ok, %{resource: page, revision: page_revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Post-timeout page",
        author_id: author.id,
        resource_type_id: Oli.Resources.ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, page_revision)

    current_root = AuthoringResolver.root_container(project.slug)

    assert {:ok, _} =
             ChangeTracker.track_revision(project.slug, current_root, %{
               children: [page.id],
               author_id: author.id
             })
  end

  test "an active course import blocks project publishing", %{
    author: author,
    project: project,
    root: root
  } do
    working_publication = Oli.Publishing.project_working_publication(project.slug)
    other_author = author_fixture()

    assert {:ok, _run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:error, message} =
             Oli.Publishing.publish_project(project, "Publish during import", author.id)

    assert message =~ "OpenStax course import is in progress"
    assert Oli.Publishing.project_working_publication(project.slug).id == working_publication.id

    assert {:acquired} =
             Oli.Authoring.Locks.acquire(
               project.slug,
               working_publication.id,
               root.resource_id,
               other_author.id
             )
  end

  test "late worker checkpoints cannot revive or rewrite a cancelled run", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert {:ok, cancelled} = CourseImport.cancel_run(run.id, author)
    assert cancelled.status == :cancelled
    assert cancelled.progress["stage"] == "cancelled"

    assert [%Oban.Job{state: "cancelled"}] =
             Repo.all(
               from(job in Oban.Job,
                 where: fragment("?->>'run_id' = ?", job.args, ^run.id)
               )
             )

    assert {:error, {:invalid_status, :cancelled, :preflighting}} =
             CourseImport.persist_scope_snapshot(run.id, %{
               "book_slug" => "sample-book",
               "chapters" => []
             })

    assert {:error, {:invalid_status, :cancelled, _active_statuses}} =
             CourseImport.set_progress(run.id, %{"stage" => "preflighting"})

    assert {:ok, persisted} = CourseImport.fetch_run(run.id)
    assert persisted.status == :cancelled
    assert persisted.progress["stage"] == "cancelled"
  end

  test "lesson-planning finalization cannot write metadata after cancellation", %{
    author: author,
    project: project,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert :ok = perform_job(PreflightWorker, %{"run_id" => run.id})
    assert {:ok, _} = CourseImport.update_scope(run.id, author, ["chapter-1"])
    assert :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    assert {:ok, planning_checkpoint} = CourseImport.approve_outline(run.id, author)
    assert planning_checkpoint.status == :planning_lessons
    assert {:ok, planning} = CourseImport.get_run(project, author, run.id)

    [unit] = planning.units

    unit
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    run
    |> Oli.OpenStax.CourseImport.Run.update_changeset(%{latest_plan_version: 7})
    |> Repo.update!()

    assert {:ok, cancelled} = CourseImport.cancel_run(run.id, author)
    assert cancelled.status == :cancelled

    assert {:error, {:invalid_status, :cancelled, :planning_lessons}} =
             CourseImport.finalize_lesson_planning(run.id)

    persisted_run = Repo.get!(Oli.OpenStax.CourseImport.Run, run.id)
    persisted_unit = Repo.get!(Oli.OpenStax.CourseImport.Unit, unit.id)

    assert persisted_run.status == :cancelled
    assert persisted_run.latest_plan_version == 7
    assert persisted_unit.status == "pending"
  end

  test "a root change before apply fails without publishing partial curriculum", %{
    author: author,
    project: project,
    root: root
  } do
    run = ready_to_apply_run(project, root, author)

    {:ok, %{resource: concurrent, revision: revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Concurrent page",
        author_id: author.id,
        resource_type_id: Oli.Resources.ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, revision)

    current_root = AuthoringResolver.root_container(project.slug)

    assert {:error, :course_import_in_progress} =
             ChangeTracker.track_revision(project.slug, current_root, %{
               children: [concurrent.id],
               author_id: author.id
             })

    # Simulate an out-of-band writer that bypasses the shared root lock so the
    # worker's final fail-safe check is still exercised.
    assert {:ok, bypass_revision} =
             Oli.Resources.create_revision_from_previous(current_root, %{
               children: [concurrent.id],
               author_id: author.id
             })

    working_publication = Oli.Publishing.project_working_publication(project.slug)

    assert {:ok, _mapping} =
             Oli.Publishing.upsert_published_resource(
               working_publication,
               bypass_revision
             )

    project_resource_count_before =
      Repo.aggregate(
        from(pr in Oli.Authoring.Course.ProjectResource,
          where: pr.project_id == ^project.id
        ),
        :count
      )

    assert {:discard, :project_root_not_empty} =
             ApplyWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 3,
               max_attempts: 3
             })

    assert Repo.get!(Oli.OpenStax.CourseImport.Run, run.id).status == :failed

    project_resource_count_after =
      Repo.aggregate(
        from(pr in Oli.Authoring.Course.ProjectResource,
          where: pr.project_id == ^project.id
        ),
        :count
      )

    assert project_resource_count_after == project_resource_count_before
    assert AuthoringResolver.root_container(project.slug).children == [concurrent.id]
  end

  test "a dry-run compiler failure returns the run to editable lesson review", %{
    author: author,
    project: project,
    root: root
  } do
    approved = approved_run(project, root, author)
    lesson = approved.units |> Enum.flat_map(& &1.lessons) |> List.first()
    plan = List.first(lesson.plans)

    invalid_questions = %{
      "items" => [
        %{"prompt" => "Choose one.", "type" => "multiple_choice"},
        %{"prompt" => "Explain the choice.", "type" => "short_answer"}
      ]
    }

    plan
    |> Ecto.Changeset.change(questions_payload: invalid_questions)
    |> Repo.update!()

    assert {:error, {:compile_failed, _reason}} =
             CourseImport.start_apply(project, approved.id, author)

    assert {:ok, review_run} = CourseImport.get_run(project, author, approved.id)
    assert review_run.status == :awaiting_lesson_approval
    assert review_run.error["phase"] == "compile"
    assert review_run.error["recoverable"]
    assert review_run.error["lesson_ids"] == [lesson.id]

    returned_lesson =
      review_run.units
      |> Enum.flat_map(& &1.lessons)
      |> Enum.find(&(&1.id == lesson.id))

    assert returned_lesson.status == "needs_attention"
    refute List.first(returned_lesson.plans).approved_by_user

    assert {:ok, repaired} =
             CourseImport.update_lesson_plan(
               lesson.id,
               author,
               %{
                 "objective" => "Explain the corrected lesson",
                 "narrative" => "A corrected source-grounded narrative.",
                 "questions_payload" => %{
                   "items" => [
                     %{"prompt" => "Explain the main idea.", "type" => "short_answer"},
                     %{"prompt" => "Apply the main idea.", "type" => "short_answer"}
                   ]
                 }
               },
               lesson.plan_mode
             )

    refute List.first(repaired.plans).approved_by_user
  end

  test "authors can approve and compile a lesson with advisory check failures", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [warning_lesson, other_lesson] = review_run.units |> Enum.flat_map(& &1.lessons)
    warning_plan = List.first(warning_lesson.plans)

    failed_snapshot = %{
      "status" => "failed",
      "results" => [
        %{
          "check_type" => "source_fidelity",
          "status" => "failed",
          "findings" => %{"issues" => ["Two major source blocks were not accounted for."]},
          "repair_plan" => %{"review_source_coverage" => true}
        }
      ]
    }

    warning_plan
    |> Ecto.Changeset.change(checks_snapshot: failed_snapshot)
    |> Repo.update!()

    warning_lesson
    |> Ecto.Changeset.change(status: "needs_attention")
    |> Repo.update!()

    assert {:ok, approved_warning} =
             CourseImport.approve_lesson(review_run.id, warning_lesson.id, author)

    assert approved_warning.status == "approved"

    persisted_warning_plan = Repo.get!(Oli.OpenStax.CourseImport.LessonPlan, warning_plan.id)
    assert persisted_warning_plan.approved_by_user
    assert persisted_warning_plan.checks_snapshot == failed_snapshot

    assert {:ok, _approved_other} =
             CourseImport.approve_lesson(review_run.id, other_lesson.id, author)

    assert {:ok, compiling} = CourseImport.get_run(project, author, review_run.id)
    assert compiling.status == :compiling

    assert {:ok, applying} = CourseImport.start_apply(project, compiling.id, author)
    assert applying.status == :applying
  end

  test "compiling requires every selected lesson's current plan to remain approved", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [stale_lesson, other_lesson] = review_run.units |> Enum.flat_map(& &1.lessons)
    stale_plan = List.first(stale_lesson.plans)

    stale_current_plan =
      %Oli.OpenStax.CourseImport.LessonPlan{}
      |> Oli.OpenStax.CourseImport.LessonPlan.changeset(%{
        lesson_id: stale_lesson.id,
        version: stale_plan.version + 1,
        content_payload: stale_plan.content_payload,
        questions_payload: stale_plan.questions_payload,
        checks_snapshot: stale_plan.checks_snapshot,
        created_by: "author",
        approved_by_user: false
      })
      |> Repo.insert!()

    stale_lesson
    |> Ecto.Changeset.change(status: "approved", last_plan_version: stale_current_plan.version)
    |> Repo.update!()

    # This models a plan edit landing immediately before the final compile
    # transition. The current plan must win over the stale lesson status.
    assert {:ok, _approved} =
             CourseImport.approve_lesson(review_run.id, other_lesson.id, author)

    assert {:ok, current} = CourseImport.get_run(project, author, review_run.id)
    assert current.status == :awaiting_lesson_approval
  end

  test "development bulk approval approves every lesson atomically and transitions once", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    assert Enum.all?(review_run.units |> Enum.flat_map(& &1.lessons), fn lesson ->
             List.first(lesson.plans).generation_metadata == %{
               "strategy" => "deterministic_test"
             }
           end)

    assert {:ok, applying} = CourseImport.approve_all_lessons(review_run.id, author)
    assert applying.status == :applying
    assert_enqueued(worker: ApplyWorker, args: %{"run_id" => review_run.id})

    assert Enum.all?(applying.units |> Enum.flat_map(& &1.lessons), fn lesson ->
             lesson.status == "approved" and List.first(lesson.plans).approved_by_user
           end)
  end

  test "Basic lesson plans preserve an accepted ten-question batch", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    basic_lesson =
      review_run.units
      |> Enum.flat_map(& &1.lessons)
      |> Enum.find(&(&1.plan_mode == "basic"))

    original_plan = List.first(basic_lesson.plans)
    original_questions = original_plan.questions_payload["items"]

    ten_questions =
      1..10
      |> Enum.map(fn index ->
        original_questions
        |> Enum.at(rem(index - 1, length(original_questions)))
        |> Map.put("id", "q#{index}")
        |> Map.put(
          "prompt",
          "Scenario #{index}: " <>
            Enum.at(original_questions, rem(index - 1, length(original_questions)))["prompt"]
        )
      end)

    assert {:ok, updated} =
             CourseImport.update_lesson_plan(
               basic_lesson.id,
               author,
               %{"questions_payload" => %{"items" => ten_questions}},
               "basic"
             )

    latest = Enum.max_by(updated.plans, & &1.version)

    assert length(latest.questions_payload["items"]) == 10,
           inspect(
             Enum.map(updated.plans, fn plan ->
               {plan.version, length(plan.questions_payload["items"]), plan.checks_snapshot}
             end),
             pretty: true,
             limit: :infinity
           )
  end

  test "bulk approval rolls every approval back when one lesson is busy", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    lessons = review_run.units |> Enum.flat_map(& &1.lessons)

    lessons
    |> List.last()
    |> Ecto.Changeset.change(planning_state: "running")
    |> Repo.update!()

    assert {:error, :lesson_plan_busy} =
             CourseImport.approve_all_lessons(review_run.id, author)

    assert {:ok, unchanged} = CourseImport.get_run(project, author, review_run.id)
    assert unchanged.status == :awaiting_lesson_approval

    assert Enum.all?(unchanged.units |> Enum.flat_map(& &1.lessons), fn lesson ->
             lesson.status != "approved" and not List.first(lesson.plans).approved_by_user
           end)
  end

  test "bulk approval rolls every approval back when one current plan is rejected", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [rejected_lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)

    rejected_lesson.plans
    |> List.first()
    |> Ecto.Changeset.change(rejection_reason: "Needs author revision")
    |> Repo.update!()

    assert {:error, :lesson_plan_rejected} =
             CourseImport.approve_all_lessons(review_run.id, author)

    assert {:ok, unchanged} = CourseImport.get_run(project, author, review_run.id)
    assert unchanged.status == :awaiting_lesson_approval

    assert Enum.all?(unchanged.units |> Enum.flat_map(& &1.lessons), fn lesson ->
             lesson.status != "approved" and not List.first(lesson.plans).approved_by_user
           end)
  end

  test "bulk approval records required exclusion acknowledgements in the same transaction", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = List.first(lesson.plans)

    content =
      put_in(
        plan.content_payload,
        [Access.key("coverage_manifest", %{}), "excluded_blocks"],
        [
          %{
            "id" => "author-selected-omission",
            "reason" => "This optional extension is outside the lesson scope."
          }
        ]
      )

    plan |> Ecto.Changeset.change(content_payload: content) |> Repo.update!()

    assert {:ok, _applying} = CourseImport.approve_all_lessons(review_run.id, author)

    latest =
      Oli.OpenStax.CourseImport.LessonPlan
      |> where([plan], plan.lesson_id == ^lesson.id)
      |> order_by([plan], desc: plan.version)
      |> limit(1)
      |> Repo.one!()

    assert latest.version == plan.version + 1
    assert latest.approved_by_user

    assert [%{"author_acknowledged" => true}] =
             get_in(latest.content_payload, ["coverage_manifest", "excluded_blocks"])
  end

  test "bulk approval is denied by the domain gate and by run authorization", %{
    author: author,
    project: project,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    other_author = author_fixture()

    assert {:error, :not_authorized} =
             CourseImport.approve_all_lessons(review_run.id, other_author)

    previous_enabled = Application.get_env(:oli, :openstax_course_import_approve_all_enabled)
    previous_env = Application.get_env(:oli, :env)

    on_exit(fn ->
      Application.put_env(:oli, :openstax_course_import_approve_all_enabled, previous_enabled)
      Application.put_env(:oli, :env, previous_env)
    end)

    Application.put_env(:oli, :env, :prod)
    Application.put_env(:oli, :openstax_course_import_approve_all_enabled, true)

    assert {:error, :bulk_approval_disabled} =
             CourseImport.approve_all_lessons(review_run.id, author)

    Application.put_env(:oli, :env, previous_env)
    Application.put_env(:oli, :openstax_course_import_approve_all_enabled, false)

    assert {:error, :bulk_approval_disabled} =
             CourseImport.approve_all_lessons(review_run.id, author)
  end

  defp ready_to_apply_run(project, root, author) do
    approved = approved_run(project, root, author)
    {:ok, applying} = CourseImport.start_apply(project, approved.id, author)
    applying
  end

  defp approved_run(project, root, author) do
    details = lesson_review_run(project, root, author)

    details.units
    |> Enum.flat_map(& &1.lessons)
    |> Enum.each(fn lesson ->
      {:ok, _} = CourseImport.approve_lesson(details.id, lesson.id, author)
    end)

    {:ok, approved} = CourseImport.get_run(project, author, details.id)
    assert approved.status == :compiling
    approved
  end

  defp lesson_review_run(project, root, author) do
    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/sample-book"
      )

    run = legacy_test_run(run)

    :ok = perform_job(PreflightWorker, %{"run_id" => run.id})
    {:ok, _} = CourseImport.update_scope(run.id, author, ["chapter-1"])
    :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    use_serial_lesson_planner(run.id)
    {:ok, _} = CourseImport.approve_outline(run.id, author)
    :ok = perform_job(LessonPlannerWorker, %{"run_id" => run.id})
    {:ok, details} = CourseImport.get_run(project, author, run.id)
    assert details.status == :awaiting_lesson_approval
    details
  end

  defp use_serial_lesson_planner(run_id) do
    Oli.OpenStax.CourseImport.Run
    |> Repo.get!(run_id)
    |> Oli.OpenStax.CourseImport.Run.update_changeset(%{
      lesson_planning_strategy: :serial_v1
    })
    |> Repo.update!()
  end

  defp legacy_test_run(run) do
    run
    |> Oli.OpenStax.CourseImport.Run.update_changeset(%{
      source_schema_version: 2,
      plan_schema_version: 3
    })
    |> Repo.update!()
  end
end
