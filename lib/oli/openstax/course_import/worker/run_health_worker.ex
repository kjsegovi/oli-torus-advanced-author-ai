defmodule Oli.OpenStax.CourseImport.Worker.RunHealthWorker do
  @moduledoc """
  Recovers course-import runs whose stage job vanished or was discarded.

  Oban enforces hard execution timeouts by terminating the worker process. A
  terminated final attempt cannot execute that worker's normal `mark_failed`
  branch, so this periodic health check supplies the durable user-facing
  failure transition.
  """

  use Oban.Worker,
    queue: :course_import,
    max_attempts: 3,
    unique: [
      period: 240,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Lesson, Run}
  alias Oli.Repo

  @execution_statuses [
    :preflighting,
    :ingesting,
    :staging_media,
    :planning_outline,
    :planning_lessons,
    :applying
  ]

  @active_job_states ["available", "scheduled", "executing", "retryable"]
  @batch_size 100
  @execution_batch_size 75
  @review_batch_size @batch_size - @execution_batch_size

  @impl Oban.Worker
  def perform(_job) do
    execution_runs =
      Run
      |> where(
        [run],
        run.status in ^@execution_statuses and run.source_schema_version == 3 and
          run.plan_schema_version == 6
      )
      |> order_by([run], asc: run.updated_at)
      |> limit(^@execution_batch_size)
      |> Repo.all()

    runs = execution_runs ++ parallel_review_runs()

    serial_runs = Enum.reject(runs, &parallel_lesson_run?/1)

    active_run_ids = active_background_run_ids(Enum.map(serial_runs, & &1.id))

    Enum.each(runs, fn run ->
      if parallel_lesson_run?(run) do
        recover_parallel_run(run)
      else
        recover_if_orphaned(run, active_run_ids)
      end
    end)

    :ok
  end

  defp parallel_review_runs do
    unfinished_lesson =
      from(lesson in Lesson,
        where:
          lesson.run_id == parent_as(:run).id and
            lesson.planning_generation == parent_as(:run).lesson_planning_generation and
            lesson.planning_state in ["pending", "queued", "running", "retrying"],
        select: 1
      )

    Run
    |> from(as: :run)
    |> where(
      [run],
      run.status == :awaiting_lesson_approval and
        run.lesson_planning_strategy == :parallel_v1 and run.source_schema_version == 3 and
        run.plan_schema_version == 6
    )
    |> where([_run], exists(subquery(unfinished_lesson)))
    |> order_by([run], asc: run.updated_at)
    |> limit(^@review_batch_size)
    |> Repo.all()
  end

  defp recover_if_orphaned(run, active_run_ids) do
    if MapSet.member?(active_run_ids, run.id) do
      :ok
    else
      reason = {:background_job_missing, run.status}

      case CourseImport.mark_failed_if_status(
             run.id,
             run.status,
             phase(run.status),
             reason
           ) do
        {:ok, _failed_run} ->
          :ok

        {:error, {:invalid_status, _current, _expected}} ->
          # The real worker advanced the run after this health pass loaded it.
          :ok

        {:error, reason} ->
          Logger.warning(
            "Could not recover orphaned OpenStax course import #{run.id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp recover_parallel_run(%Run{status: :planning_lessons} = run) do
    with :ok <- maybe_initialize_parallel_run(run),
         {:ok, _run} <-
           CourseImport.recover_parallel_lesson_planning(
             run.id,
             run.lesson_planning_generation
           ) do
      :ok
    else
      {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] -> :ok
      {:error, reason} -> log_parallel_recovery_failure(run, reason)
    end
  end

  defp recover_parallel_run(%Run{status: :awaiting_lesson_approval} = run) do
    if parallel_review_work?(run) do
      case CourseImport.recover_parallel_lesson_planning(
             run.id,
             run.lesson_planning_generation
           ) do
        {:ok, _run} -> :ok
        {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] -> :ok
        {:error, reason} -> log_parallel_recovery_failure(run, reason)
      end
    else
      :ok
    end
  end

  defp recover_parallel_run(_run), do: :ok

  defp maybe_initialize_parallel_run(%Run{} = run) do
    initialized? =
      Repo.exists?(
        from(lesson in Lesson,
          where:
            lesson.run_id == ^run.id and
              lesson.planning_generation == ^run.lesson_planning_generation
        )
      )

    if initialized? do
      :ok
    else
      case CourseImport.initialize_parallel_lesson_planning(
             run.id,
             run.lesson_planning_generation
           ) do
        {:ok, _run} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parallel_lesson_run?(%Run{
         lesson_planning_strategy: :parallel_v1,
         status: status
       })
       when status in [:planning_lessons, :awaiting_lesson_approval],
       do: true

  defp parallel_lesson_run?(_run), do: false

  defp parallel_review_work?(%Run{} = run) do
    Repo.exists?(
      from(lesson in Lesson,
        where:
          lesson.run_id == ^run.id and
            lesson.planning_generation == ^run.lesson_planning_generation and
            lesson.planning_state in ["pending", "queued", "running", "retrying"]
      )
    )
  end

  defp log_parallel_recovery_failure(run, reason) do
    Logger.warning(
      "Could not reconcile parallel OpenStax lesson planning for #{run.id}: #{inspect(reason)}"
    )

    :ok
  end

  defp active_background_run_ids([]), do: MapSet.new()

  defp active_background_run_ids(run_ids) do
    from(job in Oban.Job,
      where:
        job.state in ^@active_job_states and
          fragment("?->>'run_id'", job.args) in ^run_ids,
      select: fragment("?->>'run_id'", job.args),
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp phase(:preflighting), do: :preflight
  defp phase(status) when status in [:ingesting, :planning_outline], do: :outline
  defp phase(:staging_media), do: :media_staging
  defp phase(:planning_lessons), do: :lesson_planning
  defp phase(:applying), do: :apply

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)
end
