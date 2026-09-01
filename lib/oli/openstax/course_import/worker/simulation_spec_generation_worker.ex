defmodule Oli.OpenStax.CourseImport.Worker.SimulationSpecGenerationWorker do
  @moduledoc """
  Produces and independently reviews one immutable SimulationSpecV1 version.

  The worker is fenced to an author-reviewable v7 run and to the exact approved
  research set recorded on the spec. Provider errors are retried and the final
  sanitized failure is persisted without changing any legacy import.
  """

  use Oban.Worker,
    queue: :course_import_enrichment,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    AIBackend,
    Enrichment,
    PubSub,
    SimulationSpec
  }

  alias Oli.OpenStax.CourseImport.Enrichment.SimulationSpecDesigner
  alias Oli.Authoring.Course.Project
  alias Oli.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"spec_id" => spec_id, "run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Repo.get(SimulationSpec, spec_id) do
      %SimulationSpec{run_id: ^run_id, status: "designing"} = spec ->
        generate(spec, attempt, max_attempts)

      %SimulationSpec{run_id: ^run_id} ->
        :ok

      %SimulationSpec{} ->
        {:discard, :simulation_spec_run_mismatch}

      nil ->
        {:discard, :simulation_spec_not_found}
    end
  rescue
    _exception -> terminal_or_retry(spec_id, run_id, attempt, max_attempts, :spec_worker_failed)
  end

  def perform(_job), do: {:discard, :invalid_simulation_spec_job}

  defp generate(spec, attempt, max_attempts) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- ensure_reviewable(spec.run_id),
         {:ok, run} <- CourseImport.fetch_run(spec.run_id),
         {:ok, proposal} <- Enrichment.fetch_proposal(spec.proposal_id),
         {:ok, research} <- Enrichment.fetch_research_set(spec.research_set_id),
         true <- proposal.run_id == spec.run_id and research.run_id == spec.run_id,
         true <- research.status == "approved" and research.content_hash == spec.evidence_hash,
         {:ok, services} <- AIBackend.simulation_spec_services(run.ai_backend),
         designer_opts <-
           [
             three_d_enabled: three_d_enabled?(spec.project_id),
             run_id: spec.run_id,
             lesson_id: spec.lesson_id,
             operation_id: spec.id,
             cost_scope: :simulation,
             ai_backend: run.ai_backend
           ]
           |> maybe_put_services(services),
         result <-
           SimulationSpecDesigner.generate(
             proposal,
             research,
             designer_opts
           )
           |> put_duration(elapsed_milliseconds(started_at)),
         :ok <- ensure_reviewable(spec.run_id) do
      persist_result(spec, result, attempt, max_attempts)
    else
      false -> terminal_or_retry(spec.id, spec.run_id, attempt, max_attempts, :stale_research_set)
      {:error, :run_not_reviewable} -> :ok
      {:error, reason} -> terminal_or_retry(spec.id, spec.run_id, attempt, max_attempts, reason)
    end
  end

  defp persist_result(spec, {:ok, _result} = result, _attempt, _max_attempts) do
    case Enrichment.record_spec_result(spec.id, result) do
      {:ok, saved} ->
        broadcast_run(saved.run_id)
        :ok

      {:error, reason} ->
        {:error, {:simulation_spec_persistence_failed, reason}}
    end
  end

  defp persist_result(spec, {:error, reason}, attempt, max_attempts),
    do: terminal_or_retry(spec.id, spec.run_id, attempt, max_attempts, reason)

  defp persist_result(spec, _invalid, attempt, max_attempts),
    do:
      terminal_or_retry(
        spec.id,
        spec.run_id,
        attempt,
        max_attempts,
        :invalid_simulation_spec_result
      )

  defp terminal_or_retry(spec_id, run_id, attempt, max_attempts, reason) do
    if attempt < max_attempts do
      {:error, reason}
    else
      case Enrichment.record_spec_result(spec_id, {:error, reason}) do
        {:ok, spec} ->
          broadcast_run(spec.run_id)
          :ok

        {:error, persistence_reason} ->
          case ensure_reviewable(run_id) do
            :ok -> {:error, {:simulation_spec_failure_persistence_failed, persistence_reason}}
            {:error, :run_not_reviewable} -> :ok
          end
      end
    end
  end

  defp ensure_reviewable(run_id) do
    case CourseImport.fetch_run(run_id) do
      {:ok,
       %{
         status: :awaiting_lesson_approval,
         source_schema_version: 4,
         plan_schema_version: 7
       }} ->
        :ok

      _ ->
        {:error, :run_not_reviewable}
    end
  end

  defp three_d_enabled?(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> CourseImport.enrichment_capabilities(project).three_d_enabled
      nil -> false
    end
  end

  defp broadcast_run(run_id) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      PubSub.broadcast(run)
    end
  end

  defp put_duration({:ok, result}, duration_ms) when is_map(result),
    do: {:ok, Map.put(result, :duration_ms, duration_ms)}

  defp put_duration(result, _duration_ms), do: result

  defp elapsed_milliseconds(started_at),
    do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp maybe_put_services(opts, nil), do: opts
  defp maybe_put_services(opts, services), do: Keyword.put(opts, :services, services)
end
