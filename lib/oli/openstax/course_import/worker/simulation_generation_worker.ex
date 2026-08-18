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
    ArtifactCritic,
    ArtifactStorage,
    Generator,
    LibraryRegistry,
    Sandbox
  }

  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{
    Enrichment,
    PubSub,
    SimulationArtifact,
    SimulationSpec
  }

  alias Oli.Repo

  @max_builder_candidates 4

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
    started_at = System.monotonic_time(:millisecond)

    with :ok <- ensure_reviewable(artifact.run_id),
         :ok <- discard_prior_intent(artifact),
         {:ok, proposal} <- Enrichment.fetch_proposal(artifact.proposal_id),
         {:ok, spec} <- Enrichment.fetch_spec(artifact.simulation_spec_id),
         true <- spec.status == "approved" and spec.proposal_id == proposal.id,
         {:ok, research} <- Enrichment.fetch_research_set(spec.research_set_id),
         true <- research.status == "approved" and research.content_hash == spec.evidence_hash,
         {:ok, built} <-
           build_validated_artifact(artifact, proposal, spec, research, artifact.project_id),
         intent_payload <-
           generation_payload(
             built,
             elapsed_milliseconds(started_at),
             artifact.generation_metadata
           ),
         {:ok, storage_intent} <- ArtifactStorage.prepare(artifact, built.validated),
         {:ok, intent_artifact} <-
           Enrichment.record_artifact_staging_intent(
             artifact.id,
             Map.merge(intent_payload, storage_intent)
           ),
         :ok <- ensure_reviewable(artifact.run_id),
         {:ok, staged_storage} <- ArtifactStorage.stage(intent_artifact, built.validated) do
      staged_artifact = apply_storage_identity(intent_artifact, staged_storage)

      case ensure_reviewable(artifact.run_id) do
        :ok ->
          persist_staged_result(staged_artifact, intent_payload, staged_storage)

        {:error, :run_not_reviewable} ->
          discard_after_cancel(staged_artifact)
      end
    else
      {:validation_error, failure} ->
        persist_validation_failure(artifact, failure)

      false ->
        terminal_or_retry(artifact.id, attempt, max_attempts, :stale_generation_contract)

      {:error, :run_not_reviewable} ->
        _ = Enrichment.cancel_run_workflows(artifact.run_id)
        broadcast_run(artifact.run_id)
        :ok

      {:error, reason} ->
        terminal_or_retry(artifact.id, attempt, max_attempts, reason)
    end
  end

  defp build_validated_artifact(artifact, proposal, spec, research, project_id) do
    build_validated_artifact(artifact, proposal, spec, research, project_id, 1, nil, [])
  end

  defp build_validated_artifact(
         artifact,
         proposal,
         spec,
         research,
         project_id,
         attempt,
         repair,
         history
       ) do
    generator_opts =
      [simulation_spec: spec, research_set: research]
      |> maybe_put_option(:author_feedback, artifact_author_feedback(artifact))
      |> maybe_put_option(:repair, repair)

    with :ok <- ensure_reviewable(artifact.run_id),
         {:ok, generated} <- Generator.generate(proposal, generator_opts) do
      case assemble_libraries(generated, project_id) do
        {:ok, assembled} ->
          validate_and_review_candidate(
            artifact,
            proposal,
            spec,
            research,
            project_id,
            attempt,
            generated,
            assembled,
            history
          )

        {:error, reason} ->
          repair_builder_or_stop(
            artifact,
            proposal,
            spec,
            research,
            project_id,
            attempt,
            generated,
            findings(reason, "library_assembly"),
            failed_validation_summary(reason, "library_assembly"),
            %{},
            history
          )
      end
    end
  end

  defp validate_and_review_candidate(
         artifact,
         proposal,
         spec,
         research,
         project_id,
         attempt,
         generated,
         assembled,
         history
       ) do
    case validate_bundle(assembled, spec) do
      {:ok, validated} ->
        review_validated_candidate(
          artifact,
          proposal,
          spec,
          research,
          project_id,
          attempt,
          generated,
          validated,
          history
        )

      {:validation_error, reason} ->
        repair_builder_or_stop(
          artifact,
          proposal,
          spec,
          research,
          project_id,
          attempt,
          generated,
          findings(reason, "sandbox_validation"),
          failed_validation_summary(reason, "sandbox_validation"),
          %{},
          history
        )
    end
  end

  defp review_validated_candidate(
         artifact,
         proposal,
         spec,
         research,
         project_id,
         attempt,
         generated,
         validated,
         history
       ) do
    validation = compact_validation(validated)

    case ArtifactCritic.review(spec, research, generated, validated) do
      {:ok, criticism} ->
        with {:ok, persisted_attempt} <-
               persist_builder_attempt(
                 artifact,
                 generated,
                 "accepted",
                 [],
                 validation,
                 criticism,
                 validated
               ) do
          accepted = %{
            "attempt" => persisted_attempt.attempt_number,
            "status" => "accepted",
            "validation" => validation,
            "criticism" => criticism
          }

          {:ok,
           %{
             generated: generated,
             validated: validated,
             criticism: criticism,
             repair_count: attempt - 1,
             history: history ++ [accepted]
           }}
        end

      {:error, {:artifact_critic_rejected, criticism}} ->
        repair_builder_or_stop(
          artifact,
          proposal,
          spec,
          research,
          project_id,
          attempt,
          generated,
          critic_findings(criticism),
          validation,
          criticism,
          history,
          "critic_rejected"
        )

      {:error, reason} ->
        criticism = %{"failure" => finding(reason, "artifact_critic")}

        with {:ok, _persisted_attempt} <-
               persist_builder_attempt(
                 artifact,
                 generated,
                 "critic_failed",
                 findings(reason, "artifact_critic"),
                 validation,
                 criticism,
                 validated
               ) do
          {:error, reason}
        end
    end
  end

  defp repair_builder_or_stop(
         artifact,
         proposal,
         spec,
         research,
         project_id,
         attempt,
         candidate,
         findings,
         validation,
         criticism,
         history,
         status \\ "validation_failed"
       ) do
    with {:ok, persisted_attempt} <-
           persist_builder_attempt(
             artifact,
             candidate,
             status,
             findings,
             validation,
             criticism
           ) do
      entry = %{
        "attempt" => persisted_attempt.attempt_number,
        "status" => "repair",
        "outcome" => status,
        "findings" => findings,
        "validation" => validation
      }

      history = history ++ [entry]

      if attempt < @max_builder_candidates do
        build_validated_artifact(
          artifact,
          proposal,
          spec,
          research,
          project_id,
          attempt + 1,
          %{candidate: candidate, findings: findings},
          history
        )
      else
        {:validation_error,
         %{
           code: :simulation_builder_repairs_exhausted,
           stage: :validation,
           retryable: false,
           validation_payload: %{
             "status" => "failed",
             "repair_count" => attempt - 1,
             "history" => history,
             "findings" => findings
           }
         }}
      end
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
    validation_payload =
      case reason do
        %{validation_payload: payload} when is_map(payload) -> payload
        _ -> %{"status" => "failed", "findings" => [finding(reason, "validation")]}
      end

    result =
      {:ok,
       %{
         validation_status: "failed",
         validation_version: 1,
         validation_payload: validation_payload,
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

  defp assemble_libraries(bundle, project_id) do
    three_d_enabled =
      case Repo.get(Project, project_id) do
        %Project{} = project -> CourseImport.enrichment_capabilities(project).three_d_enabled
        nil -> false
      end

    LibraryRegistry.assemble(bundle, three_d_enabled: three_d_enabled)
  end

  defp validate_bundle(bundle, %SimulationSpec{} = spec) do
    validation_opts = [
      simulation_spec: spec.spec_payload,
      sample_cases: spec.spec_payload["sample_cases"] || [],
      rendering_mode: spec.spec_payload["rendering_mode"]
    ]

    case Sandbox.build_and_validate(bundle, validation_opts) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:validation_error, reason}
    end
  end

  defp generation_payload(built, duration_ms, artifact_metadata) do
    generated_metadata = built.generated[:metadata] || built.generated["metadata"] || %{}

    metadata = Map.merge(artifact_metadata || %{}, generated_metadata)

    metadata =
      Map.merge(metadata, %{
        "builder_repair_count" => built.repair_count,
        "builder_history" => built.history,
        "artifact_criticism" => built.criticism,
        "duration_ms" => duration_ms
      })

    built.validated
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

  defp artifact_author_feedback(artifact) do
    case Map.get(artifact.generation_metadata || %{}, "author_feedback") do
      feedback when is_binary(feedback) and feedback != "" -> feedback
      _ -> nil
    end
  end

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)

  defp elapsed_milliseconds(started_at),
    do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp compact_validation(validated) do
    payload = validated[:validation_payload] || validated["validation_payload"] || %{}

    %{
      "status" => payload["status"],
      "validator" => payload["validator"],
      "content_hash" => validated[:content_hash] || validated["content_hash"]
    }
  end

  defp failed_validation_summary(reason, default_validator) do
    payload =
      case reason do
        %{validation_payload: payload} when is_map(payload) -> payload
        %{"validation_payload" => payload} when is_map(payload) -> payload
        _ -> %{}
      end

    %{
      "status" => payload["status"] || "failed",
      "validator" => payload["validator"] || default_validator
    }
  end

  defp persist_builder_attempt(
         artifact,
         generated,
         status,
         findings,
         validation,
         criticism,
         validated \\ %{}
       ) do
    metadata = generated[:metadata] || generated["metadata"] || %{}

    Enrichment.record_artifact_attempt(artifact.id, %{
      status: status,
      source_hash: candidate_source_hash(generated),
      content_hash: validated[:content_hash] || validated["content_hash"],
      generator_name: metadata[:generator_name] || metadata["generator_name"],
      generator_version: metadata[:generator_version] || metadata["generator_version"],
      findings: sanitize_findings(findings),
      validation_summary: bounded_payload(validation),
      criticism: bounded_payload(criticism),
      model_usage: model_usage(metadata, criticism),
      completed_at: DateTime.utc_now()
    })
  end

  defp candidate_source_hash(generated) do
    generated
    |> then(&(&1[:files] || &1["files"] || %{}))
    |> Enum.map(fn {path, contents} ->
      {to_string(path), if(is_binary(contents), do: contents, else: inspect(contents))}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp model_usage(metadata, criticism) do
    %{
      "generator" => %{
        "provider" => metadata[:provider] || metadata["provider"],
        "model" => metadata[:model] || metadata["model"],
        "provider_usage" => metadata[:provider_usage] || metadata["provider_usage"] || %{},
        "prompt_version" => metadata[:prompt_version] || metadata["prompt_version"]
      },
      "critic" => %{
        "provider" => criticism[:provider] || criticism["provider"],
        "model" => criticism[:model] || criticism["model"],
        "provider_usage" => criticism[:provider_usage] || criticism["provider_usage"] || %{},
        "prompt_version" => criticism[:prompt_version] || criticism["prompt_version"]
      }
    }
    |> bounded_payload()
  end

  defp critic_findings(criticism) do
    case criticism[:findings] || criticism["findings"] do
      findings when is_list(findings) and findings != [] ->
        Enum.map(findings, fn finding ->
          finding
          |> stringify_keys()
          |> Map.put_new("code", "artifact_critic_rejected")
          |> Map.put_new("category", "artifact_critic")
        end)

      _ ->
        [
          %{
            "code" => "artifact_critic_rejected",
            "category" => "artifact_critic",
            "message" => bounded_string(criticism[:summary] || criticism["summary"] || "")
          }
        ]
    end
  end

  defp findings(%{findings: findings}, _stage) when is_list(findings),
    do: sanitize_findings(findings)

  defp findings(%{"findings" => findings}, _stage) when is_list(findings),
    do: sanitize_findings(findings)

  defp findings(%{validation_payload: %{"findings" => findings}}, _stage)
       when is_list(findings),
       do: sanitize_findings(findings)

  defp findings(reason, stage), do: [finding(reason, stage)]

  defp sanitize_findings(findings) do
    findings
    |> List.wrap()
    |> Enum.take(30)
    |> Enum.map(fn
      %{} = finding ->
        finding
        |> stringify_keys()
        |> Map.take([
          "category",
          "code",
          "severity",
          "message",
          "details",
          "repair",
          "path"
        ])
        |> Map.put_new("code", "validation_failed")
        |> bounded_payload()

      value when is_atom(value) ->
        %{"code" => Atom.to_string(value)}

      _ ->
        %{"code" => "validation_failed"}
    end)
  end

  defp bounded_payload(value) when is_map(value) do
    value
    |> Enum.take(30)
    |> Map.new(fn {key, item} -> {to_string(key), bounded_payload(item)} end)
  end

  defp bounded_payload(value) when is_list(value),
    do: value |> Enum.take(30) |> Enum.map(&bounded_payload/1)

  defp bounded_payload(value) when is_binary(value), do: bounded_string(value)

  defp bounded_payload(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bounded_payload(value), do: bounded_string(inspect(value))

  defp bounded_string(value), do: value |> to_string() |> String.slice(0, 1_000)

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp finding(%{} = reason, stage) do
    reason
    |> stringify_keys()
    |> Map.take(["category", "code", "severity", "message", "details", "repair", "path"])
    |> Map.put_new("code", to_string(reason[:code] || reason["code"] || :validation_failed))
    |> Map.put_new("category", stage)
    |> bounded_payload()
  end

  defp finding({code, _details}, stage) when is_atom(code),
    do: %{"code" => Atom.to_string(code), "category" => stage}

  defp finding(code, stage) when is_atom(code),
    do: %{"code" => Atom.to_string(code), "category" => stage}

  defp finding(_reason, stage), do: %{"code" => "validation_failed", "category" => stage}
end
