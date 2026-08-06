defmodule Oli.OpenStax.CourseImport.Enrichment do
  @moduledoc """
  Persistence and lifecycle boundary for OpenStax lesson enrichments.

  This context enforces two independent author approvals: first the
  instructional proposal, then an exact validated simulation artifact version.
  Generation and research failures are non-blocking and persisted only as
  sanitized classifications.
  """

  import Ecto.Query

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.Authoring.Editing.Utils, as: EditingUtils

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    Lesson,
    Run,
    SimulationArtifact
  }

  alias Oli.OpenStax.CourseImport.Enrichment.{ArtifactStorage, Failure, Origin, Research}
  alias Oli.Repo

  @max_proposals_per_lesson 3
  @active_artifact_statuses ~w(generating ready_for_review validation_failed)
  @discardable_artifact_statuses ~w(validation_failed rejected cancelled failed)

  @proposal_attr_names ~w(
    kind rank delivery_mode instructional_rationale objective_ids source_evidence
    placement learner_task resource_title resource_url metadata
  )a

  @artifact_start_attr_names ~w(generator_name generator_version generation_metadata)a

  @artifact_result_attr_names ~w(
    generator_name generator_version generation_metadata bundle_manifest capi_manifest
    accessibility_metadata validation_status validation_version validation_payload
    content_hash byte_size storage_state storage_provider storage_key storage_origin
    failure staged_at
  )a

  @doc "Returns the hard upper bound applied by both the context and database."
  def max_proposals_per_lesson, do: @max_proposals_per_lesson

  @doc """
  Reconciles the planner's ranked proposals for one lesson.

  Existing proposal ids remain stable by rank. Once research, an author
  decision, or artifact generation has begun, planner synchronization is
  locked so author-governed evidence cannot be overwritten.
  """
  @spec sync_proposals(Ecto.UUID.t(), Ecto.UUID.t(), [map()]) ::
          {:ok, [EnrichmentProposal.t()]} | {:error, term()}
  def sync_proposals(run_id, lesson_id, proposals)
      when is_binary(run_id) and is_binary(lesson_id) and is_list(proposals) do
    with :ok <- validate_proposal_count(proposals),
         {:ok, normalized} <- normalize_ranked_proposals(proposals) do
      Repo.transaction(fn ->
        {_run, _lesson} = load_scope!(run_id, lesson_id)

        existing =
          EnrichmentProposal
          |> where([proposal], proposal.lesson_id == ^lesson_id)
          |> order_by([proposal], asc: proposal.rank)
          |> lock("FOR UPDATE")
          |> Repo.all()

        ensure_sync_unlocked!(existing)

        existing_by_rank = Map.new(existing, &{&1.rank, &1})
        retained_ranks = MapSet.new(normalized, & &1.rank)

        existing
        |> Enum.reject(&MapSet.member?(retained_ranks, &1.rank))
        |> Enum.each(&Repo.delete!/1)

        normalized
        |> Enum.map(fn attrs ->
          case Map.get(existing_by_rank, attrs.rank) do
            nil -> insert_proposal!(run_id, lesson_id, attrs)
            proposal -> revise_synced_proposal!(proposal, attrs)
          end
        end)
      end)
    end
  end

  def sync_proposals(_, _, _), do: {:error, :invalid_input}

  @spec create_proposal(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def create_proposal(run_id, lesson_id, attrs)
      when is_binary(run_id) and is_binary(lesson_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs, @proposal_attr_names)

    Repo.transaction(fn ->
      {_run, _lesson} = load_scope!(run_id, lesson_id)
      rank = attrs[:rank]

      unless is_integer(rank) and rank in 1..@max_proposals_per_lesson do
        Repo.rollback(:invalid_rank)
      end

      existing_ids =
        EnrichmentProposal
        |> where([proposal], proposal.lesson_id == ^lesson_id)
        |> select([proposal], proposal.id)
        |> lock("FOR UPDATE")
        |> Repo.all()

      if length(existing_ids) >= @max_proposals_per_lesson do
        Repo.rollback(:too_many_proposals)
      end

      insert_proposal!(run_id, lesson_id, attrs)
    end)
  end

  def create_proposal(_, _, _), do: {:error, :invalid_input}

  @spec list_proposals(Ecto.UUID.t(), Ecto.UUID.t()) :: [EnrichmentProposal.t()]
  def list_proposals(run_id, lesson_id) when is_binary(run_id) and is_binary(lesson_id) do
    EnrichmentProposal
    |> where(
      [proposal],
      proposal.run_id == ^run_id and proposal.lesson_id == ^lesson_id
    )
    |> order_by([proposal], asc: proposal.rank)
    |> preload(:simulation_artifacts)
    |> Repo.all()
  end

  def list_proposals(_, _), do: []

  @spec list_proposals(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, [EnrichmentProposal.t()]} | {:error, term()}
  def list_proposals(run_id, lesson_id, %Author{} = author) do
    with {:ok, run} <- fetch_run(run_id),
         :ok <- authorize_project_id(run.project_id, author),
         true <- lesson_in_run?(lesson_id, run.id) do
      {:ok, list_proposals(run.id, lesson_id)}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def list_proposals(_, _, _), do: {:error, :invalid_input}

  @spec list_run_proposals(Ecto.UUID.t()) :: [EnrichmentProposal.t()]
  def list_run_proposals(run_id) when is_binary(run_id) do
    EnrichmentProposal
    |> where([proposal], proposal.run_id == ^run_id)
    |> order_by([proposal], asc: proposal.lesson_id, asc: proposal.rank)
    |> preload(:simulation_artifacts)
    |> Repo.all()
  end

  def list_run_proposals(_), do: []

  @spec fetch_proposal(Ecto.UUID.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, :not_found}
  def fetch_proposal(proposal_id) when is_binary(proposal_id) do
    case Repo.get(EnrichmentProposal, proposal_id) do
      nil -> {:error, :not_found}
      proposal -> {:ok, Repo.preload(proposal, :simulation_artifacts)}
    end
  end

  def fetch_proposal(_), do: {:error, :not_found}

  @spec approve_proposal(Ecto.UUID.t(), Author.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def approve_proposal(proposal_id, %Author{} = author) do
    decide_proposal(proposal_id, author, :approve, nil)
  end

  def approve_proposal(_, _), do: {:error, :invalid_input}

  @spec reject_proposal(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def reject_proposal(proposal_id, %Author{} = author, reason) when is_binary(reason) do
    decide_proposal(proposal_id, author, :reject, reason)
  end

  def reject_proposal(_, _, _), do: {:error, :invalid_input}

  @spec cancel_proposal(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def cancel_proposal(proposal_id, author, reason \\ "Cancelled by author")

  def cancel_proposal(proposal_id, %Author{} = author, reason) when is_binary(reason) do
    decide_proposal(proposal_id, author, :cancel, reason)
  end

  def cancel_proposal(_, _, _), do: {:error, :invalid_input}

  @spec omit_proposal(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def omit_proposal(proposal_id, author, reason \\ "Omitted by author")

  def omit_proposal(proposal_id, %Author{} = author, reason) when is_binary(reason) do
    decide_proposal(proposal_id, author, :omit, reason)
  end

  def omit_proposal(_, _, _), do: {:error, :invalid_input}

  @spec mark_research_running(Ecto.UUID.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def mark_research_running(proposal_id) when is_binary(proposal_id) do
    Repo.transaction(fn ->
      scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      proposal = lock_proposal!(proposal_id)

      unless proposal.state == "proposed" do
        Repo.rollback({:invalid_proposal_state, proposal.state})
      end

      if proposal.research_status == "running" do
        proposal
      else
        persist_update!(
          EnrichmentProposal.research_changeset(proposal, %{
            research_status: "running",
            research_version: proposal.research_version + 1,
            research_failure: nil
          })
        )
      end
    end)
  end

  def mark_research_running(_), do: {:error, :invalid_input}

  @spec record_research_result(Ecto.UUID.t(), {:ok, map()} | {:error, term()}) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def record_research_result(proposal_id, result) when is_binary(proposal_id) do
    Repo.transaction(fn ->
      scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      proposal = lock_proposal!(proposal_id)

      unless proposal.state == "proposed" do
        Repo.rollback({:invalid_proposal_state, proposal.state})
      end

      unless proposal.research_status == "running" do
        Repo.rollback({:invalid_research_status, proposal.research_status})
      end

      attrs = research_result_attrs(result, proposal.research_version)

      persist_update!(EnrichmentProposal.research_changeset(proposal, attrs))
    end)
  end

  def record_research_result(_, _), do: {:error, :invalid_input}

  @doc "Runs configured research and durably records its non-blocking result."
  @spec research_proposal(Ecto.UUID.t(), keyword()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def research_proposal(proposal_id, opts \\ [])

  def research_proposal(proposal_id, opts) when is_binary(proposal_id) do
    with {:ok, proposal} <- fetch_proposal(proposal_id),
         {:ok, running} <- mark_research_running(proposal.id) do
      result = Research.research(running, opts)

      case record_research_result(proposal.id, result) do
        {:ok, researched} ->
          {:ok, researched}

        {:error, reason} = error ->
          _ = fail_running_research(proposal.id, reason)
          error
      end
    end
  end

  def research_proposal(_, _), do: {:error, :invalid_input}

  @doc false
  def fail_running_research(proposal_id, reason) when is_binary(proposal_id) do
    Repo.transaction(fn ->
      scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      proposal = lock_proposal!(proposal_id)

      if proposal.research_status == "running" do
        persist_update!(
          EnrichmentProposal.research_changeset(proposal, %{
            research_status: "failed",
            research_failure: Failure.sanitize(reason, "research")
          })
        )
      else
        proposal
      end
    end)
  end

  def fail_running_research(_, _), do: {:error, :invalid_input}

  @spec begin_artifact_generation(Ecto.UUID.t(), map()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def begin_artifact_generation(proposal_id, attrs \\ %{})

  def begin_artifact_generation(proposal_id, attrs)
      when is_binary(proposal_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs, @artifact_start_attr_names)

    Repo.transaction(fn ->
      scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      proposal = lock_proposal!(proposal_id)
      ensure_generatable_proposal!(proposal)

      active? =
        Repo.exists?(
          from(artifact in SimulationArtifact,
            where:
              artifact.proposal_id == ^proposal.id and
                artifact.status in ["generating", "ready_for_review"]
          )
        )

      if active?, do: Repo.rollback(:simulation_generation_in_progress)

      versions =
        SimulationArtifact
        |> where([artifact], artifact.proposal_id == ^proposal.id)
        |> lock("FOR UPDATE")
        |> select([artifact], artifact.version)
        |> Repo.all()

      next_version = Enum.max(versions, fn -> 0 end) + 1

      persist_insert!(
        SimulationArtifact.create_changeset(
          %SimulationArtifact{},
          attrs
          |> Map.merge(%{
            proposal_id: proposal.id,
            project_id: proposal.project_id,
            run_id: proposal.run_id,
            lesson_id: proposal.lesson_id,
            version: next_version,
            status: "generating"
          })
        )
      )
    end)
  end

  def begin_artifact_generation(_, _), do: {:error, :invalid_input}

  @doc "Persists a recoverable validated storage intent before bundle upload."
  @spec record_artifact_staging_intent(Ecto.UUID.t(), map()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def record_artifact_staging_intent(artifact_id, result)
      when is_binary(artifact_id) and is_map(result) do
    attrs =
      result
      |> normalize_attrs(@artifact_result_attr_names)
      |> Map.put(:status, "generating")
      |> Map.put(:validation_status, "passed")
      |> Map.put_new(:validation_version, 1)
      |> Map.put(:storage_state, "unstaged")
      |> Map.put(:failure, nil)
      |> Map.put_new(:generated_at, DateTime.utc_now())

    Repo.transaction(fn ->
      scope = Repo.get(SimulationArtifact, artifact_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      artifact = lock_artifact!(artifact_id)

      unless artifact.status == "generating" do
        Repo.rollback({:invalid_artifact_status, artifact.status})
      end

      persist_update!(SimulationArtifact.preview_changeset(artifact, attrs))
    end)
  end

  def record_artifact_staging_intent(_, _), do: {:error, :invalid_input}

  @spec record_artifact_generation_result(
          Ecto.UUID.t(),
          {:ok, map()} | {:error, term()}
        ) :: {:ok, SimulationArtifact.t()} | {:error, term()}
  def record_artifact_generation_result(artifact_id, result) when is_binary(artifact_id) do
    Repo.transaction(fn ->
      scope = Repo.get(SimulationArtifact, artifact_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      artifact = lock_artifact!(artifact_id)

      unless artifact.status == "generating" do
        Repo.rollback({:invalid_artifact_status, artifact.status})
      end

      persist_update!(
        SimulationArtifact.preview_changeset(artifact, artifact_result_attrs(result))
      )
    end)
  end

  def record_artifact_generation_result(_, _), do: {:error, :invalid_input}

  @spec list_artifacts(Ecto.UUID.t()) :: [SimulationArtifact.t()]
  def list_artifacts(proposal_id) when is_binary(proposal_id) do
    SimulationArtifact
    |> where([artifact], artifact.proposal_id == ^proposal_id)
    |> order_by([artifact], desc: artifact.version)
    |> Repo.all()
  end

  def list_artifacts(_), do: []

  @spec approve_artifact(Ecto.UUID.t(), Author.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def approve_artifact(artifact_id, %Author{} = author) when is_binary(artifact_id) do
    Repo.transaction(fn ->
      scope = Repo.get(SimulationArtifact, artifact_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      artifact = lock_artifact!(artifact_id)
      proposal = lock_proposal!(artifact.proposal_id)
      authorize_project_id!(proposal.project_id, author)

      unless proposal.state == "approved" do
        Repo.rollback(:proposal_not_approved)
      end

      unless SimulationArtifact.ready_for_approval?(artifact) do
        Repo.rollback(:artifact_invalid)
      end

      now = DateTime.utc_now()

      SimulationArtifact
      |> where(
        [other],
        other.proposal_id == ^proposal.id and other.status == "approved" and
          other.id != ^artifact.id
      )
      |> Repo.update_all(set: [status: "superseded", updated_at: now])

      persist_update!(
        SimulationArtifact.decision_changeset(artifact, %{
          status: "approved",
          approved_by_author_id: author.id,
          approved_at: now,
          decided_by_author_id: author.id,
          decided_at: now,
          decision_reason: nil,
          approval_history:
            append_history(artifact.approval_history, "approved", author, artifact.version, nil)
        })
      )
    end)
  end

  def approve_artifact(_, _), do: {:error, :invalid_input}

  @spec reject_artifact(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def reject_artifact(artifact_id, %Author{} = author, reason)
      when is_binary(artifact_id) and is_binary(reason) do
    decide_artifact(artifact_id, author, :reject, reason)
  end

  def reject_artifact(_, _, _), do: {:error, :invalid_input}

  @spec cancel_artifact(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def cancel_artifact(artifact_id, author, reason \\ "Cancelled by author")

  def cancel_artifact(artifact_id, %Author{} = author, reason)
      when is_binary(artifact_id) and is_binary(reason) do
    decide_artifact(artifact_id, author, :cancel, reason)
  end

  def cancel_artifact(_, _, _), do: {:error, :invalid_input}

  @doc """
  Resolves the one exact artifact version approved for a proposal.

  No learner-facing URL is returned here. Call `artifact_url/2` to resolve the
  trusted storage identity through the configured storage provider.
  """
  @spec resolve_approved_artifact(Ecto.UUID.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def resolve_approved_artifact(proposal_id) when is_binary(proposal_id) do
    with {:ok, proposal} <- fetch_proposal(proposal_id),
         :ok <- ensure_approved_proposal(proposal),
         %SimulationArtifact{} = artifact <-
           Repo.one(
             from(artifact in SimulationArtifact,
               where: artifact.proposal_id == ^proposal.id and artifact.status == "approved",
               order_by: [desc: artifact.version],
               limit: 1
             )
           ),
         true <- artifact_scope_matches?(artifact, proposal),
         true <- SimulationArtifact.resolvable?(artifact) do
      {:ok, artifact}
    else
      nil -> {:error, :artifact_not_approved}
      false -> {:error, :artifact_invalid}
      {:error, _} = error -> error
    end
  end

  def resolve_approved_artifact(_), do: {:error, :not_found}

  @spec artifact_url(SimulationArtifact.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def artifact_url(artifact, opts \\ [])

  def artifact_url(%SimulationArtifact{} = artifact, opts) do
    expected_origin =
      Keyword.get(opts, :trusted_origin) ||
        Application.get_env(:oli, :openstax_generated_simulation_origin)

    opts =
      Keyword.put_new(
        opts,
        :allow_local_http,
        Application.get_env(:oli, :env) in [:dev, :test]
      )

    with true <- artifact_resolvable?(artifact, opts),
         :ok <- require_trusted_origin(expected_origin),
         :ok <- validate_resolved_url(artifact.storage_origin, expected_origin, opts),
         {:ok, url} <- ArtifactStorage.resolve(artifact, opts),
         :ok <- validate_resolved_url(url, expected_origin, opts) do
      {:ok, url}
    else
      false -> {:error, :artifact_not_approved}
      {:error, _} = error -> error
    end
  end

  def artifact_url(_, _), do: {:error, :invalid_input}

  defp require_trusted_origin(origin) when is_binary(origin), do: :ok
  defp require_trusted_origin(_origin), do: {:error, :untrusted_storage}

  defp artifact_resolvable?(artifact, opts) do
    SimulationArtifact.resolvable?(artifact) or
      (Keyword.get(opts, :allow_preview, false) and artifact.status == "ready_for_review" and
         artifact.validation_status == "passed" and
         artifact.storage_state in ["staged", "promoted"] and
         is_binary(artifact.content_hash) and is_binary(artifact.storage_key) and
         is_binary(artifact.storage_origin))
  end

  @doc "Lists approved generated proposals that do not have an approved artifact."
  @spec list_approved_but_incomplete(Ecto.UUID.t()) :: [EnrichmentProposal.t()]
  def list_approved_but_incomplete(run_id) when is_binary(run_id) do
    from(proposal in EnrichmentProposal,
      as: :proposal,
      where:
        proposal.run_id == ^run_id and proposal.kind == "generated_simulation" and
          proposal.state == "approved",
      where:
        not exists(
          from(artifact in SimulationArtifact,
            where:
              artifact.proposal_id == parent_as(:proposal).id and
                artifact.status == "approved",
            select: 1
          )
        )
    )
    |> order_by([proposal], asc: proposal.lesson_id, asc: proposal.rank)
    |> Repo.all()
  end

  def list_approved_but_incomplete(_), do: []

  @spec approved_but_incomplete?(Ecto.UUID.t()) :: boolean()
  def approved_but_incomplete?(run_id) when is_binary(run_id) do
    list_approved_but_incomplete(run_id) != []
  end

  def approved_but_incomplete?(_), do: false

  @spec ensure_generation_complete(Ecto.UUID.t()) :: :ok | {:error, term()}
  def ensure_generation_complete(run_id) when is_binary(run_id) do
    case list_approved_but_incomplete(run_id) do
      [] -> :ok
      proposals -> {:error, {:approved_enrichment_incomplete, Enum.map(proposals, & &1.id)}}
    end
  end

  def ensure_generation_complete(_), do: {:error, :invalid_input}

  @doc "Fences research and generation when an import leaves author review."
  @spec cancel_run_workflows(Ecto.UUID.t(), String.t()) ::
          {:ok, %{research: non_neg_integer(), artifacts: non_neg_integer()}}
          | {:error, term()}
  def cancel_run_workflows(run_id, reason \\ "Import is no longer in author review")

  def cancel_run_workflows(run_id, reason) when is_binary(run_id) and is_binary(reason) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()
      research_failure = Failure.sanitize(:run_not_reviewable, "research")
      generation_failure = Failure.sanitize(:run_not_reviewable, "generation")

      {research_count, _} =
        from(proposal in EnrichmentProposal,
          where: proposal.run_id == ^run_id and proposal.research_status == "running"
        )
        |> Repo.update_all(
          set: [
            research_status: "failed",
            research_failure: research_failure,
            updated_at: now
          ]
        )

      {artifact_count, _} =
        from(artifact in SimulationArtifact,
          where: artifact.run_id == ^run_id and artifact.status in ^@active_artifact_statuses
        )
        |> Repo.update_all(
          set: [
            status: "cancelled",
            decision_reason: normalize_reason(reason),
            decided_at: now,
            failure: generation_failure,
            updated_at: now
          ]
        )

      %{research: research_count, artifacts: artifact_count}
    end)
  end

  def cancel_run_workflows(_, _), do: {:error, :invalid_input}

  @doc "Marks stale provider workflows terminal so author review cannot wedge indefinitely."
  @spec reconcile_stale_workflows(DateTime.t()) ::
          {:ok, %{research: non_neg_integer(), artifacts: non_neg_integer()}}
          | {:error, term()}
  def reconcile_stale_workflows(%DateTime{} = cutoff) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      {research_count, _} =
        from(proposal in EnrichmentProposal,
          where: proposal.research_status == "running" and proposal.updated_at < ^cutoff
        )
        |> Repo.update_all(
          set: [
            research_status: "failed",
            research_failure: Failure.sanitize(:stale_workflow, "research"),
            updated_at: now
          ]
        )

      {artifact_count, _} =
        from(artifact in SimulationArtifact,
          where: artifact.status == "generating" and artifact.updated_at < ^cutoff
        )
        |> Repo.update_all(
          set: [
            status: "failed",
            validation_status: "failed",
            failure: Failure.sanitize(:stale_workflow, "generation"),
            generated_at: now,
            updated_at: now
          ]
        )

      %{research: research_count, artifacts: artifact_count}
    end)
  end

  def reconcile_stale_workflows(_), do: {:error, :invalid_input}

  @doc "Returns never-approved staged artifacts that are safe orphan candidates."
  @spec list_orphaned_artifacts(Ecto.UUID.t(), DateTime.t()) :: [SimulationArtifact.t()]
  def list_orphaned_artifacts(run_id, %DateTime{} = inserted_before) when is_binary(run_id) do
    SimulationArtifact
    |> where(
      [artifact],
      artifact.run_id == ^run_id and artifact.status in ^@discardable_artifact_statuses and
        artifact.storage_state in ["unstaged", "staged", "promoted"] and
        not is_nil(artifact.storage_provider) and not is_nil(artifact.storage_key) and
        not is_nil(artifact.content_hash) and
        is_nil(artifact.approved_at) and artifact.inserted_at < ^inserted_before
    )
    |> order_by([artifact], asc: artifact.inserted_at)
    |> Repo.all()
  end

  def list_orphaned_artifacts(_, _), do: []

  @doc """
  Discards run-scoped orphan bundles through the configured storage provider.

  Database records remain as an audit trail and are marked `discarded` only
  after provider confirmation.
  """
  @spec cleanup_orphaned_artifacts(Ecto.UUID.t(), DateTime.t(), keyword()) ::
          {:ok, %{discarded: non_neg_integer(), failed: [map()]}} | {:error, term()}
  def cleanup_orphaned_artifacts(run_id, inserted_before, opts \\ [])

  def cleanup_orphaned_artifacts(run_id, %DateTime{} = inserted_before, opts)
      when is_binary(run_id) do
    case fetch_run(run_id) do
      {:ok, _run} ->
        run_id
        |> list_orphaned_artifacts(inserted_before)
        |> Enum.reduce(%{discarded: 0, failed: []}, fn artifact, result ->
          case ArtifactStorage.discard(artifact, opts) do
            :ok ->
              now = DateTime.utc_now()

              from(current in SimulationArtifact,
                where:
                  current.id == ^artifact.id and
                    current.storage_state in ["unstaged", "staged", "promoted"]
              )
              |> Repo.update_all(set: [storage_state: "discarded", updated_at: now])

              %{result | discarded: result.discarded + 1}

            {:error, reason} ->
              failure = Failure.sanitize(reason, "artifact_cleanup")
              %{result | failed: [%{artifact_id: artifact.id, failure: failure} | result.failed]}
          end
        end)
        |> then(fn result -> {:ok, %{result | failed: Enum.reverse(result.failed)}} end)

      {:error, _} = error ->
        error
    end
  end

  def cleanup_orphaned_artifacts(_, _, _), do: {:error, :invalid_input}

  @doc "Discards orphaned bundles across all runs after the retention window."
  @spec cleanup_all_orphaned_artifacts(DateTime.t(), keyword()) ::
          {:ok, %{discarded: non_neg_integer(), failed: list()}} | {:error, term()}
  def cleanup_all_orphaned_artifacts(inserted_before, opts \\ [])

  def cleanup_all_orphaned_artifacts(%DateTime{} = inserted_before, opts) do
    run_ids =
      from(artifact in SimulationArtifact,
        where:
          artifact.status in ^@discardable_artifact_statuses and
            artifact.storage_state in ["unstaged", "staged", "promoted"] and
            not is_nil(artifact.storage_provider) and not is_nil(artifact.storage_key) and
            not is_nil(artifact.content_hash) and
            artifact.inserted_at < ^inserted_before,
        distinct: true,
        select: artifact.run_id
      )
      |> Repo.all()

    Enum.reduce_while(run_ids, {:ok, %{discarded: 0, failed: []}}, fn run_id, {:ok, total} ->
      case cleanup_orphaned_artifacts(run_id, inserted_before, opts) do
        {:ok, result} ->
          {:cont,
           {:ok,
            %{
              discarded: total.discarded + result.discarded,
              failed: total.failed ++ result.failed
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def cleanup_all_orphaned_artifacts(_, _), do: {:error, :invalid_input}

  defp insert_proposal!(run_id, lesson_id, attrs) do
    run = Repo.get!(Run, run_id)
    attrs = proposal_defaults(attrs)

    persist_insert!(
      EnrichmentProposal.create_changeset(
        %EnrichmentProposal{},
        attrs
        |> Map.merge(%{
          project_id: run.project_id,
          run_id: run.id,
          lesson_id: lesson_id,
          version: 1,
          state: "proposed"
        })
      )
    )
  end

  defp revise_synced_proposal!(proposal, attrs) do
    attrs = proposal_defaults(attrs)

    persist_update!(
      EnrichmentProposal.revision_changeset(
        proposal,
        attrs
        |> Map.merge(%{
          version: proposal.version + 1,
          state: "proposed",
          research_status: "not_started",
          research_version: 0,
          research_evidence: %{},
          research_failure: nil
        })
      )
    )
  end

  defp proposal_defaults(attrs) do
    delivery_mode =
      case attrs[:kind] do
        "generated_simulation" -> "generated_simulation"
        _ -> attrs[:delivery_mode] || "annotated_link"
      end

    Map.put(attrs, :delivery_mode, delivery_mode)
  end

  defp load_scope!(run_id, lesson_id) do
    run =
      Run
      |> where([run], run.id == ^run_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    lesson =
      Lesson
      |> where([lesson], lesson.id == ^lesson_id and lesson.run_id == ^run_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case {run, lesson} do
      {%Run{} = run, %Lesson{} = lesson} -> {run, lesson}
      _ -> Repo.rollback(:not_found)
    end
  end

  defp ensure_sync_unlocked!(existing) do
    proposal_ids = Enum.map(existing, & &1.id)

    artifact_exists =
      proposal_ids != [] and
        Repo.exists?(
          from(artifact in SimulationArtifact, where: artifact.proposal_id in ^proposal_ids)
        )

    locked =
      artifact_exists or
        Enum.any?(existing, fn proposal ->
          proposal.state != "proposed" or proposal.research_status != "not_started"
        end)

    if locked, do: Repo.rollback(:proposal_sync_locked), else: :ok
  end

  defp decide_proposal(proposal_id, author, action, reason) do
    reason = normalize_reason(reason)

    with :ok <- validate_decision_reason(action, reason) do
      Repo.transaction(fn ->
        scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
        _run = lock_reviewable_run!(scope.run_id)
        proposal = lock_proposal!(proposal_id)
        authorize_project_id!(proposal.project_id, author)
        ensure_proposal_transition!(proposal, action)

        now = DateTime.utc_now()
        state = proposal_state_for(action)

        attrs = %{
          state: state,
          decided_by_author_id: author.id,
          decided_at: now,
          decision_reason: reason,
          approval_history:
            append_history(proposal.approval_history, action, author, proposal.version, reason)
        }

        attrs =
          case action do
            :approve ->
              Map.merge(attrs, %{
                approved_by_author_id: author.id,
                approved_version: proposal.version,
                approved_at: now
              })

            _ ->
              Map.merge(attrs, %{
                approved_by_author_id: nil,
                approved_version: nil,
                approved_at: nil
              })
          end

        updated = persist_update!(EnrichmentProposal.decision_changeset(proposal, attrs))

        if action != :approve do
          cancel_incomplete_artifacts(proposal.id, author, reason, now)
        end

        updated
      end)
    end
  end

  defp ensure_proposal_transition!(proposal, :approve) do
    unless proposal.state == "proposed" do
      Repo.rollback({:invalid_proposal_state, proposal.state})
    end

    ensure_proposal_approval_ready!(proposal)
  end

  defp ensure_proposal_transition!(proposal, action) when action in [:reject, :cancel, :omit] do
    unless proposal.state in ["proposed", "approved"] do
      Repo.rollback({:invalid_proposal_state, proposal.state})
    end

    if approved_artifact_exists?(proposal.id) do
      Repo.rollback(:approved_artifact_exists)
    end

    :ok
  end

  defp ensure_proposal_approval_ready!(%{kind: "generated_simulation"}), do: :ok

  defp ensure_proposal_approval_ready!(proposal) do
    evidence = proposal.research_evidence

    if proposal.research_status == "completed" and is_map(evidence) and map_size(evidence) > 0 and
         absolute_https_url?(proposal.resource_url) do
      :ok
    else
      Repo.rollback(:curated_enrichment_not_ready)
    end
  end

  defp absolute_https_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port}
      when is_binary(host) and host != "" and (is_nil(port) or port == 443) ->
        true

      _ ->
        false
    end
  end

  defp absolute_https_url?(_), do: false

  defp approved_artifact_exists?(proposal_id) do
    Repo.exists?(
      from(artifact in SimulationArtifact,
        where: artifact.proposal_id == ^proposal_id and artifact.status == "approved"
      )
    )
  end

  defp cancel_incomplete_artifacts(proposal_id, author, reason, now) do
    from(artifact in SimulationArtifact,
      where:
        artifact.proposal_id == ^proposal_id and artifact.status in ^@active_artifact_statuses
    )
    |> Repo.update_all(
      set: [
        status: "cancelled",
        decided_by_author_id: author.id,
        decided_at: now,
        decision_reason: reason,
        updated_at: now
      ]
    )
  end

  defp decide_artifact(artifact_id, author, action, reason) do
    reason = normalize_reason(reason)

    with :ok <- validate_decision_reason(action, reason) do
      Repo.transaction(fn ->
        scope = Repo.get(SimulationArtifact, artifact_id) || Repo.rollback(:not_found)
        _run = lock_reviewable_run!(scope.run_id)
        artifact = lock_artifact!(artifact_id)
        authorize_project_id!(artifact.project_id, author)
        ensure_artifact_transition!(artifact, action)

        now = DateTime.utc_now()
        status = if action == :reject, do: "rejected", else: "cancelled"

        persist_update!(
          SimulationArtifact.decision_changeset(artifact, %{
            status: status,
            decided_by_author_id: author.id,
            decided_at: now,
            decision_reason: reason,
            approval_history:
              append_history(artifact.approval_history, action, author, artifact.version, reason)
          })
        )
      end)
    end
  end

  defp ensure_artifact_transition!(artifact, :reject) do
    if artifact.status in ["ready_for_review", "validation_failed", "approved"],
      do: :ok,
      else: Repo.rollback({:invalid_artifact_status, artifact.status})
  end

  defp ensure_artifact_transition!(artifact, :cancel) do
    if artifact.status in ["generating", "ready_for_review", "validation_failed", "failed"],
      do: :ok,
      else: Repo.rollback({:invalid_artifact_status, artifact.status})
  end

  defp ensure_generatable_proposal!(proposal) do
    cond do
      proposal.state != "approved" -> Repo.rollback(:proposal_not_approved)
      proposal.kind != "generated_simulation" -> Repo.rollback(:not_generated_simulation)
      true -> :ok
    end
  end

  defp research_result_attrs({:ok, result}, version) when is_map(result) do
    normalized =
      normalize_attrs(result, [:evidence, :resource_title, :resource_url, :delivery_mode])

    %{
      research_status: "completed",
      research_version: version,
      research_evidence: normalized[:evidence] || %{},
      research_failure: nil,
      resource_title: normalized[:resource_title],
      resource_url: normalized[:resource_url],
      delivery_mode: normalized[:delivery_mode]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp research_result_attrs({:error, reason}, version) do
    %{
      research_status: "failed",
      research_version: version,
      research_failure: Failure.sanitize(reason, "research")
    }
  end

  defp research_result_attrs(_result, version) do
    research_result_attrs({:error, :invalid_research_result}, version)
  end

  defp artifact_result_attrs({:ok, result}) when is_map(result) do
    attrs = normalize_attrs(result, @artifact_result_attr_names)
    validation_status = attrs[:validation_status] || "failed"

    status =
      case validation_status do
        "passed" -> "ready_for_review"
        _ -> "validation_failed"
      end

    attrs
    |> Map.put(:status, status)
    |> Map.put(:validation_status, validation_status)
    |> Map.put_new(:validation_version, 1)
    |> Map.put_new(:generated_at, DateTime.utc_now())
    |> maybe_put_validation_failure(status)
  end

  defp artifact_result_attrs({:error, reason}) do
    %{
      status: "failed",
      validation_status: "failed",
      failure: Failure.sanitize(reason, "generation"),
      generated_at: DateTime.utc_now()
    }
  end

  defp artifact_result_attrs(_result) do
    artifact_result_attrs({:error, :invalid_generation_result})
  end

  defp maybe_put_validation_failure(attrs, "validation_failed") do
    Map.put(
      attrs,
      :failure,
      Failure.sanitize(attrs[:failure] || :validation_failed, "validation")
    )
  end

  defp maybe_put_validation_failure(attrs, _status), do: Map.put(attrs, :failure, nil)

  defp lock_proposal!(proposal_id) do
    case Repo.one(
           from(proposal in EnrichmentProposal,
             where: proposal.id == ^proposal_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:not_found)
      proposal -> proposal
    end
  end

  defp lock_artifact!(artifact_id) do
    case Repo.one(
           from(artifact in SimulationArtifact,
             where: artifact.id == ^artifact_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:not_found)
      artifact -> artifact
    end
  end

  defp lock_reviewable_run!(run_id) do
    case Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) do
      %Run{status: :awaiting_lesson_approval} = run -> run
      %Run{status: status} -> Repo.rollback({:run_not_reviewable, status})
      nil -> Repo.rollback(:not_found)
    end
  end

  defp fetch_run(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp lesson_in_run?(lesson_id, run_id) do
    Repo.exists?(
      from(lesson in Lesson, where: lesson.id == ^lesson_id and lesson.run_id == ^run_id)
    )
  end

  defp authorize_project_id(project_id, author) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> authorize_project(project, author)
    end
  end

  defp authorize_project_id!(project_id, author) do
    case authorize_project_id(project_id, author) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_project(project, author) do
    case EditingUtils.authorize_user(author, project) do
      {:ok} -> :ok
      _ -> {:error, :not_authorized}
    end
  rescue
    _ -> {:error, :not_authorized}
  end

  defp normalize_ranked_proposals(proposals) do
    normalized =
      proposals
      |> Enum.with_index(1)
      |> Enum.map(fn
        {attrs, default_rank} when is_map(attrs) ->
          attrs = normalize_attrs(attrs, @proposal_attr_names)
          Map.put_new(attrs, :rank, default_rank)

        _ ->
          :invalid
      end)

    ranks = Enum.map(normalized, &if(is_map(&1), do: &1[:rank], else: nil))

    expected_ranks =
      case length(proposals) do
        0 -> []
        count -> Enum.to_list(1..count)
      end

    if Enum.all?(normalized, &is_map/1) and Enum.sort(ranks) == expected_ranks do
      {:ok, Enum.sort_by(normalized, & &1.rank)}
    else
      {:error, :invalid_proposal_ranks}
    end
  end

  defp validate_proposal_count(proposals) do
    if length(proposals) <= @max_proposals_per_lesson,
      do: :ok,
      else: {:error, :too_many_proposals}
  end

  defp normalize_attrs(attrs, allowed_names) do
    Enum.reduce(allowed_names, %{}, fn name, normalized ->
      string_name = Atom.to_string(name)

      cond do
        Map.has_key?(attrs, name) -> Map.put(normalized, name, Map.get(attrs, name))
        Map.has_key?(attrs, string_name) -> Map.put(normalized, name, Map.get(attrs, string_name))
        true -> normalized
      end
    end)
  end

  defp validate_decision_reason(:approve, _reason), do: :ok

  defp validate_decision_reason(_action, reason) do
    if is_binary(reason) and reason != "",
      do: :ok,
      else: {:error, :decision_reason_required}
  end

  defp normalize_reason(nil), do: nil

  defp normalize_reason(reason) when is_binary(reason),
    do: reason |> String.trim() |> String.slice(0, 2_000)

  defp normalize_reason(_), do: nil

  defp proposal_state_for(:approve), do: "approved"
  defp proposal_state_for(:reject), do: "rejected"
  defp proposal_state_for(:cancel), do: "cancelled"
  defp proposal_state_for(:omit), do: "omitted"

  defp append_history(history, action, author, version, reason) do
    entry = %{
      "action" => to_string(action),
      "author_id" => author.id,
      "version" => version,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    entry =
      if is_binary(reason) and reason != "", do: Map.put(entry, "reason", reason), else: entry

    (history || []) ++ [entry]
  end

  defp ensure_approved_proposal(%EnrichmentProposal{state: "approved"}), do: :ok
  defp ensure_approved_proposal(_), do: {:error, :proposal_not_approved}

  defp artifact_scope_matches?(artifact, proposal) do
    artifact.project_id == proposal.project_id and artifact.run_id == proposal.run_id and
      artifact.lesson_id == proposal.lesson_id
  end

  defp validate_resolved_url(url, expected_origin, opts)
       when is_binary(url) and is_binary(expected_origin) do
    resolved = URI.parse(url)
    expected = URI.parse(expected_origin)
    allow_local_http = Keyword.get(opts, :allow_local_http, false)

    secure_scheme =
      resolved.scheme == "https" or
        (allow_local_http and resolved.scheme == "http" and local_host?(resolved.host))

    same_origin =
      resolved.scheme == expected.scheme and resolved.host == expected.host and
        effective_port(resolved) == effective_port(expected)

    if secure_scheme and present_uri?(resolved) and present_uri?(expected) and same_origin,
      do: :ok,
      else: {:error, :untrusted_storage}
  end

  defp validate_resolved_url(_, _, _), do: {:error, :untrusted_storage}

  defp present_uri?(%URI{scheme: scheme, host: host}) do
    is_binary(scheme) and scheme != "" and is_binary(host) and host != ""
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_), do: nil

  defp local_host?(host), do: Origin.local_loopback_host?(host)

  defp persist_insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp persist_update!(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
