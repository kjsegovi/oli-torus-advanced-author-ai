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
      %{run_id: run_id, source_schema_version: 3}
    )
  end

  def plan_checked(run_id, lesson_id, plan, repair_attempted?) do
    snapshot = plan.checks_snapshot || %{}
    fidelity = result_for(snapshot, "source_fidelity")
    findings = fidelity["findings"] || %{}

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
        plan_schema_version: 6
      }
    )
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
end
