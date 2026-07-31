defmodule Oli.GoogleSlides.ImportRuns.GenerationWorkerTest do
  use Oli.DataCase, async: false

  alias Oli.GoogleSlides.ImportRun
  alias Oli.GoogleSlides.ImportRuns.GenerationWorker
  alias Oli.Repo

  defmodule ResultWorkflow do
    def perform(run_id) do
      send(self(), {:workflow_called, run_id})
      Process.get(:generation_worker_result)
    end
  end

  defmodule CompletingWorkflow do
    alias Oli.GoogleSlides.ImportRun
    alias Oli.Repo

    def perform(run_id) do
      run = Repo.get!(ImportRun, run_id)

      completed_run =
        run
        |> ImportRun.update_changeset(%{
          status: :completed,
          result_revision_id: Process.get(:generation_worker_result_revision_id),
          result: %{"completed" => true},
          finished_at: DateTime.utc_now()
        })
        |> Repo.update!()

      {:ok, completed_run}
    end
  end

  defmodule CancellingWorkflow do
    alias Oli.GoogleSlides.ImportRun
    alias Oli.Repo

    def perform(run_id) do
      run = Repo.get!(ImportRun, run_id)

      run
      |> ImportRun.update_changeset(%{
        status: :cancelled,
        finished_at: DateTime.utc_now()
      })
      |> Repo.update!()

      {:error, :timeout}
    end
  end

  setup do
    seed = Seeder.base_project_with_resource2()
    run = generating_run(seed)
    previous_workflow = Application.get_env(:oli, :google_slides_import_generation_workflow)

    on_exit(fn ->
      restore_application_env(
        :oli,
        :google_slides_import_generation_workflow,
        previous_workflow
      )
    end)

    {:ok, seed: seed, run: run}
  end

  test "fails deterministic errors immediately without consuming retries", %{run: run} do
    Application.put_env(:oli, :google_slides_import_generation_workflow, ResultWorkflow)
    Process.put(:generation_worker_result, {:error, :stale_plan})

    assert {:discard, :stale_plan} = GenerationWorker.perform(job(run.id, 1, 3))
    assert_receive {:workflow_called, run_id}
    assert run_id == run.id

    failed_run = Repo.get!(ImportRun, run.id)
    assert failed_run.status == :failed
    assert failed_run.error["phase"] == "generation"
    assert failed_run.error["retryable"] == false
  end

  test "fails source-fidelity validation errors immediately", %{run: run} do
    Application.put_env(:oli, :google_slides_import_generation_workflow, ResultWorkflow)

    reason =
      {:invalid_source_fidelity,
       [
         %{
           "path" => "lesson.screens[0]",
           "code" => "unresolved_source_element",
           "message" => "a source element has no reviewed disposition"
         }
       ]}

    Process.put(:generation_worker_result, {:error, reason})

    assert {:discard, ^reason} = GenerationWorker.perform(job(run.id, 1, 3))

    failed_run = Repo.get!(ImportRun, run.id)
    assert failed_run.status == :failed
    assert failed_run.error["retryable"] == false
  end

  test "records transient errors and only fails after the final attempt", %{run: run} do
    Application.put_env(:oli, :google_slides_import_generation_workflow, ResultWorkflow)
    Process.put(:generation_worker_result, {:error, :timeout})

    assert {:error, :timeout} = GenerationWorker.perform(job(run.id, 1, 3))

    retrying_run = Repo.get!(ImportRun, run.id)
    assert retrying_run.status == :generating
    assert retrying_run.error["attempt"] == 1
    assert retrying_run.error["retryable"] == true

    assert {:discard, :timeout} = GenerationWorker.perform(job(run.id, 3, 3))

    failed_run = Repo.get!(ImportRun, run.id)
    assert failed_run.status == :failed
    assert failed_run.error["retryable"] == false
  end

  test "the workflow owns the completed transition", %{seed: seed, run: run} do
    Application.put_env(:oli, :google_slides_import_generation_workflow, CompletingWorkflow)
    Process.put(:generation_worker_result_revision_id, seed.container.revision.id)

    assert :ok = GenerationWorker.perform(job(run.id, 1, 3))

    completed_run = Repo.get!(ImportRun, run.id)
    assert completed_run.status == :completed
    assert completed_run.result_revision_id == seed.container.revision.id
  end

  test "a retried job sees completion and does not execute the workflow", %{seed: seed, run: run} do
    completed_run =
      run
      |> ImportRun.update_changeset(%{
        status: :completed,
        result_revision_id: seed.container.revision.id,
        finished_at: DateTime.utc_now()
      })
      |> Repo.update!()

    Application.put_env(:oli, :google_slides_import_generation_workflow, ResultWorkflow)
    Process.put(:generation_worker_result, {:error, :timeout})

    assert :ok = GenerationWorker.perform(job(completed_run.id, 2, 3))
    refute_received {:workflow_called, _run_id}
  end

  test "a cancellation racing with failure recording stays cancelled", %{run: run} do
    Application.put_env(:oli, :google_slides_import_generation_workflow, CancellingWorkflow)

    assert :ok = GenerationWorker.perform(job(run.id, 1, 3))
    assert Repo.get!(ImportRun, run.id).status == :cancelled
  end

  defp job(run_id, attempt, max_attempts) do
    %Oban.Job{
      args: %{"run_id" => run_id},
      attempt: attempt,
      max_attempts: max_attempts
    }
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

  defp restore_application_env(application, key, nil),
    do: Application.delete_env(application, key)

  defp restore_application_env(application, key, value),
    do: Application.put_env(application, key, value)
end
