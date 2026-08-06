defmodule Oli.OpenStax.CourseImport.Worker.SimulationGenerationWorker do
  @moduledoc """
  Generates, validates, and stages one approved simulation artifact version.

  Storage identity is persisted before upload, which makes a crash after upload
  recoverable. Provider failures retry, remain non-blocking to the core import,
  and become a sanitized terminal artifact finding after the final attempt.
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

  alias Oli.OpenStax.CourseImport.Enrichment.{
    ArtifactStorage,
    Generator,
    Sandbox
  }

  alias Oli.OpenStax.CourseImport.{Enrichment, PubSub, SimulationArtifact}
  alias Oli.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"artifact_id" => artifact_id, "run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Repo.get(SimulationArtifact, artifact_id) do
      %SimulationArtifact{run_id: ^run_id, status: "generating"} = artifact ->
        run_generation(artifact, attempt, max_attempts)

      %SimulationArtifact{run_id: ^run_id} ->
        :ok

      %SimulationArtifact{} ->
        {:discard, :artifact_run_mismatch}

      nil ->
        {:discard, :artifact_not_found}
    end
  rescue
    _exception -> terminal_or_retry(artifact_id, attempt, max_attempts, :generation_worker_failed)
  end

  def perform(_job), do: {:discard, :invalid_artifact_job}

  defp run_generation(artifact, attempt, max_attempts) do
    with :ok <- ensure_reviewable(artifact.run_id),
         :ok <- discard_prior_intent(artifact),
         {:ok, proposal} <- Enrichment.fetch_proposal(artifact.proposal_id),
         {:ok, generated} <- Generator.generate(proposal),
         {:ok, validated} <- validate_bundle(generated),
         intent_payload <- generation_payload(validated, generated),
         {:ok, storage_intent} <- ArtifactStorage.prepare(artifact, validated),
         {:ok, intent_artifact} <-
           Enrichment.record_artifact_staging_intent(
             artifact.id,
             Map.merge(intent_payload, storage_intent)
           ),
         :ok <- ensure_reviewable(artifact.run_id),
         {:ok, staged_storage} <- ArtifactStorage.stage(intent_artifact, validated) do
      staged_artifact = apply_storage_identity(intent_artifact, staged_storage)

      case ensure_reviewable(artifact.run_id) do
        :ok ->
          persist_staged_result(staged_artifact, intent_payload, staged_storage)

        {:error, :run_not_reviewable} ->
          discard_after_cancel(staged_artifact)
      end
    else
      {:validation_error, reason} ->
        persist_validation_failure(artifact, reason)

      {:error, :run_not_reviewable} ->
        _ = Enrichment.cancel_run_workflows(artifact.run_id)
        broadcast_run(artifact.run_id)
        :ok

      {:error, reason} ->
        terminal_or_retry(artifact.id, attempt, max_attempts, reason)
    end
  end

  defp persist_staged_result(artifact, intent_payload, staged_storage) do
    result =
      intent_payload
      |> Map.merge(staged_storage)
      |> Map.put(:validation_status, "passed")
      |> Map.put(:staged_at, DateTime.utc_now())

    case Enrichment.record_artifact_generation_result(artifact.id, {:ok, result}) do
      {:ok, saved} ->
        broadcast_run(saved.run_id)
        :ok

      {:error, reason} ->
        _ = ArtifactStorage.discard(artifact)

        case ensure_reviewable(artifact.run_id) do
          :ok -> {:error, {:artifact_result_persistence_failed, reason}}
          {:error, :run_not_reviewable} -> :ok
        end
    end
  end

  defp persist_validation_failure(artifact, reason) do
    result =
      {:ok,
       %{
         validation_status: "failed",
         validation_version: 1,
         validation_payload: %{"status" => "failed"},
         failure: reason
       }}

    case Enrichment.record_artifact_generation_result(artifact.id, result) do
      {:ok, saved} ->
        broadcast_run(saved.run_id)
        :ok

      {:error, persistence_reason} ->
        {:error, {:artifact_result_persistence_failed, persistence_reason}}
    end
  end

  defp discard_after_cancel(artifact) do
    case ArtifactStorage.discard(artifact) do
      :ok ->
        _ = Enrichment.cancel_run_workflows(artifact.run_id)
        broadcast_run(artifact.run_id)
        :ok

      {:error, reason} ->
        {:error, {:artifact_cancel_cleanup_failed, reason}}
    end
  end

  defp discard_prior_intent(%SimulationArtifact{} = artifact) do
    if prior_intent?(artifact) do
      ArtifactStorage.discard(artifact)
    else
      :ok
    end
  end

  defp prior_intent?(artifact) do
    artifact.storage_state == "unstaged" and is_binary(artifact.storage_provider) and
      is_binary(artifact.storage_key) and is_binary(artifact.content_hash) and
      is_map(artifact.bundle_manifest) and map_size(artifact.bundle_manifest) > 0
  end

  defp validate_bundle(bundle) do
    case Sandbox.build_and_validate(bundle) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:validation_error, reason}
    end
  end

  defp generation_payload(validated, generated) do
    metadata = generated[:metadata] || generated["metadata"] || %{}

    validated
    |> Map.put(:validation_status, "passed")
    |> Map.put_new(:validation_version, 1)
    |> maybe_put(:generator_name, metadata[:generator_name] || metadata["generator_name"])
    |> maybe_put(
      :generator_version,
      metadata[:generator_version] || metadata["generator_version"]
    )
    |> Map.put(:generation_metadata, metadata)
  end

  defp apply_storage_identity(artifact, identity) do
    Enum.reduce(identity, artifact, fn
      {key, value}, current
      when key in [
             :storage_provider,
             :storage_key,
             :storage_origin,
             :storage_state,
             :byte_size
           ] ->
        Map.put(current, key, value)

      _entry, current ->
        current
    end)
  end

  defp terminal_or_retry(artifact_id, attempt, max_attempts, reason) do
    if attempt < max_attempts do
      {:error, reason}
    else
      case Enrichment.record_artifact_generation_result(artifact_id, {:error, reason}) do
        {:ok, artifact} ->
          broadcast_run(artifact.run_id)
          :ok

        {:error, recording_reason} ->
          case ensure_reviewable(artifact_id_run_id(artifact_id)) do
            :ok -> {:error, {:artifact_failure_persistence_failed, recording_reason}}
            {:error, :run_not_reviewable} -> :ok
          end
      end
    end
  end

  defp artifact_id_run_id(artifact_id) do
    case Repo.get(SimulationArtifact, artifact_id) do
      %SimulationArtifact{run_id: run_id} -> run_id
      nil -> nil
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

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
