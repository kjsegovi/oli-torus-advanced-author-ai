defmodule Oli.OpenStax.CourseImport.Worker.EnrichmentResearchWorker do
  @moduledoc """
  Performs non-blocking curated-resource research for one proposal.

  Run-status fences before and after provider work prevent an executing job
  from reviving research after the import leaves author review.
  """

  use Oban.Worker,
    queue: :course_import_enrichment,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.Enrichment.Research
  alias Oli.OpenStax.CourseImport.{AIBackend, Enrichment, PubSub}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"proposal_id" => proposal_id, "run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with :ok <- ensure_reviewable(run_id),
         {:ok, run} <- CourseImport.fetch_run(run_id),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run_id,
         {:ok, running} <- Enrichment.mark_research_running(proposal.id),
         result <- Research.research(running, AIBackend.research_options(run.ai_backend)),
         :ok <- ensure_reviewable(run_id) do
      persist_result(proposal_id, run_id, result, attempt, max_attempts)
    else
      false ->
        {:discard, :proposal_run_mismatch}

      {:error, :not_found} ->
        {:discard, :proposal_not_found}

      {:error, :run_not_reviewable} ->
        _ = Enrichment.cancel_run_workflows(run_id)
        :ok

      {:error, reason} ->
        terminal_or_retry(proposal_id, run_id, attempt, max_attempts, reason)
    end
  rescue
    _exception ->
      terminal_or_retry(proposal_id, run_id, attempt, max_attempts, :research_worker_failed)
  end

  def perform(_job), do: {:discard, :invalid_research_job}

  defp persist_result(proposal_id, run_id, {:ok, _evidence} = result, _attempt, _max_attempts) do
    case Enrichment.record_research_result(proposal_id, result) do
      {:ok, proposal} ->
        broadcast_run(proposal.run_id)
        :ok

      {:error, reason} ->
        case ensure_reviewable(run_id) do
          :ok -> {:error, {:research_result_persistence_failed, reason}}
          {:error, :run_not_reviewable} -> :ok
        end
    end
  end

  defp persist_result(proposal_id, run_id, {:error, reason}, attempt, max_attempts) do
    terminal_or_retry(proposal_id, run_id, attempt, max_attempts, reason)
  end

  defp persist_result(proposal_id, run_id, _invalid, attempt, max_attempts) do
    terminal_or_retry(
      proposal_id,
      run_id,
      attempt,
      max_attempts,
      :invalid_research_result
    )
  end

  defp terminal_or_retry(proposal_id, run_id, attempt, max_attempts, reason) do
    if attempt < max_attempts do
      {:error, reason}
    else
      case Enrichment.fail_running_research(proposal_id, reason) do
        {:ok, proposal} ->
          broadcast_run(proposal.run_id)
          :ok

        {:error, persistence_reason} ->
          case ensure_reviewable(run_id) do
            :ok -> {:error, {:research_failure_persistence_failed, persistence_reason}}
            {:error, :run_not_reviewable} -> :ok
          end
      end
    end
  end

  defp ensure_reviewable(run_id) do
    case CourseImport.fetch_run(run_id) do
      {:ok, %{status: :awaiting_lesson_approval}} -> :ok
      _ -> {:error, :run_not_reviewable}
    end
  end

  defp broadcast_run(run_id) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      PubSub.broadcast(run)
    end
  end
end
