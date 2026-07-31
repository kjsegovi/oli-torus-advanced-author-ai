defmodule Oli.OpenStax.CourseImport.Worker.PreflightWorker do
  @moduledoc """
  Discovers the bounded OpenStax table of contents and pauses for scope review.
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
  alias Oli.OpenStax.CourseImport.{Run, Source}

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

  defp perform_run(%Run{status: :preflighting} = run, attempt, max_attempts) do
    with {:ok, _run} <-
           CourseImport.set_progress(
             run.id,
             %{
               "stage" => "preflighting",
               "work_state" => "running",
               "stage_totals" => [
                 %{"label" => "OpenStax source checked", "completed" => 0, "total" => 1}
               ]
             },
             :preflighting
           ),
         {:ok, snapshot} <- Source.discover(run.source_url, source_options()),
         {:ok, _run} <- CourseImport.persist_scope_snapshot(run.id, snapshot),
         {:ok, _run} <- CourseImport.transition_run(run.id, :awaiting_scope) do
      :ok
    else
      {:error, reason} -> retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(%Run{status: status}, _attempt, _max_attempts)
       when status in [
              :awaiting_scope,
              :ingesting,
              :staging_media,
              :planning_outline,
              :awaiting_outline_approval,
              :planning_lessons,
              :awaiting_lesson_approval,
              :compiling,
              :applying,
              :completed,
              :failed,
              :cancelled
            ],
       do: :ok

  defp retry_or_fail(run_id, attempt, max_attempts, reason) when attempt < max_attempts do
    _ =
      CourseImport.set_progress(
        run_id,
        %{
          "work_state" => "retrying",
          "attempt" => attempt,
          "max_attempts" => max_attempts
        },
        :preflighting
      )

    {:error, reason}
  end

  defp retry_or_fail(run_id, _attempt, _max_attempts, reason) do
    CourseImport.mark_failed(run_id, :preflight, reason)
    {:discard, reason}
  end

  defp source_options,
    do: Application.get_env(:oli, :openstax_course_import_source_options, [])

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 5)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(3)
end
