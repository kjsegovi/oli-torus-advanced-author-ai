defmodule Oli.GoogleSlides.ImportRunsTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.Authoring.Collaborators
  alias Oli.GoogleSlides.ImportRun
  alias Oli.GoogleSlides.ImportRuns
  alias Oli.GoogleSlides.ImportRuns.{AnalysisWorker, GenerationWorker}
  alias Oli.Repo

  setup do
    author = author_fixture()
    %{project: project, resource: container} = project_fixture(author)

    %{author: author, project: project, container: container}
  end

  describe "owner scope" do
    test "get, list, resume, and mutations never expose a collaborator's run", %{
      author: owner,
      project: project,
      container: container
    } do
      other_author = author_fixture()
      assert {:ok, _collaborator} = Collaborators.add_collaborator(other_author, project)
      assert {:ok, run} = start_run(project, owner, container)

      assert {:error, :not_found} = ImportRuns.get_run(project, other_author, run.id)
      assert {:ok, []} = ImportRuns.list_runs(project, other_author)

      assert {:error, :not_found} =
               ImportRuns.get_active_run(project, other_author, container)

      assert {:error, :not_found} =
               ImportRuns.submit_answers(project, other_author, run.id, %{"q1" => "answer"})

      assert {:error, :not_found} =
               ImportRuns.approve_plan(project, other_author, run.id, 0)

      assert {:error, :not_found} =
               ImportRuns.start_generation(project, other_author, run.id, plan_version: 0)

      assert {:error, :not_found} = ImportRuns.cancel(project, other_author, run.id)
      assert Repo.get!(ImportRun, run.id).status == :analyzing
    end

    test "get_active_run returns only the owner's active run", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)
      assert {:ok, resumed} = ImportRuns.get_active_run(project, author, container)
      assert resumed.id == run.id

      assert {:ok, _cancelled} = ImportRuns.cancel(project, author, run.id)
      assert {:error, :not_found} = ImportRuns.get_active_run(project, author, container)
    end
  end

  describe "approval audit" do
    test "approval records the owner and time before generation", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, ready} =
               ImportRuns.complete_analysis(run.id, :ready_for_review, %{
                 lesson_plan: %{"title" => "Reviewed lesson"}
               })

      assert ready.plan_version == 1
      assert {:ok, approved} = ImportRuns.approve_plan(project, author, run.id, 1)
      assert approved.approved_plan_version == 1
      assert approved.approved_by_author_id == author.id
      assert %DateTime{} = approved.approved_at

      assert {:ok, generating} =
               ImportRuns.start_generation(project, author, run.id, plan_version: 1)

      assert generating.status == :generating

      assert_enqueued(
        worker: GenerationWorker,
        args: %{"run_id" => run.id}
      )
    end
  end

  describe "active run uniqueness" do
    test "one active run is allowed per project target and terminal runs release it", %{
      author: author,
      project: project,
      container: container
    } do
      other_author = author_fixture()
      assert {:ok, _collaborator} = Collaborators.add_collaborator(other_author, project)
      assert {:ok, first} = start_run(project, author, container)

      assert {:error, %Ecto.Changeset{} = changeset} =
               start_run(project, other_author, container)

      assert "already has an active Google Slides import" in errors_on(changeset).target_container_resource_id

      assert {:ok, %{status: :cancelled}} = ImportRuns.cancel(project, author, first.id)
      assert {:ok, second} = start_run(project, other_author, container)
      refute second.id == first.id
      assert {:ok, %{id: second_id}} = ImportRuns.get_active_run(project, other_author, container)
      assert second_id == second.id
      assert {:error, :not_found} = ImportRuns.get_active_run(project, author, container)
    end

    test "cancel is terminal and cannot be overwritten", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)
      assert {:ok, cancelled} = ImportRuns.cancel(project, author, run.id)
      assert cancelled.status == :cancelled

      assert {:error, {:invalid_transition, :cancelled, :cancelled}} =
               ImportRuns.cancel(project, author, run.id)

      assert {:error, {:invalid_transition, :cancelled, :ready_for_review}} =
               ImportRuns.complete_analysis(run.id, :ready_for_review, %{
                 lesson_plan: %{"title" => "Too late"}
               })

      assert Repo.get!(ImportRun, run.id).status == :cancelled
    end
  end

  describe "analysis continuation enqueueing" do
    test "new v2 runs use the configured prompt-token tranche", %{
      author: author,
      project: project,
      container: container
    } do
      previous = Application.get_env(:oli, :google_slides_ai_import, [])

      configured =
        case previous do
          config when is_list(config) ->
            Keyword.put(config, :analysis_budget_prompt_tokens, 750_000)

          config when is_map(config) ->
            Map.put(config, :analysis_budget_prompt_tokens, 750_000)

          _other ->
            [analysis_budget_prompt_tokens: 750_000]
        end

      Application.put_env(:oli, :google_slides_ai_import, configured)
      on_exit(fn -> Application.put_env(:oli, :google_slides_ai_import, previous) end)

      assert {:ok, run} = start_run(project, author, container)
      assert run.analysis_version == 2
      assert run.analysis_state["current_phase"] == "inventory"
      assert run.analysis_state["budget_tranche_tokens"] == 750_000
      assert run.analysis_state["budget_limit_tokens"] == 750_000
    end

    test "structure and budget pauses resume from the exact checkpoint", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      structure_state =
        run.analysis_state
        |> Map.put("structure_proposal", %{
          "version" => 3,
          "oneLesson" => %{"startSlide" => 1, "endSlide" => 80},
          "split" => %{
            "lessons" => [
              %{"startSlide" => 1, "endSlide" => 40},
              %{"startSlide" => 41, "endSlide" => 80}
            ]
          }
        })

      assert {:ok, paused} =
               ImportRuns.complete_analysis(run.id, :awaiting_structure, %{
                 analysis_state: structure_state
               })

      assert paused.status == :awaiting_structure

      assert {:ok, resumed} =
               ImportRuns.submit_structure_decision(
                 project,
                 author,
                 run.id,
                 3,
                 :split
               )

      assert resumed.status == :analyzing
      assert resumed.analysis_state["structure_decision"]["choice"] == "split"
      assert resumed.analysis_state["current_phase"] == "detail"
      assert resumed.analysis_state["checkpoint_version"] == 1

      assert {:ok, _budget_paused} =
               ImportRuns.complete_analysis(resumed.id, :awaiting_budget, %{
                 analysis_state:
                   resumed.analysis_state
                   |> Map.put("budget_limit_tokens", 2_000_000)
                   |> Map.put("continuation_tranche", 1)
               })

      assert {:ok, budget_resumed} =
               ImportRuns.approve_analysis_continuation(
                 project,
                 author,
                 run.id,
                 1
               )

      assert budget_resumed.status == :analyzing
      assert budget_resumed.analysis_state["budget_limit_tokens"] == 4_000_000
      assert budget_resumed.analysis_state["continuation_tranche"] == 2
      assert budget_resumed.analysis_state["checkpoint_version"] == 2
    end

    test "an executing analysis job does not swallow an answer continuation", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)
      [first_job] = all_enqueued(worker: AnalysisWorker, args: %{"run_id" => run.id})

      first_job
      |> Ecto.Changeset.change(state: "executing")
      |> Repo.update!()

      assert {:ok, _awaiting} =
               ImportRuns.complete_analysis(run.id, :awaiting_answers, %{
                 questions: [%{"id" => "q1"}],
                 lesson_plan: %{"blockers" => [%{"id" => "q1"}]}
               })

      assert {:ok, continued} =
               ImportRuns.submit_answers(project, author, run.id, %{"q1" => "answer"})

      assert continued.status == :analyzing
      assert continued.answers == %{"q1" => "answer"}

      jobs =
        Oban.Job
        |> where([job], job.worker == ^first_job.worker)
        |> where([job], fragment("?->>'run_id' = ?", job.args, ^run.id))
        |> Repo.all()

      assert Enum.sort(Enum.map(jobs, & &1.state)) == ["available", "executing"]
    end

    test "a v2 answer continuation uses the next checkpoint version", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, _awaiting} =
               ImportRuns.complete_analysis(run.id, :awaiting_answers, %{
                 questions: [%{"id" => "q1"}],
                 lesson_plan: %{"blockers" => [%{"id" => "q1"}]}
               })

      assert {:ok, continued} =
               ImportRuns.submit_answers(project, author, run.id, %{"q1" => "answer"})

      persisted = Repo.get!(ImportRun, run.id)
      assert persisted.status == :analyzing
      assert persisted.answers == %{"q1" => "answer"}
      assert persisted.analysis_state["checkpoint_version"] == 1
      assert continued.analysis_state["checkpoint_version"] == 1

      assert_enqueued(
        worker: AnalysisWorker,
        args: %{"run_id" => run.id, "checkpoint_version" => 1}
      )
    end

    test "only current scalar blocker answers are persisted", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, _awaiting} =
               ImportRuns.complete_analysis(run.id, :awaiting_answers, %{
                 questions: [%{"id" => "q1"}],
                 lesson_plan: %{"blockers" => [%{"key" => "q1"}]}
               })

      assert {:ok, continued} =
               ImportRuns.submit_answers(project, author, run.id, %{
                 "q1" => "  reviewed answer  ",
                 "not-a-current-blocker" => "discard me"
               })

      assert continued.answers == %{"q1" => "reviewed answer"}
    end

    test "rejects oversized or structured blocker answers without persisting them", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, _awaiting} =
               ImportRuns.complete_analysis(run.id, :awaiting_answers, %{
                 questions: [%{"id" => "q1"}],
                 lesson_plan: %{"blockers" => [%{"key" => "q1"}]}
               })

      assert {:error, :invalid_answer_payload} =
               ImportRuns.submit_answers(project, author, run.id, %{
                 "q1" => %{"nested" => "not allowed"}
               })

      assert {:error, :invalid_answer_payload} =
               ImportRuns.submit_answers(project, author, run.id, %{
                 "q1" => String.duplicate("x", 8_001)
               })

      persisted = Repo.get!(ImportRun, run.id)
      assert persisted.status == :awaiting_answers
      assert persisted.answers == %{}
    end
  end

  describe "safe failure classification" do
    test "classifies AI authentication failures without persisting provider bodies", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, failed} =
               ImportRuns.fail(
                 run.id,
                 :analysis,
                 {:completion_failed,
                  %{status_code: 401, body: "provider response must not be persisted"}}
               )

      assert failed.error["code"] == "ai_authentication_failed"

      assert failed.error["message"] ==
               "The configured AI service credentials were rejected. Ask an administrator to verify the AI service configuration."

      refute inspect(failed.error) =~ "provider response must not be persisted"
    end

    test "classifies planner and Google authentication limits", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, planner_run} = start_run(project, author, container)

      assert {:ok, failed_planner_run} =
               ImportRuns.fail(
                 planner_run.id,
                 :analysis,
                 {:tool_budget_exhausted, 8, [%{tool: "private-payload"}]}
               )

      assert failed_planner_run.error["code"] == "planner_step_limit_exceeded"
      refute inspect(failed_planner_run.error) =~ "private-payload"

      assert {:ok, google_run} = start_run(project, author, container)

      assert {:ok, failed_google_run} =
               ImportRuns.fail(
                 google_run.id,
                 :analysis,
                 {:token_http_status, 400, "private Google response"}
               )

      assert failed_google_run.error["code"] == "google_service_account_rejected"
      refute inspect(failed_google_run.error) =~ "private Google response"
    end

    test "classifies structured plan validation errors without persisting details", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, failed} =
               ImportRuns.fail(run.id, :analysis, [
                 %{
                   "code" => "unknown_object",
                   "path" => "lesson.screens[0].sourceRefs[0]",
                   "message" => "private source validation detail"
                 }
               ])

      assert failed.error["code"] == "planner_output_invalid"

      assert failed.error["message"] ==
               "The AI planner returned a lesson plan that did not pass validation. Try again or contact support."

      refute inspect(failed.error) =~ "private source validation detail"
    end

    test "distinguishes timeout, connection, routing, and capacity failures", %{
      author: author,
      project: project,
      container: container
    } do
      expected_codes = [
        {:recv_timeout, "ai_request_timed_out"},
        {:nxdomain, "ai_connection_failed"},
        {:all_breakers_open, "ai_routing_unavailable"},
        {:over_capacity, "ai_capacity_unavailable"}
      ]

      Enum.each(expected_codes, fn {provider_reason, expected_code} ->
        assert {:ok, run} = start_run(project, author, container)

        assert {:ok, failed_run} =
                 ImportRuns.fail(run.id, :analysis, {:completion_failed, provider_reason})

        assert failed_run.error["code"] == expected_code
      end)
    end

    test "preserves the provider failure when retries end behind an open breaker", %{
      author: author,
      project: project,
      container: container
    } do
      assert {:ok, run} = start_run(project, author, container)

      assert {:ok, retrying} =
               ImportRuns.record_retry(
                 run.id,
                 :analysis,
                 {:completion_failed, %{status_code: 503, body: "private provider response"}},
                 1
               )

      assert retrying.error["code"] == "ai_provider_unavailable"

      assert {:ok, failed} =
               ImportRuns.fail(
                 run.id,
                 :analysis,
                 {:completion_failed, :all_breakers_open},
                 3
               )

      assert failed.error["code"] == "ai_provider_unavailable"
      assert failed.error["routing_code"] == "ai_routing_unavailable"
      assert failed.error["attempt"] == 3
      assert failed.error["retryable"] == false
      refute inspect(failed.error) =~ "private provider response"
    end
  end

  defp start_run(project, author, container) do
    ImportRuns.start_analysis(project, author, container, %{
      presentation_url: "https://docs.google.com/presentation/d/test-deck/edit",
      options: %{"layout_mode" => "responsive"}
    })
  end
end
