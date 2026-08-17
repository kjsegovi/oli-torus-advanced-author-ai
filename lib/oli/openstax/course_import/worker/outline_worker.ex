defmodule Oli.OpenStax.CourseImport.Worker.OutlineWorker do
  @moduledoc """
  Ingests the approved OpenStax chapter scope and persists the outline.
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
  alias Oli.OpenStax.CourseImport.{Parser, RichSource, Run, Source}

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

  defp perform_run(%Run{status: :ingesting} = run, attempt, max_attempts) do
    selected_ids = get_in(run.scope_manifest || %{}, ["selected_chapter_ids"]) || []

    with {:ok, _run} <-
           CourseImport.set_progress(
             run.id,
             %{"stage" => "ingesting", "work_state" => "running"},
             :ingesting
           ),
         {:ok, snapshot} <-
           Source.ingest(run.preflight_snapshot || %{}, selected_ids, source_options(run)),
         {:ok, _run} <- CourseImport.persist_ingested_snapshot(run.id, snapshot),
         {:ok, _run} <- CourseImport.transition_run(run.id, :planning_outline),
         :ok <- persist_outline(run, snapshot) do
      :ok
    else
      {:error, reason} -> retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(%Run{status: :planning_outline} = run, attempt, max_attempts) do
    with {:ok, _run} <-
           CourseImport.set_progress(
             run.id,
             %{"stage" => "planning_outline", "work_state" => "running"},
             :planning_outline
           ),
         {:ok, snapshot} <- planning_snapshot(run),
         :ok <- persist_outline(run, snapshot) do
      :ok
    else
      {:error, reason} -> retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(%Run{status: status}, _attempt, _max_attempts)
       when status in [
              :awaiting_outline_approval,
              :planning_lessons,
              :awaiting_lesson_approval,
              :compiling,
              :staging_media,
              :applying,
              :completed,
              :failed,
              :cancelled
            ],
       do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts),
    do: {:discard, {:invalid_run_status, status}}

  defp persist_outline(%Run{} = run, snapshot) do
    with {:ok, outline} <-
           Parser.build_outline(snapshot, plan_schema_version: run.plan_schema_version),
         {:ok, _units} <- CourseImport.upsert_units_and_lessons(run.id, outline),
         {:ok, _run} <- CourseImport.transition_run(run.id, :awaiting_outline_approval) do
      :ok
    end
  end

  defp planning_snapshot(%Run{source_schema_version: 3} = run),
    do: RichSource.load_snapshot(run.id, run.preflight_snapshot || %{})

  defp planning_snapshot(%Run{source_schema_version: version}),
    do: {:error, {:unsupported_openstax_source_schema, version}}

  defp retry_or_fail(run_id, attempt, max_attempts, reason) when attempt < max_attempts do
    _ =
      CourseImport.set_progress(run_id, %{
        "work_state" => "retrying",
        "attempt" => attempt,
        "max_attempts" => max_attempts
      })

    {:error, reason}
  end

  defp retry_or_fail(run_id, _attempt, _max_attempts, reason) do
    CourseImport.mark_failed(run_id, :outline, reason)
    {:discard, reason}
  end

  defp source_options(%Run{}) do
    :oli
    |> Application.get_env(:openstax_course_import_source_options, [])
    |> Keyword.put_new(:strict_book_content, true)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)
end
