defmodule Oli.GoogleSlides.ImportRuns.AnalysisWorkerTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleSlides.ImportRun
  alias Oli.GoogleSlides.ImportRuns
  alias Oli.GoogleSlides.ImportRuns.AnalysisWorker
  alias Oli.Repo

  defmodule ReadyWorkflow do
    def perform(_run_id) do
      {:ok, :ready_for_review,
       %{
         lesson_plan: %{"title" => "Ready lesson"},
         validation_results: %{"status" => "ready"}
       }}
    end
  end

  defmodule PermanentErrorWorkflow do
    def perform(_run_id), do: {:error, :invalid_lesson_plan}
  end

  defmodule TransientErrorWorkflow do
    def perform(_run_id), do: {:error, {:http_status, 503, "private upstream response"}}
  end

  defmodule ExceptionWorkflow do
    def perform(_run_id), do: raise(ArgumentError, "private source content")
  end

  defmodule CheckpointWorkflow do
    def perform(run_id) do
      run = Oli.GoogleSlides.ImportRuns.fetch_run(run_id)

      {:checkpoint,
       %{
         analysis_state:
           run.analysis_state
           |> Map.put("phase", "detail")
           |> Map.put("completed_units", 1)
       }}
    end
  end

  defmodule SyntheticLongDeckWorkflow do
    def perform(run_id) do
      run = Oli.GoogleSlides.ImportRuns.fetch_run(run_id)
      completed_units = run.analysis_state["completed_units"] || 0

      case completed_units do
        completed when completed < 3 ->
          {:checkpoint,
           %{
             analysis_state:
               run.analysis_state
               |> Map.put("phase", "detail")
               |> Map.put("completed_units", completed + 1)
               |> Map.put("total_units", 18)
               |> Map.put("current_slide_range", %{
                 "start" => completed * 12 + 1,
                 "end" => (completed + 1) * 12
               })
               |> Map.update(
                 "accumulated_usage",
                 %{"prompt_tokens" => 400_000},
                 fn usage ->
                   Map.update(usage, "prompt_tokens", 400_000, &(&1 + 400_000))
                 end
               )
           }}

        _completed ->
          {:ok, :ready_for_review,
           %{
             lesson_plan: %{"title" => "Synthetic 80-slide lesson"},
             validation_results: %{"status" => "ready"}
           }}
      end
    end
  end

  defmodule CancellingWorkflow do
    def perform(run_id) do
      run = Oli.GoogleSlides.ImportRuns.fetch_run(run_id)
      project = Oli.Repo.get!(Oli.Authoring.Course.Project, run.project_id)
      author = Oli.Repo.get!(Oli.Accounts.Author, run.author_id)

      {:ok, _cancelled} = Oli.GoogleSlides.ImportRuns.cancel(project, author, run_id)

      {:ok, :ready_for_review, %{lesson_plan: %{"title" => "Late result"}}}
    end
  end

  setup do
    previous_workflow =
      Application.get_env(:oli, :google_slides_import_analysis_workflow)

    on_exit(fn ->
      if previous_workflow do
        Application.put_env(
          :oli,
          :google_slides_import_analysis_workflow,
          previous_workflow
        )
      else
        Application.delete_env(:oli, :google_slides_import_analysis_workflow)
      end
    end)

    author = author_fixture()
    %{project: project, resource: container} = project_fixture(author)
    {:ok, run} = start_run(project, author, container)

    %{author: author, project: project, run: run}
  end

  test "persists a successful analysis result", %{run: run} do
    use_workflow(ReadyWorkflow)

    assert :ok = perform(run, 1, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :ready_for_review
    assert persisted.plan_version == 1
    assert persisted.lesson_plan == %{"title" => "Ready lesson"}
    assert is_nil(persisted.error)
  end

  test "permanent analysis errors fail immediately without consuming retries", %{run: run} do
    use_workflow(PermanentErrorWorkflow)

    assert {:discard, :invalid_lesson_plan} = perform(run, 1, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :failed
    assert persisted.error["retryable"] == false
    assert persisted.error["attempt"] == 1
    assert persisted.error["phase"] == "analysis"
    assert persisted.finished_at
  end

  test "transient network and server errors remain analyzing before the final attempt", %{
    run: run
  } do
    use_workflow(TransientErrorWorkflow)
    reason = {:http_status, 503, "private upstream response"}

    assert {:error, ^reason} = perform(run, 1, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :analyzing
    assert persisted.error["retryable"] == true
    assert persisted.error["attempt"] == 1
    assert persisted.error["code"] == "google_slides_temporarily_unavailable"
    refute persisted.error["message"] =~ "private upstream response"
  end

  test "a transient error becomes terminal on the final attempt", %{run: run} do
    use_workflow(TransientErrorWorkflow)
    reason = {:http_status, 503, "private upstream response"}

    assert {:discard, ^reason} = perform(run, 3, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :failed
    assert persisted.error["retryable"] == false
    assert persisted.error["attempt"] == 3
  end

  test "persists only sanitized exception diagnostics", %{run: run} do
    use_workflow(ExceptionWorkflow)

    assert {:discard, {:internal_exception, "ArgumentError", location}} = perform(run, 1, 3)
    assert location["module"] =~ "ExceptionWorkflow"
    assert location["function"] == "perform"

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :failed
    assert persisted.error["code"] == "internal_exception"
    assert persisted.error["diagnostic"]["exception"] == "ArgumentError"
    assert persisted.error["diagnostic"]["location"]["module"] =~ "ExceptionWorkflow"
    refute inspect(persisted.error) =~ "private source content"
  end

  test "cancellation wins over an in-flight successful analysis", %{run: run} do
    use_workflow(CancellingWorkflow)

    assert :ok = perform(run, 1, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :cancelled
    assert persisted.finished_at
    assert is_nil(persisted.lesson_plan)
  end

  test "checkpoints enqueue the next version and stale jobs are discarded", %{run: run} do
    use_workflow(CheckpointWorkflow)

    assert :ok = perform(run, 0, 1, 3)

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :analyzing
    assert persisted.analysis_state["checkpoint_version"] == 1
    assert persisted.analysis_state["completed_units"] == 1

    assert_enqueued(
      worker: AnalysisWorker,
      args: %{"run_id" => run.id, "checkpoint_version" => 1}
    )

    assert {:discard, :stale_checkpoint} = perform(run, 0, 1, 3)
  end

  test "a synthetic 80-slide deck crosses repeated 400k checkpoints without failing", %{
    run: run
  } do
    use_workflow(SyntheticLongDeckWorkflow)

    for checkpoint_version <- 0..3 do
      assert :ok = perform(run, checkpoint_version, 1, 3)

      persisted = Repo.get!(ImportRun, run.id)
      refute persisted.status == :failed
    end

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.status == :ready_for_review
    assert persisted.analysis_state["completed_units"] == 3
    assert persisted.analysis_state["accumulated_usage"]["prompt_tokens"] == 1_200_000
  end

  test "retry classification is limited to transient transport, capacity, and server failures" do
    assert AnalysisWorker.retryable_error?(:timeout)
    assert AnalysisWorker.retryable_error?({:completion_failed, :econnreset})
    assert AnalysisWorker.retryable_error?({:http_status, 429, ""})
    assert AnalysisWorker.retryable_error?({:token_http_status, 502, ""})
    assert AnalysisWorker.retryable_error?(%{status_code: 503, body: ""})
    assert AnalysisWorker.retryable_error?(:all_breakers_open)

    refute AnalysisWorker.retryable_error?(:not_configured)
    refute AnalysisWorker.retryable_error?(:presentation_not_accessible)
    refute AnalysisWorker.retryable_error?({:http_status, 400, ""})
    refute AnalysisWorker.retryable_error?({:invalid_lesson_plan, ["missing title"]})
  end

  defp use_workflow(module) do
    Application.put_env(:oli, :google_slides_import_analysis_workflow, module)
  end

  defp perform(run, attempt, max_attempts) do
    perform(run, 0, attempt, max_attempts)
  end

  defp perform(run, checkpoint_version, attempt, max_attempts) do
    AnalysisWorker.perform(%Oban.Job{
      args: %{"run_id" => run.id, "checkpoint_version" => checkpoint_version},
      attempt: attempt,
      max_attempts: max_attempts
    })
  end

  defp start_run(%Project{} = project, %Author{} = author, container) do
    ImportRuns.start_analysis(project, author, container, %{
      presentation_url: "https://docs.google.com/presentation/d/test-deck/edit"
    })
  end
end
