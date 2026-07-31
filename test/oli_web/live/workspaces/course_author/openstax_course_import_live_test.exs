defmodule OliWeb.Workspaces.CourseAuthor.OpenStaxCourseImportLiveTest do
  use OliWeb.ConnCase, async: false
  use Oban.Testing, repo: Oli.Repo

  import Phoenix.LiveViewTest

  alias Oli.Authoring.Course
  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.Run

  alias Oli.OpenStax.CourseImport.Worker.{
    ApplyWorker,
    LessonPlannerWorker,
    OutlineWorker,
    PreflightWorker
  }

  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.Resources.ResourceType
  alias Oli.ScopedFeatureFlags

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

    Application.put_env(
      :oli,
      :openstax_course_import_source_options,
      http_client: HTTPClient
    )

    on_exit(fn ->
      if is_nil(previous_options) do
        Application.delete_env(:oli, :openstax_course_import_source_options)
      else
        Application.put_env(:oli, :openstax_course_import_source_options, previous_options)
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
             "#openstax-course-scope input[name='chapters[]'][value='chapter-1']"
           )

    assert has_element?(
             view,
             "#openstax-course-scope input[name='chapters[]'][value='chapter-2']"
           )

    refute has_element?(view, "#openstax-course-import-processing")
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

  test "shows instructional sections, worked examples, and takeaways in lesson review cards", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    plan = List.first(lesson.plans)
    [section | _] = plan.content_payload["instructional_sections"]
    [worked_example | _] = plan.content_payload["worked_examples"]
    [application_problem | _] = plan.content_payload["application_problems"]
    [takeaway | _] = plan.content_payload["key_takeaways"]

    source_media_url = "https://assets.openstax.org/oscms-prodcms/media/example.png"

    lesson
    |> Ecto.Changeset.change(plan_mode: "advanced")
    |> Oli.Repo.update!()

    updated_sections =
      plan.content_payload["instructional_sections"]
      |> Enum.with_index(1)
      |> Enum.map(fn {instructional_section, index} ->
        Map.put(instructional_section, "evidence_block_ids", ["source-block-#{index}"])
      end)

    plan
    |> Ecto.Changeset.change(
      content_payload:
        plan.content_payload
        |> Map.put("instructional_sections", updated_sections)
        |> Map.put("learning_objectives", ["Explain the reviewed OpenStax source"])
        |> Map.put("media", [
          %{
            "source_media_id" => "source-figure-1",
            "source_url" => source_media_url,
            "alt" => "A source-grounded computing diagram",
            "caption" => "Computing connects several disciplines.",
            "credit" => "OpenStax",
            "rights_status" => "approved"
          }
        ])
        |> Map.put("coverage_manifest", %{
          "available_block_ids" => ["source-block-1", "source-block-2", "source-block-3"],
          "included_block_ids" => ["source-block-1", "source-block-2"],
          "excluded_blocks" => [
            %{
              "id" => "source-block-3",
              "reason" => "This historical aside is supplemental to the lesson objective."
            }
          ]
        })
        |> Map.put("advanced_blueprint", %{
          "screens" => [
            %{
              "id" => "discipline-decision",
              "kind" => "decision",
              "title" => "Choose a computing discipline",
              "prompt" => "Which discipline best fits this scenario?",
              "interaction_type" => "dropdown",
              "choices" => [
                %{
                  "id" => "data",
                  "text" => "Data science",
                  "correct" => true,
                  "feedback" => "This choice uses evidence from the data-science section."
                },
                %{
                  "id" => "other",
                  "text" => "Another discipline",
                  "correct" => false,
                  "feedback" => "Review how each discipline uses computing."
                }
              ],
              "remediation_section_id" => "source-block-1"
            }
          ],
          "remediation_paths" => [
            %{
              "from_question_id" => "discipline-decision",
              "to_section_id" => "source-block-1"
            }
          ]
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

    assert has_element?(
             view,
             "#{material_selector} [data-openstax-material-section='instructional'] h6",
             section["heading"]
           )

    assert has_element?(
             view,
             "#{material_selector} [data-openstax-material-section='worked-example'] h6",
             worked_example["title"]
           )

    assert has_element?(
             view,
             "#{material_selector} [data-openstax-material-section='takeaways'] li",
             takeaway
           )

    assert has_element?(
             view,
             "#{material_selector} [data-openstax-material-section='application-problem']",
             application_problem["prompt"]
           )

    assert has_element?(view, material_selector, "Mapped learning objectives")
    assert has_element?(view, material_selector, "Explain the reviewed OpenStax source")
    assert has_element?(view, material_selector, "source-block-1")
    assert has_element?(view, "#{material_selector} img[src='#{source_media_url}']")
    assert has_element?(view, material_selector, "Source content excluded from this lesson")
    assert has_element?(view, material_selector, "source-block-3")
    assert has_element?(view, material_selector, "historical aside")

    assert has_element?(
             view,
             "#{material_selector} [data-openstax-advanced-screen='discipline-decision']",
             "Choose a computing discipline"
           )

    assert has_element?(view, material_selector, "Review how each discipline uses computing")
    assert has_element?(view, material_selector, "discipline-decision")
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
             "You may edit, regenerate, or approve this lesson as-is."
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

  test "needs-attention lesson is marked for author review without blocking approval", %{
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
             "You may edit, regenerate, or approve this lesson as-is."
           )

    assert has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}']",
             "Approve lesson"
           )

    refute has_element?(
             view,
             "button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}'][disabled]"
           )

    view
    |> element("button[phx-click='approve_lesson'][phx-value-lesson_id='#{lesson.id}']")
    |> render_click()

    approved_lesson =
      Oli.Repo.get!(Oli.OpenStax.CourseImport.Lesson, lesson.id)

    approved_plan =
      Oli.Repo.get!(Oli.OpenStax.CourseImport.LessonPlan, plan.id)

    assert approved_lesson.status == "approved"
    assert approved_plan.approved_by_user
    assert approved_plan.checks_snapshot == failed_checks_snapshot()

    refute render(view) =~ "Changes are needed before approval."
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

  test "lesson edits preserve structured content and question metadata", %{
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
    original_questions = original_plan.questions_payload["items"]

    assert Enum.all?(original_questions, fn question ->
             question["answer_keywords"] != [] and
               is_binary(question["correct_feedback"]) and
               is_binary(question["incorrect_feedback"]) and
               is_binary(question["remediation"]) and
               question["source_evidence_links"] != []
           end)

    updated_objective =
      "#{original_content["objective"]} for #{lesson.title}"

    updated_narrative =
      "#{original_content["narrative"]}\n\n#{lesson.title} connects this source material."

    updated_prompts =
      original_questions
      |> Enum.with_index()
      |> Enum.map(fn
        {question, 0} ->
          "#{question["prompt"]} In #{lesson.title}, explain your reasoning."

        {question, _index} ->
          question["prompt"]
      end)

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
        "question_order" => Enum.map(original_questions, & &1["id"]),
        "question_prompts" =>
          original_questions
          |> Enum.zip(updated_prompts)
          |> Map.new(fn {question, prompt} -> {question["id"], prompt} end),
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

    normalized_collection_keys = ["instructional_sections", "worked_examples"]

    assert Map.drop(updated_plan.content_payload, [
             "objective",
             "learning_objectives",
             "narrative" | normalized_collection_keys
           ]) ==
             Map.drop(original_content, [
               "objective",
               "learning_objectives",
               "narrative" | normalized_collection_keys
             ])

    Enum.zip(
      original_content["instructional_sections"],
      updated_plan.content_payload["instructional_sections"]
    )
    |> Enum.each(fn {original, updated} ->
      assert Map.take(updated, Map.keys(original)) == original
    end)

    Enum.zip(
      original_content["worked_examples"],
      updated_plan.content_payload["worked_examples"]
    )
    |> Enum.each(fn {original, updated} ->
      assert Map.take(updated, Map.keys(original)) == original
    end)

    assert Enum.map(updated_plan.questions_payload["items"], & &1["prompt"]) == updated_prompts

    Enum.zip(original_questions, updated_plan.questions_payload["items"])
    |> Enum.each(fn {original, updated} ->
      preserved_keys = Map.keys(original) -- ["prompt"]
      assert Map.take(updated, preserved_keys) == Map.take(original, preserved_keys)
    end)
  end

  test "rich section edits preserve evidence ids and sibling lesson material", %{
    conn: conn,
    project: project,
    author: author,
    root: root
  } do
    review_run = lesson_review_run(project, root, author)

    {:ok, review_run} = CourseImport.get_run(project, author, review_run.id)
    [lesson | _] = review_run.units |> Enum.flat_map(& &1.lessons)
    original_plan = List.first(lesson.plans)
    [first_section | remaining_sections] = original_plan.content_payload["instructional_sections"]

    assert {:ok, source_corpus} =
             Oli.OpenStax.CourseImport.RichSource.load_lesson_corpus(lesson.id)

    [source_block | _] = source_corpus["source_blocks"]
    evidence_id = source_block["id"]

    first_section =
      first_section
      |> Map.update("evidence_block_ids", [evidence_id], fn existing_ids ->
        Enum.uniq(existing_ids ++ [evidence_id])
      end)
      |> Map.put("media_refs", ["source-figure-1"])

    original_content =
      original_plan.content_payload
      |> Map.put("opening_hook", "What can the Introduction source help us explain?")
      |> Map.put(
        "why_this_matters",
        "The Introduction source supports decisions learners make throughout this lesson."
      )
      |> Map.put("instructional_sections", [first_section | remaining_sections])
      |> Map.put("advanced_blueprint", %{
        "screens" => [
          %{
            "id" => "screen-1",
            "kind" => "exploration",
            "evidence_block_ids" => [evidence_id],
            "rules" => [%{"when" => "incorrect", "then" => "review-section-1"}]
          }
        ],
        "review_metadata" => %{"keep" => true}
      })

    original_plan =
      original_plan
      |> Ecto.Changeset.change(content_payload: original_content)
      |> Oli.Repo.update!()

    original_questions = original_plan.questions_payload["items"]
    updated_heading = "Introduction source foundations"

    updated_explanation =
      "#{first_section["explanation"]} The Introduction source now gives learners one more evidence-based connection to explain."

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{review_run.id}"
      )

    view
    |> element("button[phx-click='edit_lesson'][phx-value-lesson_id='#{lesson.id}']")
    |> render_click()

    assert has_element?(
             view,
             "textarea[name='lesson_plan[instructional_sections][0][explanation]']"
           )

    view
    |> form("#edit-openstax-lesson-#{lesson.id}", %{
      "lesson_id" => lesson.id,
      "lesson_plan" => %{
        "learning_objectives" => Enum.join(original_content["learning_objectives"], "\n"),
        "narrative" => original_content["narrative"],
        "instructional_sections" => %{
          "0" => %{
            "heading" => updated_heading,
            "explanation" => updated_explanation
          }
        },
        "question_order" => Enum.map(original_questions, & &1["id"]),
        "question_prompts" => Map.new(original_questions, &{&1["id"], &1["prompt"]}),
        "plan_mode" => "basic"
      }
    })
    |> render_submit()

    assert {:ok, refreshed} = CourseImport.get_run(project, author, review_run.id)

    updated_lesson =
      refreshed.units
      |> Enum.flat_map(& &1.lessons)
      |> Enum.find(&(&1.id == lesson.id))

    updated_plan = List.first(updated_lesson.plans)

    [updated_section | updated_remaining_sections] =
      updated_plan.content_payload["instructional_sections"]

    assert Enum.any?(updated_lesson.plans, &(&1.created_by == "author"))

    assert updated_plan.checks_snapshot["status"] == "passed",
           inspect(updated_plan.checks_snapshot["results"], pretty: true, limit: :infinity)

    assert updated_section["heading"] == updated_heading
    assert updated_section["explanation"] == updated_explanation

    assert Map.drop(updated_section, ["heading", "explanation"]) ==
             Map.drop(first_section, ["heading", "explanation"])

    assert updated_remaining_sections == remaining_sections

    sibling_keys = [
      "opening_hook",
      "why_this_matters",
      "worked_examples",
      "curiosity_prompts",
      "application_problems",
      "key_takeaways",
      "media",
      "advanced_blueprint"
    ]

    assert Map.take(updated_plan.content_payload, sibling_keys) ==
             Map.take(original_content, sibling_keys)
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
    use_serial_lesson_planner(run.id)
    assert {:ok, _run} = CourseImport.approve_outline(run.id, author)
    assert :ok = perform_job(LessonPlannerWorker, %{"run_id" => run.id})

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
    use_serial_lesson_planner(run.id)
    {:ok, _run} = CourseImport.approve_outline(run.id, author)
    :ok = perform_job(LessonPlannerWorker, %{"run_id" => run.id})
    {:ok, review_run} = CourseImport.get_run(project, author, run.id)
    review_run
  end

  defp use_serial_lesson_planner(run_id) do
    Run
    |> Oli.Repo.get!(run_id)
    |> Run.update_changeset(%{lesson_planning_strategy: :serial_v1})
    |> Oli.Repo.update!()
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
