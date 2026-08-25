defmodule Oli.OpenStax.CourseImport do
  @moduledoc """
  Durable context for project-scoped OpenStax course imports.

  This module is the authorization and state-machine boundary. Background
  workers may only advance runs through these functions, which keeps retries,
  browser reconnection, and user mutations consistent.
  """

  import Ecto.Query

  require Logger

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.Authoring.Editing.Utils, as: EditingUtils

  alias Oli.OpenStax.CourseImport.{
    AdvancedPlanV7,
    AIBackend,
    BasicPlanV7,
    Checks,
    Compiler,
    Enrichment,
    EnrichmentProposal,
    EnrichmentResearchSet,
    FullSource,
    ImportContract,
    Lesson,
    LessonCheck,
    LessonPlan,
    MediaIngestor,
    Outbox,
    Parser,
    PubSub,
    QualityCritic,
    RichSource,
    Run,
    SimulationArtifact,
    SimulationSpec,
    SourceAsset,
    Telemetry,
    Unit
  }

  @source_schema_version 4
  @plan_schema_version 7

  alias Oli.OpenStax.CourseImport.Worker.{
    ApplyWorker,
    EnrichmentResearchWorker,
    LessonPlanningCoordinatorWorker,
    LessonPlanWorker,
    MediaWorker,
    OutlineWorker,
    PreflightWorker,
    SimulationGenerationWorker,
    SimulationSpecGenerationWorker
  }

  alias Oli.OpenStax.CourseImport.Enrichment.{ArtifactStorage, Generator, Research, Sandbox}

  alias Oli.Publishing.AuthoringResolver
  alias Oli.Publishing
  alias Oli.Repo
  alias Oli.Resources.Revision
  alias Oli.ScopedFeatureFlags

  @active_statuses [
    :preflighting,
    :awaiting_scope,
    :ingesting,
    :staging_media,
    :planning_outline,
    :awaiting_outline_approval,
    :planning_lessons,
    :awaiting_lesson_approval,
    :compiling,
    :applying
  ]

  @terminal_statuses [:completed, :failed, :cancelled]
  @active_lesson_planning_states ["queued", "running", "retrying"]
  @unfinished_lesson_planning_states ["pending" | @active_lesson_planning_states]
  @progress_timing_history_limit 20
  @progress_item_history_limit 30

  @allowed_transitions %{
    preflighting: [:awaiting_scope, :failed, :cancelled],
    awaiting_scope: [:ingesting, :failed, :cancelled],
    ingesting: [:planning_outline, :failed, :cancelled],
    planning_outline: [:awaiting_outline_approval, :failed, :cancelled],
    awaiting_outline_approval: [:planning_lessons, :failed, :cancelled],
    planning_lessons: [:awaiting_lesson_approval, :failed, :cancelled],
    awaiting_lesson_approval: [:compiling, :failed, :cancelled],
    compiling: [:awaiting_lesson_approval, :staging_media, :applying, :failed, :cancelled],
    staging_media: [:awaiting_lesson_approval, :applying, :failed, :cancelled],
    applying: [:completed, :failed, :cancelled],
    completed: [],
    failed: [],
    cancelled: []
  }

  @spec available?(Project.t(), Author.t()) :: boolean()
  def available?(%Project{} = project, %Author{} = author) do
    (test_conveniences_enabled?() or
       ScopedFeatureFlags.enabled?(:openstax_course_import, project)) and
      authorize_project(project, author) == :ok
  rescue
    _ -> false
  end

  def available?(_, _), do: false

  @doc "Returns whether local-only OpenStax import testing conveniences are active."
  @spec test_conveniences_enabled?() :: boolean()
  def test_conveniences_enabled? do
    Application.get_env(:oli, :env) in [:dev, :test] and
      Application.get_env(:oli, :openstax_course_import_test_conveniences_enabled, false) == true
  end

  @doc "Returns project-scoped enrichment availability for the author review UI."
  @spec enrichment_capabilities(Project.t(), AIBackend.backend()) :: map()
  def enrichment_capabilities(project, ai_backend \\ :openai_api)

  def enrichment_capabilities(%Project{} = project, ai_backend) do
    generated_enabled =
      project_feature_enabled?(
        project,
        :openstax_generated_enrichment,
        :openstax_generated_enrichment_enabled
      )

    web_research_enabled =
      project_feature_enabled?(
        project,
        :openstax_simulation_web_research,
        :openstax_web_research_enabled
      )

    three_d_enabled =
      project_feature_enabled?(
        project,
        :openstax_simulation_3d_generation,
        :openstax_three_d_generation_enabled
      )

    delivery_enabled =
      project_feature_enabled?(
        project,
        :openstax_generated_simulation_delivery,
        :openstax_generated_simulation_delivery_enabled
      )

    kill_switch =
      Application.get_env(:oli, :openstax_generated_simulation_kill_switch, true) == true

    generator_available = Generator.available?(AIBackend.generator_options(ai_backend))
    sandbox_available = Sandbox.available?()
    storage_available = ArtifactStorage.available?()

    %{
      generated_enabled: generated_enabled,
      web_research_enabled: web_research_enabled,
      three_d_enabled: three_d_enabled,
      delivery_enabled: delivery_enabled,
      delivery_kill_switch: kill_switch,
      generator_available: generator_available,
      sandbox_available: sandbox_available,
      storage_available: storage_available,
      generated_available:
        generated_enabled and generator_available and sandbox_available and storage_available,
      research_available:
        generated_enabled and web_research_enabled and
          Research.available?(AIBackend.research_options(ai_backend)),
      delivery_available: generated_enabled and delivery_enabled and not kill_switch
    }
  rescue
    _ ->
      %{
        generated_enabled: false,
        web_research_enabled: false,
        three_d_enabled: false,
        delivery_enabled: false,
        delivery_kill_switch: true,
        generator_available: false,
        sandbox_available: false,
        storage_available: false,
        generated_available: false,
        research_available: false,
        delivery_available: false
      }
  end

  def enrichment_capabilities(_, _),
    do: %{
      generated_enabled: false,
      web_research_enabled: false,
      three_d_enabled: false,
      delivery_enabled: false,
      delivery_kill_switch: true,
      generator_available: false,
      sandbox_available: false,
      storage_available: false,
      generated_available: false,
      research_available: false,
      delivery_available: false
    }

  defp project_feature_enabled?(project, scoped_feature, application_key) do
    Application.get_env(:oli, application_key, false) == true or
      ScopedFeatureFlags.enabled?(scoped_feature, project)
  end

  @spec start_import(Project.t(), Revision.t() | integer(), Author.t(), String.t(), keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def start_import(project, target_container, author, source_url, opts \\ [])

  def start_import(
        %Project{} = project,
        target_container,
        %Author{} = author,
        source_url,
        opts
      )
      when is_binary(source_url) and is_list(opts) do
    source_url = String.trim(source_url)
    ai_backend = Keyword.get(opts, :ai_backend, :openai_api)

    with :ok <- authorize_project(project, author),
         :ok <- ensure_feature_available(project),
         :ok <- AIBackend.validate_start(ai_backend),
         {:ok, target_resource_id} <- target_resource_id(target_container),
         :ok <- ensure_project_root_empty(project, target_resource_id),
         :ok <- ensure_no_active_run(project.id, target_resource_id) do
      case Parser.parse_openstax_url(source_url) do
        {:ok, book_slug} ->
          create_run(project, author, target_resource_id, source_url, book_slug, ai_backend)

        {:error, :invalid_openstax_url} ->
          create_invalid_source_run(project, author, target_resource_id, source_url, ai_backend)
      end
    end
  end

  def start_import(%Project{}, _target, _author, _source_url, _opts), do: {:error, :invalid_input}

  @spec get_run(Project.t(), Author.t(), Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def get_run(%Project{} = project, %Author{} = author, run_id) when is_binary(run_id) do
    with :ok <- authorize_project(project, author) do
      case Repo.one(
             from(run in Run,
               where:
                 run.id == ^run_id and run.project_id == ^project.id and
                   run.author_id == ^author.id
             )
           ) do
        nil -> {:error, :not_found}
        run -> with(:ok <- ensure_current_run_schema(run), do: {:ok, preload_run(run)})
      end
    end
  end

  def get_run(_, _, _), do: {:error, :not_found}

  @doc """
  Returns the authorized run row without loading its units, lessons, and plan
  history. Long-running LiveView polling uses this lightweight checkpoint and
  reloads the full plan only when the workflow enters a review stage.
  """
  @spec get_run_checkpoint(Project.t(), Author.t(), Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def get_run_checkpoint(%Project{} = project, %Author{} = author, run_id)
      when is_binary(run_id) do
    with :ok <- authorize_project(project, author) do
      case Repo.one(
             from(run in Run,
               where:
                 run.id == ^run_id and run.project_id == ^project.id and
                   run.author_id == ^author.id
             )
           ) do
        nil -> {:error, :not_found}
        run -> with(:ok <- ensure_current_run_schema(run), do: {:ok, run})
      end
    end
  end

  def get_run_checkpoint(_, _, _), do: {:error, :not_found}

  @spec get_active_run(Project.t(), Author.t(), Revision.t() | integer()) ::
          {:ok, Run.t()} | {:error, term()}
  def get_active_run(%Project{} = project, %Author{} = author, target_container) do
    with :ok <- authorize_project(project, author),
         {:ok, target_resource_id} <- target_resource_id(target_container) do
      case Repo.one(
             from(run in Run,
               where:
                 run.project_id == ^project.id and run.author_id == ^author.id and
                   run.target_root_container_resource_id == ^target_resource_id and
                   run.status in ^@active_statuses and
                   run.source_schema_version == @source_schema_version and
                   run.plan_schema_version == @plan_schema_version,
               order_by: [desc: run.inserted_at],
               limit: 1
             )
           ) do
        nil -> {:error, :not_found}
        run -> {:ok, preload_run(run)}
      end
    end
  end

  @doc "Returns whether this project has an unfinished pre-v7 import without mutating it."
  @spec unfinished_legacy_run?(Project.t(), Author.t()) :: boolean()
  def unfinished_legacy_run?(%Project{} = project, %Author{} = author) do
    with :ok <- authorize_project(project, author) do
      Repo.exists?(
        from(run in Run,
          where:
            run.project_id == ^project.id and run.author_id == ^author.id and
              run.status in ^@active_statuses and
              (run.source_schema_version != @source_schema_version or
                 run.plan_schema_version != @plan_schema_version)
        )
      )
    else
      _ -> false
    end
  end

  def unfinished_legacy_run?(_, _), do: false

  @spec load_run_details(Ecto.UUID.t(), Author.t()) :: {:ok, Run.t()} | {:error, term()}
  def load_run_details(run_id, %Author{} = author) when is_binary(run_id) do
    with {:ok, run} <- get_owned_run(run_id, author),
         :ok <- ensure_current_run_schema(run),
         %Project{} = project <- Repo.get(Project, run.project_id),
         :ok <- authorize_project(project, author) do
      {:ok, preload_run(run)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def load_run_details(_, _), do: {:error, :not_found}

  @spec list_for_author(integer(), Author.t(), pos_integer()) :: {:ok, [Run.t()]}
  def list_for_author(project_id, author, limit \\ 50)

  def list_for_author(project_id, %Author{} = author, limit)
      when is_integer(project_id) and is_integer(limit) and limit > 0 do
    case Repo.get(Project, project_id) do
      nil ->
        {:error, :not_found}

      project ->
        with :ok <- authorize_project(project, author) do
          {:ok,
           Repo.all(
             from(run in Run,
               where:
                 run.project_id == ^project_id and run.author_id == ^author.id and
                   run.source_schema_version == @source_schema_version and
                   run.plan_schema_version == @plan_schema_version,
               order_by: [desc: run.inserted_at],
               limit: ^limit
             )
           )}
        end
    end
  end

  def list_for_author(_, _, _), do: {:error, :invalid_input}

  @spec update_scope(Ecto.UUID.t(), Author.t(), [String.t()]) ::
          {:ok, Run.t()} | {:error, term()}
  def update_scope(run_id, %Author{} = author, selected_chapter_ids)
      when is_binary(run_id) and is_list(selected_chapter_ids) do
    selected_ids =
      selected_chapter_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_scope),
         false <- Enum.empty?(selected_ids),
         {:ok, scope_attrs} <- scope_attrs(run, selected_ids) do
      transition_with_job(
        run,
        :ingesting,
        scope_attrs,
        OutlineWorker.new(%{"run_id" => run.id})
      )
    else
      true -> {:error, :no_chapters_selected}
      {:error, _} = error -> error
    end
  end

  def update_scope(_, _, _), do: {:error, :invalid_input}

  @spec approve_outline(Run.t() | Ecto.UUID.t(), Author.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def approve_outline(%Run{id: run_id}, %Author{} = author), do: approve_outline(run_id, author)

  def approve_outline(run_id, %Author{} = author) when is_binary(run_id) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_outline_approval),
         true <- run_has_lessons?(run.id) do
      attrs = %{
        outline_approved_by_author_id: author.id,
        outline_approved_at: DateTime.utc_now()
      }

      transition_to_parallel_lesson_planning(run, attrs)
    else
      false -> {:error, :empty_outline}
      {:error, _} = error -> error
    end
  end

  @spec update_lesson_plan(String.t(), Author.t(), map(), String.t() | nil) ::
          {:ok, Lesson.t()} | {:error, term()}
  def update_lesson_plan(lesson_id, %Author{} = author, payload, plan_mode)
      when is_binary(lesson_id) and is_map(payload) do
    with {:ok, lesson} <- lesson_with_run(lesson_id),
         {:ok, run} <- authorized_run(lesson.run_id, author),
         :ok <- ensure_status(lesson.run.status, :awaiting_lesson_approval),
         :ok <- validate_plan_mode(plan_mode || lesson.plan_mode),
         :ok <- ensure_authoring_mode_transition(lesson.plan_mode, plan_mode || lesson.plan_mode),
         :ok <- ensure_current_run_schema(run) do
      persist_lesson_plan(
        lesson,
        payload,
        plan_mode || lesson.plan_mode,
        "author",
        true
      )
    end
  end

  def update_lesson_plan(_, _, _, _), do: {:error, :invalid_input}

  defp ensure_authoring_mode_transition("basic", "advanced"),
    do: {:error, :advanced_requires_fresh_generation}

  defp ensure_authoring_mode_transition(_current, _requested), do: :ok

  @spec approve_lesson(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def approve_lesson(run_id, lesson_id, %Author{} = author) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval) do
      result =
        Repo.transaction(fn ->
          locked_run =
            Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))

          :ok = rollback_unless_ok(ensure_status(locked_run.status, :awaiting_lesson_approval))

          lesson =
            Repo.one(
              from(lesson in Lesson,
                where: lesson.id == ^lesson_id and lesson.run_id == ^locked_run.id,
                lock: "FOR UPDATE"
              )
            ) || Repo.rollback(:not_found)

          :ok = rollback_unless_ok(ensure_lesson_not_busy(lesson))
          plan = latest_plan_or_nil(lesson.id) || Repo.rollback(:missing_lesson_plan)
          :ok = rollback_unless_ok(ensure_plan_approvable(plan))
          now = DateTime.utc_now()
          plan = acknowledged_plan_for_approval!(lesson, plan, author, now)

          :ok =
            rollback_unless_ok(
              ensure_current_plan_approvable(lesson, plan, locked_run.plan_schema_version)
            )

          approved_lesson =
            lesson
            |> Lesson.changeset(%{
              status: "approved",
              approved_by_author_id: author.id,
              approved_at: now,
              planning_state: "completed",
              planning_error: nil,
              last_plan_version: plan.version,
              planning_finished_at: lesson.planning_finished_at || now
            })
            |> Repo.update!()

          plan
          |> LessonPlan.changeset(%{
            approved_by_user: true,
            approved_at: now,
            rejection_reason: nil
          })
          |> Repo.update!()

          transition = maybe_transition_to_compiling_locked(locked_run)

          {Repo.preload(approved_lesson, :plans, force: true), transition}
        end)

      case result do
        {:ok, {approved_lesson, {:transitioned, compiling_run}}} ->
          # The transition is committed with the final lesson approval while
          # holding the run lock, so a concurrent plan edit cannot invalidate
          # approval between the readiness check and this status change.
          after_transition({:ok, compiling_run})
          sync_review_counts(run.id)
          maybe_reconcile_parallel_review_progress(run.id)
          {:ok, approved_lesson}

        {:ok, {approved_lesson, :not_ready}} ->
          sync_review_counts(run.id)
          maybe_reconcile_parallel_review_progress(run.id)
          {:ok, approved_lesson}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp acknowledged_plan_for_approval!(lesson, plan, author, now) do
    source_context = lesson_source_context(lesson)

    exclusions =
      get_in(plan.content_payload, ["coverage_manifest", "excluded_blocks"])
      |> List.wrap()

    if Enum.any?(
         exclusions,
         &exclusion_needs_acknowledgement?(source_context, &1, plan.version)
       ) do
      version = next_plan_version(lesson.id)

      {acknowledged_exclusions, acknowledgements} =
        Enum.map_reduce(exclusions, [], fn exclusion, history ->
          if exclusion_needs_acknowledgement?(source_context, exclusion, plan.version) do
            acknowledgement = %{
              "exclusion_id" => exclusion["id"],
              "author_id" => author.id,
              "acknowledged_at" => DateTime.to_iso8601(now),
              "plan_version" => version,
              "reason" => exclusion["reason"]
            }

            updated =
              exclusion
              |> Map.put("author_acknowledged", true)
              |> Map.put("acknowledged_by_author_id", author.id)
              |> Map.put("acknowledged_at", DateTime.to_iso8601(now))
              |> Map.put("acknowledged_plan_version", version)

            {updated, history ++ [acknowledgement]}
          else
            {exclusion, history}
          end
        end)

      content_payload =
        put_in(
          plan.content_payload,
          ["coverage_manifest", "excluded_blocks"],
          acknowledged_exclusions
        )

      payload = %{
        "content_payload" => content_payload,
        "questions_payload" => plan.questions_payload
      }

      results = Checks.run(source_context, payload)

      acknowledged_plan =
        %LessonPlan{}
        |> LessonPlan.changeset(%{
          lesson_id: lesson.id,
          version: version,
          content_payload: content_payload,
          questions_payload: plan.questions_payload,
          generation_metadata: plan.generation_metadata,
          checks_snapshot: checks_snapshot(results),
          created_by: "author",
          approved_by_user: false,
          exclusion_acknowledgements: acknowledgements
        })
        |> Repo.insert!()

      persist_checks!(lesson.id, version, results)
      acknowledged_plan
    else
      plan
    end
  end

  defp exclusion_needs_acknowledgement?(source_context, exclusion, plan_version)
       when is_map(exclusion) do
    not FullSource.deterministic_exclusion?(source_context, exclusion) and
      (exclusion["author_acknowledged"] != true or
         not is_integer(exclusion["acknowledged_by_author_id"]) or
         not is_binary(exclusion["acknowledged_at"]) or
         exclusion["acknowledged_plan_version"] != plan_version)
  end

  defp exclusion_needs_acknowledgement?(_source_context, _exclusion, _plan_version), do: false

  defp ensure_current_plan_approvable(lesson, %LessonPlan{} = plan, 7) do
    quality_gate = get_in(plan.generation_metadata || %{}, ["quality_gate"]) || %{}
    coverage = plan.content_payload["coverage_manifest"] || %{}
    available = MapSet.new(List.wrap(coverage["available_source_block_ids"]))
    included = MapSet.new(List.wrap(coverage["included_source_block_ids"]))
    contract = {plan.content_payload["authoring_mode"], plan.content_payload["schema_version"]}

    cond do
      not ImportContract.current_content?(plan.content_payload) ->
        {:error, :plan_schema_version_mismatch}

      quality_gate["approved"] != true or numeric_confidence(quality_gate["confidence"]) < 0.9 ->
        {:error, :quality_gate_not_approved}

      List.wrap(quality_gate["hard_blockers"]) != [] ->
        {:error, :quality_hard_blockers}

      List.wrap(quality_gate["repairs"]) != [] ->
        {:error, :quality_repairs_pending}

      coverage["complete"] != true or available != included or
        List.wrap(coverage["missing_source_block_ids"]) != [] or
          List.wrap(coverage["duplicate_source_block_ids"]) != [] ->
        {:error, :source_coverage_incomplete}

      contract == {"advanced", 7} and List.wrap(plan.questions_payload["items"]) != [] ->
        {:error, :advanced_questions_must_be_single_sourced}

      true ->
        results =
          Checks.run(lesson_source_context(lesson), %{
            "content_payload" => plan.content_payload,
            "questions_payload" => plan.questions_payload,
            "generation_metadata" => plan.generation_metadata
          })

        if Checks.passed?(results), do: :ok, else: {:error, :quality_checks_failed}
    end
  end

  defp ensure_current_plan_approvable(_lesson, %LessonPlan{}, run_plan_schema_version),
    do: {:error, {:unsupported_openstax_plan_schema, run_plan_schema_version}}

  defp numeric_confidence(value) when is_integer(value), do: value / 1
  defp numeric_confidence(value) when is_float(value), do: value

  defp numeric_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      _ -> 0.0
    end
  end

  defp numeric_confidence(_value), do: 0.0

  @spec approve_all_lessons(Run.t() | Ecto.UUID.t(), Author.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def approve_all_lessons(%Run{id: run_id}, %Author{} = author),
    do: approve_all_lessons(run_id, author)

  def approve_all_lessons(run_id, %Author{} = author) do
    with true <- approve_all_lessons_enabled?(),
         {:ok, run} <- authorized_run(run_id, author) do
      result =
        Repo.transaction(fn ->
          locked_run = lock_run!(run.id)
          :ok = rollback_unless_ok(reauthorize_locked_run(locked_run, author))

          cond do
            locked_run.status == :compiling ->
              locked_run

            locked_run.status != :awaiting_lesson_approval ->
              Repo.rollback({:invalid_status, locked_run.status, :awaiting_lesson_approval})

            true ->
              lessons = lock_selected_lessons(locked_run.id)

              if lessons == [] do
                Repo.rollback(:no_lessons_to_approve)
              end

              :ok = rollback_unless_ok(Enrichment.ensure_generation_complete(locked_run.id))
              now = DateTime.utc_now()

              approvals =
                Enum.map(lessons, fn lesson ->
                  :ok = rollback_unless_ok(ensure_lesson_not_busy(lesson))
                  plan = latest_plan_or_nil(lesson.id) || Repo.rollback(:missing_lesson_plan)

                  if lesson.last_plan_version != plan.version do
                    Repo.rollback(:lesson_plan_version_stale)
                  end

                  :ok = rollback_unless_ok(ensure_plan_approvable(plan))
                  plan = acknowledged_plan_for_approval!(lesson, plan, author, now)

                  :ok =
                    rollback_unless_ok(
                      ensure_current_plan_approvable(
                        lesson,
                        plan,
                        locked_run.plan_schema_version
                      )
                    )

                  {lesson, plan}
                end)

              Enum.each(approvals, fn {lesson, plan} ->
                lesson
                |> Lesson.changeset(%{
                  status: "approved",
                  approved_by_author_id: author.id,
                  approved_at: now,
                  planning_state: "completed",
                  planning_error: nil,
                  last_plan_version: plan.version,
                  planning_finished_at: lesson.planning_finished_at || now
                })
                |> Repo.update!()

                plan
                |> LessonPlan.changeset(%{
                  approved_by_user: true,
                  approved_at: now,
                  rejection_reason: nil
                })
                |> Repo.update!()
              end)

              case maybe_transition_to_compiling_locked(locked_run) do
                {:transitioned, compiling_run} -> compiling_run
                :not_ready -> Repo.rollback(:lessons_pending_approval)
              end
          end
        end)

      case result do
        {:ok, compiling_run} ->
          with {:ok, updated_run} <- after_transition({:ok, compiling_run}),
               %Project{} = project <- Repo.get(Project, updated_run.project_id),
               {:ok, downstream_run} <- start_apply(project, updated_run.id, author) do
            sync_review_counts(run.id)
            maybe_reconcile_parallel_review_progress(run.id)
            {:ok, preload_run(downstream_run)}
          else
            nil -> {:error, :not_found}
            {:error, _reason} = error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :bulk_approval_disabled}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def approve_all_lessons_enabled? do
    Application.get_env(:oli, :env) in [:dev, :test] and
      Application.get_env(:oli, :openstax_course_import_approve_all_enabled, false) == true
  end

  defp reauthorize_locked_run(
         %Run{author_id: author_id} = run,
         %Author{id: author_id} = author
       ) do
    with :ok <- ensure_current_run_schema(run) do
      case Repo.get(Project, run.project_id) do
        %Project{} = project -> authorize_project(project, author)
        nil -> {:error, :not_found}
      end
    end
  end

  defp reauthorize_locked_run(_run, _author), do: {:error, :not_found}

  @spec reject_lesson(Ecto.UUID.t(), Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def reject_lesson(run_id, lesson_id, %Author{} = author, reason)
      when is_binary(reason) do
    reason = String.trim(reason)

    with false <- reason == "",
         {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval) do
      Repo.transaction(fn ->
        locked_run =
          Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))

        :ok = rollback_unless_ok(ensure_status(locked_run.status, :awaiting_lesson_approval))

        lesson =
          Repo.one(
            from(lesson in Lesson,
              where: lesson.id == ^lesson_id and lesson.run_id == ^locked_run.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        :ok = rollback_unless_ok(ensure_lesson_not_busy(lesson))
        plan = latest_plan_or_nil(lesson.id) || Repo.rollback(:missing_lesson_plan)

        rejected =
          lesson
          |> Lesson.changeset(%{
            status: "ready_for_review",
            approved_by_author_id: nil,
            approved_at: nil
          })
          |> Repo.update!()

        plan
        |> LessonPlan.changeset(%{
          approved_by_user: false,
          approved_at: nil,
          rejection_reason: reason
        })
        |> Repo.update!()

        Repo.preload(rejected, :plans, force: true)
      end)
      |> case do
        {:ok, rejected} ->
          sync_review_counts(run.id)
          {:ok, rejected}

        {:error, error} ->
          {:error, error}
      end
    else
      true -> {:error, :rejection_reason_required}
      {:error, _} = error -> error
    end
  end

  def reject_lesson(_, _, _, _), do: {:error, :invalid_input}

  @spec approve_enrichment_proposal(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def approve_enrichment_proposal(run_id, proposal_id, %Author{} = author)
      when is_binary(run_id) and is_binary(proposal_id) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id,
         :ok <- ensure_generated_proposal_available(run, proposal) do
      Enrichment.approve_proposal(proposal.id, author)
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def approve_enrichment_proposal(_, _, _), do: {:error, :invalid_input}

  @spec approve_enrichment_evidence(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          Author.t()
        ) :: {:ok, EnrichmentResearchSet.t()} | {:error, term()}
  def approve_enrichment_evidence(
        run_id,
        proposal_id,
        research_set_id,
        content_hash,
        %Author{} = author
      )
      when is_binary(run_id) and is_binary(proposal_id) and is_binary(research_set_id) and
             is_binary(content_hash) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id,
         :ok <- ensure_generated_proposal_enabled(run, proposal) do
      Enrichment.approve_evidence(proposal.id, research_set_id, content_hash, author)
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def approve_enrichment_evidence(_, _, _, _, _), do: {:error, :invalid_input}

  @spec reject_enrichment_evidence(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          Author.t(),
          String.t()
        ) :: {:ok, EnrichmentResearchSet.t()} | {:error, term()}
  def reject_enrichment_evidence(
        run_id,
        proposal_id,
        research_set_id,
        content_hash,
        %Author{} = author,
        reason
      )
      when is_binary(run_id) and is_binary(proposal_id) and is_binary(research_set_id) and
             is_binary(content_hash) and is_binary(reason) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id,
         :ok <- ensure_generated_proposal_enabled(run, proposal) do
      Enrichment.reject_evidence(proposal.id, research_set_id, content_hash, author, reason)
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def reject_enrichment_evidence(_, _, _, _, _, _), do: {:error, :invalid_input}

  @spec request_enrichment_research(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def request_enrichment_research(run_id, proposal_id, %Author{} = author)
      when is_binary(run_id) and is_binary(proposal_id) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         true <- enrichment_capabilities(run_project(run), run.ai_backend).research_available,
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <-
           proposal.run_id == run.id and
             proposal.state in [
               "proposed",
               "researching",
               "evidence_review",
               "designing",
               "artifact_review",
               "failed"
             ],
         true <- proposal.research_status != "running",
         {:ok, _job} <-
           Oban.insert(
             EnrichmentResearchWorker.new(%{
               "proposal_id" => proposal.id,
               "run_id" => run.id
             })
           ) do
      {:ok, proposal}
    else
      false -> {:error, :research_unavailable}
      {:error, _} = error -> error
    end
  end

  def request_enrichment_research(_, _, _), do: {:error, :invalid_input}

  @spec omit_enrichment_proposal(Ecto.UUID.t(), Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, EnrichmentProposal.t()} | {:error, term()}
  def omit_enrichment_proposal(
        run_id,
        proposal_id,
        author,
        reason \\ "Omitted during lesson review"
      )

  def omit_enrichment_proposal(run_id, proposal_id, %Author{} = author, reason)
      when is_binary(run_id) and is_binary(proposal_id) and is_binary(reason) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id,
         {:ok, omitted} <- Enrichment.omit_proposal(proposal.id, author, reason) do
      maybe_advance_after_enrichment_decision(run)
      {:ok, omitted}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def omit_enrichment_proposal(_, _, _, _), do: {:error, :invalid_input}

  @spec request_simulation_spec(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, SimulationSpec.t()} | {:error, term()}
  def request_simulation_spec(run_id, proposal_id, %Author{} = author)
      when is_binary(run_id) and is_binary(proposal_id) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id and proposal.state == "designing",
         :ok <- ensure_generated_proposal_enabled(run, proposal),
         false <- active_simulation_spec?(proposal.id) do
      case Repo.transaction(fn ->
             with {:ok, spec} <- Enrichment.begin_spec_generation(proposal.id),
                  {:ok, _job} <-
                    Oban.insert(
                      SimulationSpecGenerationWorker.new(%{
                        "spec_id" => spec.id,
                        "run_id" => run.id
                      })
                    ) do
               spec
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, spec} -> {:ok, spec}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :simulation_spec_generation_unavailable}
      true -> {:error, :simulation_spec_generation_in_progress}
      {:error, _} = error -> error
    end
  end

  def request_simulation_spec(_, _, _), do: {:error, :invalid_input}

  @spec request_simulation_generation(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          Author.t()
        ) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def request_simulation_generation(
        run_id,
        proposal_id,
        simulation_spec_id,
        simulation_spec_hash,
        %Author{} = author
      ) do
    request_simulation_generation(
      run_id,
      proposal_id,
      simulation_spec_id,
      simulation_spec_hash,
      nil,
      author
    )
  end

  def request_simulation_generation(_, _, _, _, _), do: {:error, :invalid_input}

  @spec request_simulation_generation(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t() | nil,
          Author.t()
        ) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def request_simulation_generation(
        run_id,
        proposal_id,
        simulation_spec_id,
        simulation_spec_hash,
        author_feedback,
        %Author{} = author
      )
      when is_binary(run_id) and is_binary(proposal_id) and is_binary(simulation_spec_id) and
             is_binary(simulation_spec_hash) do
    with {:ok, author_feedback} <- normalize_simulation_author_feedback(author_feedback),
         {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         true <- enrichment_capabilities(run_project(run), run.ai_backend).generated_available,
         {:ok, proposal} <- Enrichment.fetch_proposal(proposal_id),
         true <- proposal.run_id == run.id,
         true <-
           proposal.kind == "generated_simulation" and
             proposal.state in ["designing", "artifact_review"],
         false <- active_simulation_artifact?(proposal.id) do
      case Repo.transaction(fn ->
             with {:ok, artifact} <-
                    Enrichment.begin_artifact_generation(proposal.id, %{
                      simulation_spec_id: simulation_spec_id,
                      simulation_spec_hash: simulation_spec_hash,
                      generation_metadata: simulation_generation_metadata(author_feedback)
                    }),
                  {:ok, _job} <-
                    Oban.insert(
                      SimulationGenerationWorker.new(%{
                        "artifact_id" => artifact.id,
                        "run_id" => run.id
                      })
                    ) do
               artifact
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, artifact} -> {:ok, artifact}
        {:error, reason} -> {:error, reason}
      end
    else
      false ->
        {:error, :simulation_generation_unavailable}

      true ->
        {:error, :simulation_generation_in_progress}

      {:error, _reason} = error ->
        error
    end
  end

  def request_simulation_generation(_, _, _, _, _, _), do: {:error, :invalid_input}

  @spec approve_simulation_artifact(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          String.t(),
          Author.t()
        ) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def approve_simulation_artifact(run_id, artifact_id, version, content_hash, %Author{} = author)
      when is_binary(run_id) and is_binary(artifact_id) and is_integer(version) and version > 0 and
             is_binary(content_hash) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         %SimulationArtifact{run_id: ^run_id} <- Repo.get(SimulationArtifact, artifact_id),
         {:ok, artifact} <-
           Enrichment.approve_artifact(artifact_id, version, content_hash, author) do
      maybe_advance_after_enrichment_decision(run)
      {:ok, artifact}
    else
      nil -> {:error, :not_found}
      %SimulationArtifact{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def approve_simulation_artifact(_, _, _, _, _), do: {:error, :invalid_input}

  @spec reject_simulation_artifact(Ecto.UUID.t(), Ecto.UUID.t(), Author.t(), String.t()) ::
          {:ok, SimulationArtifact.t()} | {:error, term()}
  def reject_simulation_artifact(run_id, artifact_id, %Author{} = author, reason)
      when is_binary(run_id) and is_binary(artifact_id) and is_binary(reason) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval),
         %SimulationArtifact{run_id: ^run_id} <- Repo.get(SimulationArtifact, artifact_id) do
      Enrichment.reject_artifact(artifact_id, author, reason)
    else
      nil -> {:error, :not_found}
      %SimulationArtifact{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def reject_simulation_artifact(_, _, _, _), do: {:error, :invalid_input}

  @spec regenerate_lesson(Ecto.UUID.t(), Ecto.UUID.t(), Author.t()) ::
          {:ok, Lesson.t()} | {:error, term()}
  def regenerate_lesson(run_id, lesson_id, %Author{} = author) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval) do
      enqueue_lesson_regeneration(run, lesson_id)
    end
  end

  @spec regenerate_blocked_lessons(Ecto.UUID.t(), Author.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def regenerate_blocked_lessons(run_id, %Author{} = author) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :awaiting_lesson_approval) do
      lessons =
        Repo.all(
          from(lesson in Lesson,
            join: unit in Unit,
            on: unit.id == lesson.unit_id,
            where: lesson.run_id == ^run.id and lesson.selected == true,
            order_by: [asc: unit.order, asc: lesson.order, asc: lesson.id],
            select: lesson
          )
        )

      blocked_lessons =
        Enum.filter(lessons, fn lesson ->
          not lesson_planning_busy?(lesson) and lesson_requires_regeneration?(lesson, run)
        end)

      case blocked_lessons do
        [] ->
          {:error, :no_blocked_lessons_to_repair}

        lessons ->
          Enum.reduce_while(lessons, {:ok, 0}, fn lesson, {:ok, count} ->
            case enqueue_lesson_regeneration(run, lesson.id) do
              {:ok, _lesson} -> {:cont, {:ok, count + 1}}
              {:error, reason} -> {:halt, {:error, {:bulk_lesson_repair_failed, count, reason}}}
            end
          end)
      end
    end
  end

  defp lesson_requires_regeneration?(lesson, run) do
    case latest_plan_or_nil(lesson.id) do
      %LessonPlan{} = plan ->
        lesson.status in ["needs_attention", "needs_repair", "failed"] or
          plan.rejection_reason not in [nil, ""] or
          ensure_current_plan_approvable(lesson, plan, run.plan_schema_version) != :ok

      nil ->
        false
    end
  end

  defp lesson_planning_busy?(lesson),
    do: lesson.planning_state in @unfinished_lesson_planning_states

  @spec cancel_run(Ecto.UUID.t(), Author.t()) :: {:ok, Run.t()} | {:error, term()}
  def cancel_run(run_id, %Author{} = author) do
    with {:ok, run} <- authorized_run(run_id, author),
         true <- run.status in @active_statuses do
      case cancel_run_with_planning_fence(run.id) do
        {:ok, cancelled} ->
          cancel_background_jobs(cancelled.id)
          {:ok, cancelled}

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :not_cancellable}
      {:error, _} = error -> error
    end
  end

  @spec retry_run(Ecto.UUID.t(), Author.t()) :: {:ok, Run.t()} | {:error, term()}
  def retry_run(run_id, %Author{} = author) do
    with {:ok, run} <- authorized_run(run_id, author),
         :ok <- ensure_status(run.status, :failed) do
      case failure_phase(run) do
        phase when phase in ["lesson_planning", "checks"] ->
          retry_parallel_lesson_planning(run)

        _other ->
          with {:ok, target_status, job} <- retry_target(run) do
            force_status_with_job(run, target_status, job)
          end
      end
    end
  end

  @spec start_apply(Project.t(), Run.t() | Ecto.UUID.t(), Author.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def start_apply(%Project{} = project, %Run{id: run_id}, %Author{} = author),
    do: start_apply(project, run_id, author)

  def start_apply(%Project{} = project, run_id, %Author{} = author)
      when is_binary(run_id) do
    with {:ok, run} <- get_run(project, author, run_id),
         :ok <- ensure_status(run.status, :compiling),
         true <- all_lessons_approved?(run.id),
         :ok <- Enrichment.ensure_generation_complete(run.id),
         :ok <- ensure_project_root_empty(project, run.target_root_container_resource_id) do
      planned_media_ids = planned_required_media_ids(run)

      with {:ok, discovery_media_urls} <-
             MediaIngestor.discovery_media_urls(run.id, planned_media_ids),
           {:ok, dry_run} <-
             Compiler.dry_run(run,
               media_urls: discovery_media_urls,
               attribution: source_attribution(run),
               generated_simulation_delivery_enabled:
                 enrichment_capabilities(project, run.ai_backend).delivery_available
             ),
           compiled_media_ids <- MediaIngestor.required_media_ids(dry_run),
           true <- compiled_media_ids == planned_media_ids,
           {:ok, _selected_assets} <-
             MediaIngestor.select_required_assets(run.id, compiled_media_ids) do
        required_media_ids = compiled_media_ids

        checkpoint = %{
          "schema_version" => 1,
          "required_media_ids" => required_media_ids,
          "approved_plan_digest" => approved_plan_digest(run)
        }

        attrs = %{
          error: nil,
          progress:
            merge_progress(run.progress, %{
              "counts" => %{"source_assets_required" => length(required_media_ids)}
            }),
          result:
            (run.result || %{})
            |> Map.put("compile_checkpoint", checkpoint)
            |> maybe_put_final_dry_run(required_media_ids, dry_run)
        }

        case required_media_ids do
          [] ->
            transition_with_job(
              run,
              :applying,
              attrs,
              ApplyWorker.new(%{"run_id" => run.id})
            )

          _ids ->
            transition_with_job(
              run,
              :staging_media,
              attrs,
              MediaWorker.new(%{"run_id" => run.id})
            )
        end
      else
        false ->
          return_compile_failure_to_review(run, :required_media_selection_changed)

        {:error, reason} ->
          return_compile_failure_to_review(run, reason)
      end
    else
      false -> {:error, :lessons_pending_approval}
      {:error, _} = error -> error
    end
  end

  @spec transition_run(Ecto.UUID.t(), Run.status()) :: {:ok, Run.t()} | {:error, term()}
  def transition_run(run_id, next_status), do: transition_run(run_id, next_status, %{})

  @spec transition_run(Ecto.UUID.t(), Run.status(), map()) ::
          {:ok, Run.t()} | {:error, term()}
  def transition_run(run_id, next_status, attrs) when is_binary(run_id) and is_map(attrs) do
    result =
      Repo.transaction(fn ->
        run = Repo.one(from(r in Run, where: r.id == ^run_id, lock: "FOR UPDATE"))

        with %Run{} <- run,
             :ok <- ensure_transition_allowed(run.status, next_status),
             {:ok, updated} <-
               run
               |> Run.update_changeset(transition_attrs(run, next_status, attrs))
               |> Repo.update(),
             :ok <- Outbox.persist(updated) do
          updated
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  @spec fetch_run(Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def fetch_run(run_id) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  def fetch_run(_), do: {:error, :not_found}

  @doc false
  def compile_checkpoint(%Run{} = run) do
    case get_in(run.result || %{}, ["compile_checkpoint"]) do
      %{
        "required_media_ids" => ids,
        "approved_plan_digest" => digest
      } = checkpoint
      when is_list(ids) and is_binary(digest) ->
        if digest == approved_plan_digest(preload_run(run)),
          do: {:ok, checkpoint},
          else: {:error, :stale_compile_checkpoint}

      _ ->
        {:error, :missing_compile_checkpoint}
    end
  end

  @doc false
  def source_attribution(%Run{} = run) do
    persisted =
      case RichSource.load_run_corpus(run.id) do
        {:ok, %{attribution: attribution}} when is_map(attribution) -> attribution
        _ -> %{}
      end

    persisted
    |> stringify_keys()
    |> Map.put_new("source_provider", "OpenStax")
    |> Map.put_new(
      "source_title",
      get_in(run.preflight_snapshot || %{}, ["title"]) || run.book_slug
    )
    |> Map.put_new(
      "book_title",
      get_in(run.preflight_snapshot || %{}, ["title"]) || run.book_slug
    )
    |> Map.put_new("source_url", run.source_url)
    |> Map.put_new("license", "CC BY 4.0")
    |> Map.put_new("license_type", "cc_by")
    |> Map.put_new("license_url", "https://creativecommons.org/licenses/by/4.0/")
  end

  @doc false
  def finish_media_staging(%Run{} = run, compiled) when is_map(compiled) do
    transition_with_job(
      run,
      :applying,
      %{
        error: nil,
        result:
          (run.result || %{})
          |> Map.put("dry_run", compiled)
          |> Map.put("media_staged_at", DateTime.to_iso8601(DateTime.utc_now()))
      },
      ApplyWorker.new(%{"run_id" => run.id})
    )
  end

  @doc false
  def return_media_failure_to_review(run_id, reason) do
    result =
      Repo.transaction(fn ->
        run =
          Repo.one(from(candidate in Run, where: candidate.id == ^run_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:not_found)

        :ok = rollback_unless_ok(ensure_status(run.status, :staging_media))

        required_ids =
          get_in(run.result || %{}, ["compile_checkpoint", "required_media_ids"]) || []

        affected_lesson_ids = lessons_referencing_media(run.id, required_ids)

        Repo.update_all(
          from(asset in SourceAsset, where: asset.run_id == ^run.id),
          set: [required: false, updated_at: DateTime.utc_now()]
        )

        Repo.update_all(
          from(lesson in Lesson,
            where: lesson.id in ^affected_lesson_ids
          ),
          set: [
            status: "needs_attention",
            approved_by_author_id: nil,
            approved_at: nil,
            updated_at: DateTime.utc_now()
          ]
        )

        Repo.update_all(
          from(plan in LessonPlan,
            where: plan.lesson_id in ^affected_lesson_ids and plan.approved_by_user == true
          ),
          set: [approved_by_user: false, approved_at: nil, updated_at: DateTime.utc_now()]
        )

        error = %{
          "phase" => "media_staging",
          "reason" => inspect(reason),
          "message" =>
            "One or more selected OpenStax images could not be safely imported. Edit or regenerate the affected lesson to remove or replace that media.",
          "recoverable" => true,
          "source_media_ids" => required_ids
        }

        with {:ok, updated} <-
               run
               |> Run.update_changeset(
                 transition_attrs(run, :awaiting_lesson_approval, %{
                   error: error,
                   result: Map.drop(run.result || %{}, ["compile_checkpoint", "dry_run"])
                 })
               )
               |> Repo.update(),
             :ok <- Outbox.persist(updated) do
          updated
        else
          {:error, transition_reason} -> Repo.rollback(transition_reason)
        end
      end)

    after_transition(result)
  end

  @doc false
  def persist_scope_snapshot(run_id, snapshot) when is_map(snapshot) do
    {chapters, selected_ids} = initial_or_stored_scope_selection(run_id, snapshot)

    update_run_if_status(run_id, :preflighting, %{
      preflight_snapshot: Map.put(snapshot, "chapters", chapters),
      scope_manifest: %{
        "book_slug" => snapshot["book_slug"],
        "title" => snapshot["title"],
        "chapters" => chapters,
        "selected_chapter_ids" => selected_ids
      },
      progress: %{
        "stage" => "preflighting",
        "stage_totals" => [
          %{
            "label" => "Chapters discovered",
            "completed" => length(chapters),
            "total" => length(chapters)
          }
        ]
      }
    })
  end

  defp initial_or_stored_scope_selection(run_id, snapshot) do
    discovered = Map.get(snapshot, "chapters", [])

    stored_selection =
      case Repo.get(Run, run_id) do
        %Run{scope_manifest: manifest} when is_map(manifest) ->
          if Map.has_key?(manifest, "selected_chapter_ids") do
            {:stored, List.wrap(manifest["selected_chapter_ids"])}
          else
            :initial
          end

        _ ->
          :initial
      end

    selected_ids =
      case stored_selection do
        {:stored, ids} ->
          ids

        :initial ->
          if test_conveniences_enabled?(),
            do: [],
            else: Enum.map(discovered, & &1["id"])
      end

    selected_set = MapSet.new(selected_ids)

    chapters =
      Enum.map(discovered, fn chapter ->
        Map.put(chapter, "selected", MapSet.member?(selected_set, chapter["id"]))
      end)

    discovered_ids = MapSet.new(chapters, & &1["id"])
    selected_ids = Enum.filter(selected_ids, &MapSet.member?(discovered_ids, &1))

    {chapters, selected_ids}
  end

  @doc false
  def persist_ingested_snapshot(run_id, snapshot) when is_map(snapshot) do
    case Repo.get(Run, run_id) do
      %Run{source_schema_version: @source_schema_version} ->
        persist_rich_ingested_snapshot(run_id, snapshot)

      %Run{source_schema_version: version} ->
        {:error, {:unsupported_openstax_source_schema, version}}

      nil ->
        {:error, :not_found}
    end
  end

  defp persist_rich_ingested_snapshot(run_id, snapshot) do
    chapters = Map.get(snapshot, "chapters", [])
    compact_snapshot = RichSource.compact_snapshot(snapshot)
    compact_chapters = Map.get(compact_snapshot, "chapters", [])

    with {:ok, corpus_counts} <- RichSource.persist_snapshot(run_id, snapshot) do
      update_run_if_status(run_id, :ingesting, %{
        preflight_snapshot: compact_snapshot,
        scope_manifest: %{
          "book_slug" => snapshot["book_slug"],
          "title" => snapshot["title"],
          "chapters" => Enum.map(compact_chapters, &Map.put(&1, "selected", true)),
          "selected_chapter_ids" => snapshot["selected_chapter_ids"] || []
        },
        progress: %{
          "stage" => "ingesting",
          "counts" => %{
            "sections_extracted" => corpus_counts.sections,
            "source_blocks_extracted" => corpus_counts.blocks,
            "source_assets_discovered" => corpus_counts.assets
          },
          "stage_totals" => [
            %{
              "label" => "Chapters read",
              "completed" => length(chapters),
              "total" => length(chapters)
            },
            %{
              "label" => "Sections retained",
              "completed" => corpus_counts.sections,
              "total" => count_snapshot_sections(chapters)
            },
            %{
              "label" => "Source blocks retained",
              "completed" => corpus_counts.blocks,
              "total" => corpus_counts.blocks
            }
          ]
        }
      })
    end
  end

  @doc false
  def persist_source_corpus(run_id, snapshot), do: RichSource.persist_snapshot(run_id, snapshot)

  @doc false
  def load_source_snapshot(run_id, base_snapshot \\ %{}),
    do: RichSource.load_snapshot(run_id, base_snapshot)

  @doc false
  def load_source_corpus(run_id), do: RichSource.load_run_corpus(run_id)

  @doc false
  def load_lesson_source_corpus(lesson_id), do: RichSource.load_lesson_corpus(lesson_id)

  @doc false
  def link_lesson_sources(run_id), do: RichSource.link_lessons(run_id)

  @doc false
  def rich_content_versions(%Project{}),
    do: {ImportContract.source_schema_version(), ImportContract.plan_schema_version()}

  @doc false
  def advanced_enabled?(%Project{}) do
    Application.get_env(:oli, :openstax_advanced_pages_enabled, true)
  end

  @doc false
  def initialize_parallel_lesson_planning(run_id, generation)
      when is_binary(run_id) and is_integer(generation) and generation > 0 do
    result =
      Repo.transaction(fn ->
        run = lock_run!(run_id)
        :ok = rollback_unless_ok(ensure_parallel_generation(run, generation, [:planning_lessons]))

        lessons = lock_selected_lessons(run.id)

        if lessons == [] do
          Repo.rollback(:no_lessons_to_plan)
        end

        now = DateTime.utc_now()

        lessons
        |> Enum.with_index(1)
        |> Enum.each(fn {lesson, position} ->
          attrs =
            if lesson.last_plan_version > 0 do
              completed_planning_attrs(lesson, generation, position, now)
            else
              pending_planning_attrs(lesson, generation, position, "initial", now)
            end

          lesson
          |> Lesson.changeset(attrs)
          |> Repo.update!()
        end)

        reconcile_lesson_planning_locked(run, generation, now)
      end)

    announce_parallel_result(result)
  end

  def initialize_parallel_lesson_planning(_run_id, _generation),
    do: {:error, :invalid_lesson_planning_generation}

  @doc false
  def claim_lesson_plan_job(args, attempt, job_id)
      when is_map(args) and is_integer(attempt) and attempt > 0 and is_integer(job_id) do
    with {:ok, job_args} <- normalize_lesson_job_args(args) do
      result =
        Repo.transaction(fn ->
          run = lock_run!(job_args.run_id)

          :ok =
            rollback_unless_ok(
              ensure_parallel_generation(
                run,
                job_args.generation,
                planning_statuses(job_args.operation)
              )
            )

          lesson = lock_lesson!(job_args.lesson_id, run.id)

          cond do
            lesson.planning_request_id != job_args.request_id or
                lesson.planning_generation != job_args.generation ->
              Repo.rollback(:stale_lesson_planning_job)

            lesson.planning_state == "completed" ->
              {:already_completed, run}

            lesson.planning_oban_job_id != job_id ->
              Repo.rollback(:stale_lesson_planning_job)

            lesson.planning_state not in ["queued", "running", "retrying"] ->
              Repo.rollback(:stale_lesson_planning_job)

            job_args.operation == "regenerate" and
                lesson.last_plan_version != job_args.base_plan_version ->
              Repo.rollback(:stale_lesson_planning_job)

            true ->
              now = DateTime.utc_now()

              claimed =
                lesson
                |> Lesson.changeset(%{
                  planning_state: "running",
                  planning_attempts: max(lesson.planning_attempts, attempt),
                  planning_started_at: lesson.planning_started_at || now,
                  planning_last_progress_at: now,
                  planning_error: nil
                })
                |> Repo.update!()

              %{run: updated_run} =
                reconciliation =
                reconcile_lesson_planning_locked(run, job_args.generation, now)

              {:claimed, claimed, updated_run, reconciliation}
          end
        end)

      case result do
        {:ok, {:already_completed, _run}} ->
          {:ok, :already_completed}

        {:ok, {:claimed, lesson, run, _reconciliation}} ->
          source = lesson_source_map(lesson)
          project = Repo.get(Project, run.project_id)

          with :ok <- ensure_usable_lesson_source(run, source) do
            PubSub.broadcast(run)

            Telemetry.lesson_job_started(
              run.id,
              lesson.id,
              lesson.planning_attempts,
              if(lesson.planning_attempts == 1,
                do: duration_seconds(lesson.planning_queued_at, lesson.planning_started_at),
                else: nil
              )
            )

            {:ok,
             %{
               source: source,
               lesson_id: lesson.id,
               run_id: run.id,
               planning_request_id: lesson.planning_request_id,
               project_id: run.project_id,
               author_id: run.author_id,
               generation_checkpoint: lesson.generation_checkpoint || %{},
               objective_ledger:
                 approved_objective_ledger(run.id, lesson.planning_position || job_args.position),
               planning_position: lesson.planning_position || job_args.position,
               plan_schema_version: run.plan_schema_version,
               ai_backend: AIBackend.backend(run),
               advanced_enabled: not is_nil(project) and advanced_enabled?(project)
             }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def claim_lesson_plan_job(_args, _attempt, _job_id), do: {:error, :invalid_lesson_job}

  @doc false
  def persist_lesson_generation_checkpoint(args, stage, payload)
      when is_map(args) and is_binary(stage) and is_map(payload) do
    with {:ok, job_args} <- normalize_lesson_job_args(args) do
      Repo.transaction(fn ->
        run = lock_run!(job_args.run_id)

        :ok =
          rollback_unless_ok(
            ensure_parallel_generation(
              run,
              job_args.generation,
              planning_statuses(job_args.operation)
            )
          )

        lesson = lock_lesson!(job_args.lesson_id, run.id)

        if lesson.planning_request_id != job_args.request_id or
             lesson.planning_generation != job_args.generation do
          Repo.rollback(:stale_lesson_planning_job)
        end

        checkpoint = %{
          "request_id" => job_args.request_id,
          "stage" => stage,
          "payload" => payload,
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        lesson
        |> Lesson.changeset(%{
          generation_checkpoint: checkpoint,
          planning_last_progress_at: DateTime.utc_now()
        })
        |> Repo.update!()

        checkpoint
      end)
    end
  end

  def persist_lesson_generation_checkpoint(_args, _stage, _payload),
    do: {:error, :invalid_generation_checkpoint}

  @doc false
  def approved_objective_ledger(run_id, planning_position)
      when is_binary(run_id) and is_integer(planning_position) and planning_position > 0 do
    Lesson
    |> where(
      [lesson],
      lesson.run_id == ^run_id and lesson.selected == true and
        lesson.planning_position < ^planning_position
    )
    |> order_by([lesson], asc: lesson.planning_position)
    |> Repo.all()
    |> Enum.flat_map(&lesson_objective_ledger_entries/1)
  end

  def approved_objective_ledger(_run_id, _planning_position), do: []

  defp lesson_objective_ledger_entries(%Lesson{} = lesson) do
    checkpoint = lesson.generation_checkpoint || %{}
    stage = checkpoint["stage"]
    checkpoint_payload = checkpoint["payload"] || %{}

    content =
      cond do
        stage in ["content_approved", "questions_approved", "completed"] ->
          checkpoint_payload["content_payload"] || %{}

        true ->
          case latest_plan_or_nil(lesson.id) do
            %LessonPlan{} = plan ->
              if get_in(plan.generation_metadata || %{}, ["quality_gate", "approved"]) == true,
                do: plan.content_payload || %{},
                else: %{}

            nil ->
              %{}
          end
      end

    evidence_ids =
      content
      |> Map.get("source_block_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    content
    |> Map.get("learning_objectives", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {objective, index} ->
      %{
        "id" => "#{lesson.id}:objective-#{index}",
        "text" => objective,
        "lesson_id" => lesson.id,
        "lesson_title" => lesson.title,
        "planning_position" => lesson.planning_position,
        "evidence_block_ids" => evidence_ids
      }
    end)
  end

  @doc false
  def complete_lesson_plan_job(
        args,
        %{plan_mode: plan_mode, payload: payload, created_by: created_by} = planning_result
      )
      when is_map(args) and is_map(payload) do
    enrichment_proposals = Map.get(planning_result, :enrichment_proposals, [])
    generation_metadata = Map.get(planning_result, :metadata, %{})

    with {:ok, job_args} <- normalize_lesson_job_args(args),
         :ok <- validate_plan_mode(plan_mode) do
      result =
        Repo.transaction(fn ->
          run = lock_run!(job_args.run_id)

          :ok =
            rollback_unless_ok(
              ensure_parallel_generation(
                run,
                job_args.generation,
                planning_statuses(job_args.operation)
              )
            )

          lesson = lock_lesson!(job_args.lesson_id, run.id)

          cond do
            lesson.planning_request_id != job_args.request_id or
                lesson.planning_generation != job_args.generation ->
              Repo.rollback(:stale_lesson_planning_job)

            lesson.planning_state == "completed" ->
              {Repo.preload(lesson, :plans, force: true), run, false, false}

            lesson.planning_state not in ["queued", "running", "retrying"] ->
              Repo.rollback(:stale_lesson_planning_job)

            job_args.operation == "regenerate" and
                lesson.last_plan_version != job_args.base_plan_version ->
              Repo.rollback(:stale_lesson_planning_job)

            true ->
              existing = latest_plan_or_nil(lesson.id)

              {planned_lesson, persisted?} =
                if job_args.operation == "initial" and not is_nil(existing) do
                  {Repo.preload(lesson, :plans, force: true), false}
                else
                  payload = Map.put(payload, "generation_metadata", generation_metadata)

                  {:ok, payload} =
                    sync_planned_enrichments(
                      run,
                      lesson,
                      payload,
                      enrichment_proposals
                    )

                  {
                    persist_locked_lesson_plan(
                      lesson,
                      existing,
                      payload,
                      plan_mode,
                      created_by,
                      plan_mode == "advanced",
                      run.plan_schema_version
                    ),
                    true
                  }
                end

              now = DateTime.utc_now()

              completed =
                planned_lesson
                |> Lesson.changeset(%{
                  planning_state: "completed",
                  planning_attempts: max(planned_lesson.planning_attempts, 1),
                  planning_last_progress_at: now,
                  planning_finished_at: now,
                  planning_error: nil,
                  generation_checkpoint:
                    completed_generation_checkpoint(planned_lesson.generation_checkpoint, now)
                })
                |> Repo.update!()
                |> Repo.preload(:plans, force: true)

              run = maybe_update_latest_plan_version_locked(run, completed.last_plan_version)
              duration = duration_seconds(completed.planning_started_at, now)

              reconciliation =
                reconcile_lesson_planning_locked(run, job_args.generation, now, duration)

              {completed, reconciliation.run, reconciliation.terminal?, persisted?}
          end
        end)

      case result do
        {:ok, {lesson, run, terminal?, persisted?}} ->
          announce_parallel_run(run, terminal?)

          if persisted? do
            case latest_plan_or_nil(lesson.id) do
              %LessonPlan{} = plan ->
                Telemetry.plan_checked(run.id, lesson.id, plan, plan.created_by == "system")

              nil ->
                :ok
            end

            Telemetry.lesson_job_completed(
              run.id,
              lesson.id,
              lesson.planning_attempts,
              duration_seconds(lesson.planning_started_at, lesson.planning_finished_at)
            )
          end

          {:ok, lesson, run}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def complete_lesson_plan_job(_args, _result), do: {:error, :invalid_lesson_plan_result}

  defp completed_generation_checkpoint(checkpoint, now) when is_map(checkpoint) do
    checkpoint
    |> Map.put("stage", "completed")
    |> Map.put("updated_at", DateTime.to_iso8601(now))
  end

  defp completed_generation_checkpoint(_checkpoint, _now), do: %{}

  @doc false
  def retry_lesson_plan_job(args, attempt, category)
      when is_map(args) and is_integer(attempt) and attempt > 0 and is_atom(category) do
    retry_lesson_plan_job(args, attempt, category, %{})
  end

  @doc false
  def retry_lesson_plan_job(args, attempt, category, details)
      when is_map(args) and is_integer(attempt) and attempt > 0 and is_atom(category) and
             is_map(details) do
    update_lesson_plan_job_failure(args, attempt, category, "retrying", details)
  end

  @doc false
  def fail_lesson_plan_job(args, attempt, category)
      when is_map(args) and is_integer(attempt) and attempt > 0 and is_atom(category) do
    fail_lesson_plan_job(args, attempt, category, %{})
  end

  @doc false
  def fail_lesson_plan_job(args, attempt, category, details)
      when is_map(args) and is_integer(attempt) and attempt > 0 and is_atom(category) and
             is_map(details) do
    update_lesson_plan_job_failure(args, attempt, category, "failed", details)
  end

  @doc false
  def reconcile_lesson_planning(run_id, generation)
      when is_binary(run_id) and is_integer(generation) and generation > 0 do
    result =
      Repo.transaction(fn ->
        run = lock_run!(run_id)

        :ok =
          rollback_unless_ok(
            ensure_parallel_generation(
              run,
              generation,
              [:planning_lessons, :awaiting_lesson_approval]
            )
          )

        reconcile_lesson_planning_locked(run, generation, DateTime.utc_now())
      end)

    announce_parallel_result(result)
  end

  def reconcile_lesson_planning(_run_id, _generation),
    do: {:error, :invalid_lesson_planning_generation}

  @doc false
  def recover_parallel_lesson_planning(run_id, generation)
      when is_binary(run_id) and is_integer(generation) and generation > 0 do
    result =
      Repo.transaction(fn ->
        run = lock_run!(run_id)

        :ok =
          rollback_unless_ok(
            ensure_parallel_generation(
              run,
              generation,
              [:planning_lessons, :awaiting_lesson_approval]
            )
          )

        now = DateTime.utc_now()

        recovered_failures =
          run.id
          |> lock_selected_lessons()
          |> Enum.filter(
            &(&1.planning_generation == generation and
                &1.planning_state in @active_lesson_planning_states)
          )
          |> Enum.map(&recover_lesson_job_locked(&1, now))
          |> Enum.reject(&is_nil/1)

        run
        |> reconcile_lesson_planning_locked(generation, now)
        |> Map.put(:recovered_failures, recovered_failures)
      end)

    announce_parallel_result(result)
  end

  def recover_parallel_lesson_planning(_run_id, _generation),
    do: {:error, :invalid_lesson_planning_generation}

  @doc false
  def set_progress(run_id, progress, expected_status \\ nil)

  def set_progress(run_id, progress, expected_status) when is_map(progress) do
    result =
      Repo.transaction(fn ->
        run =
          Repo.one(
            from(run in Run,
              where: run.id == ^run_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        allowed_statuses =
          if is_nil(expected_status), do: @active_statuses, else: [expected_status]

        if run.status in allowed_statuses do
          merged =
            run.progress
            |> merge_progress(progress)
            |> Map.put("stage", Atom.to_string(run.status))
            |> touch_progress_timing(run, DateTime.utc_now())

          run
          |> Run.update_changeset(%{progress: merged})
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          expected = if is_nil(expected_status), do: @active_statuses, else: expected_status
          Repo.rollback({:invalid_status, run.status, expected})
        end
      end)

    case result do
      {:ok, updated} ->
        PubSub.broadcast(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def upsert_units_and_lessons(run_id, %{"units" => units} = outline)
      when is_list(units) do
    result =
      Repo.transaction(fn ->
        run =
          Repo.one!(
            from(r in Run,
              where: r.id == ^run_id,
              lock: "FOR UPDATE"
            )
          )

        :ok = rollback_unless_ok(ensure_status(run.status, :planning_outline))
        Repo.delete_all(from(unit in Unit, where: unit.run_id == ^run_id))

        persisted =
          units
          |> Enum.map(fn unit_spec ->
            lessons = unit_spec["lessons"] || []

            unit =
              %Unit{}
              |> Unit.changeset(%{
                run_id: run.id,
                unit_name: unit_spec["unit_name"],
                order: unit_spec["order"],
                source_reference: unit_spec["source_reference"] || %{},
                status: "ready_for_review",
                source_sections_count:
                  Enum.reduce(
                    lessons,
                    0,
                    &(&2 + length(&1["source_sections"] || []))
                  ),
                plan_payload: %{
                  "source_title" => outline["title"],
                  "lesson_count" => length(lessons)
                },
                assessment_payload: %{},
                selected: true
              })
              |> Repo.insert!()

            Enum.each(lessons, fn lesson_spec ->
              %Lesson{}
              |> Lesson.changeset(%{
                run_id: run.id,
                unit_id: unit.id,
                order: lesson_spec["order"],
                title: lesson_spec["title"],
                source_sections: lesson_spec["source_sections"] || [],
                source_objectives: lesson_spec["source_objectives"] || [],
                plan_mode: "basic",
                status: "pending",
                last_plan_version: 0,
                source_excerpt: lesson_spec["source_excerpt"],
                source_evidence_links: lesson_spec["source_evidence_links"] || [],
                source_word_count: lesson_spec["source_word_count"] || 0,
                source_coverage: lesson_spec["source_coverage"] || %{},
                selected: true
              })
              |> Repo.insert!()
            end)

            unit
          end)

        persisted
      end)

    case result do
      {:ok, persisted} ->
        with {:ok, _linked_count} <- maybe_link_lesson_sources(run_id),
             {:ok, _run} <-
               set_progress(
                 run_id,
                 %{
                   "stage" => "planning_outline",
                   "counts" => %{
                     "lessons_outlined" =>
                       Enum.reduce(units, 0, &(&2 + length(&1["lessons"] || [])))
                   },
                   "stage_totals" => [
                     %{
                       "label" => "Units planned",
                       "completed" => length(persisted),
                       "total" => length(persisted)
                     },
                     %{
                       "label" => "Lessons outlined",
                       "completed" => Enum.reduce(units, 0, &(&2 + length(&1["lessons"] || []))),
                       "total" => Enum.reduce(units, 0, &(&2 + length(&1["lessons"] || [])))
                     }
                   ]
                 },
                 :planning_outline
               ) do
          {:ok, persisted}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:outline_persistence_failed, Exception.message(exception)}}
  end

  @doc false
  def finalize_lesson_planning(run_id) when is_binary(run_id) do
    result =
      Repo.transaction(fn ->
        run =
          Repo.one(
            from(candidate in Run,
              where: candidate.id == ^run_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        with :ok <- ensure_status(run.status, :planning_lessons),
             :ok <- ensure_transition_allowed(run.status, :awaiting_lesson_approval) do
          latest_plan_version =
            Repo.one(
              from(lesson in Lesson,
                where: lesson.run_id == ^run_id and lesson.selected == true,
                select: coalesce(max(lesson.last_plan_version), 0)
              )
            )

          Repo.update_all(
            from(unit in Unit, where: unit.run_id == ^run_id),
            set: [status: "ready_for_review"]
          )

          with {:ok, updated} <-
                 run
                 |> Run.update_changeset(
                   transition_attrs(run, :awaiting_lesson_approval, %{
                     latest_plan_version: latest_plan_version
                   })
                 )
                 |> Repo.update(),
               :ok <- Outbox.persist(updated) do
            updated
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  def finalize_lesson_planning(_), do: {:error, :invalid_input}

  @doc false
  def run_with_resources(run_id) do
    with {:ok, run} <- fetch_run(run_id), do: {:ok, preload_run(run)}
  end

  @doc false
  def mark_failed(run_id, phase, reason) do
    error = failure_payload(phase, reason)

    case fetch_run(run_id) do
      {:ok, %Run{status: :failed} = run} ->
        update_run(run.id, %{error: error})

      {:ok, %Run{status: status}} when status in @active_statuses ->
        transition_run(run_id, :failed, %{error: error})

      {:ok, _run} ->
        {:error, :not_recoverable}

      {:error, _} = error_result ->
        error_result
    end
  end

  @doc false
  def mark_failed_if_status(run_id, expected_status, phase, reason)
      when is_binary(run_id) and is_atom(expected_status) do
    error = failure_payload(phase, reason)

    result =
      Repo.transaction(fn ->
        run =
          Repo.one(
            from(candidate in Run,
              where: candidate.id == ^run_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        with :ok <- ensure_status(run.status, expected_status),
             :ok <- ensure_transition_allowed(run.status, :failed),
             {:ok, updated} <-
               run
               |> Run.update_changeset(transition_attrs(run, :failed, %{error: error}))
               |> Repo.update(),
             :ok <- Outbox.persist(updated) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  @doc false
  def ensure_apply_preconditions(%Run{} = run) do
    with %Project{} = project <- Repo.get(Project, run.project_id),
         :ok <- ensure_project_root_empty(project, run.target_root_container_resource_id),
         true <- all_lessons_approved?(run.id),
         :ok <- Enrichment.ensure_generation_complete(run.id),
         :ok <- ensure_required_media_ready(run) do
      :ok
    else
      nil -> {:error, :project_not_found}
      false -> {:error, :lessons_pending_approval}
      {:error, _} = error -> error
    end
  end

  @doc false
  def ensure_required_media_ready(%Run{} = run) do
    with {:ok, checkpoint} <- compile_checkpoint(run),
         {:ok, media_urls} <- MediaIngestor.required_media_urls(run.id),
         true <-
           Map.keys(media_urls) |> Enum.sort() == checkpoint["required_media_ids"] do
      :ok
    else
      false -> {:error, :required_media_selection_changed}
      {:error, _} = error -> error
    end
  end

  @doc false
  def complete_apply_in_transaction(%Run{status: :applying} = run, result)
      when is_map(result) do
    if Repo.in_transaction?() do
      now = DateTime.utc_now()

      with {:ok, updated} <-
             run
             |> Run.update_changeset(%{
               status: :completed,
               result: result,
               progress:
                 build_progress(:completed, run.progress, now)
                 |> merge_progress(%{
                   "counts" => %{
                     "lessons_created" => result["lessons_applied"] || 0
                   },
                   "stage_totals" => [
                     %{
                       "label" => "Lessons created",
                       "completed" => result["lessons_applied"] || 0,
                       "total" => result["lessons_applied"] || 0
                     }
                   ]
                 }),
               finished_at: now
             })
             |> Repo.update(),
           :ok <- Outbox.persist(updated) do
        {:ok, updated}
      end
    else
      {:error, :transaction_required}
    end
  end

  def complete_apply_in_transaction(%Run{status: status}, _result),
    do: {:error, {:invalid_status, status, :applying}}

  @doc false
  def announce_run_update(%Run{} = run) do
    PubSub.broadcast(run)
    dispatch_notification(run)
    :ok
  end

  @doc false
  def reset_for_test!(run_id) do
    Repo.delete_all(from(run in Run, where: run.id == ^run_id))
  end

  defp create_run(project, author, target_resource_id, source_url, book_slug, ai_backend) do
    {source_schema_version, _plan_schema_version} = rich_content_versions(project)
    now = DateTime.utc_now()

    attrs = %{
      project_id: project.id,
      author_id: author.id,
      target_root_container_resource_id: target_resource_id,
      source_url: source_url,
      ai_backend: ai_backend,
      book_slug: book_slug,
      scope_manifest: %{"book_slug" => book_slug, "chapters" => []},
      progress:
        :preflighting
        |> build_progress(%{}, now)
        |> Map.put("work_state", "queued"),
      source_schema_version: source_schema_version,
      plan_schema_version: ImportContract.plan_schema_version(),
      lesson_planning_strategy: :parallel_v1,
      lesson_planning_parallelism: lesson_planning_parallelism(ai_backend),
      started_at: now
    }

    Repo.transaction(fn ->
      with :ok <- lock_and_validate_import_start(project, target_resource_id),
           {:ok, run} <- Repo.insert(Run.create_changeset(%Run{}, attrs)),
           {:ok, _job} <- Oban.insert(PreflightWorker.new(%{"run_id" => run.id})) do
        run
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, run} ->
        PubSub.broadcast(run)
        {:ok, run}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_run_changeset_error(changeset)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_invalid_source_run(project, author, target_resource_id, source_url, ai_backend) do
    now = DateTime.utc_now()

    error = %{
      "phase" => "validation",
      "reason" => "invalid_openstax_url",
      "message" => "Use a URL matching https://openstax.org/details/books/<book-slug>.",
      "recoverable" => false
    }

    attrs = %{
      project_id: project.id,
      author_id: author.id,
      target_root_container_resource_id: target_resource_id,
      status: :failed,
      source_url: source_url,
      ai_backend: ai_backend,
      book_slug: "invalid-source",
      scope_manifest: %{},
      progress: build_progress(:failed, %{}, now),
      error: error,
      started_at: now,
      finished_at: now
    }

    result =
      Repo.transaction(fn ->
        with :ok <- lock_and_validate_import_start(project, target_resource_id),
             {:ok, run} <- %Run{} |> Run.create_changeset(attrs) |> Repo.insert(),
             :ok <- Outbox.persist(run) do
          run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        announce_run_update(run)
        {:ok, run}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_run_changeset_error(changeset)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_and_validate_import_start(project, target_resource_id) do
    publication = Publishing.project_working_publication(project.slug)

    with %{project_id: project_id, root_resource_id: root_resource_id} <- publication,
         true <- project_id == project.id and root_resource_id == target_resource_id do
      Repo.query!(
        "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
        [publication.id, target_resource_id]
      )

      with %{id: current_publication_id} <- Publishing.project_working_publication(project.slug),
           true <- current_publication_id == publication.id,
           :ok <- ensure_project_root_empty(project, target_resource_id),
           :ok <- ensure_no_active_run(project.id, target_resource_id) do
        :ok
      else
        false -> {:error, :project_publication_changed}
        nil -> {:error, :invalid_target}
        {:error, _} = error -> error
      end
    else
      nil -> {:error, :invalid_target}
      false -> {:error, :target_must_be_project_root}
    end
  end

  defp scope_attrs(run, selected_ids) do
    snapshot = run.preflight_snapshot || %{}
    chapters = snapshot["chapters"] || []
    available_ids = MapSet.new(Enum.map(chapters, & &1["id"]))
    selected_set = MapSet.new(selected_ids)

    if MapSet.subset?(selected_set, available_ids) do
      selected_chapters =
        Enum.map(chapters, fn chapter ->
          Map.put(chapter, "selected", MapSet.member?(selected_set, chapter["id"]))
        end)

      {:ok,
       %{
         preflight_snapshot: Map.put(snapshot, "chapters", selected_chapters),
         scope_manifest: %{
           "book_slug" => run.book_slug,
           "title" => snapshot["title"],
           "chapters" => selected_chapters,
           "selected_chapter_ids" => selected_ids
         }
       }}
    else
      {:error, :invalid_chapter_selection}
    end
  end

  defp persist_lesson_plan(
         lesson,
         payload,
         plan_mode,
         created_by,
         allow_repair?,
         opts \\ []
       ) do
    result =
      Repo.transaction(fn ->
        locked_run =
          Repo.one!(
            from(r in Run,
              where: r.id == ^lesson.run_id,
              lock: "FOR UPDATE"
            )
          )

        if locked_run.status not in [:planning_lessons, :awaiting_lesson_approval] do
          Repo.rollback(
            {:invalid_status, locked_run.status, [:planning_lessons, :awaiting_lesson_approval]}
          )
        end

        locked_lesson =
          Repo.one!(
            from(l in Lesson,
              where: l.id == ^lesson.id and l.run_id == ^locked_run.id,
              lock: "FOR UPDATE"
            )
          )

        if locked_run.status == :awaiting_lesson_approval do
          :ok = rollback_unless_ok(ensure_lesson_not_busy(locked_lesson))
        end

        existing = latest_plan_or_nil(locked_lesson.id)

        updated_lesson =
          if Keyword.get(opts, :skip_if_exists, false) and not is_nil(existing) do
            Repo.preload(locked_lesson, :plans, force: true)
          else
            payload =
              case Keyword.fetch(opts, :enrichment_proposals) do
                {:ok, proposals} ->
                  {:ok, synced_payload} =
                    sync_planned_enrichments(
                      locked_run,
                      locked_lesson,
                      payload,
                      proposals
                    )

                  synced_payload

                :error ->
                  payload
              end

            persist_locked_lesson_plan(
              locked_lesson,
              existing,
              payload,
              plan_mode,
              created_by,
              allow_repair?,
              locked_run.plan_schema_version
            )
          end

        now = DateTime.utc_now()

        updated_lesson =
          updated_lesson
          |> Lesson.changeset(%{
            planning_state: "completed",
            planning_last_progress_at: now,
            planning_finished_at: now,
            planning_error: nil
          })
          |> Repo.update!()
          |> Repo.preload(:plans, force: true)

        if updated_lesson.last_plan_version > locked_run.latest_plan_version do
          locked_run
          |> Run.update_changeset(%{latest_plan_version: updated_lesson.last_plan_version})
          |> Repo.update!()
        end

        updated_lesson
      end)

    case result do
      {:ok, updated_lesson} ->
        sync_review_counts(updated_lesson.run_id)
        maybe_reconcile_parallel_review_progress(updated_lesson.run_id)
        latest_plan = Enum.max_by(updated_lesson.plans, & &1.version)

        Telemetry.plan_checked(
          updated_lesson.run_id,
          updated_lesson.id,
          latest_plan,
          latest_plan.created_by == "system"
        )

        {:ok, updated_lesson}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:lesson_plan_persistence_failed, Exception.message(exception)}}
  end

  defp sync_planned_enrichments(run, lesson, payload, proposals)
       when is_map(payload) and is_list(proposals) do
    normalized = normalize_planned_enrichment_proposals(proposals)
    payload = strip_model_enrichment_references(payload)

    case Enrichment.sync_proposals(run.id, lesson.id, normalized) do
      {:ok, _persisted} ->
        {:ok, payload}

      {:error, :proposal_sync_locked} ->
        # Reviewer decisions and generated artifact history own the proposal
        # records after planning. A lesson regeneration must not overwrite them.
        {:ok, payload}

      {:error, reason} ->
        Logger.warning(
          "OpenStax enrichment proposal persistence degraded to a normal lesson",
          run_id: run.id,
          lesson_id: lesson.id,
          reason: inspect(reason)
        )

        {:ok, payload}
    end
  rescue
    exception ->
      Logger.warning(
        "OpenStax enrichment proposal persistence raised and was omitted",
        run_id: run.id,
        lesson_id: lesson.id,
        exception: exception.__struct__
      )

      {:ok, strip_model_enrichment_references(payload)}
  end

  defp sync_planned_enrichments(_run, _lesson, payload, _proposals),
    do: {:ok, strip_model_enrichment_references(payload)}

  defp normalize_planned_enrichment_proposals(proposals) do
    proposals
    |> Enum.take(Enrichment.max_proposals_per_lesson())
    |> Enum.with_index(1)
    |> Enum.map(fn {proposal, rank} ->
      planner_id = proposal["id"] || proposal[:id] || "enrichment-proposal-#{rank}"
      kind = proposal["kind"] || proposal[:kind]

      metadata =
        (proposal["metadata"] || proposal[:metadata] || %{})
        |> Map.new()
        |> Map.put("planner_id", planner_id)
        |> maybe_put_map_value(
          "research_query",
          proposal["research_query"] || proposal[:research_query]
        )
        |> maybe_put_map_value(
          "planner_research_evidence",
          proposal["research_evidence"] || proposal[:research_evidence]
        )

      %{
        "rank" => rank,
        "kind" => normalize_enrichment_kind(kind),
        "instructional_rationale" =>
          proposal["instructional_rationale"] || proposal[:instructional_rationale],
        "objective_ids" => proposal["objective_ids"] || proposal[:objective_ids] || [],
        "source_evidence" => proposal["source_evidence"] || proposal[:source_evidence] || %{},
        "placement" => proposal["placement"] || proposal[:placement] || %{},
        "learner_task" => proposal["learner_task"] || proposal[:learner_task],
        "metadata" => metadata
      }
    end)
  end

  defp normalize_enrichment_kind("curated_resource"), do: "external_resource"
  defp normalize_enrichment_kind(kind), do: kind

  defp strip_model_enrichment_references(payload) do
    update_in(
      payload,
      [Access.key("content_payload", %{}), Access.key("experience_blueprint", %{})],
      &Map.put(&1, "enrichment_references", [])
    )
  end

  defp maybe_put_map_value(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

  defp persist_locked_lesson_plan(
         locked_lesson,
         existing,
         payload,
         plan_mode,
         created_by,
         allow_repair?,
         run_plan_schema_version
       ) do
    :ok =
      rollback_unless_ok(
        ensure_payload_schema_version(
          payload,
          run_plan_schema_version,
          plan_mode,
          locked_lesson.plan_mode
        )
      )

    normalized =
      normalize_lesson_payload(
        locked_lesson,
        payload,
        plan_mode,
        existing,
        run_plan_schema_version
      )
      |> maybe_invalidate_author_quality(created_by)

    Repo.update_all(
      from(plan in LessonPlan, where: plan.lesson_id == ^locked_lesson.id),
      set: [approved_by_user: false, approved_at: nil]
    )

    first_version = next_plan_version(locked_lesson.id)
    source_context = lesson_source_context(locked_lesson)
    first_results = Checks.run(source_context, normalized)

    first_plan =
      insert_plan!(
        locked_lesson,
        first_version,
        normalized,
        created_by,
        first_results
      )

    persist_checks!(locked_lesson.id, first_version, first_results)

    # Current-schema author edits never invoke the removed deterministic legacy
    # repairer. They create a new version and rerun deterministic gates; model
    # Repairs happen only inside the reviewed v7 pipelines.
    _allow_repair? = allow_repair?
    {final_plan, final_results, repair_increment} = {first_plan, first_results, 0}

    status =
      if Checks.passed?(final_results) and not current_quality_attention_required?(final_plan),
        do: "ready_for_review",
        else: "needs_attention"

    updated_lesson =
      locked_lesson
      |> Lesson.changeset(%{
        plan_mode: plan_mode,
        status: status,
        last_plan_version: final_plan.version,
        approved_by_author_id: nil,
        approved_at: nil,
        last_repair_attempt_at:
          if(repair_increment == 1,
            do: DateTime.utc_now(),
            else: locked_lesson.last_repair_attempt_at
          ),
        repair_attempts: locked_lesson.repair_attempts + repair_increment
      })
      |> Repo.update!()

    Repo.preload(updated_lesson, :plans, force: true)
  end

  defp insert_plan!(lesson, version, payload, created_by, results) do
    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: version,
      content_payload: payload["content_payload"],
      questions_payload: payload["questions_payload"],
      generation_metadata: payload["generation_metadata"] || %{},
      checks_snapshot: checks_snapshot(results),
      created_by: created_by,
      approved_by_user: false
    })
    |> Repo.insert!()
  end

  defp persist_checks!(lesson_id, version, results) do
    Enum.each(results, fn result ->
      %LessonCheck{}
      |> LessonCheck.changeset(%{
        lesson_id: lesson_id,
        version: version,
        check_type: result.check_type,
        status: result.status,
        findings: result.findings,
        repair_plan: result.repair_plan
      })
      |> Repo.insert!()
    end)
  end

  defp current_quality_attention_required?(%LessonPlan{
         content_payload: %{"schema_version" => schema, "authoring_mode" => mode},
         generation_metadata: metadata
       })
       when {mode, schema} in [{"basic", 7}, {"advanced", 7}] do
    quality_gate = get_in(metadata || %{}, ["quality_gate"]) || %{}

    quality_gate["approved"] != true or numeric_confidence(quality_gate["confidence"]) < 0.9 or
      List.wrap(quality_gate["hard_blockers"]) != [] or
      List.wrap(quality_gate["repairs"]) != []
  end

  defp current_quality_attention_required?(_plan), do: true

  defp checks_snapshot(results) do
    %{
      "status" => if(Checks.passed?(results), do: "passed", else: "failed"),
      "results" =>
        Enum.map(results, fn result ->
          %{
            "check_type" => result.check_type,
            "status" => result.status,
            "findings" => result.findings,
            "repair_plan" => result.repair_plan
          }
        end)
    }
  end

  defp maybe_invalidate_author_quality(payload, "author") do
    finding = %{
      "severity" => "repair",
      "code" => "author_edit_requires_critic_review",
      "message" =>
        "The author edit must pass the current specialist critic gates before approval."
    }

    update_in(payload, ["generation_metadata"], fn metadata ->
      metadata = metadata || %{}
      gate = metadata["quality_gate"] || %{}

      Map.put(
        metadata,
        "quality_gate",
        Map.merge(gate, %{
          "approved" => false,
          "confidence" => 0.0,
          "outcome" => "needs_attention",
          "repairs" => Enum.uniq(List.wrap(gate["repairs"]) ++ [finding])
        })
      )
    end)
  end

  defp maybe_invalidate_author_quality(payload, _created_by), do: payload

  defp normalize_lesson_payload(
         lesson,
         payload,
         plan_mode,
         existing,
         run_plan_schema_version
       ) do
    existing_content = if(existing, do: existing.content_payload || %{}, else: %{})
    existing_questions = if(existing, do: existing.questions_payload || %{}, else: %{})

    existing_generation_metadata =
      if(existing, do: existing.generation_metadata || %{}, else: %{})

    incoming_content =
      case payload["content_payload"] || payload[:content_payload] do
        content when is_map(content) -> content
        _ -> Map.drop(payload, ["questions_payload", :questions_payload, "questions", :questions])
      end

    objective =
      incoming_content["objective"] || incoming_content[:objective] ||
        existing_content["objective"] ||
        "Explain and apply the lesson's core ideas"

    objectives =
      incoming_content["learning_objectives"] || incoming_content[:learning_objectives] ||
        existing_content["learning_objectives"] || [objective]

    content =
      existing_content
      |> Map.merge(stringify_keys(incoming_content))
      |> Map.put("title", lesson.title)
      |> Map.put("objective", objective)
      |> Map.put("learning_objectives", List.wrap(objectives))
      |> Map.put_new("narrative", lesson.source_excerpt || "")
      |> Map.put("source_evidence_links", lesson.source_evidence_links || [])
      |> Map.put("authoring_mode", plan_mode)

    incoming_questions =
      payload["questions_payload"] || payload[:questions_payload] ||
        payload["questions"] || payload[:questions] || existing_questions

    questions =
      if(plan_mode == "advanced", do: [], else: incoming_questions)
      |> normalize_questions(10)
      |> Enum.with_index(1)
      |> Enum.map(fn {question, index} ->
        question
        |> Map.put_new("id", "q#{index}")
        |> Map.put_new("type", "short_answer")
        |> Map.put("source_evidence_links", lesson.source_evidence_links || [])
      end)

    content =
      content
      |> normalize_content_for_authoring_mode(plan_mode)
      |> enforce_system_schema_version(run_plan_schema_version, plan_mode)
      |> strip_untrusted_exclusion_acknowledgements(run_plan_schema_version)

    %{
      "content_payload" => content,
      "questions_payload" => %{"items" => questions},
      "generation_metadata" =>
        payload["generation_metadata"] || payload[:generation_metadata] ||
          existing_generation_metadata
    }
  end

  defp normalize_content_for_authoring_mode(content, "basic") do
    Map.drop(content, [
      "experience_blueprint",
      "advanced_v7_contract"
    ])
  end

  defp normalize_content_for_authoring_mode(content, "advanced"), do: content

  defp ensure_payload_schema_version(payload, 7, "basic", "advanced") do
    incoming = payload["content_payload"] || payload[:content_payload] || payload

    case incoming_schema_version(incoming) do
      7 -> :ok
      nil -> {:error, :plan_schema_version_required}
      _other -> {:error, :plan_schema_version_immutable}
    end
  end

  defp ensure_payload_schema_version(payload, 7, plan_mode, current_plan_mode)
       when plan_mode in ["basic", "advanced"] and current_plan_mode in ["basic", "advanced"] do
    incoming = payload["content_payload"] || payload[:content_payload] || payload
    expected = expected_content_schema_version(7, plan_mode)

    case incoming_schema_version(incoming) do
      ^expected -> :ok
      nil when is_map(incoming) -> {:error, :plan_schema_version_required}
      nil -> {:error, :invalid_plan_payload}
      _other -> {:error, :plan_schema_version_immutable}
    end
  end

  defp ensure_payload_schema_version(
         _payload,
         run_plan_schema_version,
         plan_mode,
         current_plan_mode
       ),
       do:
         {:error,
          {:unsupported_openstax_schema_contract, run_plan_schema_version, plan_mode,
           current_plan_mode}}

  defp incoming_schema_version(%{} = content),
    do: content["schema_version"] || content[:schema_version]

  defp incoming_schema_version(_content), do: nil

  defp enforce_system_schema_version(content, 7, plan_mode)
       when plan_mode in ["basic", "advanced"],
       do:
         Map.put(
           content,
           "schema_version",
           expected_content_schema_version(7, plan_mode)
         )

  defp enforce_system_schema_version(_content, run_plan_schema_version, plan_mode),
    do:
      raise(
        ArgumentError,
        "unsupported OpenStax schema contract #{inspect({run_plan_schema_version, plan_mode})}"
      )

  defp expected_content_schema_version(7, "basic"), do: 7
  defp expected_content_schema_version(7, "advanced"), do: 7

  defp expected_content_schema_version(run_plan_schema_version, plan_mode),
    do:
      raise(
        ArgumentError,
        "unsupported OpenStax schema contract #{inspect({run_plan_schema_version, plan_mode})}"
      )

  defp strip_untrusted_exclusion_acknowledgements(content, run_plan_schema_version)
       when run_plan_schema_version in [6, 7] do
    update_in(
      content,
      [Access.key("coverage_manifest", %{}), Access.key("excluded_blocks", [])],
      fn exclusions ->
        Enum.map(List.wrap(exclusions), fn
          exclusion when is_map(exclusion) ->
            Map.drop(exclusion, [
              "author_acknowledged",
              "acknowledged_by_author_id",
              "acknowledged_at",
              "acknowledged_plan_version"
            ])

          exclusion ->
            exclusion
        end)
      end
    )
  end

  defp strip_untrusted_exclusion_acknowledgements(_content, run_plan_schema_version),
    do:
      raise(ArgumentError, "unsupported OpenStax run schema #{inspect(run_plan_schema_version)}")

  defp normalize_questions(%{"items" => items}, limit) when is_list(items),
    do: normalize_questions(items, limit)

  defp normalize_questions(%{"questions" => items}, limit) when is_list(items),
    do: normalize_questions(items, limit)

  defp normalize_questions(items, limit) when is_list(items) and limit in [6, 10] do
    items
    |> Enum.map(fn
      question when is_binary(question) -> %{"prompt" => String.trim(question)}
      question when is_map(question) -> stringify_keys(question)
      _ -> %{}
    end)
    |> Enum.filter(&(is_binary(&1["prompt"]) and String.trim(&1["prompt"]) != ""))
    |> Enum.take(limit)
  end

  defp normalize_questions(_, _limit), do: []

  defp latest_plan_or_nil(lesson_id) do
    Repo.one(
      from(plan in LessonPlan,
        where: plan.lesson_id == ^lesson_id,
        order_by: [desc: plan.version],
        limit: 1
      )
    )
  end

  defp next_plan_version(lesson_id) do
    Repo.one(
      from(plan in LessonPlan,
        where: plan.lesson_id == ^lesson_id,
        select: coalesce(max(plan.version), 0)
      )
    ) + 1
  end

  defp ensure_plan_approvable(%LessonPlan{rejection_reason: reason})
       when reason not in [nil, ""],
       do: {:error, :lesson_plan_rejected}

  defp ensure_plan_approvable(%LessonPlan{}), do: :ok

  defp lesson_source_map(lesson) do
    base = %{
      "title" => lesson.title,
      "source_excerpt" => lesson.source_excerpt,
      "source_sections" => lesson.source_sections || [],
      "source_evidence_links" => lesson.source_evidence_links || [],
      "source_objectives" => lesson.source_objectives || []
    }

    base
    |> maybe_put_lesson_repair_context(lesson)
    |> merge_lesson_source_corpus(lesson)
  end

  defp maybe_put_lesson_repair_context(base, %Lesson{planning_operation: "regenerate"} = lesson) do
    case latest_plan_or_nil(lesson.id) do
      %LessonPlan{} = plan ->
        quality_gate =
          plan.generation_metadata["quality_gate"] ||
            plan.generation_metadata[:quality_gate] || %{}

        findings =
          List.wrap(quality_gate["hard_blockers"] || quality_gate[:hard_blockers]) ++
            List.wrap(quality_gate["repairs"] || quality_gate[:repairs])

        repair_context = %{
          "author_feedback" => normalized_repair_feedback(plan.rejection_reason),
          "critic_findings" =>
            findings
            |> Enum.take(20)
            |> Enum.map(fn finding ->
              repair_finding(finding)
            end),
          "phase_findings" => repair_phase_findings(plan.content_payload, quality_gate),
          "previous_candidates" => repair_candidates(plan),
          "previous_finding_fingerprint" => QualityCritic.fingerprint_findings(findings),
          "previous_plan_version" => plan.version,
          "required_action" =>
            "Edit the supplied previous candidates to resolve every applicable finding. Preserve unrelated generated fields and never change the authoritative source."
        }

        if repair_context["author_feedback"] || repair_context["critic_findings"] != [] do
          Map.put(base, "repair_context", repair_context)
        else
          base
        end

      nil ->
        base
    end
  end

  defp maybe_put_lesson_repair_context(base, _lesson), do: base

  defp normalized_repair_feedback(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      feedback -> String.slice(feedback, 0, 2_000)
    end
  end

  defp normalized_repair_feedback(_value), do: nil

  defp repair_phase_findings(content, quality_gate) do
    mode = content["authoring_mode"] || content[:authoring_mode]

    fallback =
      List.wrap(quality_gate["hard_blockers"] || quality_gate[:hard_blockers]) ++
        List.wrap(quality_gate["repairs"] || quality_gate[:repairs])

    case mode do
      "advanced" ->
        phase_findings(
          review_repair_findings(quality_gate, "experience_critic"),
          review_repair_findings(quality_gate, "activity_critic"),
          fallback,
          &activity_finding?/1,
          "experience",
          "activities"
        )

      _ ->
        phase_findings(
          review_repair_findings(quality_gate, "content_critic"),
          review_repair_findings(quality_gate, "question_critic"),
          fallback,
          &question_finding?/1,
          "content",
          "questions"
        )
    end
  end

  defp phase_findings(primary, secondary, fallback, secondary?, primary_key, secondary_key) do
    {primary, secondary} =
      if primary == [] and secondary == [] do
        {secondary_findings, primary_findings} = Enum.split_with(fallback, secondary?)
        {primary_findings, secondary_findings}
      else
        {primary, secondary}
      end

    %{
      primary_key => primary |> Enum.take(20) |> Enum.map(&repair_finding/1),
      secondary_key => secondary |> Enum.take(20) |> Enum.map(&repair_finding/1)
    }
  end

  defp activity_finding?(finding) do
    path = to_string(finding["path"] || finding[:path] || "")
    code = to_string(finding["code"] || finding[:code] || "")

    String.contains?(path, ["activities", "activity_slots"]) or
      String.contains?(code, ["activity", "response", "feedback", "distractor"])
  end

  defp question_finding?(finding) do
    path = to_string(finding["path"] || finding[:path] || "")
    code = to_string(finding["code"] || finding[:code] || "")

    String.contains?(path, ["questions", "questions_payload", ".items["]) or
      String.contains?(code, ["question", "answer", "distractor", "feedback"])
  end

  defp review_repair_findings(quality_gate, critic_key) do
    quality_gate
    |> Map.get(critic_key, %{})
    |> Map.get("findings", [])
    |> List.wrap()
    |> Enum.filter(&((&1["severity"] || &1[:severity]) in ["hard_blocker", "repair"]))
    |> Enum.take(20)
    |> Enum.map(&repair_finding/1)
  end

  defp repair_finding(finding) do
    finding
    |> stringify_keys()
    |> Map.take(~w(severity code path message))
  end

  defp repair_candidates(%LessonPlan{content_payload: %{"authoring_mode" => "advanced"}} = plan) do
    %{
      "experience" => AdvancedPlanV7.architecture_repair_candidate(plan.content_payload),
      "activities" => AdvancedPlanV7.activity_repair_candidate(plan.content_payload),
      "questions" => plan.questions_payload || %{}
    }
  end

  defp repair_candidates(%LessonPlan{} = plan) do
    %{
      "content" => BasicPlanV7.repair_candidate(plan.content_payload || %{}),
      "questions" => plan.questions_payload || %{}
    }
  end

  defp ensure_usable_lesson_source(%Run{source_schema_version: @source_schema_version}, source) do
    source
    |> Map.get("source_blocks", [])
    |> List.wrap()
    |> Enum.any?(&usable_source_block?/1)
    |> case do
      true -> :ok
      false -> {:error, :missing_lesson_source}
    end
  end

  defp ensure_usable_lesson_source(%Run{source_schema_version: version}, _source),
    do: {:error, {:unsupported_openstax_source_schema, version}}

  defp usable_source_block?(block) when is_map(block) do
    source_id = block["id"] || block[:id]
    text = block["normalized_text"] || block[:normalized_text] || block["text"] || block[:text]

    is_binary(source_id) and String.trim(source_id) != "" and
      is_binary(text) and String.trim(text) != ""
  end

  defp usable_source_block?(_block), do: false

  defp lesson_source_context(lesson) do
    base = %{
      "title" => lesson.title,
      "source_excerpt" => lesson.source_excerpt || "",
      "source_sections" => lesson.source_sections || [],
      "source_objectives" => lesson.source_objectives || [],
      "source_evidence_links" => lesson.source_evidence_links || []
    }

    merge_lesson_source_corpus(base, lesson)
  end

  defp merge_lesson_source_corpus(base, lesson) do
    case RichSource.load_lesson_corpus(lesson.id) do
      {:ok, corpus} ->
        base
        |> Map.merge(
          Map.take(corpus, [
            "source_blocks",
            "source_media",
            "source_word_count",
            "source_coverage",
            "attribution"
          ])
        )
        |> Map.put("source_section_details", corpus["source_sections"] || [])

      {:error, _reason} ->
        base
        |> Map.put_new("source_blocks", [])
        |> Map.put_new("source_media", [])
        |> Map.put_new("source_word_count", lesson.source_word_count || 0)
        |> Map.put_new("source_coverage", lesson.source_coverage || %{})
    end
  end

  defp maybe_transition_to_compiling_locked(%Run{} = locked_run) do
    if all_lessons_approved?(locked_run.id) and
         Enrichment.ensure_generation_complete(locked_run.id) == :ok do
      :ok = rollback_unless_ok(ensure_transition_allowed(locked_run.status, :compiling))

      updated_run =
        locked_run
        |> Run.update_changeset(transition_attrs(locked_run, :compiling, %{}))
        |> Repo.update!()

      {:transitioned, updated_run}
    else
      :not_ready
    end
  end

  defp ensure_generated_proposal_available(_run, %{kind: kind})
       when kind != "generated_simulation",
       do: :ok

  defp ensure_generated_proposal_available(%Run{} = run, proposal) do
    case {run_project(run), Repo.get(Lesson, proposal.lesson_id)} do
      {%Project{} = project, %Lesson{plan_mode: "advanced", run_id: run_id}}
      when run_id == run.id ->
        if enrichment_capabilities(project, run.ai_backend).generated_available do
          :ok
        else
          {:error, :simulation_generation_unavailable}
        end

      {%Project{}, %Lesson{}} ->
        {:error, :generated_enrichment_requires_advanced_authoring}

      _ ->
        {:error, :project_or_lesson_not_found}
    end
  end

  defp ensure_generated_proposal_enabled(_run, %{kind: kind})
       when kind != "generated_simulation",
       do: {:error, :not_generated_simulation}

  defp ensure_generated_proposal_enabled(%Run{} = run, proposal) do
    case {run_project(run), Repo.get(Lesson, proposal.lesson_id)} do
      {%Project{} = project, %Lesson{plan_mode: "advanced", run_id: run_id}}
      when run_id == run.id ->
        if enrichment_capabilities(project, run.ai_backend).generated_enabled,
          do: :ok,
          else: {:error, :simulation_generation_unavailable}

      {%Project{}, %Lesson{}} ->
        {:error, :generated_enrichment_requires_advanced_authoring}

      _ ->
        {:error, :project_or_lesson_not_found}
    end
  end

  defp active_simulation_spec?(proposal_id) do
    Repo.exists?(
      from(spec in SimulationSpec,
        where: spec.proposal_id == ^proposal_id and spec.status == "designing"
      )
    )
  end

  defp active_simulation_artifact?(proposal_id) do
    proposal_id
    |> Enrichment.list_artifacts()
    |> Enum.any?(&(&1.status in ["generating", "ready_for_review"]))
  end

  defp maybe_advance_after_enrichment_decision(%Run{status: :awaiting_lesson_approval} = run) do
    if all_lessons_approved?(run.id) and Enrichment.ensure_generation_complete(run.id) == :ok do
      case transition_to_compiling_if_ready(run.id) do
        {:ok, _updated} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_advance_after_enrichment_decision(_run), do: :ok

  defp run_project(%Run{project_id: project_id}), do: Repo.get(Project, project_id)

  defp transition_to_compiling_if_ready(run_id) do
    result =
      Repo.transaction(fn ->
        locked_run =
          Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) ||
            Repo.rollback(:not_found)

        :ok = rollback_unless_ok(ensure_status(locked_run.status, :awaiting_lesson_approval))

        case maybe_transition_to_compiling_locked(locked_run) do
          {:transitioned, updated_run} -> updated_run
          :not_ready -> Repo.rollback(:lessons_pending_approval)
        end
      end)

    after_transition(result)
  end

  defp return_compile_failure_to_review(run, reason) do
    result =
      Repo.transaction(fn ->
        locked_run =
          Repo.one(from(candidate in Run, where: candidate.id == ^run.id, lock: "FOR UPDATE")) ||
            Repo.rollback(:not_found)

        :ok = rollback_unless_ok(ensure_status(locked_run.status, :compiling))

        affected_lesson_ids =
          case lesson_ids_from_compile_failure(reason) do
            [] -> selected_lesson_ids(locked_run.id)
            ids -> ids
          end

        now = DateTime.utc_now()

        Repo.update_all(
          from(lesson in Lesson, where: lesson.id in ^affected_lesson_ids),
          set: [
            status: "needs_attention",
            approved_by_author_id: nil,
            approved_at: nil,
            updated_at: now
          ]
        )

        Repo.update_all(
          from(plan in LessonPlan,
            where: plan.lesson_id in ^affected_lesson_ids and plan.approved_by_user == true
          ),
          set: [approved_by_user: false, approved_at: nil, updated_at: now]
        )

        error = %{
          "phase" => "compile",
          "reason" => inspect(reason),
          "message" =>
            "One or more approved lesson plans could not be compiled. Edit or regenerate the affected plan and try again.",
          "recoverable" => true,
          "lesson_ids" => affected_lesson_ids
        }

        with {:ok, updated} <-
               locked_run
               |> Run.update_changeset(
                 transition_attrs(locked_run, :awaiting_lesson_approval, %{
                   error: error,
                   result: Map.drop(locked_run.result || %{}, ["compile_checkpoint", "dry_run"])
                 })
               )
               |> Repo.update(),
             :ok <- Outbox.persist(updated) do
          updated
        else
          {:error, transition_reason} -> Repo.rollback(transition_reason)
        end
      end)
      |> after_transition()

    case result do
      {:ok, review_run} ->
        affected_lesson_ids = get_in(review_run.error || %{}, ["lesson_ids"]) || []
        Telemetry.compile_failed(run.id, reason, affected_lesson_ids)
        {:error, {:compile_failed, reason}}

      {:error, transition_reason} ->
        {:error, transition_reason}
    end
  end

  defp lesson_ids_from_compile_failure({:unit_compile_failed, _unit_id, reason}),
    do: lesson_ids_from_compile_failure(reason)

  defp lesson_ids_from_compile_failure({reason, lesson_id})
       when reason in [:lesson_not_compilable, :lesson_not_approved] and is_binary(lesson_id),
       do: [lesson_id]

  defp lesson_ids_from_compile_failure({:lesson_artifact_invalid, lesson_id, _reason})
       when is_binary(lesson_id),
       do: [lesson_id]

  defp lesson_ids_from_compile_failure(_reason), do: []

  defp selected_lesson_ids(run_id) do
    Repo.all(
      from(lesson in Lesson,
        where: lesson.run_id == ^run_id and lesson.selected == true,
        select: lesson.id
      )
    )
  end

  defp all_lessons_approved?(run_id) do
    plans_query = from(plan in LessonPlan, order_by: [desc: plan.version])

    selected_lessons =
      Repo.all(
        from(lesson in Lesson,
          where: lesson.run_id == ^run_id and lesson.selected == true,
          preload: [plans: ^plans_query]
        )
      )

    selected_lessons != [] and
      Enum.all?(selected_lessons, &current_lesson_plan_approved?/1)
  end

  defp current_lesson_plan_approved?(%Lesson{
         status: "approved",
         last_plan_version: last_plan_version,
         plans: [%LessonPlan{} = latest_plan | _]
       }) do
    latest_plan.version == last_plan_version and
      latest_plan.approved_by_user and
      latest_plan.rejection_reason in [nil, ""]
  end

  defp current_lesson_plan_approved?(_), do: false

  defp approved_plan_digest(run) do
    units =
      run.units
      |> Enum.filter(& &1.selected)
      |> Enum.sort_by(& &1.order)
      |> Enum.map(fn unit ->
        %{
          unit_id: unit.id,
          assessment_payload: unit.assessment_payload || %{},
          lessons:
            unit.lessons
            |> Enum.filter(& &1.selected)
            |> Enum.sort_by(& &1.order)
            |> Enum.map(fn lesson ->
              plan = Enum.max_by(lesson.plans, & &1.version, fn -> nil end)

              %{
                lesson_id: lesson.id,
                plan_id: plan && plan.id,
                plan_version: plan && plan.version,
                approved: plan && plan.approved_by_user,
                mode: lesson.plan_mode
              }
            end)
        }
      end)

    enrichments =
      run.id
      |> Enrichment.list_run_proposals()
      |> Enum.filter(&(&1.state == "approved"))
      |> Enum.map(fn proposal ->
        approved_artifact =
          proposal.simulation_artifacts
          |> List.wrap()
          |> Enum.find(&(&1.status == "approved"))

        %{
          proposal_id: proposal.id,
          proposal_version: proposal.approved_version,
          kind: proposal.kind,
          artifact_id: approved_artifact && approved_artifact.id,
          artifact_version: approved_artifact && approved_artifact.version,
          content_hash: approved_artifact && approved_artifact.content_hash
        }
      end)
      |> Enum.sort_by(& &1.proposal_id)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {run.plan_schema_version, units, enrichments},
        [:deterministic]
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp planned_required_media_ids(run) do
    available =
      Repo.all(
        from(asset in SourceAsset,
          where: asset.run_id == ^run.id,
          select: asset.source_key
        )
      )
      |> MapSet.new()

    run.units
    |> Enum.filter(& &1.selected)
    |> Enum.flat_map(fn unit ->
      lesson_payloads =
        unit.lessons
        |> Enum.filter(& &1.selected)
        |> Enum.flat_map(fn lesson ->
          case Enum.max_by(lesson.plans, & &1.version, fn -> nil end) do
            %LessonPlan{} = plan -> [plan.content_payload || %{}, plan.questions_payload || %{}]
            nil -> []
          end
        end)

      [unit.assessment_payload || %{} | lesson_payloads]
    end)
    |> Enum.reduce(MapSet.new(), &collect_source_keys(&1, &2, available))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_source_keys(value, found, available) when is_binary(value) do
    if MapSet.member?(available, value), do: MapSet.put(found, value), else: found
  end

  defp collect_source_keys(value, found, available) when is_list(value),
    do: Enum.reduce(value, found, &collect_source_keys(&1, &2, available))

  defp collect_source_keys(value, found, available) when is_map(value) do
    Enum.reduce(value, found, fn {key, nested}, acc ->
      with_key = collect_source_keys(key, acc, available)
      collect_source_keys(nested, with_key, available)
    end)
  end

  defp collect_source_keys(_value, found, _available), do: found

  defp maybe_put_final_dry_run(result, [], dry_run), do: Map.put(result, "dry_run", dry_run)

  defp maybe_put_final_dry_run(result, _required_media_ids, _dry_run),
    do: Map.delete(result, "dry_run")

  defp lessons_referencing_media(run_id, required_ids) do
    required = MapSet.new(required_ids)
    plans_query = from(plan in LessonPlan, order_by: [desc: plan.version])

    lessons =
      Repo.all(
        from(lesson in Lesson,
          where: lesson.run_id == ^run_id and lesson.selected == true,
          preload: [plans: ^plans_query]
        )
      )

    matching =
      Enum.filter(lessons, fn
        %Lesson{plans: [%LessonPlan{} = plan | _]} ->
          payload_references_media?(
            %{
              "content_payload" => plan.content_payload,
              "questions_payload" => plan.questions_payload
            },
            required
          )

        _ ->
          false
      end)

    case matching do
      [] when required_ids != [] -> Enum.map(lessons, & &1.id)
      _ -> Enum.map(matching, & &1.id)
    end
  end

  defp payload_references_media?(value, required) when is_binary(value),
    do: MapSet.member?(required, value)

  defp payload_references_media?(value, required) when is_list(value),
    do: Enum.any?(value, &payload_references_media?(&1, required))

  defp payload_references_media?(value, required) when is_map(value),
    do:
      Enum.any?(value, fn {key, nested} ->
        payload_references_media?(key, required) or payload_references_media?(nested, required)
      end)

  defp payload_references_media?(_value, _required), do: false

  defp run_has_lessons?(run_id) do
    Repo.exists?(
      from(lesson in Lesson,
        where: lesson.run_id == ^run_id and lesson.selected == true
      )
    )
  end

  defp retry_target(%Run{} = run) do
    phase = get_in(run.error || %{}, ["phase"]) || ""
    recoverable = get_in(run.error || %{}, ["recoverable"])

    cond do
      recoverable == false ->
        {:error, :not_recoverable}

      phase in ["validation"] ->
        {:error, :not_recoverable}

      phase in ["preflight", "source_discovery"] ->
        {:ok, :preflighting, PreflightWorker.new(%{"run_id" => run.id})}

      phase in ["ingest", "outline", "outline_planning"] ->
        if selected_scope?(run),
          do: {:ok, :ingesting, OutlineWorker.new(%{"run_id" => run.id})},
          else: {:ok, :preflighting, PreflightWorker.new(%{"run_id" => run.id})}

      phase in ["media", "media_staging"] ->
        {:ok, :staging_media, MediaWorker.new(%{"run_id" => run.id})}

      phase in ["lesson_planning", "checks"] ->
        {:error, :retry_requires_parallel_lesson_reconciliation}

      phase in ["apply"] ->
        {:ok, :applying, ApplyWorker.new(%{"run_id" => run.id})}

      phase in ["compile"] ->
        {:error, :retry_requires_lesson_review}

      true ->
        {:ok, :preflighting, PreflightWorker.new(%{"run_id" => run.id})}
    end
  end

  defp selected_scope?(run) do
    case get_in(run.scope_manifest || %{}, ["selected_chapter_ids"]) do
      ids when is_list(ids) -> ids != []
      _ -> false
    end
  end

  defp transition_to_parallel_lesson_planning(%Run{} = run, attrs) do
    generation = run.lesson_planning_generation + 1
    parallelism = lesson_planning_parallelism(run.ai_backend)

    transition_with_job(
      run,
      :planning_lessons,
      Map.merge(attrs, %{
        lesson_planning_strategy: :parallel_v1,
        lesson_planning_generation: generation,
        lesson_planning_parallelism: parallelism,
        error: nil
      }),
      LessonPlanningCoordinatorWorker.new(%{
        "run_id" => run.id,
        "generation" => generation
      })
    )
  end

  defp retry_parallel_lesson_planning(%Run{} = run) do
    generation = run.lesson_planning_generation + 1

    force_status_with_job(
      run,
      :planning_lessons,
      LessonPlanningCoordinatorWorker.new(%{
        "run_id" => run.id,
        "generation" => generation
      }),
      %{
        lesson_planning_strategy: :parallel_v1,
        lesson_planning_generation: generation,
        lesson_planning_parallelism: lesson_planning_parallelism(run.ai_backend)
      }
    )
  end

  defp failure_phase(%Run{} = run), do: get_in(run.error || %{}, ["phase"]) || ""

  defp configured_lesson_planning_parallelism do
    Application.get_env(:oli, :openstax_course_import_max_parallel_lessons, 3)
    |> case do
      value when is_integer(value) -> value
      _ -> 3
    end
    |> max(1)
    |> min(8)
  end

  defp lesson_planning_parallelism(:local_codex), do: 1
  defp lesson_planning_parallelism(_ai_backend), do: configured_lesson_planning_parallelism()

  defp transition_with_job(%Run{} = run, next_status, attrs, job_changeset) do
    attrs =
      Map.update(attrs, :progress, %{"work_state" => "queued"}, fn progress ->
        merge_progress(progress, %{"work_state" => "queued"})
      end)

    result =
      Repo.transaction(fn ->
        locked = Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))

        with :ok <- ensure_transition_allowed(locked.status, next_status),
             {:ok, updated} <-
               locked
               |> Run.update_changeset(transition_attrs(locked, next_status, attrs))
               |> Repo.update(),
             :ok <- Outbox.persist(updated),
             {:ok, _job} <- Oban.insert(job_changeset) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  defp force_status_with_job(run, status, job_changeset, extra_attrs \\ %{}) do
    result =
      Repo.transaction(fn ->
        locked = Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"))
        :ok = rollback_unless_ok(ensure_status(locked.status, :failed))

        project = Repo.get(Project, locked.project_id) || Repo.rollback(:project_not_found)

        attrs =
          %{
            status: status,
            error: nil,
            finished_at: nil,
            progress:
              status
              |> build_progress(locked.progress)
              |> Map.put("work_state", "queued"),
            started_at: locked.started_at || DateTime.utc_now()
          }
          |> Map.merge(extra_attrs)

        with :ok <-
               lock_and_validate_import_start(
                 project,
                 locked.target_root_container_resource_id
               ),
             {:ok, updated} <- locked |> Run.update_changeset(attrs) |> Repo.update(),
             {:ok, %Oban.Job{conflict?: false}} <- Oban.insert(job_changeset),
             :ok <- Outbox.persist(updated) do
          updated
        else
          {:ok, %Oban.Job{conflict?: true}} ->
            Repo.rollback(:retry_job_already_active)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  defp after_transition({:ok, %Run{} = run}) do
    PubSub.broadcast(run)
    dispatch_notification(run)
    {:ok, run}
  end

  defp after_transition({:error, reason}), do: {:error, reason}

  defp transition_attrs(run, next_status, attrs) do
    now = DateTime.utc_now()
    {incoming_progress, attrs} = Map.pop(attrs, :progress)

    progress =
      next_status
      |> build_progress(run.progress, now)
      |> maybe_merge_transition_progress(incoming_progress)

    %{
      status: next_status,
      progress: progress,
      finished_at:
        if(next_status in @terminal_statuses and run.status not in @terminal_statuses,
          do: now,
          else: run.finished_at
        ),
      failure_count:
        if(next_status == :failed, do: run.failure_count + 1, else: run.failure_count)
    }
    |> Map.merge(attrs)
  end

  defp build_progress(status, progress, now \\ DateTime.utc_now()) do
    progress = stringify_keys(progress || %{})
    next_stage = Atom.to_string(status)

    %{
      "stage" => next_stage,
      "counts" => progress["counts"] || %{},
      "stage_totals" =>
        if(progress["stage"] == next_stage, do: progress["stage_totals"] || [], else: []),
      "timing" => transition_progress_timing(progress, next_stage, now)
    }
  end

  defp sync_review_counts(run_id) do
    plans_checked =
      Repo.aggregate(
        from(lesson in Lesson,
          where:
            lesson.run_id == ^run_id and lesson.selected == true and lesson.last_plan_version > 0
        ),
        :count
      )

    plans_validated =
      Repo.aggregate(
        from(lesson in Lesson,
          where:
            lesson.run_id == ^run_id and lesson.selected == true and
              lesson.status in ["ready_for_review", "approved", "compiled", "applied"]
        ),
        :count
      )

    lessons_approved =
      Repo.aggregate(
        from(lesson in Lesson,
          where:
            lesson.run_id == ^run_id and lesson.selected == true and
              lesson.status in ["approved", "compiled", "applied"]
        ),
        :count
      )

    set_progress(run_id, %{
      "counts" => %{
        "plans_checked" => plans_checked,
        "plans_validated" => plans_validated,
        "lessons_approved" => lessons_approved
      }
    })
  end

  defp maybe_link_lesson_sources(run_id) do
    case Repo.get(Run, run_id) do
      %Run{source_schema_version: @source_schema_version} ->
        RichSource.link_lessons(run_id)

      %Run{source_schema_version: version} ->
        {:error, {:unsupported_openstax_source_schema, version}}

      nil ->
        {:error, :not_found}
    end
  end

  defp merge_progress(existing, incoming) do
    existing = stringify_keys(existing || %{})
    incoming = stringify_keys(incoming || %{})

    Map.merge(existing, incoming, fn
      "counts", existing_counts, incoming_counts
      when is_map(existing_counts) and is_map(incoming_counts) ->
        Map.merge(existing_counts, incoming_counts)

      _key, _existing_value, incoming_value ->
        incoming_value
    end)
  end

  defp maybe_merge_transition_progress(progress, incoming) when is_map(incoming) do
    stage = progress["stage"]
    timing = progress["timing"]

    progress
    |> merge_progress(incoming)
    |> Map.put("stage", stage)
    |> Map.put("timing", timing)
  end

  defp maybe_merge_transition_progress(progress, _incoming), do: progress

  defp touch_progress_timing(progress, %Run{} = run, now) do
    current_stage = Atom.to_string(run.status)

    existing =
      run.progress
      |> Kernel.||(%{})
      |> stringify_keys()
      |> Map.put_new("updated_at", run.updated_at || run.started_at)

    timing =
      existing
      |> transition_progress_timing(current_stage, now)
      |> record_completed_item_durations(existing, progress, now)
      |> Map.put("last_progress_at", DateTime.to_iso8601(now))

    progress
    |> Map.put("stage", current_stage)
    |> Map.put("timing", timing)
  end

  defp transition_progress_timing(progress, next_stage, now) do
    timing =
      case progress["timing"] do
        value when is_map(value) -> stringify_keys(value)
        _ -> %{}
      end

    previous_stage = progress["stage"]
    now_iso = DateTime.to_iso8601(now)
    history = timing["stage_history"] |> List.wrap()

    cond do
      is_binary(previous_stage) and previous_stage != "" and previous_stage != next_stage ->
        history =
          history
          |> Kernel.++([
            stage_history_entry(
              previous_stage,
              timing["stage_started_at"],
              now
            )
          ])
          |> Enum.take(-@progress_timing_history_limit)

        %{
          "stage_started_at" => now_iso,
          "last_progress_at" => now_iso,
          "stage_history" => history,
          "item_durations_seconds" => []
        }

      true ->
        %{
          "stage_started_at" =>
            timing["stage_started_at"] ||
              datetime_to_iso8601(run_progress_fallback_datetime(progress)) || now_iso,
          "last_progress_at" => timing["last_progress_at"] || now_iso,
          "stage_history" => history,
          "item_durations_seconds" => timing["item_durations_seconds"] |> List.wrap()
        }
    end
  end

  defp record_completed_item_durations(
         timing,
         _previous_progress,
         %{"lesson_planning" => planning},
         _now
       )
       when is_map(planning),
       do: timing

  defp record_completed_item_durations(timing, previous_progress, progress, now) do
    with {previous_completed, previous_total} <- progress_total(previous_progress),
         {completed, total} <- progress_total(progress),
         true <- total == previous_total and completed > previous_completed,
         {:ok, sample_started_at, _offset} <-
           DateTime.from_iso8601(item_started_at(previous_progress, timing) || "") do
      duration =
        now
        |> DateTime.diff(sample_started_at, :millisecond)
        |> max(0)
        |> Kernel./(completed - previous_completed)
        |> Kernel./(1_000)

      samples =
        timing["item_durations_seconds"]
        |> List.wrap()
        |> Kernel.++(List.duplicate(duration, completed - previous_completed))
        |> Enum.take(-@progress_item_history_limit)

      Map.put(timing, "item_durations_seconds", samples)
    else
      _ -> timing
    end
  end

  defp item_started_at(previous_progress, timing) do
    previous_progress
    |> Map.get("current_item", %{})
    |> case do
      current when is_map(current) -> current["started_at"] || current[:started_at]
      _ -> nil
    end
    |> Kernel.||(timing["last_progress_at"])
  end

  defp progress_total(progress) when is_map(progress) do
    progress
    |> Map.get("stage_totals", [])
    |> List.wrap()
    |> Enum.find_value(fn
      total when is_map(total) ->
        completed = total["completed"] || total[:completed]
        count = total["total"] || total[:total]

        if is_number(completed) and is_number(count) and count > 0,
          do: {completed, count},
          else: nil

      _ ->
        nil
    end)
  end

  defp progress_total(_), do: nil

  defp stage_history_entry(stage, started_at, finished_at) do
    %{
      "stage" => stage,
      "started_at" => started_at,
      "finished_at" => DateTime.to_iso8601(finished_at),
      "duration_seconds" => elapsed_seconds(started_at, finished_at)
    }
  end

  defp elapsed_seconds(started_at, finished_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> max(DateTime.diff(finished_at, parsed, :second), 0)
      _ -> nil
    end
  end

  defp elapsed_seconds(_started_at, _finished_at), do: nil

  defp run_progress_fallback_datetime(progress) do
    progress["updated_at"] || progress["started_at"]
  end

  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso8601(value) when is_binary(value), do: value
  defp datetime_to_iso8601(_), do: nil

  defp update_run(run_id, attrs) do
    with %Run{} = run <- Repo.get(Run, run_id),
         {:ok, updated} <- run |> Run.update_changeset(attrs) |> Repo.update() do
      PubSub.broadcast(updated)
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_run_if_status(run_id, expected_status, attrs) do
    result =
      Repo.transaction(fn ->
        run =
          Repo.one(
            from(run in Run,
              where: run.id == ^run_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:not_found)

        :ok = rollback_unless_ok(ensure_status(run.status, expected_status))

        attrs = touch_progress_attrs(attrs, run)

        run
        |> Run.update_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, updated} ->
        PubSub.broadcast(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch_progress_attrs(attrs, %Run{} = run) do
    case Map.fetch(attrs, :progress) do
      {:ok, incoming} when is_map(incoming) ->
        progress =
          run.progress
          |> merge_progress(incoming)
          |> Map.put("stage", Atom.to_string(run.status))
          |> touch_progress_timing(run, DateTime.utc_now())

        Map.put(attrs, :progress, progress)

      _ ->
        attrs
    end
  end

  defp reconcile_lesson_planning_locked(run, generation, now, duration_sample \\ nil) do
    lessons = lock_selected_lessons(run.id)

    active =
      Enum.filter(
        lessons,
        &(&1.planning_generation == generation and
            &1.planning_state in @active_lesson_planning_states)
      )

    pending =
      Enum.filter(
        lessons,
        &(&1.planning_generation == generation and &1.planning_state == "pending")
      )

    open_slots = max(run.lesson_planning_parallelism - length(active), 0)

    pending
    |> Enum.take(open_slots)
    |> Enum.each(&enqueue_lesson_job_locked(&1, run, generation, now))

    lessons = lock_selected_lessons(run.id)
    progress = parallel_lesson_progress(run, lessons, generation, now, duration_sample)
    stats = lesson_planning_stats(lessons, generation)

    cond do
      run.status == :planning_lessons and stats.pending == 0 and stats.active == 0 and
          stats.failed > 0 ->
        failed_lessons =
          lessons
          |> Enum.filter(
            &(&1.planning_generation == generation and &1.planning_state == "failed")
          )
          |> Enum.take(20)

        error = %{
          "phase" => "lesson_planning",
          "reason" => "lesson_jobs_failed",
          "message" =>
            "#{stats.failed} lesson #{if(stats.failed == 1, do: "plan", else: "plans")} could not be generated after retries. Retry the import to regenerate only the failed lessons.",
          "recoverable" => true,
          "failed_count" => stats.failed,
          "lesson_ids" => Enum.map(failed_lessons, & &1.id),
          "lesson_titles" => Enum.map(failed_lessons, & &1.title),
          "planning_generation" => generation
        }

        updated =
          run
          |> Run.update_changeset(
            transition_attrs(run, :failed, %{error: error, progress: progress})
          )
          |> Repo.update!()

        :ok = rollback_unless_ok(Outbox.persist(updated))
        %{run: updated, terminal?: true}

      run.status == :planning_lessons and stats.pending == 0 and stats.active == 0 and
        stats.completed == stats.total and stats.total > 0 ->
        latest_plan_version = Enum.max(Enum.map(lessons, & &1.last_plan_version), fn -> 0 end)

        Repo.update_all(
          from(unit in Unit, where: unit.run_id == ^run.id),
          set: [status: "ready_for_review", updated_at: now]
        )

        updated =
          run
          |> Run.update_changeset(
            transition_attrs(run, :awaiting_lesson_approval, %{
              latest_plan_version: latest_plan_version,
              progress: progress,
              error: nil
            })
          )
          |> Repo.update!()

        :ok = rollback_unless_ok(Outbox.persist(updated))
        %{run: updated, terminal?: true}

      true ->
        updated =
          run
          |> Run.update_changeset(%{progress: progress})
          |> Repo.update!()

        %{run: updated, terminal?: false}
    end
  end

  defp enqueue_lesson_job_locked(%Lesson{} = lesson, %Run{} = run, generation, now) do
    request_id = lesson.planning_request_id || Ecto.UUID.generate()

    args = %{
      "run_id" => run.id,
      "lesson_id" => lesson.id,
      "generation" => generation,
      "request_id" => request_id,
      "position" => lesson.planning_position,
      "operation" => lesson.planning_operation,
      "base_plan_version" => lesson.planning_base_plan_version,
      "attempt_offset" => lesson.planning_attempts
    }

    job =
      case insert_lesson_plan_job(LessonPlanWorker.new(args)) do
        {:ok, %Oban.Job{} = job} -> job
        {:error, reason} -> Repo.rollback({:lesson_job_enqueue_failed, lesson.id, reason})
      end

    if not is_integer(job.id) do
      Repo.rollback({:lesson_job_enqueue_failed, lesson.id, :missing_job_id})
    end

    lesson
    |> Lesson.changeset(%{
      planning_state: "queued",
      planning_generation: generation,
      planning_request_id: request_id,
      planning_oban_job_id: job.id,
      planning_queued_at: lesson.planning_queued_at || now,
      planning_last_progress_at: now,
      planning_finished_at: nil
    })
    |> Repo.update!()

    Telemetry.lesson_job_enqueued(run.id, lesson.id, generation, lesson.planning_operation)
  end

  defp insert_lesson_plan_job(job_changeset) do
    case Application.get_env(:oli, :openstax_course_import_lesson_job_inserter) do
      nil -> Oban.insert(job_changeset)
      inserter when is_function(inserter, 1) -> inserter.(job_changeset)
      _invalid -> {:error, :invalid_lesson_job_inserter}
    end
  end

  defp parallel_lesson_progress(run, lessons, generation, now, duration_sample) do
    stats = lesson_planning_stats(lessons, generation)
    active_items = parallel_active_items(lessons, generation)

    previous_lesson_planning =
      run.progress
      |> Kernel.||(%{})
      |> Map.get("lesson_planning", %{})
      |> stringify_keys()

    lesson_planning = %{
      "total" => stats.total,
      "pending" => stats.pending,
      "queued" => stats.queued,
      "running" => stats.running,
      "retrying" => stats.retrying,
      "completed" => stats.completed,
      "failed" => stats.failed,
      "parallelism" => run.lesson_planning_parallelism,
      "active_items" => active_items
    }

    incoming = %{
      "work_state" => parallel_work_state(stats, run.status),
      "lesson_planning" => lesson_planning,
      "active_items" => active_items,
      "current_items" => active_items,
      "current_item" => List.first(active_items),
      "counts" => %{
        "plans_total" => stats.total,
        "plans_pending" => stats.pending,
        "plans_queued" => stats.queued,
        "plans_running" => stats.running,
        "plans_retrying" => stats.retrying,
        "plans_checked" => stats.completed,
        "plans_completed" => stats.completed,
        "plans_failed" => stats.failed,
        "plans_validated" => stats.validated,
        "lessons_approved" => stats.approved,
        "effective_parallelism" => min(run.lesson_planning_parallelism, max(stats.active, 1))
      },
      "stage_totals" => [
        %{
          "label" => "Lesson plans checked",
          "completed" => stats.completed,
          "total" => stats.total
        }
      ]
    }

    progress =
      run.progress
      |> merge_progress(incoming)
      |> Map.put("stage", Atom.to_string(run.status))

    progress =
      if previous_lesson_planning == lesson_planning and is_nil(duration_sample) do
        progress
      else
        touch_progress_timing(progress, run, now)
      end

    maybe_append_parallel_duration(progress, duration_sample)
  end

  defp lesson_planning_stats(lessons, generation) do
    current = Enum.filter(lessons, &(&1.planning_generation == generation))

    counts =
      Enum.frequencies_by(current, fn lesson ->
        if lesson.planning_state in Lesson.planning_states(),
          do: lesson.planning_state,
          else: "pending"
      end)

    completed =
      Enum.count(lessons, &(&1.last_plan_version > 0 and &1.planning_state == "completed"))

    %{
      total: length(lessons),
      pending: Map.get(counts, "pending", 0),
      queued: Map.get(counts, "queued", 0),
      running: Map.get(counts, "running", 0),
      retrying: Map.get(counts, "retrying", 0),
      completed: completed,
      failed: Map.get(counts, "failed", 0),
      active:
        Map.get(counts, "queued", 0) + Map.get(counts, "running", 0) +
          Map.get(counts, "retrying", 0),
      validated:
        Enum.count(
          lessons,
          &(&1.status in ["ready_for_review", "approved", "compiled", "applied"])
        ),
      approved: Enum.count(lessons, &(&1.status in ["approved", "compiled", "applied"]))
    }
  end

  defp parallel_active_items(lessons, generation) do
    lessons
    |> Enum.filter(
      &(&1.planning_generation == generation and
          &1.planning_state in @active_lesson_planning_states)
    )
    |> Enum.sort_by(&(&1.planning_position || 0))
    |> Enum.map(fn lesson ->
      %{
        "lesson_id" => lesson.id,
        "title" => lesson.title,
        "state" => lesson.planning_state,
        "attempt" => lesson.planning_attempts,
        "position" => lesson.planning_position,
        "operation" => lesson.planning_operation
      }
    end)
  end

  defp parallel_work_state(%{running: running}, _status) when running > 0, do: "running"
  defp parallel_work_state(%{retrying: retrying}, _status) when retrying > 0, do: "retrying"
  defp parallel_work_state(%{queued: queued}, _status) when queued > 0, do: "queued"
  defp parallel_work_state(%{pending: pending}, _status) when pending > 0, do: "queued"

  defp parallel_work_state(%{failed: failed}, :awaiting_lesson_approval) when failed > 0,
    do: "idle"

  defp parallel_work_state(_stats, _status), do: "completed"

  defp maybe_append_parallel_duration(progress, duration)
       when is_number(duration) and duration >= 0 do
    timing = stringify_keys(progress["timing"] || %{})

    samples =
      timing["item_durations_seconds"]
      |> List.wrap()
      |> Kernel.++([duration])
      |> Enum.take(-@progress_item_history_limit)

    Map.put(progress, "timing", Map.put(timing, "item_durations_seconds", samples))
  end

  defp maybe_append_parallel_duration(progress, _duration), do: progress

  defp normalize_lesson_job_args(args) do
    normalized = stringify_keys(args)

    values = %{
      run_id: normalized["run_id"],
      lesson_id: normalized["lesson_id"],
      generation: normalized["generation"],
      request_id: normalized["request_id"],
      position: normalized["position"],
      operation: normalized["operation"],
      base_plan_version: normalized["base_plan_version"] || 0
    }

    if is_binary(values.run_id) and is_binary(values.lesson_id) and
         is_integer(values.generation) and values.generation > 0 and
         is_binary(values.request_id) and is_integer(values.position) and values.position > 0 and
         values.operation in Lesson.planning_operations() and
         is_integer(values.base_plan_version) and values.base_plan_version >= 0 do
      {:ok, values}
    else
      {:error, :invalid_lesson_job}
    end
  end

  defp ensure_parallel_generation(%Run{} = run, generation, allowed_statuses) do
    cond do
      run.lesson_planning_strategy != :parallel_v1 ->
        {:error, :stale_lesson_planning_job}

      run.lesson_planning_generation != generation ->
        {:error, :stale_lesson_planning_job}

      run.status not in allowed_statuses ->
        {:error, :stale_lesson_planning_job}

      true ->
        :ok
    end
  end

  defp planning_statuses("initial"), do: [:planning_lessons]
  defp planning_statuses("regenerate"), do: [:awaiting_lesson_approval]

  defp pending_planning_attrs(lesson, generation, position, operation, now) do
    if lesson.planning_generation == generation and is_binary(lesson.planning_request_id) do
      %{
        planning_position: position,
        planning_operation: operation,
        planning_last_progress_at: lesson.planning_last_progress_at || now
      }
    else
      %{
        planning_state: "pending",
        planning_operation: operation,
        planning_generation: generation,
        planning_request_id: Ecto.UUID.generate(),
        planning_position: position,
        planning_oban_job_id: nil,
        planning_attempts: 0,
        planning_base_plan_version: lesson.last_plan_version,
        planning_queued_at: nil,
        planning_started_at: nil,
        planning_last_progress_at: now,
        planning_finished_at: nil,
        planning_error: nil,
        generation_checkpoint: lesson.generation_checkpoint || %{}
      }
    end
  end

  defp completed_planning_attrs(lesson, generation, position, now) do
    %{
      planning_state: "completed",
      planning_operation: "initial",
      planning_generation: generation,
      planning_request_id: nil,
      planning_position: position,
      planning_oban_job_id: nil,
      planning_base_plan_version: lesson.last_plan_version,
      planning_last_progress_at: now,
      planning_finished_at: lesson.planning_finished_at || now,
      planning_error: nil
    }
  end

  defp lock_run!(run_id) do
    Repo.one(from(run in Run, where: run.id == ^run_id, lock: "FOR UPDATE")) ||
      Repo.rollback(:not_found)
  end

  defp lock_lesson!(lesson_id, run_id) do
    Repo.one(
      from(lesson in Lesson,
        where: lesson.id == ^lesson_id and lesson.run_id == ^run_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  defp lock_selected_lessons(run_id) do
    Repo.all(
      from(lesson in Lesson,
        join: unit in Unit,
        on: unit.id == lesson.unit_id,
        where: lesson.run_id == ^run_id and lesson.selected == true,
        order_by: [asc: unit.order, asc: lesson.order, asc: lesson.id],
        select: lesson,
        lock: "FOR UPDATE"
      )
    )
  end

  defp planning_position_for_lesson(%Lesson{} = lesson) do
    lesson.run_id
    |> lock_selected_lessons()
    |> Enum.find_index(&(&1.id == lesson.id))
    |> case do
      nil -> 1
      index -> index + 1
    end
  end

  defp review_status_for_lesson(%Lesson{status: status})
       when status in ["needs_attention", "needs_repair"],
       do: status

  defp review_status_for_lesson(_lesson), do: "ready_for_review"

  defp maybe_update_latest_plan_version_locked(run, version)
       when is_integer(version) and version > run.latest_plan_version do
    run
    |> Run.update_changeset(%{latest_plan_version: version})
    |> Repo.update!()
  end

  defp maybe_update_latest_plan_version_locked(run, _version), do: run

  defp duration_seconds(%DateTime{} = started_at, %DateTime{} = finished_at) do
    finished_at
    |> DateTime.diff(started_at, :millisecond)
    |> max(0)
    |> Kernel./(1_000)
  end

  defp duration_seconds(_started_at, _finished_at), do: nil

  defp recover_lesson_job_locked(%Lesson{} = lesson, now) do
    job =
      if is_integer(lesson.planning_oban_job_id),
        do: Repo.get(Oban.Job, lesson.planning_oban_job_id),
        else: nil

    job_state = if job, do: to_string(job.state), else: nil
    attempts = max(lesson.planning_attempts, if(job, do: job.attempt || 0, else: 0))

    {attrs, failure_category} =
      case job_state do
        "available" ->
          {%{planning_state: "queued", planning_last_progress_at: now}, nil}

        "executing" ->
          {%{planning_state: "running", planning_last_progress_at: now}, nil}

        state when state in ["scheduled", "retryable"] ->
          {
            %{
              planning_state: "retrying",
              planning_attempts: attempts,
              planning_last_progress_at: now
            },
            nil
          }

        state when state in ["discarded", "cancelled"] ->
          category =
            case state do
              "discarded" -> :background_job_discarded
              "cancelled" -> :background_job_cancelled
            end

          {
            %{
              planning_state: "failed",
              planning_attempts: attempts,
              planning_last_progress_at: now,
              planning_finished_at: now,
              planning_error: %{
                "category" => Atom.to_string(category),
                "attempt" => attempts,
                "retryable" => false
              }
            },
            category
          }

        _missing_or_completed when attempts >= 4 ->
          category =
            if is_nil(job),
              do: :background_job_missing_exhausted,
              else: :background_job_exhausted

          {
            %{
              planning_state: "failed",
              planning_attempts: attempts,
              planning_last_progress_at: now,
              planning_finished_at: now,
              planning_error: %{
                "category" => Atom.to_string(category),
                "attempt" => attempts,
                "retryable" => false
              }
            },
            category
          }

        _missing_or_completed ->
          {
            %{
              planning_state: "pending",
              planning_oban_job_id: nil,
              planning_attempts: attempts,
              planning_last_progress_at: now,
              planning_error: %{
                "category" => "background_job_recovered",
                "attempt" => attempts,
                "retryable" => true
              }
            },
            nil
          }
      end

    updated_lesson =
      lesson
      |> Lesson.changeset(attrs)
      |> Repo.update!()

    case failure_category do
      nil ->
        nil

      category ->
        %{
          lesson_id: updated_lesson.id,
          attempt: updated_lesson.planning_attempts,
          category: category
        }
    end
  end

  defp ensure_lesson_not_busy(%Lesson{planning_state: state})
       when state in @active_lesson_planning_states,
       do: {:error, :lesson_plan_busy}

  defp ensure_lesson_not_busy(%Lesson{
         planning_state: "pending",
         planning_operation: "regenerate",
         planning_request_id: request_id
       })
       when is_binary(request_id),
       do: {:error, :lesson_plan_busy}

  defp ensure_lesson_not_busy(_lesson), do: :ok

  defp announce_parallel_result({:ok, %{run: run, terminal?: terminal?} = result}) do
    result
    |> Map.get(:recovered_failures, [])
    |> Enum.each(fn failure ->
      Telemetry.lesson_job_failed(
        run.id,
        failure.lesson_id,
        failure.attempt,
        failure.category
      )
    end)

    announce_parallel_run(run, terminal?)
    {:ok, run}
  end

  defp announce_parallel_result({:error, reason}), do: {:error, reason}

  defp announce_parallel_run(%Run{} = run, terminal?) do
    PubSub.broadcast(run)

    if terminal? do
      Telemetry.lesson_batch_finished(
        run.id,
        run.lesson_planning_generation,
        run.status,
        completed_stage_duration(run.progress, "planning_lessons"),
        get_in(run.error || %{}, ["failed_count"]) || 0
      )

      dispatch_notification(run)
    end

    :ok
  end

  defp completed_stage_duration(progress, stage) do
    progress
    |> Kernel.||(%{})
    |> get_in(["timing", "stage_history"])
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"stage" => ^stage, "duration_seconds" => duration} when is_number(duration) -> duration
      _entry -> nil
    end)
  end

  defp maybe_reconcile_parallel_review_progress(run_id) do
    case Repo.get(Run, run_id) do
      %Run{
        status: :awaiting_lesson_approval,
        lesson_planning_strategy: :parallel_v1,
        lesson_planning_generation: generation
      }
      when generation > 0 ->
        case reconcile_lesson_planning(run_id, generation) do
          {:ok, _run} -> :ok
          {:error, :stale_lesson_planning_job} -> :ok
          {:error, _reason} -> :ok
        end

      _run ->
        :ok
    end
  end

  defp cancel_run_with_planning_fence(run_id) do
    result =
      Repo.transaction(fn ->
        run = lock_run!(run_id)
        :ok = rollback_unless_ok(ensure_transition_allowed(run.status, :cancelled))
        now = DateTime.utc_now()

        Repo.update_all(
          from(lesson in Lesson,
            where:
              lesson.run_id == ^run.id and
                lesson.planning_state in ^@unfinished_lesson_planning_states
          ),
          set: [
            planning_state: "cancelled",
            planning_finished_at: now,
            planning_last_progress_at: now,
            planning_error: %{"category" => "cancelled_by_user", "retryable" => false},
            updated_at: now
          ]
        )

        {:ok, _cancelled_workflows} =
          Enrichment.cancel_run_workflows(run.id, "Import cancelled by author")

        with {:ok, cancelled} <-
               run
               |> Run.update_changeset(
                 transition_attrs(run, :cancelled, %{
                   lesson_planning_generation: run.lesson_planning_generation + 1
                 })
               )
               |> Repo.update(),
             :ok <- Outbox.persist(cancelled) do
          cancelled
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    after_transition(result)
  end

  defp enqueue_lesson_regeneration(%Run{} = run, lesson_id) do
    result =
      Repo.transaction(fn ->
        locked_run = lock_run!(run.id)
        :ok = rollback_unless_ok(ensure_status(locked_run.status, :awaiting_lesson_approval))

        lesson = lock_lesson!(lesson_id, locked_run.id)
        :ok = rollback_unless_ok(ensure_lesson_not_busy(lesson))

        if lesson.last_plan_version <= 0 do
          Repo.rollback(:missing_lesson_plan)
        end

        generation = max(locked_run.lesson_planning_generation, 1)
        now = DateTime.utc_now()
        request_id = Ecto.UUID.generate()

        Repo.update_all(
          from(plan in LessonPlan, where: plan.lesson_id == ^lesson.id),
          set: [approved_by_user: false, approved_at: nil]
        )

        position = lesson.planning_position || planning_position_for_lesson(lesson)

        queued_lesson =
          lesson
          |> Lesson.changeset(%{
            status: review_status_for_lesson(lesson),
            approved_by_author_id: nil,
            approved_at: nil,
            planning_state: "pending",
            planning_operation: "regenerate",
            planning_generation: generation,
            planning_request_id: request_id,
            planning_position: position,
            planning_oban_job_id: nil,
            planning_attempts: 0,
            planning_base_plan_version: lesson.last_plan_version,
            planning_queued_at: nil,
            planning_started_at: nil,
            planning_last_progress_at: now,
            planning_finished_at: nil,
            planning_error: nil,
            generation_checkpoint: %{}
          })
          |> Repo.update!()

        locked_run =
          if locked_run.lesson_planning_strategy != :parallel_v1 or
               locked_run.lesson_planning_generation != generation do
            locked_run
            |> Run.update_changeset(%{
              lesson_planning_strategy: :parallel_v1,
              lesson_planning_generation: generation,
              lesson_planning_parallelism: lesson_planning_parallelism(locked_run.ai_backend)
            })
            |> Repo.update!()
          else
            locked_run
          end

        reconciliation = reconcile_lesson_planning_locked(locked_run, generation, now)
        {Repo.reload!(queued_lesson), reconciliation.run}
      end)

    case result do
      {:ok, {lesson, updated_run}} ->
        PubSub.broadcast(updated_run)
        {:ok, lesson}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_lesson_plan_job_failure(args, attempt, category, planning_state, details) do
    with {:ok, job_args} <- normalize_lesson_job_args(args) do
      result =
        Repo.transaction(fn ->
          run = lock_run!(job_args.run_id)

          :ok =
            rollback_unless_ok(
              ensure_parallel_generation(
                run,
                job_args.generation,
                planning_statuses(job_args.operation)
              )
            )

          lesson = lock_lesson!(job_args.lesson_id, run.id)

          if lesson.planning_request_id != job_args.request_id or
               lesson.planning_generation != job_args.generation or
               lesson.planning_state == "completed" do
            Repo.rollback(:stale_lesson_planning_job)
          end

          now = DateTime.utc_now()
          terminal? = planning_state == "failed"

          failure_attrs =
            %{
              planning_state: planning_state,
              planning_attempts: max(lesson.planning_attempts, attempt),
              planning_last_progress_at: now,
              planning_finished_at: if(terminal?, do: now, else: nil),
              planning_error: %{
                "category" => Atom.to_string(category),
                "attempt" => attempt,
                "retryable" => not terminal?,
                "message" => lesson_planning_failure_message(category),
                "details" => details
              }
            }
            |> maybe_put_terminal_lesson_attention(terminal?)

          updated_lesson =
            lesson
            |> Lesson.changeset(failure_attrs)
            |> Repo.update!()

          duration =
            if terminal?, do: duration_seconds(updated_lesson.planning_started_at, now), else: nil

          reconciliation =
            reconcile_lesson_planning_locked(run, job_args.generation, now, duration)

          {updated_lesson, reconciliation.run, reconciliation.terminal?}
        end)

      case result do
        {:ok, {lesson, updated_run, terminal?}} ->
          announce_parallel_run(updated_run, terminal?)

          if planning_state == "retrying" do
            Telemetry.lesson_job_retrying(updated_run.id, lesson.id, attempt, category)
          else
            Telemetry.lesson_job_failed(updated_run.id, lesson.id, attempt, category)
          end

          {:ok, lesson, updated_run}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp lesson_planning_failure_message(:content_validation_exhausted),
    do:
      "Generated Basic content did not satisfy the lesson contract after bounded generation and repair."

  defp lesson_planning_failure_message(:content_quality_exhausted),
    do:
      "The independent content critic did not approve this Basic lesson after one targeted repair."

  defp lesson_planning_failure_message(:content_quality_stalled),
    do: "Content repair stopped because the independent critic repeated the same findings."

  defp lesson_planning_failure_message(:question_quality_exhausted),
    do:
      "The independent question critic did not approve the question set after one targeted repair."

  defp lesson_planning_failure_message(:question_quality_stalled),
    do: "Question repair stopped because the independent critic repeated the same findings."

  defp lesson_planning_failure_message(:agent_persistence_failed),
    do: "Question generation could not start with the lesson's author context."

  defp lesson_planning_failure_message(:question_agent_exhausted),
    do: "Question generation exhausted its bounded review or validation budget."

  defp lesson_planning_failure_message(:source_prompt_limit_exceeded),
    do: "The retained lesson source is too large for one generation request."

  defp lesson_planning_failure_message(:current_source_ast_required),
    do:
      "This lesson does not contain the current source AST. Start a new OpenStax import instead."

  defp lesson_planning_failure_message(:provider_timeout),
    do: "The content provider timed out; the lesson will be retried automatically."

  defp lesson_planning_failure_message(:rate_limited),
    do: "The content provider throttled the request; the lesson will be retried automatically."

  defp lesson_planning_failure_message(:provider_unavailable),
    do:
      "The content provider is temporarily unavailable; the lesson will be retried automatically."

  defp lesson_planning_failure_message(:database_unavailable),
    do: "The database was temporarily unavailable; the lesson will be retried automatically."

  defp lesson_planning_failure_message(:provider_unauthorized),
    do: "The content provider rejected the configured credentials."

  defp lesson_planning_failure_message(:provider_forbidden),
    do: "The content provider denied this generation request."

  defp lesson_planning_failure_message(:provider_request_rejected),
    do: "The content provider rejected the generation request."

  defp lesson_planning_failure_message(:provider_not_configured),
    do: "The content provider is not configured for this environment."

  defp lesson_planning_failure_message(:provider_configuration_error),
    do: "The content provider configuration is invalid."

  defp lesson_planning_failure_message(:unclassified_generation_failure),
    do:
      "Lesson generation returned an unexpected result and was stopped without automatic retries."

  defp lesson_planning_failure_message(:lesson_plan_persistence_failed),
    do: "The generated lesson could not be saved and needs attention."

  defp lesson_planning_failure_message(:plan_schema_version_mismatch),
    do: "The generated lesson did not match this import's plan schema version."

  defp lesson_planning_failure_message(:internal_exception),
    do: "Lesson generation encountered an unexpected internal error and needs attention."

  defp lesson_planning_failure_message(_category),
    do: "The lesson could not be generated and needs attention."

  defp maybe_put_terminal_lesson_attention(attrs, true),
    do: Map.put(attrs, :status, "needs_attention")

  defp maybe_put_terminal_lesson_attention(attrs, false), do: attrs

  defp authorized_run(run_id, author) do
    with {:ok, run} <- get_owned_run(run_id, author),
         :ok <- ensure_current_run_schema(run),
         %Project{} = project <- Repo.get(Project, run.project_id),
         :ok <- authorize_project(project, author) do
      {:ok, run}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_current_run_schema(%Run{} = run), do: ImportContract.ensure_current_run(run)

  defp get_owned_run(run_id, author) do
    case Repo.get(Run, run_id) do
      %Run{author_id: author_id} = run when author_id == author.id -> {:ok, run}
      %Run{} -> {:error, :not_authorized}
      nil -> {:error, :not_found}
    end
  end

  defp lesson_with_run(lesson_id) do
    case Repo.one(from(lesson in Lesson, where: lesson.id == ^lesson_id, preload: [:run])) do
      nil -> {:error, :not_found}
      lesson -> {:ok, lesson}
    end
  end

  defp preload_run(run) do
    Repo.preload(
      run,
      [
        enrichment_proposals:
          from(proposal in EnrichmentProposal,
            order_by: [asc: proposal.lesson_id, asc: proposal.rank],
            preload: [
              research_sets:
                ^from(research in EnrichmentResearchSet,
                  order_by: [desc: research.version]
                ),
              simulation_specs:
                ^from(spec in SimulationSpec,
                  order_by: [desc: spec.version]
                ),
              simulation_artifacts:
                ^from(artifact in SimulationArtifact,
                  order_by: [desc: artifact.version]
                )
            ]
          ),
        units:
          from(unit in Unit,
            order_by: [asc: unit.order],
            preload: [
              lessons:
                ^from(lesson in Lesson,
                  order_by: [asc: lesson.order],
                  preload: [
                    plans:
                      ^from(plan in LessonPlan,
                        order_by: [desc: plan.version]
                      )
                  ]
                )
            ]
          )
      ],
      force: true
    )
  end

  defp ensure_project_root_empty(project, resource_id) do
    case AuthoringResolver.root_container(project.slug) do
      %Revision{resource_id: ^resource_id, children: children} when children in [nil, []] -> :ok
      %Revision{resource_id: ^resource_id} -> {:error, :project_root_not_empty}
      %Revision{} -> {:error, :target_must_be_project_root}
      nil -> {:error, :invalid_target}
    end
  end

  defp target_resource_id(%Revision{resource_id: id}) when is_integer(id), do: {:ok, id}
  defp target_resource_id(id) when is_integer(id), do: {:ok, id}
  defp target_resource_id(_), do: {:error, :invalid_target}

  defp ensure_no_active_run(project_id, target_resource_id) do
    if Repo.exists?(
         from(run in Run,
           where:
             run.project_id == ^project_id and
               run.target_root_container_resource_id == ^target_resource_id and
               run.status in ^@active_statuses
         )
       ),
       do: {:error, :run_in_progress},
       else: :ok
  end

  defp cancel_background_jobs(run_id) do
    query =
      from(job in Oban.Job,
        where:
          job.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'run_id' = ?", job.args, ^run_id)
      )

    {:ok, _cancelled_jobs} = Oban.cancel_all_jobs(query)
    :ok
  rescue
    exception ->
      Logger.warning(
        "OpenStax course import #{run_id} was cancelled, but its background job cancellation raised: #{Exception.message(exception)}"
      )

      :ok
  end

  defp authorize_project(project, author) do
    case EditingUtils.authorize_user(author, project) do
      {:ok} -> :ok
      _ -> {:error, :not_authorized}
    end
  rescue
    _ -> {:error, :not_authorized}
  end

  defp ensure_feature_available(project) do
    if test_conveniences_enabled?() or
         ScopedFeatureFlags.enabled?(:openstax_course_import, project),
       do: :ok,
       else: {:error, :feature_disabled}
  rescue
    _ -> {:error, :feature_disabled}
  end

  defp ensure_status(current, expected) do
    if current == expected,
      do: :ok,
      else: {:error, {:invalid_status, current, expected}}
  end

  defp rollback_unless_ok(:ok), do: :ok
  defp rollback_unless_ok({:error, reason}), do: Repo.rollback(reason)

  defp ensure_transition_allowed(current, next) do
    if next in Map.get(@allowed_transitions, current, []),
      do: :ok,
      else: {:error, {:invalid_transition, current, next}}
  end

  defp validate_plan_mode(mode) when mode in ["basic", "advanced"], do: :ok
  defp validate_plan_mode(_), do: {:error, :invalid_plan_mode}

  defp handle_run_changeset_error(changeset) do
    case changeset.errors[:target_root_container_resource_id] do
      nil -> {:error, changeset}
      _ -> {:error, :run_in_progress}
    end
  end

  defp dispatch_notification(run) do
    case Outbox.dispatch(run) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "OpenStax course import notification for #{run.id} is durable but awaiting dispatcher recovery: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp count_snapshot_sections(chapters) do
    Enum.reduce(chapters, 0, &(&2 + length(&1["sections"] || [])))
  end

  defp failure_message(phase, reason) do
    "The #{phase} stage failed: #{inspect(reason)}"
  end

  defp failure_payload(phase, reason) do
    %{
      "phase" => to_string(phase),
      "reason" => inspect(reason),
      "message" => failure_message(phase, reason),
      "recoverable" => recoverable_failure?(phase, reason)
    }
  end

  defp recoverable_failure?(:validation, _reason), do: false
  defp recoverable_failure?("validation", _reason), do: false
  defp recoverable_failure?(_phase, :invalid_openstax_url), do: false
  defp recoverable_failure?(_phase, _reason), do: true

  defp normalize_simulation_author_feedback(nil), do: {:ok, nil}

  defp normalize_simulation_author_feedback(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) <= 2_000 -> {:ok, value}
      true -> {:error, :simulation_author_feedback_too_long}
    end
  end

  defp normalize_simulation_author_feedback(_value), do: {:error, :invalid_input}

  defp simulation_generation_metadata(nil), do: %{}

  defp simulation_generation_metadata(author_feedback),
    do: %{"author_feedback" => author_feedback}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
