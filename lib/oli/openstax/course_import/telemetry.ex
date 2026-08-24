defmodule Oli.OpenStax.CourseImport.Telemetry do
  @moduledoc """
  Stable telemetry boundary for the rich OpenStax import pipeline.

  Measurements stay numeric and bounded; source text and generated lesson
  content are intentionally excluded from metadata.
  """

  @prefix [:oli, :openstax, :course_import]

  def source_persisted(run_id, counts) do
    execute(
      :source_persisted,
      %{
        sections: number(counts, :sections),
        blocks: number(counts, :blocks),
        assets: number(counts, :assets)
      },
      %{run_id: run_id, source_schema_version: 4}
    )
  end

  def plan_checked(run_id, lesson_id, plan, repair_attempted?) do
    snapshot = plan.checks_snapshot || %{}
    fidelity = result_for(snapshot, "source_fidelity")
    findings = fidelity["findings"] || %{}

    :ok =
      execute(
        :plan_checked,
        %{
          validation_passed: if(snapshot["status"] == "passed", do: 1, else: 0),
          repair_attempted: if(repair_attempted?, do: 1, else: 0),
          included_blocks: numeric(findings["included_block_count"]),
          available_blocks: numeric(findings["available_block_count"]),
          instructional_words: numeric(findings["instructional_word_count"])
        },
        %{
          run_id: run_id,
          lesson_id: lesson_id,
          plan_version: plan.version,
          plan_schema_version: 7
        }
      )

    emit_opportunity_stage(run_id, lesson_id, plan)
  end

  def lesson_job_enqueued(run_id, lesson_id, generation, operation) do
    execute(
      :lesson_job_enqueued,
      %{count: 1},
      %{
        run_id: run_id,
        lesson_id: lesson_id,
        generation: numeric(generation),
        operation: safe_operation(operation)
      }
    )
  end

  def lesson_job_started(run_id, lesson_id, attempt, queue_wait_seconds) do
    execute(
      :lesson_job_started,
      %{
        count: 1,
        attempt: numeric(attempt),
        queue_wait_seconds: numeric(queue_wait_seconds)
      },
      %{run_id: run_id, lesson_id: lesson_id}
    )
  end

  def lesson_job_completed(run_id, lesson_id, attempts, duration_seconds) do
    execute(
      :lesson_job_completed,
      %{
        count: 1,
        attempts: numeric(attempts),
        duration_seconds: numeric(duration_seconds)
      },
      %{run_id: run_id, lesson_id: lesson_id}
    )
  end

  def lesson_job_retrying(run_id, lesson_id, attempt, category) do
    execute(
      :lesson_job_retrying,
      %{count: 1, attempt: numeric(attempt)},
      %{run_id: run_id, lesson_id: lesson_id, reason: reason_class(category)}
    )
  end

  def lesson_job_failed(run_id, lesson_id, attempt, category) do
    execute(
      :lesson_job_failed,
      %{count: 1, attempt: numeric(attempt)},
      %{run_id: run_id, lesson_id: lesson_id, reason: reason_class(category)}
    )
  end

  def lesson_batch_finished(run_id, generation, outcome, duration_seconds, failed_count) do
    execute(
      :lesson_batch_finished,
      %{
        count: 1,
        duration_seconds: numeric(duration_seconds),
        failed_lessons: numeric(failed_count)
      },
      %{
        run_id: run_id,
        generation: numeric(generation),
        outcome: safe_batch_outcome(outcome)
      }
    )
  end

  def media_staged(run_id, result) do
    execute(
      :media_staged,
      %{
        total: numeric(result.total),
        staged: numeric(result.staged),
        reused: numeric(result.reused),
        skipped: numeric(result.skipped),
        bytes_staged: numeric(result.bytes_staged)
      },
      %{run_id: run_id}
    )
  end

  def media_failed(run_id, reason) do
    execute(:media_failed, %{count: 1}, %{run_id: run_id, reason: reason_class(reason)})
  end

  def compile_failed(run_id, reason, affected_lesson_ids) do
    execute(
      :compile_failed,
      %{count: 1, affected_lessons: length(affected_lesson_ids)},
      %{run_id: run_id, reason: reason_class(reason)}
    )
  end

  @doc """
  Emits one bounded generated-simulation lifecycle event.

  Callers may supply provider usage and validator summaries, but this boundary
  deliberately keeps prompts, claims, source text, generated code, URLs, and
  author-entered decision reasons out of telemetry.
  """
  def simulation_stage(stage, outcome, scope, details \\ %{})

  def simulation_stage(stage, outcome, scope, details)
      when is_map(scope) and is_map(details) do
    execute(
      :simulation_stage,
      %{
        count: 1,
        candidate_count: number(details, :candidate_count),
        duration_ms: number(details, :duration_ms),
        input_tokens: number(details, :input_tokens),
        output_tokens: number(details, :output_tokens),
        web_search_calls: number(details, :web_search_calls),
        source_count: number(details, :source_count),
        repair_count: number(details, :repair_count),
        validation_failures: number(details, :validation_failures),
        artifact_bytes: number(details, :artifact_bytes),
        capi_sample_count: number(details, :capi_sample_count),
        capi_sample_failures: number(details, :capi_sample_failures)
      },
      %{
        run_id: map_value(scope, :run_id),
        lesson_id: map_value(scope, :lesson_id),
        proposal_id: map_value(scope, :proposal_id),
        record_id: map_value(scope, :record_id),
        version: numeric(map_value(scope, :version)),
        stage: safe_stage(stage),
        outcome: safe_simulation_outcome(outcome),
        provider: safe_label(map_value(details, :provider)),
        model: safe_label(map_value(details, :model)),
        rendering_mode: safe_rendering_mode(map_value(details, :rendering_mode)),
        library_ids: safe_library_ids(map_value(details, :library_ids))
      }
    )
  end

  def simulation_stage(_stage, _outcome, _scope, _details), do: :ok

  @doc "Emits an author decision without recording free-form decision text."
  def simulation_author_decision(decision, scope) when is_map(scope) do
    execute(
      :simulation_author_decision,
      %{count: 1},
      %{
        run_id: map_value(scope, :run_id),
        lesson_id: map_value(scope, :lesson_id),
        proposal_id: map_value(scope, :proposal_id),
        record_id: map_value(scope, :record_id),
        version: numeric(map_value(scope, :version)),
        decision: safe_author_decision(decision)
      }
    )
  end

  def simulation_author_decision(_decision, _scope), do: :ok

  defp execute(event, measurements, metadata) do
    :telemetry.execute(@prefix ++ [event], measurements, metadata)
    :ok
  end

  defp result_for(%{"results" => results}, check_type) when is_list(results) do
    Enum.find(results, %{}, fn result ->
      is_map(result) and result["check_type"] == check_type
    end)
  end

  defp result_for(_snapshot, _check_type), do: %{}

  defp number(counts, key) when is_map(counts) do
    counts
    |> Map.get(key, Map.get(counts, to_string(key), 0))
    |> numeric()
  end

  defp map_value(value, key) when is_map(value) do
    Map.get(value, key, Map.get(value, to_string(key)))
  end

  defp map_value(_value, _key), do: nil

  defp numeric(value) when is_integer(value) and value >= 0, do: value
  defp numeric(value) when is_float(value) and value >= 0, do: value
  defp numeric(_value), do: 0

  defp reason_class(reason) when is_atom(reason), do: reason

  defp reason_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      class when is_atom(class) -> class
      _ -> :unclassified
    end
  end

  defp reason_class(_reason), do: :unclassified

  defp safe_operation("initial"), do: :initial
  defp safe_operation("regenerate"), do: :regenerate
  defp safe_operation(_operation), do: :unknown

  defp safe_batch_outcome(:awaiting_lesson_approval), do: :ready_for_review
  defp safe_batch_outcome(:failed), do: :failed
  defp safe_batch_outcome(_outcome), do: :unknown

  defp safe_stage(stage)
       when stage in [:opportunity, :research, :specification, :artifact, :delivery],
       do: stage

  defp safe_stage(_stage), do: :unknown

  defp safe_simulation_outcome(outcome)
       when outcome in [
              :started,
              :ready_for_review,
              :approved,
              :rejected,
              :omitted,
              :cancelled,
              :superseded,
              :passed,
              :failed
            ],
       do: outcome

  defp safe_simulation_outcome(_outcome), do: :unknown

  defp safe_author_decision(decision)
       when decision in [
              :approve_evidence,
              :reject_evidence,
              :approve_artifact,
              :reject_artifact,
              :omit_proposal,
              :cancel_proposal,
              :cancel_artifact
            ],
       do: decision

  defp safe_author_decision(_decision), do: :unknown

  defp safe_rendering_mode("2d"), do: :two_d
  defp safe_rendering_mode("3d"), do: :three_d
  defp safe_rendering_mode(:two_d), do: :two_d
  defp safe_rendering_mode(:three_d), do: :three_d
  defp safe_rendering_mode(_mode), do: :unknown

  defp safe_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 80)
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp safe_label(_value), do: nil

  defp safe_library_ids(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(16)
  end

  defp emit_opportunity_stage(run_id, lesson_id, plan) do
    metadata = plan.generation_metadata || %{}
    opportunity = map_value(metadata, :simulation_opportunities) || %{}
    status = map_value(opportunity, :status)

    case status do
      "approved" ->
        designer = map_value(opportunity, :designer) || %{}

        simulation_stage(
          :opportunity,
          :approved,
          %{
            run_id: run_id,
            lesson_id: lesson_id,
            record_id: Map.get(plan, :id),
            version: plan.version
          },
          %{
            candidate_count: map_value(opportunity, :opportunity_count),
            duration_ms: map_value(opportunity, :duration_ms),
            input_tokens: sum_metric(opportunity, "input_tokens"),
            output_tokens: sum_metric(opportunity, "output_tokens"),
            repair_count: map_value(opportunity, :repair_count),
            provider: map_value(designer, :provider) |> label_value(),
            model: map_value(designer, :model)
          }
        )

      "omitted" ->
        simulation_stage(
          :opportunity,
          :omitted,
          %{
            run_id: run_id,
            lesson_id: lesson_id,
            record_id: Map.get(plan, :id),
            version: plan.version
          },
          %{}
        )

      _ ->
        :ok
    end
  end

  defp sum_metric(value, metric) when is_map(value) do
    own = map_value(value, metric)
    own = if is_number(own) and own >= 0, do: own, else: 0
    own + (value |> Map.values() |> Enum.map(&sum_metric(&1, metric)) |> Enum.sum())
  end

  defp sum_metric(value, metric) when is_list(value),
    do: value |> Enum.map(&sum_metric(&1, metric)) |> Enum.sum()

  defp sum_metric(_value, _metric), do: 0

  defp label_value(value) when is_atom(value), do: Atom.to_string(value)
  defp label_value(value), do: value
end
