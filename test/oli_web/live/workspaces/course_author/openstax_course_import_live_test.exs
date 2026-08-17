defmodule OliWeb.Workspaces.CourseAuthor.OpenStaxCourseImportLiveTest do
  use OliWeb.ConnCase, async: false
  use Oban.Testing, repo: Oli.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Oli.Authoring.Course
  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.Run

  alias Oli.OpenStax.CourseImport.Worker.{
    ApplyWorker,
    LessonPlanWorker,
    OutlineWorker,
    PreflightWorker
  }

  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.Resources.ResourceType
  alias Oli.ScopedFeatureFlags

  defmodule DeterministicLessonPlanner do
    alias Oli.OpenStax.CourseImport.BasicPlanV5

    def plan(lesson, index, _opts) do
      block_ids = lesson |> BasicPlanV5.source_blocks() |> Enum.map(& &1["id"])

      candidate = %{
        "title" => lesson["title"],
        "orientation" => %{"overview" => "Read the complete source evidence."},
        "content_groups" => [
          %{
            "id" => "source-content",
            "title" => lesson["title"] || "Source content",
            "instructional_purpose" => "reading",
            "source_block_ids" => block_ids
          }
        ],
        "question_slots" => [],
        "synthesis" => %{
          "heading" => "Synthesis",
          "summary" => "Connect the evidence to the objectives.",
          "takeaways" => ["Support conclusions with source evidence."]
        }
      }

      {:ok, content} = BasicPlanV5.build(candidate, lesson, index)

      {:ok,
       %{
         plan_mode: "basic",
         payload: %{
           "content_payload" => content,
           "questions_payload" => %{"items" => []}
         },
         enrichment_proposals: [],
         created_by: "system",
         metadata: %{
           "strategy" => "deterministic_current_contract_test",
           "quality_gate" => %{
             "approved" => true,
             "confidence" => 0.99,
             "hard_blockers" => [],
             "repairs" => [],
             "advisories" => []
           }
         }
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
           <a href="/books/sample-book/pages/2-introduction">Ch. 2 Introduction</a>
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

  setup %{conn: conn} do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax import LiveView")

    root = AuthoringResolver.root_container(project.slug) || root
    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    previous_options = Application.get_env(:oli, :openstax_course_import_source_options)

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
        Application.put_env(:oli, :openstax_course_import_source_options, previous_options)
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

    conn =
      conn
      |> Plug.Test.init_test_session(lti_session: nil)
      |> log_in_author(author)

    {:ok, conn: conn, project: project, author: author, root: root}
  end

  test "shows the OpenStax book URL form", %{conn: conn, project: project} do
    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax")

    assert has_element?(view, "#openstax-course-import-form")

    assert has_element?(
             view,
             "#openstax-course-import-form input[type='url'][placeholder='https://openstax.org/details/books/introduction-computer-science']"
           )

    assert has_element?(view, "#openstax-course-import-form button", "Plan course")
    assert has_element?(view, "#openstax-course-import", "full book can take several hours")
  end

  test "explains that course creation requires an empty project root", %{
    conn: conn,
    project: project,
    author: author
  } do
    {:ok, %{resource: page, revision: page_revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Existing lesson",
        author_id: author.id,
        resource_type_id: ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, page_revision)

    root = AuthoringResolver.root_container(project.slug)

    assert {:ok, _} =
             ChangeTracker.track_revision(project.slug, root, %{
               children: [page.id],
               author_id: author.id
             })

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax")

    html =
      view
      |> form("#openstax-course-import-form",
        openstax_course_import: %{
          source_url: "https://openstax.org/details/books/sample-book"
        }
      )
      |> render_submit()

    assert html =~ "empty root curriculum"
  end

  test "shows an accessible running animation while background work is active", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    assert has_element?(view, "#openstax-course-import-processing[aria-busy='true']")

    assert has_element?(
             view,
             "#openstax-course-import-progress[role='progressbar'][aria-label='OpenStax import progress']"
           )

    assert has_element?(
             view,
             "#openstax-course-import-timing[aria-live='off'][data-estimate-state]"
           )

    assert has_element?(view, "#openstax-course-import-estimate")
    assert has_element?(view, "#openstax-course-import-elapsed", "Current stage elapsed")

    assert has_element?(
             view,
             "#openstax-course-import-processing-estimate[aria-live='off']"
           )

    assert has_element?(view, "#openstax-course-import-processing", "You can close this tab")
  end

  test "recomputes a delayed estimate from a same-status polling checkpoint", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    now = DateTime.utc_now()

    progress = %{
      "stage" => "planning_lessons",
      "counts" => %{"plans_checked" => 0},
      "stage_totals" => [
        %{"label" => "Lesson plans checked", "completed" => 0, "total" => 4}
      ],
      "timing" => %{
        "stage_started_at" => DateTime.to_iso8601(now),
        "last_progress_at" => DateTime.to_iso8601(now),
        "stage_history" => []
      }
    }

    run =
      run
      |> Ecto.Changeset.change(status: :planning_lessons, progress: progress, updated_at: now)
      |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    refute has_element?(view, "#openstax-course-import-delay-warning")

    stale_at = DateTime.add(now, -8, :hour)

    stale_progress =
      put_in(progress, ["timing"], %{
        "stage_started_at" => DateTime.to_iso8601(stale_at),
        "last_progress_at" => DateTime.to_iso8601(stale_at),
        "stage_history" => []
      })

    run
    |> Ecto.Changeset.change(progress: stale_progress, updated_at: stale_at)
    |> Oli.Repo.update!()

    send(view.pid, :poll_run)
    render(view)

    assert has_element?(
             view,
             "#openstax-course-import-delay-warning[role='status'][aria-live='polite']",
             "This step is taking longer than expected"
           )

    assert has_element?(
             view,
             "#openstax-course-import-delay-warning",
             "No new progress checkpoint has been recorded recently"
           )
  end

  test "keeps the running animation visible while approved figures are staged", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    run
    |> Ecto.Changeset.change(
      status: :staging_media,
      progress: %{
        "stage" => "staging_media",
        "counts" => %{"assets_staged" => 1},
        "stage_totals" => [
          %{"label" => "Required media staged", "completed" => 1, "total" => 2}
        ]
      }
    )
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    assert has_element?(view, "#openstax-course-import-processing[aria-busy='true']")

    assert has_element?(
             view,
             "#openstax-course-import-processing",
             "Copying approved OpenStax figures"
           )

    assert has_element?(view, "dd", "1")
  end

  test "resumes an awaiting-scope run with chapter choices and an accessible timeline", %{
    conn: conn,
    project: project,
    author: author,
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

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    assert has_element?(view, "#openstax-course-import")

    assert has_element?(
             view,
             "nav[aria-label='Course import progress'] .openstax-course-import-timeline"
           )

    assert has_element?(
             view,
             ".openstax-course-import-timeline-step.is-active",
             "Choose chapters"
           )

    assert has_element?(view, "#openstax-course-scope")

    assert has_element?(
             view,
             "#openstax-course-import-timing[data-estimate-state='waiting_for_user']",
             "Waiting for your chapter selection. Background timing is paused."
           )

    refute has_element?(view, "#openstax-course-import-elapsed")

    assert has_element?(
             view,
             "#openstax-course-scope input[name='chapters[]'][value='chapter-1'][checked]"
           )

    assert has_element?(
             view,
             "#openstax-course-scope input[name='chapters[]'][value='chapter-2'][checked]"
           )

    assert render(view) =~ "All discovered chapters are selected"
    refute has_element?(view, "#openstax-course-scope button[disabled]")

    refute has_element?(view, "#openstax-course-import-processing")
  end

  test "local chapter scope starts empty, tracks changes, and rejects an empty submission", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    Application.put_env(:oli, :openstax_course_import_test_conveniences_enabled, true)

    assert {:ok, run} =
             CourseImport.start_import(
               project,
               root,
               author,
               "https://openstax.org/details/books/sample-book"
             )

    assert :ok = perform_job(PreflightWorker, %{"run_id" => run.id})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    assert render(view) =~ "No chapters are selected by default"
    refute has_element?(view, "#openstax-course-scope input[checked]")
    assert has_element?(view, "#openstax-course-scope button[disabled]")

    empty_html = view |> form("#openstax-course-scope", %{}) |> render_submit()
    assert empty_html =~ "Select at least one chapter before continuing"

    view
    |> form("#openstax-course-scope", %{"chapters" => ["chapter-1"]})
    |> render_change()

    assert has_element?(
             view,
             "#openstax-course-scope input[value='chapter-1'][checked]"
           )

    refute has_element?(view, "#openstax-course-scope button[disabled]")
  end

  test "shows lesson titles, objectives, and sources before outline approval", %{
    conn: conn,
    project: project,
    author: author,
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
    assert {:ok, _run} = CourseImport.update_scope(run.id, author, ["chapter-1"])
    assert :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    assert {:ok, outline_run} = CourseImport.get_run(project, author, run.id)

    [lesson | _] = outline_run.units |> Enum.flat_map(& &1.lessons)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    assert has_element?(
             view,
             "#openstax-course-import-queue",
             "Review the course outline"
           )

    assert has_element?(
             view,
             "#openstax-course-import-timing[data-estimate-state='waiting_for_user'][data-estimate-milestone='lesson_plans_ready']",
             "Waiting for you to approve the course outline. Background timing is paused."
           )

    assert has_element?(
             view,
             "#openstax-course-import-estimate-note",
             "After approval, allow about"
           )

    assert has_element?(view, "li", lesson.title)

    Enum.each(lesson.source_objectives, fn objective ->
      assert has_element?(view, "li", objective)
    end)

    Enum.each(lesson.source_sections, fn section ->
      assert has_element?(view, "span", section)
    end)
  end

  test "shows the schema 6 learner deck and its governed review views", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = List.first(lesson.plans)
    [group | _] = plan.content_payload["content_groups"]
    [source_block | _] = group["source_blocks"]
    activity_id = "source-decision"

    lesson
    |> Ecto.Changeset.change(plan_mode: "advanced")
    |> Oli.Repo.update!()

    plan
    |> Ecto.Changeset.change(
      content_payload:
        plan.content_payload
        |> Map.put("schema_version", 6)
        |> Map.put("authoring_mode", "advanced")
        |> Map.put("question_slots", [])
        |> Map.put("experience_blueprint", %{
          "driving_question" => "What conclusion is best supported by the source evidence?",
          "stages" => [
            %{
              "id" => "investigation",
              "title" => "Investigate the evidence",
              "roles" => [
                "orientation",
                "prediction",
                "investigation",
                "evidence",
                "interpretation",
                "transfer",
                "synthesis"
              ],
              "items" => [
                %{"kind" => "content_group", "ref_id" => group["id"]},
                %{"kind" => "activity", "ref_id" => activity_id}
              ]
            }
          ],
          "activities" => [
            %{
              "id" => activity_id,
              "context" => "Use the evidence you just reviewed before choosing.",
              "prompt" => "Which conclusion is supported?",
              "interaction_type" => "multiple_choice",
              "choices" => [
                %{
                  "id" => "supported",
                  "text" => "The source-supported conclusion",
                  "correct" => true,
                  "feedback" => "Correct. This conclusion follows from the cited evidence."
                },
                %{
                  "id" => "unsupported",
                  "text" => "An unsupported conclusion",
                  "correct" => false,
                  "feedback" => "Revisit the evidence and compare what each claim requires."
                }
              ],
              "hint" => "Identify the observation that directly supports each conclusion.",
              "remediation_content_group_id" => group["id"],
              "evidence_block_ids" => [source_block["id"]],
              "objective_ids" => []
            }
          ],
          "activity_slots" => [],
          "remediation_paths" => [
            %{
              "from_activity_id" => activity_id,
              "to_content_group_id" => group["id"]
            }
          ],
          "duration_manifest" => %{"total_minutes" => 55},
          "estimated_minutes" => 55,
          "enrichment_references" => []
        })
    )
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    material_selector = "#generated-lesson-material-#{lesson.id}"

    assert has_element?(view, "#{material_selector}[open]", "Generated lesson material")

    assert has_element?(view, "#{material_selector} [data-openstax-v6-learner-preview]")
    assert has_element?(view, material_selector, "Learner Preview")
    assert has_element?(view, material_selector, "Stage Flow")
    assert has_element?(view, material_selector, "Activities and Branches")
    assert has_element?(view, material_selector, "Source Coverage")
    assert has_element?(view, material_selector, "Quality History")
    assert has_element?(view, "#{material_selector} [data-openstax-v6-stage='investigation']")
    assert has_element?(view, material_selector, group["title"])
    assert has_element?(view, material_selector, "Which conclusion is supported?")
    assert has_element?(view, material_selector, "Not sure support")
    assert has_element?(view, material_selector, group["id"])
  end

  test "approved lesson cards remain editable until the review stage closes", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = List.first(lesson.plans)

    plan
    |> Ecto.Changeset.change(checks_snapshot: failed_checks_snapshot())
    |> Oli.Repo.update!()

    lesson
    |> Ecto.Changeset.change(status: "approved")
    |> Oli.Repo.update!()

    plan
    |> Ecto.Changeset.change(approved_by_user: true)
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert has_element?(
             view,
             "#openstax-course-import-queue",
             "Review the lesson plans"
           )

    assert has_element?(
             view,
             "[data-openstax-author-review-badge]",
             "Author review"
           )

    assert has_element?(
             view,
             "[data-openstax-author-review-warning]",
             "Resolve them or regenerate this lesson before approval."
           )

    assert has_element?(
             view,
             "button[phx-click='edit_lesson'][phx-value-lesson_id='#{lesson.id}']"
           )

    assert has_element?(
             view,
             "button[phx-click='regenerate_lesson'][phx-value-lesson_id='#{lesson.id}']"
           )

    assert has_element?(
             view,
             "button[phx-click='open_reject_lesson'][phx-value-lesson_id='#{lesson.id}']"
           )

    refute has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}']"
           )
  end

  test "needs-attention lesson is blocked until its hard findings are repaired", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = List.first(lesson.plans)

    lesson
    |> Ecto.Changeset.change(status: "needs_attention", planning_state: "completed")
    |> Oli.Repo.update!()

    plan
    |> Ecto.Changeset.change(checks_snapshot: failed_checks_snapshot())
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert has_element?(
             view,
             "[data-openstax-author-review-badge]",
             "Author review"
           )

    assert has_element?(
             view,
             "[data-openstax-author-review-warning]",
             "Resolve them or regenerate this lesson before approval."
           )

    assert has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}']",
             "Approve lesson"
           )

    assert has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}'][disabled]"
           )

    unchanged_lesson = Oli.Repo.get!(Oli.OpenStax.CourseImport.Lesson, lesson.id)
    unchanged_plan = Oli.Repo.get!(Oli.OpenStax.CourseImport.LessonPlan, plan.id)

    assert unchanged_lesson.status == "needs_attention"
    refute unchanged_plan.approved_by_user
  end

  test "shows parallel lesson progress and disables actions for a regenerating lesson", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)

    lesson
    |> Ecto.Changeset.change(
      planning_state: "retrying",
      planning_operation: "regenerate",
      planning_attempts: 2,
      planning_position: 1
    )
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert has_element?(view, "#openstax-lesson-planning-summary", "1 retrying")
    assert has_element?(view, "#openstax-active-lesson-plans", lesson.title)
    assert has_element?(view, "span[role='status']", "Retrying regeneration")

    for action <- ["edit_lesson", "regenerate_lesson", "open_reject_lesson", "approve_lesson"] do
      assert has_element?(
               view,
               "button[phx-click='#{action}'][phx-value-lesson_id='#{lesson.id}'][disabled]"
             )
    end

    view
    |> render_click("edit_lesson", %{"lesson_id" => lesson.id})

    assert has_element?(
             view,
             "[role='alert']",
             "That lesson is being regenerated"
           )

    refute has_element?(view, "#edit-openstax-lesson-#{lesson.id}")
  end

  test "summarizes actionable lesson failure categories", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [content_lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)

    content_lesson
    |> Ecto.Changeset.change(
      planning_state: "failed",
      planning_error: %{
        "category" => "content_validation_exhausted",
        "retryable" => false,
        "message" => "Generated Basic content did not satisfy the lesson contract."
      }
    )
    |> Oli.Repo.update!()

    review_run
    |> Run.update_changeset(%{
      status: :failed,
      error: %{
        "phase" => "lesson_planning",
        "recoverable" => true,
        "message" => "One lesson plan could not be generated."
      }
    })
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert render(view) =~ "Basic content validation exhausted: 1"
    assert has_element?(view, "button[phx-click='retry_run']", "Retry import")
  end

  test "shows unresolved v5 repairs and blocks approval without failing the import", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = Enum.max_by(lesson.plans, & &1.version)

    repair = %{
      "severity" => "repair",
      "code" => "feedback_consistency",
      "path" => "$.questions_payload.items[0]",
      "message" => "Align the answer guidance and feedback before approval."
    }

    plan
    |> Ecto.Changeset.change(
      content_payload:
        plan.content_payload
        |> Map.put("schema_version", 5)
        |> Map.put("authoring_mode", "basic"),
      generation_metadata: %{
        "pipeline" => "openstax_basic_v5",
        "quality_gate" => %{
          "approved" => false,
          "confidence" => 0.96,
          "hard_blockers" => [],
          "repairs" => [repair],
          "advisories" => [],
          "outcome" => "needs_attention"
        }
      },
      checks_snapshot: %{"status" => "passed", "results" => []}
    )
    |> Oli.Repo.update!()

    lesson
    |> Ecto.Changeset.change(status: "needs_attention", planning_state: "completed")
    |> Oli.Repo.update!()

    {:ok, view, html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert html =~ "Repairs still required"
    assert html =~ repair["message"]

    assert has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}'][disabled]"
           )

    refute has_element?(view, "button[phx-click='retry_run']", "Retry import")
  end

  test "shows compiling as an instructor gate instead of active background work", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    review_run.units
    |> Enum.flat_map(& &1.lessons)
    |> Enum.each(fn lesson ->
      assert {:ok, _lesson} = CourseImport.approve_lesson(review_run.id, lesson.id, author)
    end)

    assert {:ok, compiling_run} = CourseImport.get_run(project, author, review_run.id)
    assert compiling_run.status == :compiling

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert has_element?(
             view,
             "#openstax-course-import-queue",
             "Ready for you to create the course"
           )

    assert has_element?(
             view,
             "#openstax-course-import-timing[data-estimate-state='waiting_for_user']",
             "Waiting for you to start course creation. Background timing is paused."
           )

    refute has_element?(view, "#openstax-course-import-processing")
  end

  test "shows the development approve-all shortcut with explicit confirmation", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    assert has_element?(
             view,
             "button[phx-click='approve_all'][data-confirm]",
             "Approve all lessons"
           )
  end

  test "hides the approve-all shortcut when the environment gate is disabled", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    previous = Application.get_env(:oli, :openstax_course_import_approve_all_enabled)
    Application.put_env(:oli, :openstax_course_import_approve_all_enabled, false)

    on_exit(fn ->
      Application.put_env(:oli, :openstax_course_import_approve_all_enabled, previous)
    end)

    review_run = lesson_review_run(project, root, author)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    refute has_element?(view, "button[phx-click='approve_all']")
  end

  test "lesson edits preserve the source AST and current Basic v5 contract", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    {:ok, review_run} = CourseImport.get_run(project, author, review_run.id)

    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    original_plan = List.first(lesson.plans)
    original_content = original_plan.content_payload
    assert original_plan.questions_payload["items"] == []
    assert original_content["schema_version"] == 5
    assert original_content["authoring_mode"] == "basic"

    updated_objective =
      "#{original_content["objective"]} for #{lesson.title}"

    updated_narrative =
      "#{original_content["narrative"]}\n\n#{lesson.title} connects this source material."

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    view
    |> element("button[phx-click='edit_lesson'][phx-value-lesson_id='#{lesson.id}']")
    |> render_click()

    view
    |> form("#edit-openstax-lesson-#{lesson.id}", %{
      "lesson_id" => lesson.id,
      "lesson_plan" => %{
        "learning_objectives" => updated_objective,
        "narrative" => updated_narrative,
        "plan_mode" => lesson.plan_mode
      }
    })
    |> render_submit()

    refute has_element?(view, "#edit-openstax-lesson-#{lesson.id}")

    assert {:ok, refreshed} = CourseImport.get_run(project, author, review_run.id)

    updated_lesson =
      refreshed.units
      |> Enum.flat_map(& &1.lessons)
      |> Enum.find(&(&1.id == lesson.id))

    updated_plan = List.first(updated_lesson.plans)

    assert updated_plan.version > original_plan.version
    assert updated_plan.content_payload["objective"] == updated_objective
    assert updated_plan.content_payload["learning_objectives"] == [updated_objective]
    assert updated_plan.content_payload["narrative"] == updated_narrative

    assert updated_plan.questions_payload["items"] == []

    assert updated_plan.content_payload["content_groups"] ==
             original_content["content_groups"]

    assert updated_plan.content_payload["coverage_manifest"] ==
             original_content["coverage_manifest"]

    assert updated_plan.content_payload["source_block_ids"] ==
             original_content["source_block_ids"]
  end

  test "returns to a renderable curriculum after applying the generated course", %{
    conn: conn,
    project: project,
    author: author,
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
    assert {:ok, _run} = CourseImport.update_scope(run.id, author, ["chapter-1"])
    assert :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    assert {:ok, _run} = CourseImport.approve_outline(run.id, author)
    assert :ok = drain_lesson_plan_jobs(run.id)

    assert {:ok, lesson_review} = CourseImport.get_run(project, author, run.id)

    lesson_review.units
    |> Enum.flat_map(& &1.lessons)
    |> Enum.each(fn lesson ->
      assert {:ok, _lesson} = CourseImport.approve_lesson(run.id, lesson.id, author)
    end)

    assert {:ok, _run} = CourseImport.start_apply(project, run.id, author)
    assert :ok = perform_job(ApplyWorker, %{"run_id" => run.id})

    assert {:ok, completed} = CourseImport.get_run(project, author, run.id)
    assert completed.status == :completed

    {:ok, completed_view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"
      )

    curriculum_path = ~p"/workspaces/course_author/#{project.slug}/curriculum"

    assert {:ok, curriculum_view, html} =
             completed_view
             |> element("a", "Return to curriculum")
             |> render_click()
             |> follow_redirect(conn, curriculum_path)

    assert html =~ "Curriculum | #{project.title}"
    assert has_element?(curriculum_view, "[phx-value-slug]")
  end

  defp lesson_review_run(project, root, author) do
    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/sample-book"
      )

    :ok = perform_job(PreflightWorker, %{"run_id" => run.id})
    {:ok, _run} = CourseImport.update_scope(run.id, author, ["chapter-1"])
    :ok = perform_job(OutlineWorker, %{"run_id" => run.id})
    {:ok, _run} = CourseImport.approve_outline(run.id, author)
    :ok = drain_lesson_plan_jobs(run.id)
    {:ok, review_run} = CourseImport.get_run(project, author, run.id)
    review_run
  end

  defp drain_lesson_plan_jobs(run_id) do
    run = Oli.Repo.get!(Run, run_id)

    assert {:ok, _run} =
             CourseImport.initialize_parallel_lesson_planning(
               run_id,
               run.lesson_planning_generation
             )

    drain_queued_lesson_jobs(run_id, 100)
  end

  defp drain_queued_lesson_jobs(_run_id, 0), do: {:error, :lesson_job_drain_exhausted}

  defp drain_queued_lesson_jobs(run_id, remaining) do
    run = Oli.Repo.get!(Run, run_id)

    if run.status == :planning_lessons do
      jobs =
        Oli.OpenStax.CourseImport.Lesson
        |> where(
          [lesson],
          lesson.run_id == ^run_id and lesson.planning_state == "queued" and
            not is_nil(lesson.planning_oban_job_id)
        )
        |> order_by([lesson], asc: lesson.planning_position)
        |> Oli.Repo.all()
        |> Enum.map(&Oli.Repo.get!(Oban.Job, &1.planning_oban_job_id))

      case jobs do
        [] ->
          {:error, :no_queued_lesson_jobs}

        jobs ->
          Enum.each(jobs, fn job ->
            assert :ok = LessonPlanWorker.perform(%{job | attempt: 1, max_attempts: 4})
          end)

          drain_queued_lesson_jobs(run_id, remaining - 1)
      end
    else
      :ok
    end
  end

  defp failed_checks_snapshot do
    %{
      "status" => "failed",
      "results" => [
        %{
          "check_type" => "source_fidelity",
          "status" => "failed",
          "findings" => %{
            "issues" => ["Two source blocks need an author decision."]
          },
          "repair_plan" => %{
            "add_block_evidence" => true,
            "add_source_evidence_links" => true
          }
        }
      ]
    }
  end
end
