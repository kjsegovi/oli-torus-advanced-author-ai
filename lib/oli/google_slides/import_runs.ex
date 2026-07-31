defmodule Oli.GoogleSlides.ImportRuns do
  @moduledoc """
  Durable lifecycle and authorization boundary for AI-assisted Google Slides imports.

  Public functions accept both the project and the acting author. Worker-facing
  functions are explicitly named `fetch_run/1`, `complete_*`, `record_retry/4`,
  and `fail/3`; callers outside the import workflow should not use those
  authorization-bypassing functions.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Oli.Accounts
  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleSlides.{ImportAnalysisChunk, ImportRun}
  alias Oli.GoogleSlides.AI.ImportPlan
  alias Oli.GoogleSlides.ImportRuns.{AnalysisWorker, GenerationWorker, PubSub}
  alias Oli.GoogleSlides.ImportWorkflow.AnswerResolver
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias Oli.Resources.{Resource, ResourceType, Revision}

  @active_statuses [
    :analyzing,
    :awaiting_structure,
    :awaiting_budget,
    :awaiting_answers,
    :ready_for_review,
    :generating
  ]
  @analysis_outcomes [:awaiting_structure, :awaiting_budget, :awaiting_answers, :ready_for_review]
  @final_analysis_outcomes [:awaiting_answers, :ready_for_review]
  @default_analysis_budget 2_000_000
  @max_answer_count 100
  @max_answer_key_bytes 256
  @max_answer_value_bytes 8_000
  @max_answers_bytes 64_000

  @allowed_transitions %{
    analyzing: [
      :awaiting_structure,
      :awaiting_budget,
      :awaiting_answers,
      :ready_for_review,
      :failed,
      :cancelled
    ],
    awaiting_structure: [:analyzing, :failed, :cancelled],
    awaiting_budget: [:analyzing, :failed, :cancelled],
    awaiting_answers: [:analyzing, :failed, :cancelled],
    ready_for_review: [:generating, :failed, :cancelled],
    generating: [:completed, :failed, :cancelled],
    completed: [],
    failed: [],
    cancelled: []
  }

  @analysis_result_fields [
    :presentation_id,
    :presentation_revision,
    :presentation_fingerprint,
    :presentation_metadata,
    :source_snapshot,
    :analysis_state,
    :questions,
    :lesson_plan,
    :warnings,
    :validation_results,
    :model_usage
  ]

  @generation_result_fields [
    :result_revision_id,
    :result,
    :warnings,
    :validation_results,
    :model_usage
  ]

  @type error ::
          :not_found
          | :not_authorized
          | :invalid_target_container
          | :stale_plan
          | :stale_source
          | {:invalid_transition, ImportRun.status(), ImportRun.status()}
          | Ecto.Changeset.t()
          | term()

  @doc """
  Creates an analyzing run and enqueues its first analysis job atomically.

  At most one non-terminal run may target the same container in a project.
  Completed, failed, and cancelled imports do not prevent re-importing.
  """
  @spec start_analysis(
          Project.t(),
          Author.t(),
          Resource.t() | Revision.t() | pos_integer(),
          map()
        ) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def start_analysis(%Project{} = project, %Author{} = author, target_container, attrs)
      when is_map(attrs) do
    target_container_resource_id = target_resource_id(target_container)

    with :ok <- authorize(project, author),
         :ok <- validate_target_container(project, target_container_resource_id) do
      now = DateTime.utc_now()

      attrs =
        attrs
        |> normalize_create_attrs()
        |> Map.put_new(:analysis_version, configured_analysis_version())
        |> initialize_analysis_state()
        |> Map.merge(%{
          project_id: project.id,
          author_id: author.id,
          target_container_resource_id: target_container_resource_id,
          analysis_started_at: now
        })

      Multi.new()
      |> Multi.insert(:run, ImportRun.create_changeset(%ImportRun{}, attrs))
      |> Oban.insert(:analysis_job, fn %{run: run} ->
        AnalysisWorker.new(analysis_job_args(run))
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{run: run}} ->
          :ok = PubSub.broadcast(run)
          {:ok, run}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns a run only when the actor can access its project and owns the run.
  """
  @spec get_run(Project.t(), Author.t(), Ecto.UUID.t()) ::
          {:ok, ImportRun.t()} | {:error, :not_authorized | :not_found}
  def get_run(%Project{} = project, %Author{} = author, run_id) do
    with :ok <- authorize(project, author),
         %ImportRun{} = run <-
           Repo.get_by(ImportRun,
             id: run_id,
             project_id: project.id,
             author_id: author.id
           ) do
      {:ok, run}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_run(run_id, %Project{} = project, %Author{} = author),
    do: get_run(project, author, run_id)

  @doc """
  Returns the active run owned by the author for a target container.

  This is the durable resume lookup used when an author returns to the
  curriculum after starting an import.
  """
  @spec get_active_run(
          Project.t(),
          Author.t(),
          Resource.t() | Revision.t() | pos_integer()
        ) ::
          {:ok, ImportRun.t()} | {:error, :not_authorized | :not_found}
  def get_active_run(%Project{} = project, %Author{} = author, target_container) do
    target_container_resource_id = target_resource_id(target_container)

    with :ok <- authorize(project, author),
         true <- is_integer(target_container_resource_id),
         %ImportRun{} = run <-
           Repo.one(
             from(run in ImportRun,
               where:
                 run.project_id == ^project.id and
                   run.author_id == ^author.id and
                   run.target_container_resource_id == ^target_container_resource_id and
                   run.status in ^@active_statuses,
               limit: 1
             )
           ) do
      {:ok, run}
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Lists the actor's import history in the project.

  Options may contain `:target_container_resource_id` or `:presentation_id`.
  """
  @spec list_runs(Project.t(), Author.t(), keyword()) ::
          {:ok, [ImportRun.t()]} | {:error, :not_authorized}
  def list_runs(%Project{} = project, %Author{} = author, opts \\ []) do
    with :ok <- authorize(project, author) do
      limit = opts |> Keyword.get(:limit, 50) |> normalize_list_limit()

      query =
        from(run in ImportRun,
          where: run.project_id == ^project.id and run.author_id == ^author.id,
          order_by: [desc: run.inserted_at],
          limit: ^limit
        )
        |> maybe_filter(:target_container_resource_id, opts[:target_container_resource_id])
        |> maybe_filter(:presentation_id, opts[:presentation_id])

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Returns the newest completed import of a presentation without loading the
  retained source snapshot or lesson-plan JSON.
  """
  @spec find_prior_completed_import(
          Project.t(),
          Author.t(),
          String.t(),
          Ecto.UUID.t()
        ) ::
          {:ok, map() | nil} | {:error, :not_authorized}
  def find_prior_completed_import(
        %Project{} = project,
        %Author{} = author,
        presentation_id,
        excluded_run_id
      )
      when is_binary(presentation_id) do
    with :ok <- authorize(project, author) do
      prior =
        Repo.one(
          from(run in ImportRun,
            where:
              run.project_id == ^project.id and
                run.author_id == ^author.id and
                run.presentation_id == ^presentation_id and
                run.id != ^excluded_run_id and
                run.status == :completed,
            order_by: [desc: run.inserted_at],
            limit: 1,
            select: %{
              id: run.id,
              result_revision_id: run.result_revision_id
            }
          )
        )

      {:ok, prior}
    end
  end

  @doc """
  Stores blocker answers, returns the run to analysis, and enqueues the continuation atomically.
  """
  @spec submit_answers(Project.t(), Author.t(), Ecto.UUID.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def submit_answers(%Project{} = project, %Author{} = author, run_id, answers)
      when is_map(answers) do
    with :ok <- authorize(project, author) do
      transact_with_run(run_id, project.id, author.id, fn run ->
        with :ok <- ensure_transition(run, :analyzing),
             {:ok, normalized_answers} <- validate_answers(run, answers),
             {:ok, _resolved_plan} <-
               AnswerResolver.apply(run.lesson_plan, normalized_answers),
             {:ok, updated_run} <-
               update_record(run, %{
                 status: :analyzing,
                 answers: normalized_answers,
                 error: nil,
                 analysis_started_at: DateTime.utc_now(),
                 analysis_completed_at: nil,
                 analysis_state: advance_checkpoint(run.analysis_state)
               }),
             {:ok, _job} <-
               enqueue_analysis(updated_run.id, checkpoint_version(updated_run.analysis_state)) do
          updated_run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp validate_answers(%ImportRun{} = run, answers) do
    allowed_keys = answer_keys(run)

    with :ok <- validate_answer_count(answers),
         {:ok, normalized} <- normalize_answer_values(answers, allowed_keys),
         :ok <- validate_answer_payload(normalized) do
      {:ok, normalized}
    end
  end

  defp answer_keys(%ImportRun{} = run) do
    blocker_keys =
      run.lesson_plan
      |> ImportPlan.lessons()
      |> Enum.flat_map(&(&1["blockers"] || []))
      |> Enum.flat_map(fn blocker ->
        [Map.get(blocker, "key"), Map.get(blocker, "id")]
      end)

    question_keys =
      (run.questions || [])
      |> Enum.flat_map(fn question ->
        [Map.get(question, "key"), Map.get(question, "id")]
      end)

    blocker_keys
    |> Kernel.++(question_keys)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  defp validate_answer_count(answers) when map_size(answers) <= @max_answer_count, do: :ok
  defp validate_answer_count(_answers), do: {:error, :answer_payload_too_large}

  defp normalize_answer_values(answers, allowed_keys) do
    Enum.reduce_while(answers, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_binary(key) ->
        cond do
          byte_size(key) > @max_answer_key_bytes ->
            {:halt, {:error, :answer_payload_too_large}}

          not MapSet.member?(allowed_keys, key) ->
            {:cont, {:ok, normalized}}

          valid_answer_value?(value) and answer_value_size(value) <= @max_answer_value_bytes ->
            {:cont, {:ok, Map.put(normalized, key, normalize_answer_value(value))}}

          true ->
            {:halt, {:error, :invalid_answer_payload}}
        end

      {_key, _value}, _acc ->
        {:halt, {:error, :invalid_answer_payload}}
    end)
  end

  defp validate_answer_payload(answers) do
    if map_size(answers) > 0 and byte_size(Jason.encode!(answers)) <= @max_answers_bytes do
      :ok
    else
      {:error, :invalid_answer_payload}
    end
  end

  defp valid_answer_value?(value),
    do: is_binary(value) or is_boolean(value) or is_number(value)

  defp answer_value_size(value) when is_binary(value), do: byte_size(value)
  defp answer_value_size(value), do: value |> Jason.encode!() |> byte_size()

  defp normalize_answer_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_answer_value(value), do: value

  defp normalize_list_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp normalize_list_limit(_limit), do: 50

  @doc """
  Records approval for exactly the current lesson-plan version.
  """
  @spec approve_plan(Project.t(), Author.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def approve_plan(%Project{} = project, %Author{} = author, run_id, plan_version)
      when is_integer(plan_version) and plan_version >= 0 do
    with :ok <- authorize(project, author) do
      transact_with_run(run_id, project.id, author.id, fn run ->
        cond do
          run.status != :ready_for_review ->
            Repo.rollback({:invalid_transition, run.status, :ready_for_review})

          is_nil(run.lesson_plan) or run.plan_version != plan_version ->
            Repo.rollback(:stale_plan)

          true ->
            case update_record(run, %{
                   approved_plan_version: plan_version,
                   approved_by_author_id: author.id,
                   approved_at: DateTime.utc_now(),
                   error: nil
                 }) do
              {:ok, updated_run} -> updated_run
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
    end
  end

  @doc """
  Starts deterministic lesson generation for an approved, current plan.

  Options require `:plan_version` and may include the analyzed
  `:presentation_fingerprint` to reject a stale source.
  """
  @spec start_generation(Project.t(), Author.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def start_generation(%Project{} = project, %Author{} = author, run_id, opts)
      when is_list(opts) do
    expected_plan_version = Keyword.fetch!(opts, :plan_version)
    expected_fingerprint = opts[:presentation_fingerprint]

    with :ok <- authorize(project, author) do
      transact_with_run(run_id, project.id, author.id, fn run ->
        with :ok <- validate_generation_version(run, expected_plan_version),
             :ok <- validate_source_fingerprint(run, expected_fingerprint),
             :ok <- ensure_transition(run, :generating),
             {:ok, updated_run} <-
               update_record(run, %{
                 status: :generating,
                 error: nil,
                 generation_started_at: DateTime.utc_now(),
                 finished_at: nil
               }),
             {:ok, _job} <- enqueue_generation(updated_run.id) do
          updated_run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def start_generation(
        %Project{} = project,
        %Author{} = author,
        run_id,
        expected_plan_version
      )
      when is_integer(expected_plan_version) do
    start_generation(project, author, run_id, plan_version: expected_plan_version)
  end

  @doc """
  Cancels any active run. Terminal runs remain immutable.
  """
  @spec cancel(Project.t(), Author.t(), Ecto.UUID.t()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def cancel(%Project{} = project, %Author{} = author, run_id) do
    with :ok <- authorize(project, author) do
      transition(run_id, :cancelled, %{finished_at: DateTime.utc_now()},
        project_id: project.id,
        author_id: author.id
      )
    end
  end

  @doc """
  Fetches a run without author authorization for an Oban workflow.
  """
  @spec fetch_run(Ecto.UUID.t()) :: ImportRun.t() | nil
  def fetch_run(run_id), do: Repo.get(ImportRun, run_id)

  @doc """
  Returns persisted v2 source chunks in deterministic planning order.
  """
  @spec list_analysis_chunks(Ecto.UUID.t()) :: [ImportAnalysisChunk.t()]
  def list_analysis_chunks(run_id) do
    Repo.all(
      from(chunk in ImportAnalysisChunk,
        where: chunk.run_id == ^run_id,
        order_by: [asc: chunk.ordinal]
      )
    )
  end

  @doc """
  Persists the v3 manifest and its source chunks, then enqueues the first
  structure-map continuation in the same transaction.
  """
  @spec initialize_analysis_chunks(
          Ecto.UUID.t(),
          non_neg_integer(),
          [map()],
          map()
        ) :: {:ok, ImportRun.t()} | {:error, error()}
  def initialize_analysis_chunks(run_id, expected_checkpoint_version, chunks, attrs)
      when is_integer(expected_checkpoint_version) and expected_checkpoint_version >= 0 and
             is_list(chunks) and is_map(attrs) do
    attrs = normalize_attrs(attrs, @analysis_result_fields)

    transact_with_run(run_id, nil, nil, fn run ->
      with :ok <- ensure_v2_analyzing_checkpoint(run, expected_checkpoint_version),
           :ok <- ensure_chunks_absent(run.id),
           :ok <- insert_analysis_chunks(run.id, chunks),
           next_state <-
             attrs
             |> Map.get(:analysis_state, run.analysis_state)
             |> put_checkpoint_version(expected_checkpoint_version + 1),
           {:ok, updated_run} <-
             update_record(
               run,
               attrs
               |> Map.put(:analysis_state, next_state)
               |> Map.put(:error, nil)
             ),
           {:ok, _job} <-
             enqueue_analysis(updated_run.id, checkpoint_version(updated_run.analysis_state)) do
        updated_run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Updates visible v2 progress without changing the checkpoint version.
  """
  @spec update_analysis_progress(Ecto.UUID.t(), non_neg_integer(), map()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def update_analysis_progress(run_id, expected_checkpoint_version, progress)
      when is_integer(expected_checkpoint_version) and expected_checkpoint_version >= 0 and
             is_map(progress) do
    transact_with_run(run_id, nil, nil, fn run ->
      with :ok <- ensure_v2_analyzing_checkpoint(run, expected_checkpoint_version),
           next_state <-
             run.analysis_state
             |> Kernel.||(%{})
             |> Map.merge(stringify_keys(progress))
             |> put_checkpoint_version(expected_checkpoint_version),
           {:ok, updated_run} <- update_record(run, %{analysis_state: next_state}) do
        updated_run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Persists bounded per-chunk status, usage, attempt count, and safe error data.
  """
  @spec update_analysis_chunk(Ecto.UUID.t(), non_neg_integer(), map()) ::
          {:ok, ImportAnalysisChunk.t()} | {:error, error()}
  def update_analysis_chunk(run_id, ordinal, attrs)
      when is_integer(ordinal) and ordinal >= 0 and is_map(attrs) do
    allowed_attrs =
      normalize_attrs(attrs, [:status, :usage, :attempt_count, :error])

    case Repo.get_by(ImportAnalysisChunk, run_id: run_id, ordinal: ordinal) do
      nil ->
        {:error, :not_found}

      chunk ->
        chunk
        |> ImportAnalysisChunk.changeset(allowed_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Persists a successful analysis outcome and advances the lifecycle.
  """
  @spec complete_analysis(
          Ecto.UUID.t(),
          :awaiting_structure | :awaiting_budget | :awaiting_answers | :ready_for_review,
          map()
        ) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def complete_analysis(run_id, outcome, attrs)
      when outcome in @analysis_outcomes and is_map(attrs) do
    attrs =
      attrs
      |> normalize_attrs(@analysis_result_fields)
      |> sync_analysis_state_phase()

    transition_attrs =
      attrs
      |> Map.put(:error, nil)
      |> maybe_mark_analysis_completed(outcome)

    transition(run_id, outcome, transition_attrs,
      increment_plan_version: outcome == :ready_for_review
    )
  end

  @doc """
  Atomically saves a validated v2 checkpoint and enqueues its continuation.

  The checkpoint version is an optimistic concurrency token. A duplicate or
  stale worker cannot overwrite newer progress or enqueue duplicate work.
  """
  @spec checkpoint_analysis(Ecto.UUID.t(), non_neg_integer(), map()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def checkpoint_analysis(run_id, expected_checkpoint_version, attrs)
      when is_integer(expected_checkpoint_version) and expected_checkpoint_version >= 0 and
             is_map(attrs) do
    attrs = normalize_attrs(attrs, @analysis_result_fields)

    transact_with_run(run_id, nil, nil, fn run ->
      with :ok <- ensure_v2_analyzing_checkpoint(run, expected_checkpoint_version),
           next_state <-
             attrs
             |> Map.get(:analysis_state, run.analysis_state)
             |> put_checkpoint_version(expected_checkpoint_version + 1),
           {:ok, updated_run} <-
             update_record(
               run,
               attrs
               |> Map.put(:analysis_state, next_state)
               |> Map.put(:error, nil)
             ),
           {:ok, _job} <-
             enqueue_analysis(updated_run.id, checkpoint_version(updated_run.analysis_state)) do
        updated_run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Records the author's one-lesson or split decision for the current proposal.
  """
  @spec submit_structure_decision(
          Project.t(),
          Author.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          :one_lesson | :split | String.t()
        ) :: {:ok, ImportRun.t()} | {:error, error()}
  def submit_structure_decision(
        %Project{} = project,
        %Author{} = author,
        run_id,
        proposal_version,
        decision
      )
      when is_integer(proposal_version) and proposal_version >= 0 do
    with :ok <- authorize(project, author),
         {:ok, normalized_decision} <- normalize_structure_decision(decision) do
      transact_with_run(run_id, project.id, author.id, fn run ->
        with :ok <- ensure_transition(run, :analyzing),
             :ok <- validate_structure_proposal(run.analysis_state, proposal_version),
             :ok <- validate_structure_choice(run.analysis_state, normalized_decision),
             next_state <-
               run.analysis_state
               |> Map.put("structure_decision", %{
                 "proposal_version" => proposal_version,
                 "choice" => Atom.to_string(normalized_decision),
                 "decided_at" => DateTime.utc_now() |> DateTime.to_iso8601()
               })
               |> Map.put("phase", "detail")
               |> advance_checkpoint(),
             {:ok, updated_run} <-
               update_record(run, %{
                 status: :analyzing,
                 analysis_state: next_state,
                 error: nil,
                 analysis_started_at: DateTime.utc_now()
               }),
             {:ok, _job} <-
               enqueue_analysis(updated_run.id, checkpoint_version(updated_run.analysis_state)) do
          updated_run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Grants another configured prompt-token tranche without discarding progress.
  """
  @spec approve_analysis_continuation(
          Project.t(),
          Author.t(),
          Ecto.UUID.t(),
          non_neg_integer()
        ) :: {:ok, ImportRun.t()} | {:error, error()}
  def approve_analysis_continuation(
        %Project{} = project,
        %Author{} = author,
        run_id,
        expected_checkpoint_version
      )
      when is_integer(expected_checkpoint_version) and expected_checkpoint_version >= 0 do
    with :ok <- authorize(project, author) do
      transact_with_run(run_id, project.id, author.id, fn run ->
        with :ok <- ensure_transition(run, :analyzing),
             :ok <- validate_checkpoint_version(run.analysis_state, expected_checkpoint_version),
             next_state <- grant_budget_tranche(run.analysis_state),
             {:ok, updated_run} <-
               update_record(run, %{
                 status: :analyzing,
                 analysis_state: next_state,
                 error: nil,
                 analysis_started_at: DateTime.utc_now()
               }),
             {:ok, _job} <-
               enqueue_analysis(updated_run.id, checkpoint_version(updated_run.analysis_state)) do
          updated_run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Persists a successful deterministic generation result.
  """
  @spec complete_generation(Ecto.UUID.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def complete_generation(run_id, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs, @generation_result_fields)

    if Map.get(attrs, :result_revision_id) do
      transition(
        run_id,
        :completed,
        attrs
        |> Map.put(:error, nil)
        |> Map.put(:finished_at, DateTime.utc_now())
      )
    else
      {:error, :result_revision_required}
    end
  end

  @doc """
  Records a retryable worker error without making the run terminal.
  """
  @spec record_retry(Ecto.UUID.t(), :analysis | :generation, term(), pos_integer()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def record_retry(run_id, phase, reason, attempt) when phase in [:analysis, :generation] do
    expected_status = if phase == :analysis, do: :analyzing, else: :generating

    update_if_status(run_id, expected_status, fn run ->
      %{
        error: error_payload(phase, reason, attempt, true, run.error)
      }
    end)
  end

  @doc """
  Marks a worker's current phase as failed after its retries are exhausted.
  """
  @spec fail(Ecto.UUID.t(), :analysis | :generation, term()) ::
          {:ok, ImportRun.t()} | {:error, error()}
  @spec fail(Ecto.UUID.t(), :analysis | :generation, term(), pos_integer() | nil) ::
          {:ok, ImportRun.t()} | {:error, error()}
  def fail(run_id, phase, reason, attempt \\ nil)
      when phase in [:analysis, :generation] do
    expected_status = if phase == :analysis, do: :analyzing, else: :generating

    transition(
      run_id,
      :failed,
      fn run ->
        %{
          error: error_payload(phase, reason, attempt, false, run.error),
          finished_at: DateTime.utc_now()
        }
      end,
      expected_status: expected_status
    )
  end

  @doc false
  def internal_exception(exception, stacktrace) when is_list(stacktrace) do
    {:internal_exception, exception_name(exception), safe_stack_location(stacktrace)}
  end

  defp enqueue_analysis(run_id, checkpoint_version) do
    %{run_id: run_id, checkpoint_version: checkpoint_version}
    |> AnalysisWorker.new()
    |> Oban.insert()
    |> reject_conflicting_job(:analysis_job_conflict)
  end

  defp enqueue_generation(run_id) do
    %{run_id: run_id}
    |> GenerationWorker.new()
    |> Oban.insert()
    |> reject_conflicting_job(:generation_job_conflict)
  end

  defp transition(run_id, next_status, attrs, opts \\ [])
       when (is_map(attrs) or is_function(attrs, 1)) and is_list(opts) do
    expected_status = opts[:expected_status]
    project_id = opts[:project_id]
    author_id = opts[:author_id]

    transact_with_run(run_id, project_id, author_id, fn run ->
      attrs = resolve_update_attrs(attrs, run)

      attrs =
        if opts[:increment_plan_version] do
          attrs
          |> Map.put(:plan_version, run.plan_version + 1)
          |> Map.put(:approved_plan_version, nil)
          |> Map.put(:approved_by_author_id, nil)
          |> Map.put(:approved_at, nil)
        else
          attrs
        end

      with :ok <- validate_expected_status(run, expected_status),
           :ok <- ensure_transition(run, next_status),
           {:ok, updated_run} <-
             update_record(run, Map.put(normalize_update_attrs(attrs), :status, next_status)) do
        updated_run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_if_status(run_id, expected_status, attrs) do
    transact_with_run(run_id, nil, nil, fn run ->
      if run.status == expected_status do
        case update_record(run, resolve_update_attrs(attrs, run)) do
          {:ok, updated_run} -> updated_run
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback({:invalid_transition, run.status, expected_status})
      end
    end)
  end

  defp resolve_update_attrs(attrs, _run) when is_map(attrs), do: attrs
  defp resolve_update_attrs(attrs, run) when is_function(attrs, 1), do: attrs.(run)

  defp transact_with_run(run_id, project_id, author_id, fun) do
    Repo.transaction(fn ->
      query =
        from(run in ImportRun,
          where: run.id == ^run_id,
          lock: "FOR UPDATE"
        )
        |> maybe_filter(:project_id, project_id)
        |> maybe_filter(:author_id, author_id)

      case Repo.one(query) do
        nil -> Repo.rollback(:not_found)
        run -> fun.(run)
      end
    end)
    |> case do
      {:ok, %ImportRun{} = run} ->
        :ok = PubSub.broadcast(run)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_record(run, attrs) do
    run
    |> ImportRun.update_changeset(attrs)
    |> Repo.update()
  end

  defp ensure_transition(%ImportRun{status: status}, next_status) do
    if next_status in Map.fetch!(@allowed_transitions, status) do
      :ok
    else
      {:error, {:invalid_transition, status, next_status}}
    end
  end

  defp validate_expected_status(_run, nil), do: :ok

  defp validate_expected_status(%ImportRun{status: status}, status), do: :ok

  defp validate_expected_status(%ImportRun{status: status}, expected),
    do: {:error, {:invalid_transition, status, expected}}

  defp validate_generation_version(run, expected_plan_version) do
    if run.plan_version == expected_plan_version and
         run.approved_plan_version == expected_plan_version and
         run.approved_by_author_id == run.author_id and
         not is_nil(run.approved_at) and
         not is_nil(run.lesson_plan) do
      :ok
    else
      {:error, :stale_plan}
    end
  end

  defp validate_source_fingerprint(_run, nil), do: :ok

  defp validate_source_fingerprint(run, expected) do
    if run.presentation_fingerprint == expected, do: :ok, else: {:error, :stale_source}
  end

  defp authorize(%Project{status: :active} = project, %Author{} = author) do
    if Accounts.can_access?(author, project), do: :ok, else: {:error, :not_authorized}
  end

  defp authorize(_project, _author), do: {:error, :not_authorized}

  defp validate_target_container(_project, nil), do: {:error, :invalid_target_container}

  defp validate_target_container(project, resource_id) do
    container_type_id = ResourceType.id_for_container()

    case AuthoringResolver.from_resource_id(project.slug, resource_id) do
      %Revision{deleted: false, resource_type_id: ^container_type_id} ->
        :ok

      _ ->
        {:error, :invalid_target_container}
    end
  end

  defp target_resource_id(%Resource{id: id}), do: id
  defp target_resource_id(%Revision{resource_id: id}), do: id
  defp target_resource_id(id) when is_integer(id), do: id
  defp target_resource_id(_), do: nil

  defp normalize_create_attrs(attrs) do
    normalize_attrs(attrs, [
      :presentation_url,
      :presentation_id,
      :presentation_revision,
      :presentation_fingerprint,
      :presentation_metadata,
      :source_snapshot,
      :analysis_version,
      :analysis_state,
      :options
    ])
  end

  defp normalize_update_attrs(attrs) do
    normalize_attrs(attrs, [
      :status,
      :presentation_id,
      :presentation_revision,
      :presentation_fingerprint,
      :presentation_metadata,
      :source_snapshot,
      :analysis_version,
      :analysis_state,
      :options,
      :questions,
      :answers,
      :lesson_plan,
      :plan_version,
      :approved_plan_version,
      :approved_by_author_id,
      :approved_at,
      :warnings,
      :validation_results,
      :result,
      :result_revision_id,
      :model_usage,
      :error,
      :analysis_started_at,
      :analysis_completed_at,
      :generation_started_at,
      :finished_at
    ])
  end

  defp normalize_attrs(attrs, fields) do
    Enum.reduce(fields, %{}, fn field, normalized ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(attrs, field) ->
          Map.put(normalized, field, Map.get(attrs, field))

        Map.has_key?(attrs, string_field) ->
          Map.put(normalized, field, Map.get(attrs, string_field))

        true ->
          normalized
      end
    end)
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [run], field(run, ^field) == ^value)

  defp reject_conflicting_job({:ok, %Oban.Job{conflict?: true}}, reason), do: {:error, reason}
  defp reject_conflicting_job(result, _reason), do: result

  defp ensure_chunks_absent(run_id) do
    exists? =
      Repo.exists?(
        from(chunk in ImportAnalysisChunk,
          where: chunk.run_id == ^run_id
        )
      )

    if exists?, do: {:error, :analysis_chunks_already_initialized}, else: :ok
  end

  defp insert_analysis_chunks(run_id, chunks) do
    chunks
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      attrs = %{
        run_id: run_id,
        ordinal: Map.get(chunk, :ordinal, Map.get(chunk, "ordinal")),
        slide_ids: Map.get(chunk, :slide_ids, Map.get(chunk, "slide_ids", [])),
        object_ids: Map.get(chunk, :object_ids, Map.get(chunk, "object_ids", [])),
        source_fragment: Map.get(chunk, :source_fragment, Map.get(chunk, "source_fragment")),
        status: :pending
      }

      case %ImportAnalysisChunk{}
           |> ImportAnalysisChunk.changeset(attrs)
           |> Repo.insert() do
        {:ok, _chunk} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp configured_analysis_version do
    configured_import_value(:analysis_version, 2)
  end

  defp initialize_analysis_state(%{analysis_version: version} = attrs) when version >= 2 do
    Map.put_new(attrs, :analysis_state, initial_analysis_state())
  end

  defp initialize_analysis_state(attrs), do: attrs

  defp initial_analysis_state do
    budget =
      configured_import_value(:analysis_budget_prompt_tokens, @default_analysis_budget)
      |> positive_integer(@default_analysis_budget)

    %{
      "phase" => "inventory",
      "current_phase" => "inventory",
      "checkpoint_version" => 0,
      "completed_units" => 0,
      "total_units" => nil,
      "current_slide_range" => nil,
      "structure_proposal" => nil,
      "structure_decision" => nil,
      "accumulated_usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0},
      "continuation_tranche" => 1,
      "budget_tranche_tokens" => budget,
      "budget_limit_tokens" => budget,
      "no_progress_count" => 0
    }
  end

  defp analysis_job_args(%ImportRun{} = run) do
    %{run_id: run.id, checkpoint_version: checkpoint_version(run.analysis_state)}
  end

  defp checkpoint_version(%{"checkpoint_version" => version}) when is_integer(version),
    do: version

  defp checkpoint_version(%{checkpoint_version: version}) when is_integer(version), do: version
  defp checkpoint_version(_state), do: 0

  defp advance_checkpoint(state) do
    put_checkpoint_version(state, checkpoint_version(state) + 1)
  end

  defp put_checkpoint_version(state, version) when is_map(state) do
    state
    |> Map.put("checkpoint_version", version)
    |> sync_current_phase()
  end

  defp put_checkpoint_version(_state, version),
    do: %{"checkpoint_version" => version, "current_phase" => "inventory"}

  defp ensure_v2_analyzing_checkpoint(
         %ImportRun{analysis_version: version, status: :analyzing, analysis_state: state},
         expected_checkpoint_version
       )
       when version >= 2,
       do: validate_checkpoint_version(state, expected_checkpoint_version)

  defp ensure_v2_analyzing_checkpoint(%ImportRun{status: status}, _expected),
    do: {:error, {:invalid_transition, status, :analyzing}}

  defp validate_checkpoint_version(state, expected) do
    if checkpoint_version(state) == expected, do: :ok, else: {:error, :stale_checkpoint}
  end

  defp normalize_structure_decision(decision) when decision in [:one_lesson, "one_lesson"],
    do: {:ok, :one_lesson}

  defp normalize_structure_decision(decision) when decision in [:split, "split"],
    do: {:ok, :split}

  defp normalize_structure_decision(_decision), do: {:error, :invalid_structure_decision}

  defp validate_structure_proposal(%{"structure_proposal" => proposal}, version)
       when is_map(proposal) do
    proposal_version = Map.get(proposal, "version") || Map.get(proposal, :version)
    if proposal_version == version, do: :ok, else: {:error, :stale_structure_proposal}
  end

  defp validate_structure_proposal(_state, _version), do: {:error, :stale_structure_proposal}

  defp validate_structure_choice(_state, :one_lesson), do: :ok

  defp validate_structure_choice(%{"structure_proposal" => proposal}, :split)
       when is_map(proposal) do
    split = Map.get(proposal, "split") || Map.get(proposal, :split)
    if is_map(split), do: :ok, else: {:error, :split_not_available}
  end

  defp validate_structure_choice(_state, :split), do: {:error, :split_not_available}

  defp grant_budget_tranche(state) when is_map(state) do
    tranche = positive_integer(Map.get(state, "budget_tranche_tokens"), @default_analysis_budget)
    current_limit = positive_integer(Map.get(state, "budget_limit_tokens"), tranche)
    current_ordinal = positive_integer(Map.get(state, "continuation_tranche"), 1)

    state
    |> Map.put("budget_limit_tokens", current_limit + tranche)
    |> Map.put("continuation_tranche", current_ordinal + 1)
    |> Map.put("phase", Map.get(state, "resume_phase", Map.get(state, "phase", "detail")))
    |> Map.delete("resume_phase")
    |> advance_checkpoint()
  end

  defp grant_budget_tranche(_state), do: initial_analysis_state() |> grant_budget_tranche()

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp configured_import_value(key, default) do
    case Application.get_env(:oli, :google_slides_ai_import, []) do
      config when is_list(config) ->
        Keyword.get(config, key, default)

      config when is_map(config) ->
        Map.get(config, key, Map.get(config, Atom.to_string(key), default))

      _other ->
        default
    end
  end

  defp sync_analysis_state_phase(%{analysis_state: state} = attrs) when is_map(state),
    do: Map.put(attrs, :analysis_state, sync_current_phase(state))

  defp sync_analysis_state_phase(attrs), do: attrs

  defp sync_current_phase(%{"phase" => phase} = state) when is_binary(phase),
    do: Map.put(state, "current_phase", phase)

  defp sync_current_phase(state), do: state

  defp maybe_mark_analysis_completed(attrs, outcome) when outcome in @final_analysis_outcomes,
    do: Map.put(attrs, :analysis_completed_at, DateTime.utc_now())

  defp maybe_mark_analysis_completed(attrs, _outcome),
    do: Map.put(attrs, :analysis_completed_at, nil)

  defp error_payload(phase, reason, attempt, retryable, previous_error) do
    payload = %{
      "phase" => Atom.to_string(phase),
      "code" => error_code(reason),
      "message" => public_error_message(phase, reason),
      "attempt" => attempt,
      "retryable" => retryable,
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload
    |> preserve_provider_failure(previous_error)
    |> maybe_put_internal_diagnostic(reason)
  end

  # A circuit breaker rejection is a consequence of an earlier provider
  # failure, not the root cause. Keep the earlier safe classification as the
  # author-facing reference while recording that routing was the terminal
  # condition. Provider bodies and transport details never enter this payload.
  defp preserve_provider_failure(
         %{"code" => "ai_routing_unavailable"} = payload,
         %{"code" => prior_code, "message" => prior_message} = previous_error
       )
       when prior_code != "ai_routing_unavailable" do
    payload
    |> Map.put("code", prior_code)
    |> Map.put("message", prior_message)
    |> Map.put("routing_code", "ai_routing_unavailable")
    |> maybe_carry_prior_routing_code(previous_error)
  end

  defp preserve_provider_failure(payload, _previous_error), do: payload

  defp maybe_carry_prior_routing_code(payload, %{"routing_code" => routing_code}),
    do: Map.put(payload, "routing_code", routing_code)

  defp maybe_carry_prior_routing_code(payload, _previous_error), do: payload

  defp maybe_put_internal_diagnostic(
         payload,
         {:internal_exception, exception, location}
       ) do
    Map.put(payload, "diagnostic", %{
      "exception" => exception,
      "location" => location
    })
  end

  defp maybe_put_internal_diagnostic(payload, _reason), do: payload

  # Import errors can contain provider response bodies, tool payloads, or URLs
  # derived from secret-bearing service configuration. Persist and render only
  # a stable classification plus an author-safe message.
  defp error_code({:completion_failed, reason}), do: completion_error_code(reason)

  defp error_code({:token_http_status, status, _body}),
    do: google_auth_error_code(status)

  defp error_code({:http_status, status, _body}),
    do: google_api_error_code(status)

  defp error_code({:tool_budget_exhausted, _max_steps, _metadata}),
    do: "planner_step_limit_exceeded"

  defp error_code(
         {:input_token_budget_exhausted, _max_input_tokens, _used_input_tokens,
          _estimated_input_tokens}
       ),
       do: "planner_input_limit_exceeded"

  defp error_code({:missing_tool_call, _payload}), do: "planner_missing_tool_call"
  defp error_code(:lesson_plan_not_created), do: "planner_did_not_create_plan"
  defp error_code(:invalid_lesson_plan_blockers), do: "planner_output_invalid"
  defp error_code({:invalid_lesson_plan, _errors}), do: "planner_output_invalid"
  defp error_code([%{} | _validation_errors]), do: "planner_output_invalid"
  defp error_code({:internal_exception, _exception, _location}), do: "internal_exception"
  defp error_code({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_code({tag, _left, _right}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "internal_error"

  defp completion_error_code(%{status_code: status}), do: ai_http_error_code(status)
  defp completion_error_code(%{"status_code" => status}), do: ai_http_error_code(status)

  defp completion_error_code(reason)
       when reason in [:timeout, :connect_timeout, :recv_timeout],
       do: "ai_request_timed_out"

  defp completion_error_code(reason)
       when reason in [
              :closed,
              :econnrefused,
              :econnreset,
              :enetdown,
              :enetunreach,
              :ehostdown,
              :ehostunreach,
              :nxdomain,
              :socket_closed_remotely
            ],
       do: "ai_connection_failed"

  defp completion_error_code(reason)
       when reason in [
              :secondary_breaker_open,
              :all_breakers_open,
              :backup_breaker_open
            ],
       do: "ai_routing_unavailable"

  defp completion_error_code(reason)
       when reason in [:over_capacity, :secondary_over_capacity],
       do: "ai_capacity_unavailable"

  defp completion_error_code(:unexpected_response), do: "ai_unexpected_response"
  defp completion_error_code(_reason), do: "ai_completion_failed"

  defp ai_http_error_code(status) when status in [401, 403], do: "ai_authentication_failed"
  defp ai_http_error_code(429), do: "ai_rate_limited"
  defp ai_http_error_code(status) when status in [408, 425], do: "ai_provider_unavailable"

  defp ai_http_error_code(status) when is_integer(status) and status >= 500,
    do: "ai_provider_unavailable"

  defp ai_http_error_code(status) when is_integer(status) and status >= 400,
    do: "ai_request_rejected"

  defp ai_http_error_code(_status), do: "ai_completion_failed"

  defp google_auth_error_code(status) when status in [400, 401, 403],
    do: "google_service_account_rejected"

  defp google_auth_error_code(429), do: "google_auth_temporarily_unavailable"

  defp google_auth_error_code(status) when is_integer(status) and status >= 500,
    do: "google_auth_temporarily_unavailable"

  defp google_auth_error_code(_status), do: "google_auth_failed"

  defp google_api_error_code(status) when status in [408, 425, 429],
    do: "google_slides_temporarily_unavailable"

  defp google_api_error_code(status) when is_integer(status) and status >= 500,
    do: "google_slides_temporarily_unavailable"

  defp google_api_error_code(_status), do: "google_slides_request_rejected"

  defp public_error_message(phase, reason) do
    case error_code(reason) do
      "presentation_not_accessible" ->
        "Torus could not access the presentation. Check its sharing settings and try again."

      "google_slides_api_disabled" ->
        "The Google Slides API is not enabled for the configured service account."

      "not_configured" ->
        "The AI planning service is not configured for Google Slides import."

      "stale_source" ->
        "The presentation changed after analysis. Start a new analysis before generating."

      "stale_plan" ->
        "The approved lesson plan is no longer current. Review and approve the latest plan."

      "source_snapshot_exceeds_limits" ->
        "The presentation exceeds the supported analysis limits."

      "invalid_source_fidelity" ->
        "The approved source-fidelity ledger is no longer valid. Analyze the presentation again."

      "invalid_source_provenance" ->
        "The approved plan no longer matches the analyzed presentation."

      "google_service_account_rejected" ->
        "Google rejected the configured service account. Ask an administrator to verify its credentials and Slides API access."

      "google_auth_temporarily_unavailable" ->
        "Google authentication is temporarily unavailable. Try the import again in a few minutes."

      "google_auth_failed" ->
        "Torus could not authenticate with Google. Ask an administrator to verify the Slides service account."

      "google_slides_request_rejected" ->
        "Google rejected the presentation request. Check the deck and the configured Slides API access."

      "google_slides_temporarily_unavailable" ->
        "Google Slides is temporarily unavailable. Try the import again in a few minutes."

      "ai_authentication_failed" ->
        "The configured AI service credentials were rejected. Ask an administrator to verify the AI service configuration."

      "ai_rate_limited" ->
        "The AI planning service is temporarily busy. Try the import again in a few minutes."

      "ai_provider_unavailable" ->
        "The AI planning service is temporarily unavailable. Try the import again in a few minutes."

      "ai_request_timed_out" ->
        "The AI planning request took longer than the configured time limit. Try the import again or contact support."

      "ai_connection_failed" ->
        "Torus could not connect to the AI planning service. Check outbound connectivity and try again."

      "ai_routing_unavailable" ->
        "The AI planning route is temporarily unavailable after repeated provider failures. Try again in a few minutes."

      "ai_capacity_unavailable" ->
        "The AI planning service is currently at capacity. Try the import again in a few minutes."

      "ai_request_rejected" ->
        "The AI service rejected the lesson-planning request. Ask an administrator to verify the configured model and request limits."

      "ai_unexpected_response" ->
        "The AI planner returned an unsupported response. Try the import again or contact support."

      "ai_completion_failed" ->
        "The AI planner could not analyze this presentation. Try again or contact support."

      "planner_step_limit_exceeded" ->
        "This presentation needs more planning steps than the current import limit allows. Contact support with the reference code."

      "planner_input_limit_exceeded" ->
        "The AI planner reached its analysis input budget before completing the lesson plan. Try again or contact support."

      "planner_no_progress" ->
        "The AI planner could not make validated progress after three saved continuations. Start over or contact support with the reference code."

      "unresolved_automatic_blockers" ->
        "Torus could not safely preserve part of this presentation without additional automatic conversion. Start over or contact support with the reference code."

      "slide_limit_exceeded" ->
        "This presentation has more than the supported 150 slides. Split the deck before importing it."

      "planner_missing_tool_call" ->
        "The AI planner did not return a reviewable lesson plan. Try the import again or contact support."

      "planner_did_not_create_plan" ->
        "The AI planner did not create a lesson plan. Try the import again or contact support."

      "planner_output_invalid" ->
        "The AI planner returned a lesson plan that did not pass validation. Try again or contact support."

      "internal_exception" ->
        "Torus encountered an internal planning error. Try again or contact support with the reference code."

      _ ->
        default_public_error_message(phase)
    end
  end

  defp default_public_error_message(:analysis),
    do: "Torus could not analyze this presentation. Try again or contact support."

  defp default_public_error_message(:generation),
    do: "Torus could not generate the approved lesson. Try the import again or contact support."

  defp exception_name(%{__struct__: module}) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp exception_name(_exception), do: "Exception"

  defp safe_stack_location([
         {module, function, arity_or_args, metadata} | _rest
       ])
       when is_atom(module) and is_atom(function) and is_list(metadata) do
    %{
      "module" => inspect(module),
      "function" => Atom.to_string(function),
      "arity" => stack_arity(arity_or_args),
      "file" => safe_stack_file(metadata[:file]),
      "line" => metadata[:line]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_stack_location(_stacktrace), do: %{}

  defp stack_arity(arity) when is_integer(arity), do: arity
  defp stack_arity(args) when is_list(args), do: length(args)
  defp stack_arity(_arity_or_args), do: nil

  defp safe_stack_file(file) when is_list(file),
    do: file |> List.to_string() |> Path.basename()

  defp safe_stack_file(file) when is_binary(file), do: Path.basename(file)
  defp safe_stack_file(_file), do: nil
end
