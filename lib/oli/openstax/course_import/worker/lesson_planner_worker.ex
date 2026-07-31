defmodule Oli.OpenStax.CourseImport.Worker.LessonPlannerWorker do
  @moduledoc """
  Generates versioned lesson plans, questions, and three durable checks.
  """

  use Oban.Worker,
    queue: :course_import_ai,
    max_attempts: 4,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.Run

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      perform_run(run, attempt, max_attempts)
    else
      {:error, :not_found} -> {:discard, :run_not_found}
    end
  rescue
    exception ->
      retry_or_fail(
        run_id,
        attempt,
        max_attempts,
        {:internal_exception, Exception.message(exception)}
      )
  end

  defp perform_run(
         %Run{status: :planning_lessons, lesson_planning_strategy: :serial_v1} = run,
         attempt,
         max_attempts
       ) do
    with {:ok, _count} <- CourseImport.generate_lesson_plans(run.id) do
      :ok
    else
      {:error, reason} -> retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(
         %Run{status: :planning_lessons, lesson_planning_strategy: :parallel_v1},
         _attempt,
         _max_attempts
       ),
       do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts)
       when status in [
              :awaiting_lesson_approval,
              :compiling,
              :applying,
              :completed,
              :failed,
              :cancelled
            ],
       do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts),
    do: {:discard, {:invalid_run_status, status}}

  defp retry_or_fail(run_id, attempt, max_attempts, reason) when attempt < max_attempts do
    _ =
      CourseImport.set_progress(
        run_id,
        %{
          "work_state" => "retrying",
          "attempt" => attempt,
          "max_attempts" => max_attempts,
          "current_item" => nil
        },
        :planning_lessons
      )

    {:error, reason}
  end

  defp retry_or_fail(run_id, _attempt, _max_attempts, reason) do
    CourseImport.mark_failed(run_id, :lesson_planning, reason)
    {:discard, reason}
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  # A full 120-section source can produce roughly 60 lesson plans. Keeping the
  # work in one resumable job preserves deterministic ordering and lets retries
  # skip persisted lessons, while this explicit budget accommodates configured
  # provider receive timeouts for a book-scale run.
  def timeout(_job), do: :timer.hours(4)
end
