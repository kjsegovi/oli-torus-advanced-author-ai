defmodule OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest do
  use OliWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Oli.Publishing.AuthoringResolver
  alias Oli.Seeder

  setup %{conn: conn} do
    original_config = Application.get_env(:oli, :google_slides_ai_import, [])

    on_exit(fn ->
      Application.put_env(:oli, :google_slides_ai_import, original_config)
    end)

    map = Seeder.base_project_with_resource2()
    container = AuthoringResolver.root_container(map.project.slug)

    conn =
      conn
      |> Plug.Test.init_test_session(lti_session: nil)
      |> log_in_author(map.author)

    {:ok, conn: conn, project: map.project, container: container, author: map.author}
  end

  test "curriculum exposes the dedicated import action when the workflow is available", %{
    conn: conn,
    project: project,
    container: container
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow)

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum")

    assert has_element?(
             view,
             "a[href='/workspaces/course_author/#{project.slug}/curriculum/#{container.slug}/import/google-slides']",
             "Import from Google Slides"
           )
  end

  test "content admins can discover the importer when setup is incomplete", %{
    conn: conn,
    project: project,
    container: container,
    author: author
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.UnavailableWorkflow
    )

    author
    |> Ecto.Changeset.change(system_role_id: Oli.Accounts.SystemRole.role_id().content_admin)
    |> Oli.Repo.update!()

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum")

    assert has_element?(
             view,
             "a[href='/workspaces/course_author/#{project.slug}/curriculum/#{container.slug}/import/google-slides']",
             "Import from Google Slides"
           )
  end

  test "regular authors do not see an unavailable importer", %{
    conn: conn,
    project: project,
    container: container
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.UnavailableWorkflow
    )

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum")

    refute has_element?(
             view,
             "a[href='/workspaces/course_author/#{project.slug}/curriculum/#{container.slug}/import/google-slides']"
           )
  end

  test "authors can analyze, review, and generate without mutating during onboarding", %{
    conn: conn,
    project: project,
    container: container
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/#{container.slug}/import/google-slides"
      )

    assert has_element?(view, "#google-slides-import-form")

    view
    |> form("#google-slides-import-form", %{
      "google_slides_import" => %{
        "presentation_url" => "https://docs.google.com/presentation/d/presentation-123/edit",
        "layout_mode" => "pixel"
      }
    })
    |> render_submit()

    assert has_element?(view, "#google-slides-import-review", "Imported lesson plan")
    assert has_element?(view, "#generate-google-slides-lesson", "Generate Lesson")

    view
    |> element("#generate-google-slides-lesson")
    |> render_click()

    assert has_element?(view, "#google-slides-import-completed", "Lesson created successfully")

    assert has_element?(
             view,
             "a[href='/workspaces/course_author/#{project.slug}/curriculum/generated-lesson/edit']",
             "Open lesson in Advanced Author"
           )
  end

  test "direct navigation explains when the workflow is unavailable", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.UnavailableWorkflow
    )

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides")

    assert has_element?(view, "[role='alert']", "Google Slides import is unavailable")
    assert has_element?(view, "#google-slides-import-form button[disabled]")
  end

  test "a durable run can be resumed from its URL", %{conn: conn, project: project} do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=ready-run"
      )

    assert has_element?(view, "#google-slides-import-review", "Imported lesson plan")
  end

  test "analysis shows accessible indeterminate progress and describes the work", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.AnalyzingWorkflow
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=analyzing-run"
      )

    assert has_element?(view, "#google-slides-import-analyzing[aria-busy='true']")

    assert has_element?(
             view,
             "#google-slides-import-analysis-progress[role='progressbar'][aria-label='Presentation analysis progress'][aria-describedby='google-slides-import-analysis-description']"
           )

    refute has_element?(view, "#google-slides-import-analysis-progress[aria-valuenow]")

    assert has_element?(
             view,
             "#google-slides-import-analysis-progress > .google-slides-import-progress-indicator"
           )

    refute has_element?(
             view,
             "#google-slides-import-analysis-progress > .google-slides-import-progress-fill"
           )

    assert has_element?(
             view,
             "#google-slides-import-analysis-stages",
             "Reading slide content and speaker notes"
           )

    assert has_element?(
             view,
             "#google-slides-import-analysis-stages",
             "Mapping objectives and approved components"
           )

    assert has_element?(
             view,
             "#google-slides-import-analysis-stages",
             "Checking adaptivity, feedback, and source fidelity"
           )
  end

  test "chunked analysis shows exact determinate progress and slide range", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.DeterminateWorkflow
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=determinate-run"
      )

    assert has_element?(
             view,
             "#google-slides-import-analysis-progress[aria-valuemin='0'][aria-valuemax='18'][aria-valuenow='6']"
           )

    assert has_element?(
             view,
             "#google-slides-import-analysis-progress > .google-slides-import-progress-fill[style='width: 33.3%']"
           )

    assert has_element?(
             view,
             "#google-slides-import-analyzing",
             "Analyzing slides 25–36 of 82 · Step 7 of 18"
           )
  end

  test "lesson generation shows continuous accessible activity", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.GeneratingWorkflow
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=generating-run"
      )

    assert has_element?(view, "#google-slides-generate-tab-activity")
    assert has_element?(view, "#google-slides-import-generating[aria-busy='true']")

    assert has_element?(
             view,
             "#google-slides-import-generation-progress[role='progressbar'][aria-label='Lesson generation progress'][aria-describedby='google-slides-import-generation-description']"
           )

    refute has_element?(view, "#google-slides-import-generation-progress[aria-valuenow]")

    assert has_element?(
             view,
             "#google-slides-import-generation-progress > .google-slides-import-progress-indicator"
           )

    assert has_element?(
             view,
             "#google-slides-import-generation-stages",
             "Importing source visuals"
           )
  end

  test "authors can choose the validated sibling-lesson structure", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.StructureWorkflow
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=structure-run"
      )

    assert has_element?(view, "#google-slides-import-structure", "Create 2 sibling lessons")
    assert has_element?(view, "#google-slides-import-structure", "Slides 1–40")
    assert has_element?(view, "#google-slides-import-structure", "Slides 41–82")

    view
    |> element("button[phx-click='choose_structure'][phx-value-decision='split']")
    |> render_click()

    assert has_element?(view, "#google-slides-import-analyzing")
  end

  test "budget pauses keep progress and resume from the saved checkpoint", %{
    conn: conn,
    project: project
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.BudgetWorkflow)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=budget-run"
      )

    assert has_element?(
             view,
             "#google-slides-import-budget",
             "Analysis progress is safely saved"
           )

    assert has_element?(view, "#google-slides-import-budget", "Step 9 of 18")

    view
    |> element("button[phx-click='continue_analysis_budget']")
    |> render_click()

    assert has_element?(view, "#google-slides-import-analyzing")
  end

  test "review shows bounded source, content, interaction, adaptivity, and variable evidence", %{
    conn: conn,
    project: project
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow)

    {:ok, view, html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=ready-run"
      )

    assert has_element?(view, "#screen-review-0", "Slide 1 — Welcome and feedback")
    assert has_element?(view, "#screen-0-part-1", "Diagram showing the lesson feedback loop")
    assert has_element?(view, "#screen-0-interaction-0", "Which choice explains the concept?")
    assert has_element?(view, "#screen-0-interaction-0", "oli_multiple_choice")
    assert has_element?(view, "#screen-0-interaction-0", ~s({"choice":"option-b"}))

    assert has_element?(
             view,
             "#screen-0-interaction-0",
             ~s({"choices":["Option A","Option B"]})
           )

    assert has_element?(view, "#screen-0-interaction-0", ~s("maxAttempts":3))
    assert has_element?(view, "#screen-0-interaction-0", "Review the diagram and try again.")
    assert has_element?(view, "#screen-0-interaction-0", "Recommended, not enabled")
    assert has_element?(view, "#screen-0-adaptivity-0", "retry-on-miss")

    assert has_element?(view, "#declared-variables", "attempt_count")
    assert has_element?(view, "#declared-variables", "Tracks formative retries")
    assert has_element?(view, "#declared-variables", "Slide 1 — Welcome and feedback")
    assert has_element?(view, "#source-fidelity-summary", "Visual fallback")

    assert has_element?(
             view,
             "#source-fidelity-entry-0",
             "Diagram showing the lesson feedback loop"
           )

    assert has_element?(view, "#source-fidelity-entry-0", "Included · rasterized")
    assert has_element?(view, "#source-background-policy", "not imported")

    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert"

    refute html =~
             OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow.long_runtime_prompt()

    assert html =~ "Explain using the learner response."
    assert html =~ "…"
  end

  test "review offers visual source slides with human-readable labels", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow,
      slide_preview: OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.SourcePreview
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=ready-run"
      )

    assert has_element?(
             view,
             "#screen-0-source-slides",
             "Slide 1 — Welcome and feedback"
           )

    view
    |> element("#review-source-slide-0-0")
    |> render_click()

    render_async(view)

    assert has_element?(
             view,
             "#google-slides-source-preview[role='dialog'][aria-modal='true']",
             "Slide 1 — Welcome and feedback"
           )

    assert has_element?(
             view,
             "#google-slides-source-preview-image[src='https://lh3.googleusercontent.com/review-slide-1']"
           )
  end

  test "source decisions explain why they are needed without exposing slide ids", %{
    conn: conn,
    project: project
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.QuestionWorkflow)

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides")

    view
    |> form("#google-slides-import-form", %{
      "google_slides_import" => %{
        "presentation_url" => "https://docs.google.com/presentation/d/presentation-123/edit",
        "layout_mode" => "responsive"
      }
    })
    |> render_submit()

    assert has_element?(
             view,
             "#google-slides-import-questions",
             "Help Torus finish the lesson plan"
           )

    assert has_element?(
             view,
             "#google-slides-import-questions",
             "Your answers do not change the Google Slides presentation."
           )

    assert has_element?(
             view,
             "#google-slides-import-questions",
             "Understanding the past helps us avoid repeating it."
           )

    assert has_element?(view, "#google-slides-import-questions", "Why am I seeing this?")
    assert has_element?(view, "#google-slides-import-questions", "Slide 17 — Ethics timeline")

    assert has_element?(
             view,
             "#google-slides-import-questions",
             "Keep this content in the lesson"
           )

    html = render(view)
    refute html =~ "g3775e9d8236_0_16"
    refute html =~ "Choose whether to include or preserve"
    refute html =~ "Include or preserve this element"

    view
    |> form("#google-slides-blocker-form", %{
      "answers" => %{
        "source_inventory_unaccounted:inventory:slide-17:timeline-copy" => "include"
      }
    })
    |> render_submit()

    assert has_element?(view, "#google-slides-import-review", "Imported lesson plan")
  end

  test "authors can magnify a source slide with the relevant element highlighted", %{
    conn: conn,
    project: project
  } do
    configure_workflow(
      OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.QuestionWorkflow,
      slide_preview: OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.SourcePreview
    )

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=question-run"
      )

    view
    |> element("#preview-source-slide-0")
    |> render_click()

    html = render_async(view)

    assert has_element?(
             view,
             "#google-slides-source-preview[role='dialog'][aria-modal='true']",
             "Slide 17 — Ethics timeline"
           )

    assert has_element?(
             view,
             "#google-slides-source-preview-image[src='https://lh3.googleusercontent.com/ethics-slide']"
           )

    assert html =~
             ~s(left: 10.0%; top: 20.0%; width: 30.0%; height: 40.0%;)

    view
    |> element("#google-slides-source-preview button[phx-click='toggle_source_preview_zoom']")
    |> render_click()

    assert has_element?(
             view,
             "#google-slides-source-preview button[aria-pressed='true']",
             "Fit to window"
           )
  end

  test "returning without a run id resumes the active import for this container", %{
    conn: conn,
    project: project
  } do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ResumeWorkflow)

    {:ok, view, _html} =
      live(conn, ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides")

    assert has_element?(view, "#google-slides-import-review", "Imported lesson plan")
  end

  test "authors can discard a reviewed plan and start over", %{conn: conn, project: project} do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=ready-run"
      )

    view
    |> element("#discard-google-slides-import")
    |> render_click()

    assert has_element?(view, "#google-slides-import-form")
    refute has_element?(view, "#google-slides-import-review")
  end

  test "failed imports show their safe reference code", %{conn: conn, project: project} do
    configure_workflow(OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.FailedWorkflow)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/workspaces/course_author/#{project.slug}/curriculum/import/google-slides?run_id=failed-run"
      )

    assert has_element?(
             view,
             "#google-slides-import-failed",
             "Torus could not analyze this presentation."
           )

    assert has_element?(
             view,
             "#google-slides-import-error-code",
             "completion_failed"
           )
  end

  defp configure_workflow(module, opts \\ []) do
    Application.put_env(
      :oli,
      :google_slides_ai_import,
      Keyword.put(opts, :workflow, module)
    )
  end

  defmodule AnalyzingWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "analyzing-run") do
      {:ok,
       %{
         id: "analyzing-run",
         status: :analyzing,
         plan_version: 0,
         questions: [],
         warnings: []
       }}
    end

    def get_run(_project, _author, _run_id), do: {:error, :not_found}
  end

  defmodule DeterminateWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "determinate-run") do
      {:ok,
       %{
         id: "determinate-run",
         status: :analyzing,
         plan_version: 0,
         questions: [],
         warnings: [],
         source_snapshot: %{
           "schemaVersion" => 3,
           "presentation" => %{"slideCount" => 82}
         },
         analysis_state: %{
           "phase" => "detail",
           "checkpoint_version" => 7,
           "completed_units" => 6,
           "total_units" => 18,
           "current_slide_range" => %{"start" => 25, "end" => 36}
         }
       }}
    end
  end

  defmodule GeneratingWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "generating-run") do
      {:ok,
       %{
         id: "generating-run",
         status: :generating,
         plan_version: 1,
         questions: [],
         warnings: []
       }}
    end

    def get_run(_project, _author, _run_id), do: {:error, :not_found}
  end

  defmodule StructureWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "structure-run"), do: {:ok, structure_run()}

    def submit_structure_decision(run, _author, 1, "split") do
      {:ok, Map.put(run, :status, :analyzing)}
    end

    defp structure_run do
      %{
        id: "structure-run",
        status: :awaiting_structure,
        plan_version: 0,
        questions: [],
        warnings: [],
        analysis_state: %{
          "checkpoint_version" => 8,
          "completed_units" => 8,
          "total_units" => 18,
          "structure_proposal" => %{
            "version" => 1,
            "oneLesson" => %{
              "title" => "Complete course",
              "startSlide" => 1,
              "endSlide" => 82
            },
            "split" => %{
              "lessons" => [
                %{"title" => "Foundations", "startSlide" => 1, "endSlide" => 40},
                %{"title" => "Applications", "startSlide" => 41, "endSlide" => 82}
              ]
            }
          }
        }
      }
    end
  end

  defmodule BudgetWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "budget-run"), do: {:ok, budget_run()}

    def approve_analysis_continuation(run, _author, 9) do
      {:ok, Map.put(run, :status, :analyzing)}
    end

    defp budget_run do
      %{
        id: "budget-run",
        status: :awaiting_budget,
        plan_version: 0,
        questions: [],
        warnings: [],
        source_snapshot: %{
          "schemaVersion" => 3,
          "presentation" => %{"slideCount" => 82}
        },
        analysis_state: %{
          "phase" => "detail",
          "checkpoint_version" => 9,
          "completed_units" => 8,
          "total_units" => 18,
          "current_slide_range" => %{"start" => 37, "end" => 48},
          "accumulated_usage" => %{"prompt_tokens" => 2_000_000},
          "budget_limit_tokens" => 2_000_000
        }
      }
    end
  end

  defmodule ReadyWorkflow do
    def available?(_project, _author), do: true

    def long_runtime_prompt,
      do: String.duplicate("Explain using the learner response. ", 20)

    def start_analysis(_project, _container, _author, attrs) do
      {:ok,
       %{
         id: "ready-run",
         status: :ready_for_review,
         plan_version: 1,
         options: attrs,
         questions: [],
         warnings: [%{message: "Review generated alt text."}],
         presentation_id: "presentation-123",
         presentation_url: "https://docs.google.com/presentation/d/presentation-123/edit",
         source_snapshot: %{
           "schemaVersion" => 3,
           "presentation" => %{
             "pageSize" => %{
               "width" => %{"magnitude" => 10_000, "unit" => "EMU"},
               "height" => %{"magnitude" => 5_000, "unit" => "EMU"}
             }
           },
           "slides" => [
             %{
               "index" => 1,
               "objectId" => "slide-1",
               "title" => "Welcome and feedback",
               "sourceInventory" => []
             },
             %{
               "index" => 2,
               "objectId" => "slide-2",
               "title" => "Knowledge check",
               "sourceInventory" => []
             }
           ]
         },
         lesson_plan: %{
           "lesson" => %{
             "title" => "Imported lesson plan",
             "screens" => [
               %{
                 "key" => "welcome",
                 "title" => "Welcome",
                 "sourceRefs" => [
                   %{
                     "slideId" => "slide-1",
                     "objectId" => "title-shape",
                     "evidence" => "Title and speaker notes"
                   }
                 ],
                 "parts" => [
                   %{
                     "key" => "intro-copy",
                     "kind" => "text",
                     "content" => %{
                       "text" =>
                         ~s|Welcome <script>alert("review")</script> to the lesson concept.|
                     },
                     "sourceRefs" => [
                       %{"slideId" => "slide-1", "objectId" => "body-shape"}
                     ]
                   },
                   %{
                     "key" => "feedback-loop-diagram",
                     "kind" => "image",
                     "content" => %{"src" => "https://example.test/feedback-loop.png"},
                     "accessibility" => %{
                       "altText" => "Diagram showing the lesson feedback loop"
                     },
                     "sourceRefs" => [
                       %{"slideId" => "slide-1", "objectId" => "diagram-image"}
                     ]
                   }
                 ],
                 "interactions" => [
                   %{
                     "key" => "concept-check",
                     "componentKey" => "oli_multiple_choice",
                     "prompt" => "Which choice explains the concept?",
                     "correctResponse" => %{"choice" => "option-b"},
                     "configuration" => %{"choices" => ["Option A", "Option B"]},
                     "evaluationPolicy" => %{
                       "maxAttempts" => 3,
                       "onCorrect" => "navigate_next",
                       "onIncorrect" => "retry_with_feedback",
                       "revealAnswerAfterMaxAttempts" => true
                     },
                     "scoring" => %{"mode" => "formative", "points" => 0},
                     "sourceEvidence" => [
                       %{
                         "slideId" => "slide-1",
                         "objectId" => "question-shape",
                         "evidence" => "Speaker notes mark option B as correct"
                       }
                     ],
                     "feedback" => %{
                       "static" => %{
                         "correct" => "Correct. You identified the key relationship.",
                         "incorrect" => "Review the diagram and try again."
                       },
                       "runtimeAi" => %{
                         "recommended" => true,
                         "enabled" => false,
                         "authorOptIn" => false,
                         "staticFallbackKey" => "incorrect",
                         "prompt" => long_runtime_prompt()
                       }
                     }
                   }
                 ],
                 "adaptivity" => [
                   %{
                     "key" => "retry-on-miss",
                     "condition" => %{
                       "operator" => "incorrect",
                       "interactionKey" => "concept-check"
                     },
                     "action" => %{
                       "type" => "navigate",
                       "targetScreenKey" => "welcome"
                     }
                   }
                 ]
               },
               %{
                 "title" => "Check your understanding",
                 "sourceRefs" => [%{"slideId" => "slide-2"}]
               }
             ]
           },
           "objectives" => %{
             "mapped" => [%{"title" => "Explain the lesson concept"}],
             "proposed" => []
           },
           "variables" => [
             %{
               "key" => "attempt_count",
               "type" => "integer",
               "initialValue" => 0,
               "purpose" => "Tracks formative retries before remediation.",
               "sourceRefs" => [
                 %{
                   "slideId" => "slide-1",
                   "objectId" => "question-shape",
                   "evidence" => "Retry instruction in speaker notes"
                 }
               ]
             }
           ],
           "assumptions" => ["The activity is formative."],
           "sourceCoverage" => [
             %{
               "inventoryId" => "slide-1:diagram-image",
               "slideId" => "slide-1",
               "objectId" => "diagram-image",
               "sourceType" => "image",
               "summary" => "Diagram showing the lesson feedback loop",
               "suggestedDisposition" => "visual_fallback",
               "fidelity" => "rasterized",
               "reviewRequired" => true,
               "status" => "included",
               "targets" => [
                 %{
                   "kind" => "part",
                   "screenKey" => "welcome",
                   "key" => "feedback-loop-diagram"
                 }
               ]
             },
             %{
               "inventoryId" => "slide-1:body-shape",
               "slideId" => "slide-1",
               "objectId" => "body-shape",
               "sourceType" => "text",
               "summary" => "Lesson introduction",
               "suggestedDisposition" => "native_semantic",
               "fidelity" => "full",
               "reviewRequired" => false,
               "status" => "included",
               "targets" => [
                 %{"kind" => "part", "screenKey" => "welcome", "key" => "intro-copy"}
               ]
             }
           ]
         }
       }}
    end

    def get_run(_project, _author, "ready-run"),
      do: start_analysis(nil, nil, nil, %{})

    def get_run(_project, _author, _run_id), do: {:error, :not_found}
    def submit_answers(run, _author, _answers), do: {:ok, run}
    def approve_plan(run, _author, _plan_version), do: {:ok, run}
    def cancel(run, _author), do: {:ok, Map.put(run, :status, :cancelled)}

    def generate(run, _author, _plan_version) do
      {:ok,
       run
       |> Map.put(:status, :completed)
       |> Map.put(:result, %{"revision_slug" => "generated-lesson"})}
    end
  end

  defmodule ResumeWorkflow do
    alias OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow

    def available?(project, author), do: ReadyWorkflow.available?(project, author)

    def get_active_run(project, author, _target_container_resource_id),
      do: ReadyWorkflow.get_run(project, author, "ready-run")

    def get_run(project, author, run_id), do: ReadyWorkflow.get_run(project, author, run_id)
    def cancel(run, author), do: ReadyWorkflow.cancel(run, author)
  end

  defmodule UnavailableWorkflow do
    def available?(_project, _author), do: false
  end

  defmodule FailedWorkflow do
    def available?(_project, _author), do: true

    def get_run(_project, _author, "failed-run") do
      {:ok,
       %{
         id: "failed-run",
         status: :failed,
         plan_version: 0,
         questions: [],
         warnings: [],
         error: %{
           "code" => "completion_failed",
           "message" => "Torus could not analyze this presentation."
         }
       }}
    end

    def get_run(_project, _author, _run_id), do: {:error, :not_found}
  end

  defmodule QuestionWorkflow do
    def available?(_project, _author), do: true

    def start_analysis(_project, _container, _author, _attrs) do
      {:ok,
       %{
         id: "question-run",
         status: :awaiting_answers,
         plan_version: 0,
         presentation_id: "presentation-123",
         presentation_url: "https://docs.google.com/presentation/d/presentation-123/edit",
         source_snapshot: %{
           "presentation" => %{
             "pageSize" => %{
               "width" => %{"magnitude" => 10_000, "unit" => "EMU"},
               "height" => %{"magnitude" => 5_000, "unit" => "EMU"}
             }
           },
           "slides" => [
             %{
               "index" => 16,
               "objectId" => "slide-17",
               "title" => "Ethics timeline",
               "sourceInventory" => [
                 %{
                   "objectId" => "timeline-copy",
                   "geometry" => %{
                     "width" => %{"magnitude" => 3_000, "unit" => "EMU"},
                     "height" => %{"magnitude" => 2_000, "unit" => "EMU"},
                     "transform" => %{
                       "scaleX" => 1,
                       "scaleY" => 1,
                       "translateX" => 1_000,
                       "translateY" => 1_000,
                       "unit" => "EMU"
                     }
                   }
                 }
               ]
             }
           ]
         },
         warnings: [],
         questions: [
           %{
             "id" => "source_inventory_unaccounted:inventory:slide-17:timeline-copy",
             "key" => "source_inventory_unaccounted:inventory:slide-17:timeline-copy",
             "prompt" =>
               "Choose whether to include or preserve Understanding the past helps us avoid repeating it., or explicitly omit it.",
             "source" => "Source slide(s): g3775e9d8236_0_16",
             "options" => [
               %{"value" => "include", "label" => "Include or preserve this element"},
               %{"value" => "omit", "label" => "Omit this element"}
             ]
           }
         ],
         lesson_plan: %{
           "blockers" => [
             %{
               "key" => "source_inventory_unaccounted:inventory:slide-17:timeline-copy",
               "code" => "source_inventory_unaccounted",
               "sourceRefs" => [
                 %{"slideId" => "slide-17", "objectId" => "timeline-copy"}
               ],
               "details" => %{
                 "summary" => %{
                   "text" => "Understanding the past helps us avoid repeating it."
                 },
                 "geometry" => %{
                   "width" => %{"magnitude" => 3_000, "unit" => "EMU"},
                   "height" => %{"magnitude" => 2_000, "unit" => "EMU"},
                   "transform" => %{
                     "scaleX" => 1,
                     "scaleY" => 1,
                     "translateX" => 1_000,
                     "translateY" => 1_000,
                     "unit" => "EMU"
                   }
                 }
               }
             }
           ]
         }
       }}
    end

    def get_run(_project, _author, "question-run"),
      do: start_analysis(nil, nil, nil, %{})

    def submit_answers(
          _run,
          _author,
          %{"source_inventory_unaccounted:inventory:slide-17:timeline-copy" => "include"}
        ) do
      with {:ok, run} <-
             OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLiveTest.ReadyWorkflow.start_analysis(
               nil,
               nil,
               nil,
               %{}
             ) do
        {:ok, Map.put(run, :id, "question-run")}
      end
    end
  end

  defmodule SourcePreview do
    def fetch(_project, _run, "slide-1") do
      {:ok,
       %{
         "url" => "https://lh3.googleusercontent.com/review-slide-1",
         "width" => 1600,
         "height" => 800
       }}
    end

    def fetch(_project, _run, "slide-2") do
      {:ok,
       %{
         "url" => "https://lh3.googleusercontent.com/review-slide-2",
         "width" => 1600,
         "height" => 800
       }}
    end

    def fetch(_project, _run, "slide-17") do
      {:ok,
       %{
         "url" => "https://lh3.googleusercontent.com/ethics-slide",
         "width" => 1600,
         "height" => 800
       }}
    end
  end
end
