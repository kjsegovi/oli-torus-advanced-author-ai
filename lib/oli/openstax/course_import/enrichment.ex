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
    AIBackend,
    EnrichmentProposal,
    EnrichmentResearchSet,
    Lesson,
    Run,
    SimulationArtifact,
    SimulationArtifactAttempt,
    SimulationSpec,
    Telemetry
  }

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.Enrichment.{
    ArtifactStorage,
    Failure,
    Origin,
    Research,
    SimulationSpecDesigner
  }

  alias Oli.Repo

  @max_proposals_per_lesson 3
  @active_artifact_statuses ~w(generating ready_for_review validation_failed)
  @discardable_artifact_statuses ~w(validation_failed rejected cancelled failed)

  @proposal_attr_names ~w(
    kind rank delivery_mode instructional_rationale objective_ids source_evidence
    placement learner_task resource_title resource_url metadata
  )a

  @artifact_start_attr_names ~w(
    generator_name generator_version generation_metadata simulation_spec_id simulation_spec_hash
  )a

  @artifact_result_attr_names ~w(
    generator_name generator_version generation_metadata bundle_manifest capi_manifest
    accessibility_metadata validation_status validation_version validation_payload
    content_hash byte_size storage_state storage_provider storage_bucket storage_identity_version
    storage_payload storage_key storage_origin
    failure staged_at
  )a

  @artifact_attempt_attr_names ~w(
    status source_hash content_hash generator_name generator_version findings
    validation_summary criticism model_usage completed_at
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
    |> preload([:research_sets, :simulation_specs, simulation_artifacts: :attempts])
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
    |> preload([:research_sets, :simulation_specs, simulation_artifacts: :attempts])
    |> Repo.all()
  end

  def list_run_proposals(_), do: []

  @spec fetch_proposal(Ecto.UUID.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, :not_found}
  def fetch_proposal(proposal_id) when is_binary(proposal_id) do
    case Repo.get(EnrichmentProposal, proposal_id) do
      nil ->
        {:error, :not_found}

      proposal ->
        {:ok,
         Repo.preload(proposal, [
           :research_sets,
           :simulation_specs,
           simulation_artifacts: :attempts
         ])}
    end
  end

  def fetch_proposal(_), do: {:error, :not_found}

  @spec approve_proposal(Ecto.UUID.t(), Author.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def approve_proposal(proposal_id, %Author{} = author) do
    with {:ok, proposal} <- fetch_proposal(proposal_id),
         :ok <- ensure_run_reviewable(proposal.run_id) do
      case proposal.kind do
        "generated_simulation" ->
          case latest_research_set(proposal.id, "evidence_review") do
            %EnrichmentResearchSet{} = research ->
              with {:ok, _approved} <-
                     approve_evidence(proposal.id, research.id, research.content_hash, author) do
                fetch_proposal(proposal.id)
              end

            nil ->
              {:error, :research_not_ready_for_approval}
          end

        _ ->
          decide_proposal(proposal_id, author, :approve, nil)
      end
    end
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
    proposal_id
    |> decide_proposal(author, :cancel, reason)
    |> emit_author_decision(:cancel_proposal)
  end

  def cancel_proposal(_, _, _), do: {:error, :invalid_input}

  @spec omit_proposal(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def omit_proposal(proposal_id, author, reason \\ "Omitted by author")

  def omit_proposal(proposal_id, %Author{} = author, reason) when is_binary(reason) do
    proposal_id
    |> decide_proposal(author, :omit, reason)
    |> emit_author_decision(:omit_proposal)
  end

  def omit_proposal(_, _, _), do: {:error, :invalid_input}

  @spec mark_research_running(Ecto.UUID.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def mark_research_running(proposal_id) when is_binary(proposal_id) do
    Repo.transaction(fn ->
      scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
      _run = lock_reviewable_run!(scope.run_id)
      proposal = lock_proposal!(proposal_id)

      unless proposal.state in [
               "proposed",
               "researching",
               "evidence_review",
               "designing",
               "artifact_review",
               "failed"
             ] do
        Repo.rollback({:invalid_proposal_state, proposal.state})
      end

      if proposal.research_status == "running" do
        proposal
      else
        version = proposal.research_version + 1

        attrs =
          if proposal.kind == "generated_simulation" do
            supersede_downstream_for_new_research!(proposal.id)
            _research = insert_research_set!(proposal, version)

            %{
              state: "researching",
              research_status: "running",
              research_version: version,
              research_evidence: %{},
              research_failure: nil
            }
          else
            %{
              state: "proposed",
              research_status: "running",
              research_version: version,
              research_evidence: %{},
              research_failure: nil
            }
          end

        persist_update!(EnrichmentProposal.research_changeset(proposal, attrs))
      end
    end)
  end

  def mark_research_running(_), do: {:error, :invalid_input}

  @spec record_research_result(Ecto.UUID.t(), {:ok, map()} | {:error, term()}) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def record_research_result(proposal_id, result) when is_binary(proposal_id) do
    transaction_result =
      Repo.transaction(fn ->
        scope = Repo.get(EnrichmentProposal, proposal_id) || Repo.rollback(:not_found)
        _run = lock_reviewable_run!(scope.run_id)
        proposal = lock_proposal!(proposal_id)

        expected_state =
          if proposal.kind == "generated_simulation", do: "researching", else: "proposed"

        unless proposal.state == expected_state do
          Repo.rollback({:invalid_proposal_state, proposal.state})
        end

        unless proposal.research_status == "running" do
          Repo.rollback({:invalid_research_status, proposal.research_status})
        end

        if proposal.kind == "generated_simulation" do
          research = lock_research_set!(proposal.id, proposal.research_version)
          research_attrs = research_set_result_attrs(result, research)

          _research =
            persist_update!(EnrichmentResearchSet.result_changeset(research, research_attrs))
        end

        attrs = research_result_attrs(result, proposal)

        persist_update!(EnrichmentProposal.research_changeset(proposal, attrs))
      end)

    emit_research_telemetry(transaction_result)
    transaction_result
  end

  def record_research_result(_, _), do: {:error, :invalid_input}

  @doc "Runs configured research and durably records its non-blocking result."
  @spec research_proposal(Ecto.UUID.t(), keyword()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def research_proposal(proposal_id, opts \\ [])

  def research_proposal(proposal_id, opts) when is_binary(proposal_id) do
    with {:ok, proposal} <- fetch_proposal(proposal_id),
         {:ok, run} <- CourseImport.fetch_run(proposal.run_id),
         {:ok, research_opts} <- AIBackend.research_options(run.ai_backend),
         {:ok, running} <- mark_research_running(proposal.id) do
      started_at = System.monotonic_time(:millisecond)
      opts = Keyword.merge(opts, research_opts)

      result =
        running
        |> Research.research(opts)
        |> put_result_duration(elapsed_milliseconds(started_at))

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
        case current_research_set(proposal.id, proposal.research_version) do
          %EnrichmentResearchSet{} = research ->
            persist_update!(
              EnrichmentResearchSet.result_changeset(research, %{
                status: "failed",
                failure: Failure.sanitize(reason, "research")
              })
            )

          nil ->
            :ok
        end

        next_state = if proposal.kind == "generated_simulation", do: "failed", else: "proposed"

        persist_update!(
          EnrichmentProposal.research_changeset(proposal, %{
            state: next_state,
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

  @doc "Approves one exact evidence version and hash before simulation design."
  @spec approve_evidence(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Author.t()) ::
          {:ok, EnrichmentResearchSet.t()} | {:error, term()}
  def approve_evidence(proposal_id, research_set_id, content_hash, %Author{} = author)
      when is_binary(proposal_id) and is_binary(research_set_id) and is_binary(content_hash) do
    result =
      Repo.transaction(fn ->
        proposal = lock_proposal!(proposal_id)
        _run = lock_reviewable_run!(proposal.run_id)
        authorize_project_id!(proposal.project_id, author)

        research =
          Repo.one(
            from(record in EnrichmentResearchSet,
              where:
                record.id == ^research_set_id and record.proposal_id == ^proposal.id and
                  record.content_hash == ^content_hash,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:stale_research_version)

        unless proposal.kind == "generated_simulation" and proposal.state == "evidence_review" and
                 research.status == "evidence_review" and
                 proposal.research_version == research.version do
          Repo.rollback(:research_not_ready_for_approval)
        end

        now = DateTime.utc_now()

        from(other in EnrichmentResearchSet,
          where:
            other.proposal_id == ^proposal.id and other.status == "approved" and
              other.id != ^research.id
        )
        |> Repo.update_all(set: [status: "superseded", updated_at: now])

        approved =
          persist_update!(
            EnrichmentResearchSet.decision_changeset(research, %{
              status: "approved",
              approved_by_author_id: author.id,
              approved_at: now,
              decided_by_author_id: author.id,
              decided_at: now,
              decision_reason: nil,
              approval_history:
                append_history(
                  research.approval_history,
                  "approve_evidence",
                  author,
                  research.version,
                  nil
                )
            })
          )

        persist_update!(
          EnrichmentProposal.research_changeset(proposal, %{
            state: "designing",
            research_status: "completed",
            research_failure: nil
          })
        )

        approved
      end)

    emit_author_decision(result, :approve_evidence)
  end

  def approve_evidence(_, _, _, _), do: {:error, :invalid_input}

  @doc "Rejects one exact evidence version and returns the proposal to research."
  @spec reject_evidence(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentResearchSet.t()} | {:error, term()}
  def reject_evidence(proposal_id, research_set_id, content_hash, %Author{} = author, reason)
      when is_binary(proposal_id) and is_binary(research_set_id) and is_binary(content_hash) and
             is_binary(reason) do
    reason = normalize_reason(reason)

    if is_nil(reason) do
      {:error, :decision_reason_required}
    else
      result =
        Repo.transaction(fn ->
          proposal = lock_proposal!(proposal_id)
          _run = lock_reviewable_run!(proposal.run_id)
          authorize_project_id!(proposal.project_id, author)

          research =
            Repo.one(
              from(record in EnrichmentResearchSet,
                where:
                  record.id == ^research_set_id and record.proposal_id == ^proposal.id and
                    record.content_hash == ^content_hash and record.status == "evidence_review",
                lock: "FOR UPDATE"
              )
            ) || Repo.rollback(:stale_research_version)

          now = DateTime.utc_now()

          rejected =
            persist_update!(
              EnrichmentResearchSet.decision_changeset(research, %{
                status: "rejected",
                decided_by_author_id: author.id,
                decided_at: now,
                decision_reason: reason,
                approval_history:
                  append_history(
                    research.approval_history,
                    "reject_evidence",
                    author,
                    research.version,
                    reason
                  )
              })
            )

          persist_update!(
            EnrichmentProposal.research_changeset(proposal, %{
              state: "researching",
              research_status: "not_started",
              research_failure: nil
            })
          )

          rejected
        end)

      emit_author_decision(result, :reject_evidence)
    end
  end

  def reject_evidence(_, _, _, _, _), do: {:error, :invalid_input}

  @spec fetch_research_set(Ecto.UUID.t()) ::
          {:ok, EnrichmentResearchSet.t()} | {:error, :not_found}
  def fetch_research_set(id) when is_binary(id) do
    case Repo.get(EnrichmentResearchSet, id) do
      nil -> {:error, :not_found}
      research -> {:ok, research}
    end
  end

  def fetch_research_set(_), do: {:error, :not_found}

  @spec begin_spec_generation(Ecto.UUID.t()) ::
          {:ok, SimulationSpec.t()} | {:error, term()}
  def begin_spec_generation(proposal_id) when is_binary(proposal_id) do
    Repo.transaction(fn ->
      proposal = lock_proposal!(proposal_id)
      _run = lock_reviewable_run!(proposal.run_id)

      unless proposal.kind == "generated_simulation" and proposal.state == "designing" do
        Repo.rollback(:research_approval_required)
      end

      research =
        latest_research_set(proposal.id, "approved") ||
          Repo.rollback(:research_approval_required)

      if Repo.exists?(
           from(spec in SimulationSpec,
             where: spec.proposal_id == ^proposal.id and spec.status == "designing"
           )
         ) do
        Repo.rollback(:simulation_spec_generation_in_progress)
      end

      versions =
        from(spec in SimulationSpec,
          where: spec.proposal_id == ^proposal.id,
          select: spec.version,
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      persist_insert!(
        SimulationSpec.create_changeset(%SimulationSpec{}, %{
          proposal_id: proposal.id,
          research_set_id: research.id,
          project_id: proposal.project_id,
          run_id: proposal.run_id,
          lesson_id: proposal.lesson_id,
          version: Enum.max(versions, fn -> 0 end) + 1,
          status: "designing",
          evidence_hash: research.content_hash,
          prompt_version: "simulation-spec-v1"
        })
      )
    end)
  end

  def begin_spec_generation(_), do: {:error, :invalid_input}

  @spec fetch_spec(Ecto.UUID.t()) :: {:ok, SimulationSpec.t()} | {:error, :not_found}
  def fetch_spec(id) when is_binary(id) do
    case Repo.get(SimulationSpec, id) do
      nil -> {:error, :not_found}
      spec -> {:ok, spec}
    end
  end

  def fetch_spec(_), do: {:error, :not_found}

  @spec record_spec_result(Ecto.UUID.t(), {:ok, map()} | {:error, term()}) ::
          {:ok, SimulationSpec.t()} | {:error, term()}
  def record_spec_result(spec_id, result) when is_binary(spec_id) do
    transaction_result =
      Repo.transaction(fn ->
        scope = Repo.get(SimulationSpec, spec_id) || Repo.rollback(:not_found)
        _run = lock_reviewable_run!(scope.run_id)
        spec = lock_spec!(spec_id)

        unless spec.status == "designing" do
          Repo.rollback({:invalid_simulation_spec_status, spec.status})
        end

        attrs = simulation_spec_result_attrs(result)
        saved = persist_update!(SimulationSpec.create_changeset(spec, attrs))

        saved
      end)

    emit_spec_telemetry(transaction_result)
    transaction_result
  end

  def record_spec_result(_, _), do: {:error, :invalid_input}

  @doc "Convenience path for tests and operator tools; UI work should enqueue the spec worker."
  def generate_spec(proposal_id, opts \\ [])

  def generate_spec(proposal_id, opts) when is_binary(proposal_id) do
    with {:ok, spec} <- begin_spec_generation(proposal_id),
         {:ok, run} <- CourseImport.fetch_run(spec.run_id),
         {:ok, proposal} <- fetch_proposal(proposal_id),
         {:ok, research} <- fetch_research_set(spec.research_set_id),
         {:ok, opts} <- maybe_put_backend_services(opts, run.ai_backend) do
      record_spec_result(spec.id, SimulationSpecDesigner.generate(proposal, research, opts))
    end
  end

  def generate_spec(_, _), do: {:error, :invalid_input}

  defp maybe_put_backend_services(opts, :local_codex) do
    with {:ok, services} <- AIBackend.simulation_spec_services(:local_codex) do
      {:ok, Keyword.put(opts, :services, services)}
    end
  end

  defp maybe_put_backend_services(opts, _backend), do: {:ok, opts}

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

      spec =
        approve_spec_for_generation!(
          proposal,
          attrs[:simulation_spec_id],
          attrs[:simulation_spec_hash]
        )

      attrs = Map.drop(attrs, [:simulation_spec_id, :simulation_spec_hash])

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

      artifact =
        persist_insert!(
          SimulationArtifact.create_changeset(
            %SimulationArtifact{},
            attrs
            |> Map.merge(%{
              proposal_id: proposal.id,
              project_id: proposal.project_id,
              run_id: proposal.run_id,
              lesson_id: proposal.lesson_id,
              simulation_spec_id: spec.id,
              version: next_version,
              status: "generating"
            })
          )
        )

      persist_update!(
        EnrichmentProposal.research_changeset(proposal, %{
          state: "artifact_review"
        })
      )

      artifact
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
    transaction_result =
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

    emit_artifact_telemetry(transaction_result)
    transaction_result
  end

  def record_artifact_generation_result(_, _), do: {:error, :invalid_input}

  @doc "Appends one immutable generated-candidate validation or critic outcome."
  @spec record_artifact_attempt(Ecto.UUID.t(), map()) ::
          {:ok, SimulationArtifactAttempt.t()} | {:error, term()}
  def record_artifact_attempt(artifact_id, attrs)
      when is_binary(artifact_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs, @artifact_attempt_attr_names)

    Repo.transaction(fn ->
      artifact = lock_artifact!(artifact_id)

      next_attempt =
        SimulationArtifactAttempt
        |> where([attempt], attempt.artifact_id == ^artifact.id)
        |> select([attempt], max(attempt.attempt_number))
        |> Repo.one()
        |> then(&((&1 || 0) + 1))

      attrs =
        attrs
        |> stringify_attempt_payloads()
        |> Map.merge(%{
          artifact_id: artifact.id,
          attempt_number: next_attempt,
          completed_at: attrs[:completed_at] || DateTime.utc_now()
        })

      persist_insert!(
        SimulationArtifactAttempt.create_changeset(%SimulationArtifactAttempt{}, attrs)
      )
    end)
  end

  def record_artifact_attempt(_, _), do: {:error, :invalid_input}

  @spec list_artifact_attempts(Ecto.UUID.t()) :: [SimulationArtifactAttempt.t()]
  def list_artifact_attempts(artifact_id) when is_binary(artifact_id) do
    SimulationArtifactAttempt
    |> where([attempt], attempt.artifact_id == ^artifact_id)
    |> order_by([attempt], asc: attempt.attempt_number)
    |> Repo.all()
  end

  def list_artifact_attempts(_), do: []

  @spec list_artifacts(Ecto.UUID.t()) :: [SimulationArtifact.t()]
  def list_artifacts(proposal_id) when is_binary(proposal_id) do
    SimulationArtifact
    |> where([artifact], artifact.proposal_id == ^proposal_id)
    |> order_by([artifact], desc: artifact.version)
    |> preload(:attempts)
    |> Repo.all()
  end

  def list_artifacts(_), do: []

  @spec approve_artifact(Ecto.UUID.t(), Author.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def approve_artifact(artifact_id, %Author{} = author) when is_binary(artifact_id) do
    case Repo.get(SimulationArtifact, artifact_id) do
      %SimulationArtifact{} = artifact ->
        approve_artifact(artifact.id, artifact.version, artifact.content_hash, author)

      nil ->
        {:error, :not_found}
    end
  end

  def approve_artifact(_, _), do: {:error, :invalid_input}

  @doc "Approves one exact immutable artifact version and content hash."
  @spec approve_artifact(Ecto.UUID.t(), pos_integer(), String.t(), Author.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def approve_artifact(artifact_id, version, content_hash, %Author{} = author)
      when is_binary(artifact_id) and is_integer(version) and version > 0 and
             is_binary(content_hash) do
    result =
      Repo.transaction(fn ->
        scope = Repo.get(SimulationArtifact, artifact_id) || Repo.rollback(:not_found)
        _run = lock_reviewable_run!(scope.run_id)
        artifact = lock_artifact!(artifact_id)
        proposal = lock_proposal!(artifact.proposal_id)
        authorize_project_id!(proposal.project_id, author)

        unless artifact.version == version and artifact.content_hash == content_hash do
          Repo.rollback(:stale_artifact_version)
        end

        unless proposal.state == "artifact_review" do
          Repo.rollback(:proposal_not_in_artifact_review)
        end

        spec =
          Repo.get(SimulationSpec, artifact.simulation_spec_id) ||
            Repo.rollback(:stale_simulation_spec)

        unless spec.status == "approved" and spec.proposal_id == proposal.id do
          Repo.rollback(:stale_simulation_spec)
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

        approved_artifact =
          persist_update!(
            SimulationArtifact.decision_changeset(artifact, %{
              status: "approved",
              approved_by_author_id: author.id,
              approved_at: now,
              decided_by_author_id: author.id,
              decided_at: now,
              decision_reason: nil,
              approval_history:
                append_history(
                  artifact.approval_history,
                  "approved",
                  author,
                  artifact.version,
                  nil
                )
            })
          )

        persist_update!(
          EnrichmentProposal.decision_changeset(proposal, %{
            approved_by_author_id: author.id,
            approved_at: now,
            decided_by_author_id: author.id,
            decided_at: now,
            decision_reason: nil,
            approved_version: proposal.version,
            state: "approved",
            approval_history:
              append_history(
                proposal.approval_history,
                "approve_artifact",
                author,
                proposal.version,
                nil
              )
          })
        )

        approved_artifact
      end)

    emit_author_decision(result, :approve_artifact)
  end

  def approve_artifact(_, _, _, _), do: {:error, :invalid_input}

  @spec reject_artifact(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def reject_artifact(artifact_id, %Author{} = author, reason)
      when is_binary(artifact_id) and is_binary(reason) do
    artifact_id
    |> decide_artifact(author, :reject, reason)
    |> emit_author_decision(:reject_artifact)
  end

  def reject_artifact(_, _, _), do: {:error, :invalid_input}

  @spec cancel_artifact(Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def cancel_artifact(artifact_id, author, reason \\ "Cancelled by author")

  def cancel_artifact(artifact_id, %Author{} = author, reason)
      when is_binary(artifact_id) and is_binary(reason) do
    artifact_id
    |> decide_artifact(author, :cancel, reason)
    |> emit_author_decision(:cancel_artifact)
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
    expected_origins = trusted_artifact_origins(artifact, opts)

    opts =
      opts
      |> Keyword.put_new(
        :allow_local_http,
        Application.get_env(:oli, :env) in [:dev, :test]
      )
      |> Keyword.put(:trusted_origins, expected_origins)

    with true <- artifact_resolvable?(artifact, opts),
         :ok <- require_trusted_origins(expected_origins),
         :ok <- validate_resolved_url(artifact.storage_origin, expected_origins, opts),
         {:ok, url} <- ArtifactStorage.resolve(artifact, opts),
         :ok <- validate_resolved_url(url, expected_origins, opts) do
      {:ok, url}
    else
      false -> {:error, :artifact_not_approved}
      {:error, _} = error -> error
    end
  end

  def artifact_url(_, _), do: {:error, :invalid_input}

  defp require_trusted_origins(origins) when is_list(origins) and origins != [], do: :ok
  defp require_trusted_origins(_origins), do: {:error, :untrusted_storage}

  defp trusted_artifact_origins(artifact, opts) do
    configured =
      Keyword.get(opts, :trusted_origin) ||
        Application.get_env(:oli, :openstax_generated_simulation_origin)

    [configured]
    |> maybe_add_legacy_artifact_origin(artifact)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp maybe_add_legacy_artifact_origin(origins, %SimulationArtifact{
         storage_provider: "s3_media",
         storage_identity_version: 1,
         storage_origin: origin
       })
       when is_binary(origin),
       do: [origin | origins]

  defp maybe_add_legacy_artifact_origin(origins, _artifact), do: origins

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
          join: run in Run,
          on: run.id == proposal.run_id,
          where:
            proposal.research_status == "running" and proposal.updated_at < ^cutoff and
              run.source_schema_version == 4 and run.plan_schema_version == 7
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
          join: run in Run,
          on: run.id == artifact.run_id,
          where:
            artifact.status == "generating" and artifact.updated_at < ^cutoff and
              run.source_schema_version == 4 and run.plan_schema_version == 7
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
        join: run in Run,
        on: run.id == artifact.run_id,
        where:
          artifact.status in ^@discardable_artifact_statuses and
            artifact.storage_state in ["unstaged", "staged", "promoted"] and
            not is_nil(artifact.storage_provider) and not is_nil(artifact.storage_key) and
            not is_nil(artifact.content_hash) and run.source_schema_version == 4 and
            run.plan_schema_version == 7 and
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

  defp insert_research_set!(proposal, version) do
    metadata = proposal.metadata || %{}
    domain = metadata["domain"] || metadata[:domain]
    query = metadata["research_query"] || metadata[:research_query]

    persist_insert!(
      EnrichmentResearchSet.create_changeset(%EnrichmentResearchSet{}, %{
        proposal_id: proposal.id,
        project_id: proposal.project_id,
        run_id: proposal.run_id,
        lesson_id: proposal.lesson_id,
        version: version,
        status: "researching",
        domain: domain,
        query: query,
        source_evidence: proposal.source_evidence,
        prompt_version: "simulation-research-v1"
      })
    )
  end

  defp supersede_downstream_for_new_research!(proposal_id) do
    now = DateTime.utc_now()

    from(record in EnrichmentResearchSet,
      where:
        record.proposal_id == ^proposal_id and record.status in ["evidence_review", "approved"]
    )
    |> Repo.update_all(set: [status: "superseded", updated_at: now])

    from(spec in SimulationSpec,
      where: spec.proposal_id == ^proposal_id and spec.status not in ["failed", "superseded"]
    )
    |> Repo.update_all(set: [status: "superseded", updated_at: now])

    from(artifact in SimulationArtifact,
      where: artifact.proposal_id == ^proposal_id and artifact.status == "ready_for_review"
    )
    |> Repo.update_all(set: [status: "superseded", updated_at: now])

    from(artifact in SimulationArtifact,
      where:
        artifact.proposal_id == ^proposal_id and
          artifact.status in ["generating", "validation_failed"]
    )
    |> Repo.update_all(set: [status: "cancelled", updated_at: now])

    :ok
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
      {%Run{source_schema_version: 4, plan_schema_version: 7} = run, %Lesson{} = lesson} ->
        {run, lesson}

      {%Run{}, %Lesson{}} ->
        Repo.rollback(:unsupported_legacy_run)

      _ ->
        Repo.rollback(:not_found)
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
    unless proposal.state in [
             "proposed",
             "researching",
             "evidence_review",
             "designing",
             "artifact_review",
             "approved",
             "failed"
           ] do
      Repo.rollback({:invalid_proposal_state, proposal.state})
    end

    if approved_artifact_exists?(proposal.id) do
      Repo.rollback(:approved_artifact_exists)
    end

    :ok
  end

  defp ensure_proposal_approval_ready!(%{kind: "generated_simulation"}),
    do: Repo.rollback(:research_approval_required)

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
    if artifact.status in ["ready_for_review", "validation_failed"],
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
      proposal.state not in ["designing", "artifact_review"] ->
        Repo.rollback(:simulation_spec_not_approved)

      proposal.kind != "generated_simulation" ->
        Repo.rollback(:not_generated_simulation)

      true ->
        :ok
    end
  end

  defp approve_spec_for_generation!(proposal, expected_id, expected_hash) do
    spec =
      Repo.one(
        from(spec in SimulationSpec,
          where:
            spec.proposal_id == ^proposal.id and
              spec.status in ["ready_for_review", "approved"],
          order_by: [desc: spec.version],
          limit: 1,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:simulation_spec_not_ready)

    unless is_binary(expected_id) and is_binary(expected_hash) and spec.id == expected_id and
             spec.content_hash == expected_hash do
      Repo.rollback(:stale_simulation_spec)
    end

    research =
      latest_research_set(proposal.id, "approved") ||
        Repo.rollback(:research_approval_required)

    unless spec.research_set_id == research.id and spec.evidence_hash == research.content_hash do
      Repo.rollback(:stale_simulation_spec)
    end

    if spec.status == "approved" do
      spec
    else
      now = DateTime.utc_now()

      from(other in SimulationSpec,
        where:
          other.proposal_id == ^proposal.id and other.status == "approved" and
            other.id != ^spec.id
      )
      |> Repo.update_all(set: [status: "superseded", updated_at: now])

      persist_update!(
        SimulationSpec.create_changeset(spec, %{
          status: "approved",
          approved_at: now
        })
      )
    end
  end

  defp research_result_attrs({:ok, result}, proposal) when is_map(result) do
    normalized =
      normalize_attrs(result, [:evidence, :resource_title, :resource_url, :delivery_mode])

    state = if proposal.kind == "generated_simulation", do: "evidence_review", else: "proposed"

    %{
      state: state,
      research_status: "completed",
      research_version: proposal.research_version,
      research_evidence: normalized[:evidence] || %{},
      research_failure: nil,
      resource_title: normalized[:resource_title],
      resource_url: normalized[:resource_url],
      delivery_mode: normalized[:delivery_mode]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp research_result_attrs({:error, reason}, proposal) do
    %{
      state: if(proposal.kind == "generated_simulation", do: "failed", else: "proposed"),
      research_status: "failed",
      research_version: proposal.research_version,
      research_failure: Failure.sanitize(reason, "research")
    }
  end

  defp research_result_attrs(_result, proposal) do
    research_result_attrs({:error, :invalid_research_result}, proposal)
  end

  defp research_set_result_attrs({:ok, result}, _research) when is_map(result) do
    normalized = normalize_attrs(result, [:evidence])
    evidence = stringify_keys(normalized[:evidence] || %{})

    %{
      status: "evidence_review",
      retrieved_sources: List.wrap(evidence["retrieved_sources"]),
      proposed_sources: List.wrap(evidence["proposed_sources"]),
      claims: List.wrap(evidence["claims"]),
      search_count: evidence["search_count"] || 0,
      source_count: evidence["source_count"] || 0,
      provider: evidence["provider"],
      model: evidence["model"],
      source_hash: evidence["source_hash"],
      content_hash: evidence["content_hash"],
      accessed_at: parse_datetime(evidence["accessed_at"]),
      validation_payload: %{
        "status" => "passed",
        "complete_source_list" => true,
        "claim_count" => length(List.wrap(evidence["claims"])),
        "provider_usage" => evidence["provider_usage"] || %{},
        "duration_ms" => evidence["duration_ms"] || 0
      },
      failure: nil
    }
  end

  defp research_set_result_attrs({:error, reason}, _research) do
    %{
      status: "failed",
      failure: Failure.sanitize(reason, "research")
    }
  end

  defp research_set_result_attrs(_result, research),
    do: research_set_result_attrs({:error, :invalid_research_result}, research)

  defp simulation_spec_result_attrs({:ok, result}) when is_map(result) do
    validation = result[:validation] || result["validation"] || %{}
    history = result[:history] || result["history"] || []
    duration_ms = result[:duration_ms] || result["duration_ms"] || 0

    %{
      status: "ready_for_review",
      spec_payload: result[:spec] || result["spec"] || %{},
      content_hash: result[:content_hash] || result["content_hash"],
      provider: result[:provider] || result["provider"],
      model: result[:model] || result["model"],
      prompt_version: result[:prompt_version] || result["prompt_version"] || "simulation-spec-v1",
      repair_count: result[:repair_count] || result["repair_count"] || 0,
      criticism: result[:criticism] || result["criticism"] || %{},
      validation_payload:
        validation
        |> Map.put("generation_history", history)
        |> Map.put("duration_ms", duration_ms),
      failure: nil
    }
  end

  defp simulation_spec_result_attrs({:error, reason}) do
    %{
      status: "failed",
      failure: Failure.sanitize(reason, "simulation_spec")
    }
  end

  defp simulation_spec_result_attrs(_),
    do: simulation_spec_result_attrs({:error, :invalid_simulation_spec_result})

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()

  defp put_result_duration({:ok, result}, duration_ms) when is_map(result) do
    evidence = result[:evidence] || result["evidence"]

    if is_map(evidence) do
      key = if Map.has_key?(result, :evidence), do: :evidence, else: "evidence"

      evidence_key =
        if Enum.any?(Map.keys(evidence), &is_atom/1), do: :duration_ms, else: "duration_ms"

      {:ok, Map.put(result, key, Map.put(evidence, evidence_key, duration_ms))}
    else
      {:ok, Map.put(result, :duration_ms, duration_ms)}
    end
  end

  defp put_result_duration(result, _duration_ms), do: result

  defp elapsed_milliseconds(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
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

  defp current_research_set(proposal_id, version) do
    Repo.one(
      from(record in EnrichmentResearchSet,
        where: record.proposal_id == ^proposal_id and record.version == ^version
      )
    )
  end

  defp latest_research_set(proposal_id, status) do
    Repo.one(
      from(record in EnrichmentResearchSet,
        where: record.proposal_id == ^proposal_id and record.status == ^status,
        order_by: [desc: record.version],
        limit: 1
      )
    )
  end

  defp lock_research_set!(proposal_id, version) do
    Repo.one(
      from(record in EnrichmentResearchSet,
        where: record.proposal_id == ^proposal_id and record.version == ^version,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:research_set_not_found)
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

  defp lock_spec!(spec_id) do
    Repo.one(from(spec in SimulationSpec, where: spec.id == ^spec_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp lock_reviewable_run!(run_id) do
    case Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) do
      %Run{
        status: :awaiting_lesson_approval,
        source_schema_version: 4,
        plan_schema_version: 7
      } = run ->
        run

      %Run{source_schema_version: source, plan_schema_version: plan}
      when source != 4 or plan != 7 ->
        Repo.rollback(:unsupported_legacy_run)

      %Run{status: status} ->
        Repo.rollback({:run_not_reviewable, status})

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp ensure_run_reviewable(run_id) do
    case Repo.get(Run, run_id) do
      %Run{
        status: :awaiting_lesson_approval,
        source_schema_version: 4,
        plan_schema_version: 7
      } ->
        :ok

      %Run{source_schema_version: source, plan_schema_version: plan}
      when source != 4 or plan != 7 ->
        {:error, :unsupported_legacy_run}

      %Run{status: status} ->
        {:error, {:run_not_reviewable, status}}

      nil ->
        {:error, :not_found}
    end
  end

  defp fetch_run(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      %Run{source_schema_version: 4, plan_schema_version: 7} = run -> {:ok, run}
      %Run{} -> {:error, :unsupported_legacy_run}
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

  defp emit_research_telemetry(
         {:ok, %EnrichmentProposal{kind: "generated_simulation"} = proposal}
       ) do
    case current_research_set(proposal.id, proposal.research_version) do
      %EnrichmentResearchSet{} = research ->
        usage = map_value(research.validation_payload, "provider_usage") || %{}

        Telemetry.simulation_stage(
          :research,
          telemetry_outcome(research.status),
          telemetry_scope(research),
          %{
            duration_ms: map_value(research.validation_payload, "duration_ms"),
            input_tokens: sum_metric(usage, "input_tokens"),
            output_tokens: sum_metric(usage, "output_tokens"),
            web_search_calls: research.search_count,
            source_count: research.source_count,
            provider: research.provider,
            model: research.model
          }
        )

      nil ->
        :ok
    end
  end

  defp emit_research_telemetry(_result), do: :ok

  defp emit_spec_telemetry({:ok, %SimulationSpec{} = spec}) do
    validation = spec.validation_payload || %{}

    Telemetry.simulation_stage(
      :specification,
      telemetry_outcome(spec.status),
      telemetry_scope(spec),
      %{
        duration_ms: map_value(validation, "duration_ms"),
        input_tokens: sum_metric(validation, "input_tokens"),
        output_tokens: sum_metric(validation, "output_tokens"),
        repair_count: spec.repair_count,
        validation_failures: count_findings(validation),
        provider: spec.provider,
        model: spec.model,
        rendering_mode: map_value(spec.spec_payload, "rendering_mode"),
        library_ids: map_value(spec.spec_payload, "library_ids")
      }
    )
  end

  defp emit_spec_telemetry(_result), do: :ok

  defp emit_artifact_telemetry({:ok, %SimulationArtifact{} = artifact}) do
    metadata = artifact.generation_metadata || %{}
    validation = artifact.validation_payload || %{}
    browser = map_value(validation, "browser") || %{}
    sample_results = List.wrap(map_value(browser, "sample_results"))

    Telemetry.simulation_stage(
      :artifact,
      telemetry_outcome(artifact.status),
      telemetry_scope(artifact),
      %{
        duration_ms: map_value(metadata, "duration_ms"),
        input_tokens: sum_metric(metadata, "input_tokens"),
        output_tokens: sum_metric(metadata, "output_tokens"),
        repair_count:
          map_value(metadata, "builder_repair_count") ||
            map_value(metadata, "source_repair_count") || 0,
        validation_failures: count_findings(validation),
        artifact_bytes: artifact.byte_size,
        capi_sample_count: length(sample_results),
        capi_sample_failures: Enum.count(sample_results, &(map_value(&1, "passed") != true)),
        provider: map_value(metadata, "provider"),
        model: map_value(metadata, "model"),
        rendering_mode: map_value(validation, "rendering_mode"),
        library_ids: map_value(artifact.bundle_manifest, "library_ids")
      }
    )
  end

  defp emit_artifact_telemetry(_result), do: :ok

  defp emit_author_decision({:ok, record} = result, decision) do
    Telemetry.simulation_author_decision(decision, telemetry_scope(record))
    result
  end

  defp emit_author_decision(result, _decision), do: result

  defp telemetry_scope(%EnrichmentResearchSet{} = research) do
    %{
      run_id: research.run_id,
      lesson_id: research.lesson_id,
      proposal_id: research.proposal_id,
      record_id: research.id,
      version: research.version
    }
  end

  defp telemetry_scope(%SimulationSpec{} = spec) do
    %{
      run_id: spec.run_id,
      lesson_id: spec.lesson_id,
      proposal_id: spec.proposal_id,
      record_id: spec.id,
      version: spec.version
    }
  end

  defp telemetry_scope(%SimulationArtifact{} = artifact) do
    %{
      run_id: artifact.run_id,
      lesson_id: artifact.lesson_id,
      proposal_id: artifact.proposal_id,
      record_id: artifact.id,
      version: artifact.version
    }
  end

  defp telemetry_scope(%EnrichmentProposal{} = proposal) do
    %{
      run_id: proposal.run_id,
      lesson_id: proposal.lesson_id,
      proposal_id: proposal.id,
      record_id: proposal.id,
      version: proposal.version
    }
  end

  defp telemetry_scope(_record), do: %{}

  defp telemetry_outcome("evidence_review"), do: :ready_for_review
  defp telemetry_outcome("ready_for_review"), do: :ready_for_review
  defp telemetry_outcome("approved"), do: :approved
  defp telemetry_outcome("rejected"), do: :rejected
  defp telemetry_outcome("omitted"), do: :omitted
  defp telemetry_outcome("cancelled"), do: :cancelled
  defp telemetry_outcome("superseded"), do: :superseded
  defp telemetry_outcome("failed"), do: :failed
  defp telemetry_outcome("validation_failed"), do: :failed
  defp telemetry_outcome(_status), do: :unknown

  defp sum_metric(value, metric) when is_map(value) do
    own = map_value(value, metric)
    own = if is_number(own) and own >= 0, do: own, else: 0

    own +
      (value
       |> Map.values()
       |> Enum.map(&sum_metric(&1, metric))
       |> Enum.sum())
  end

  defp sum_metric(value, metric) when is_list(value) do
    value |> Enum.map(&sum_metric(&1, metric)) |> Enum.sum()
  end

  defp sum_metric(_value, _metric), do: 0

  defp count_findings(value) when is_map(value) do
    own = if is_binary(map_value(value, "code")), do: 1, else: 0
    own + (value |> Map.values() |> Enum.map(&count_findings/1) |> Enum.sum())
  end

  defp count_findings(value) when is_list(value),
    do: value |> Enum.map(&count_findings/1) |> Enum.sum()

  defp count_findings(_value), do: 0

  defp map_value(value, key) when is_map(value) do
    atom_key = if is_binary(key), do: safe_existing_atom(key), else: key

    Map.get(value, key) ||
      if(atom_key, do: Map.get(value, atom_key), else: nil)
  end

  defp map_value(_value, _key), do: nil

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
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

  defp stringify_attempt_payloads(attrs) do
    attrs
    |> Map.update(:findings, [], fn findings ->
      findings |> List.wrap() |> Enum.take(30) |> stringify_keys()
    end)
    |> Map.update(:validation_summary, %{}, &stringify_keys/1)
    |> Map.update(:criticism, %{}, &stringify_keys/1)
    |> Map.update(:model_usage, %{}, &stringify_keys/1)
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_keys(item)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

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

  defp validate_resolved_url(url, expected_origins, opts)
       when is_binary(url) and is_list(expected_origins) do
    resolved = URI.parse(url)
    allow_local_http = Keyword.get(opts, :allow_local_http, false)

    secure_scheme =
      resolved.scheme == "https" or
        (allow_local_http and resolved.scheme == "http" and local_host?(resolved.host))

    same_origin =
      Enum.any?(expected_origins, fn expected_origin ->
        expected = URI.parse(expected_origin)

        present_uri?(expected) and resolved.scheme == expected.scheme and
          resolved.host == expected.host and effective_port(resolved) == effective_port(expected)
      end)

    if secure_scheme and present_uri?(resolved) and same_origin,
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
