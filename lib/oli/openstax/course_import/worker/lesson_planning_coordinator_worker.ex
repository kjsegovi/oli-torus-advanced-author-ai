defmodule Oli.OpenStax.CourseImport.Worker.LessonPlanningCoordinatorWorker do
  @moduledoc """
  Initializes and reconciles bounded, per-lesson OpenStax planning work.

  The coordinator is intentionally short lived. The durable run and lesson
  rows are the source of truth, so duplicate delivery is harmless.
  """

  use Oban.Worker,
    queue: :course_import,
    max_attempts: 4,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.OpenStax.CourseImport

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id, "generation" => generation},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case CourseImport.initialize_parallel_lesson_planning(run_id, generation) do
      {:ok, _run} ->
        :ok

      {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
        {:discard, reason}

      {:error, reason} when attempt < max_attempts ->
        {:error, reason}

      {:error, reason} ->
        _ =
          CourseImport.mark_failed_if_status(run_id, :planning_lessons, :lesson_planning, reason)

        {:discard, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_coordinator_args}

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
