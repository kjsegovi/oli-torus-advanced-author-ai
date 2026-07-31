defmodule Oli.OpenStax.CourseImport.Worker.MediaWorker do
  @moduledoc """
  Stages only media selected by the approved-plan dry run, recompiles with
  project-owned URLs, and advances the durable run to atomic apply.
  """

  use Oban.Worker,
    queue: :course_import_media,
    max_attempts: 4,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Compiler, MediaIngestor, Run, Telemetry}

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

  defp perform_run(%Run{status: :staging_media} = run, attempt, max_attempts) do
    with {:ok, checkpoint} <- CourseImport.compile_checkpoint(run),
         {:ok, _run} <-
           initialize_progress(run.id, length(checkpoint["required_media_ids"] || [])),
         {:ok, result} <- MediaIngestor.stage_required_run(run.id, media_options(run.id)),
         {:ok, _run} <- persist_progress(run.id, result),
         :ok <- Telemetry.media_staged(run.id, result),
         {:ok, media_urls} <- MediaIngestor.required_media_urls(run.id),
         true <- Map.keys(media_urls) |> Enum.sort() == checkpoint["required_media_ids"],
         {:ok, detailed_run} <- CourseImport.run_with_resources(run.id),
         {:ok, ^checkpoint} <- CourseImport.compile_checkpoint(detailed_run),
         {:ok, compiled} <-
           Compiler.dry_run(detailed_run,
             media_urls: media_urls,
             attribution: CourseImport.source_attribution(detailed_run)
           ),
         true <-
           MediaIngestor.required_media_ids(compiled) == checkpoint["required_media_ids"],
         {:ok, current_run} <- CourseImport.fetch_run(run.id),
         {:ok, _applying_run} <- CourseImport.finish_media_staging(current_run, compiled) do
      :ok
    else
      {:error, {:required_media_unavailable, _} = reason} ->
        return_to_review(run.id, reason)

      {:error, {:unknown_required_media_ids, _} = reason} ->
        return_to_review(run.id, reason)

      false ->
        return_to_review(run.id, :required_media_selection_changed)

      {:error, reason} ->
        retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(%Run{status: status}, _attempt, _max_attempts)
       when status in [:applying, :completed, :failed, :cancelled],
       do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts),
    do: {:discard, {:invalid_run_status, status}}

  defp persist_progress(run_id, result) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      completed =
        run.progress
        |> progress_count("assets_staged")
        |> max(result.staged + result.reused)
        |> min(result.total)

      reused = max(progress_count(run.progress, "assets_reused"), result.reused)

      CourseImport.set_progress(
        run_id,
        %{
          "stage" => "staging_media",
          "work_state" => "running",
          "counts" => %{
            "assets_staged" => completed,
            "assets_reused" => reused
          },
          "stage_totals" => [
            %{
              "label" => "Required media staged",
              "completed" => completed,
              "total" => result.total
            }
          ]
        },
        :staging_media
      )
    end
  end

  defp initialize_progress(run_id, total) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      completed = min(progress_count(run.progress, "assets_staged"), total)
      reused = progress_count(run.progress, "assets_reused")

      CourseImport.set_progress(
        run_id,
        %{
          "stage" => "staging_media",
          "work_state" => "running",
          "counts" => %{"assets_staged" => completed, "assets_reused" => reused},
          "stage_totals" => [
            %{
              "label" => "Required media staged",
              "completed" => completed,
              "total" => total
            }
          ]
        },
        :staging_media
      )
    end
  end

  defp progress_count(progress, key) do
    case get_in(progress || %{}, ["counts", key]) do
      count when is_integer(count) and count >= 0 -> count
      count when is_float(count) and count >= 0 -> trunc(count)
      _ -> 0
    end
  end

  defp return_to_review(run_id, reason) do
    Telemetry.media_failed(run_id, reason)

    case CourseImport.return_media_failure_to_review(run_id, reason) do
      {:ok, _run} -> {:discard, reason}
      {:error, transition_reason} -> {:discard, transition_reason}
    end
  end

  defp retry_or_fail(run_id, attempt, max_attempts, reason) when attempt < max_attempts do
    _ =
      CourseImport.set_progress(
        run_id,
        %{
          "work_state" => "retrying",
          "attempt" => attempt,
          "max_attempts" => max_attempts
        },
        :staging_media
      )

    {:error, reason}
  end

  defp retry_or_fail(run_id, _attempt, _max_attempts, reason) do
    Telemetry.media_failed(run_id, reason)
    CourseImport.mark_failed(run_id, :media_staging, reason)
    {:discard, reason}
  end

  defp media_options(run_id) do
    :oli
    |> Application.get_env(:openstax_course_import_media_options, [])
    |> Keyword.put(:on_progress, &persist_progress(run_id, &1))
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  # Staging is resumable per asset, but a large approved course can legitimately
  # select hundreds of figures. Keep this work off the control queue and make
  # the hard timeout coherent with the configured per-request/redirect bounds.
  def timeout(_job), do: :timer.hours(7)
end
