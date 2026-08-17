defmodule Oli.OpenStax.CourseImport.Estimator do
  @moduledoc """
  Produces a conservative, stage-aware estimate for an OpenStax import.

  Estimates intentionally target the next instructor checkpoint. A complete
  import has review gates whose duration is controlled by the instructor, so a
  single end-to-end countdown would be misleading.
  """

  alias Oli.OpenStax.CourseImport.Run

  @active_statuses [
    :preflighting,
    :ingesting,
    :planning_outline,
    :planning_lessons,
    :staging_media,
    :applying
  ]

  @waiting_statuses [
    :awaiting_scope,
    :awaiting_outline_approval,
    :awaiting_lesson_approval,
    :compiling
  ]

  @terminal_statuses [:failed, :cancelled]

  @spec estimate(Run.t(), keyword()) :: map()
  def estimate(run, opts \\ [])

  def estimate(%Run{} = run, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    progress = string_map(run.progress)
    timing = progress |> value("timing", %{}) |> string_map()
    status = run.status
    planning = lesson_planning_stats(run, progress)
    work_state = value(progress, "work_state", derived_work_state(planning))

    common = %{
      "state" => "unavailable",
      "milestone" => milestone(status),
      "lower_seconds" => nil,
      "upper_seconds" => nil,
      "confidence" => "low",
      "stage_elapsed_seconds" => elapsed_seconds(stage_started_at(run, timing), now),
      "stalled" => stalled?(status, work_state, last_progress_at(run, timing), now),
      "last_progress_at" => iso8601(last_progress_at(run, timing)),
      "calculated_at" => iso8601(now),
      "completed" => nil,
      "total" => nil,
      "work_state" => work_state,
      "queue_wait_included" => false,
      "parallelism" => planning.parallelism,
      "queued" => planning.queued,
      "running" => planning.running,
      "retrying" => planning.retrying,
      "failed" => planning.failed
    }

    Map.merge(common, status_estimate(run, progress, timing, now))
  end

  def estimate(_, opts),
    do: unavailable_estimate(Keyword.get(opts, :now, DateTime.utc_now()))

  defp status_estimate(%Run{status: :completed}, _progress, _timing, _now) do
    %{
      "state" => "completed",
      "milestone" => "course_created",
      "lower_seconds" => 0,
      "upper_seconds" => 0,
      "confidence" => "high",
      "stalled" => false
    }
  end

  defp status_estimate(%Run{status: status}, _progress, _timing, _now)
       when status in @terminal_statuses do
    %{
      "state" => "stopped",
      "lower_seconds" => nil,
      "upper_seconds" => nil,
      "stalled" => false
    }
  end

  defp status_estimate(%Run{status: :awaiting_outline_approval} = run, _progress, _timing, _now) do
    {lower, upper, total} = lesson_forecast(run)

    waiting_estimate("lesson_plans_ready", lower, upper, total)
  end

  defp status_estimate(%Run{status: :compiling} = run, progress, timing, _now) do
    {lower, upper} = course_creation_forecast(run, progress, timing)

    waiting_estimate("course_created", lower, upper, lesson_count(run))
  end

  defp status_estimate(%Run{status: status}, _progress, _timing, _now)
       when status in @waiting_statuses do
    waiting_estimate(milestone(status), nil, nil, nil)
  end

  defp status_estimate(%Run{status: status} = run, progress, timing, now)
       when status in @active_statuses do
    active_estimate(run, progress, timing, now)
  end

  defp status_estimate(_run, _progress, _timing, _now), do: %{}

  defp active_estimate(%Run{status: :preflighting} = run, _progress, timing, now) do
    fixed_stage_estimate("scope_ready", 20, 120, run, timing, now)
  end

  defp active_estimate(%Run{status: :ingesting} = run, _progress, timing, now) do
    chapters = max(selected_chapter_count(run), 1)
    lower = 60 + chapters * 15
    upper = 240 + chapters * 90

    fixed_stage_estimate("outline_ready", lower, upper, run, timing, now, 0, chapters)
  end

  defp active_estimate(%Run{status: :planning_outline} = run, _progress, timing, now) do
    fixed_stage_estimate("outline_ready", 30, 240, run, timing, now)
  end

  defp active_estimate(%Run{status: :planning_lessons} = run, progress, timing, now) do
    planning = lesson_planning_stats(run, progress)
    {fallback_completed, fallback_total} = progress_pair(progress, lesson_count(run))

    completed = if planning.total > 0, do: planning.completed, else: fallback_completed
    total = if planning.total > 0, do: planning.total, else: fallback_total
    terminal = min(completed + planning.failed, total || completed + planning.failed)

    "lesson_plans_ready"
    |> parallel_item_estimate(
      terminal,
      total,
      {45, 240},
      timing,
      elapsed_seconds(stage_started_at(run, timing), now),
      planning.parallelism,
      retry_delay_seconds(planning)
    )
    |> Map.put("completed", completed)
  end

  defp active_estimate(%Run{status: :staging_media} = run, progress, timing, now) do
    {completed, total} = progress_pair(progress, required_media_count(run, progress))

    media =
      item_range(
        completed,
        total,
        {2, 45},
        timing,
        elapsed_seconds(stage_started_at(run, timing), now)
      )

    {apply_lower, apply_upper} = apply_forecast(run)

    case media do
      {:ok, lower, upper, confidence} ->
        estimated_range(
          "course_created",
          lower + apply_lower,
          upper + apply_upper,
          completed,
          total,
          confidence
        )

      :unknown ->
        estimated_range(
          "course_created",
          apply_lower + 30,
          apply_upper + 600,
          completed,
          total,
          "low"
        )
    end
  end

  defp active_estimate(%Run{status: :applying} = run, _progress, timing, now) do
    {lower, upper} = apply_forecast(run)
    total = lesson_count(run)

    fixed_stage_estimate(
      "course_created",
      lower,
      upper,
      run,
      timing,
      now,
      0,
      positive_or_nil(total)
    )
  end

  defp fixed_stage_estimate(
         milestone,
         expected_lower,
         expected_upper,
         run,
         timing,
         now,
         completed \\ nil,
         total \\ nil
       ) do
    elapsed = elapsed_seconds(stage_started_at(run, timing), now)
    {lower, upper} = remaining_fixed_range(expected_lower, expected_upper, elapsed)

    estimated_range(milestone, lower, upper, completed, total, "low")
  end

  defp remaining_fixed_range(lower, upper, elapsed)
       when is_integer(elapsed) and elapsed >= 0 and elapsed < upper do
    {max(lower - elapsed, 5), max(upper - elapsed, 30)}
  end

  defp remaining_fixed_range(_lower, upper, elapsed)
       when is_integer(elapsed) and elapsed >= upper do
    {30, max(round(elapsed * 0.5), 300)}
  end

  defp remaining_fixed_range(lower, upper, _elapsed), do: {lower, upper}

  defp parallel_item_estimate(
         milestone,
         completed,
         total,
         prior,
         timing,
         stage_elapsed,
         parallelism,
         retry_delay
       ) do
    case item_range(completed, total, prior, timing, stage_elapsed, parallelism) do
      {:ok, lower, upper, confidence} ->
        milestone
        |> estimated_range(
          lower + retry_delay,
          upper + retry_delay,
          completed,
          total,
          confidence
        )
        |> Map.put("retry_delay_seconds", retry_delay)

      :unknown ->
        %{
          "state" => "estimating",
          "milestone" => milestone,
          "completed" => completed,
          "total" => positive_or_nil(total),
          "confidence" => "low",
          "retry_delay_seconds" => retry_delay
        }
    end
  end

  defp item_range(
         completed,
         total,
         prior,
         timing,
         stage_elapsed,
         parallelism \\ 1
       )

  defp item_range(
         completed,
         total,
         {prior_lower, prior_upper},
         timing,
         stage_elapsed,
         parallelism
       )
       when is_integer(completed) and completed >= 0 and is_integer(total) and
              total >= completed and is_integer(parallelism) and parallelism > 0 do
    remaining = max(total - completed, 0)
    waves = ceil(remaining / parallelism)
    samples = duration_samples(timing)

    {per_item_lower, per_item_upper, confidence} =
      observed_item_range(samples, completed, stage_elapsed, prior_lower, prior_upper)

    lower = round(waves * per_item_lower)
    upper = round(waves * per_item_upper)

    if remaining == 0,
      do: {:ok, 5, 30, confidence},
      else: {:ok, lower, max(upper, lower), confidence}
  end

  defp item_range(_, _, _, _, _, _), do: :unknown

  defp observed_item_range(samples, completed, stage_elapsed, prior_lower, prior_upper) do
    observed =
      case samples do
        [] when is_integer(completed) and completed > 0 and is_number(stage_elapsed) ->
          [stage_elapsed / completed]

        values ->
          values
      end

    case observed do
      [] ->
        {prior_lower, prior_upper, "low"}

      values ->
        center = percentile(values, 0.5)
        slower = percentile(values, 0.8)

        lower = max(prior_lower * 0.6, center * 0.7)
        upper = max(prior_upper * 0.75, slower * 1.4)
        upper = min(upper, max(prior_upper * 4, 3_600))

        {lower, max(upper, lower), confidence(length(values), completed)}
    end
  end

  defp lesson_forecast(run) do
    total = lesson_count(run)
    parallelism = configured_parallelism(run, %{}, total)
    waves = ceil(total / parallelism)

    if total > 0,
      do: {waves * 45, waves * 240, total},
      else: {nil, nil, nil}
  end

  defp course_creation_forecast(run, progress, timing) do
    media_total = required_media_count(run, progress)

    {media_lower, media_upper} =
      case item_range(0, media_total, {2, 45}, timing, nil) do
        {:ok, lower, upper, _confidence} -> {lower, upper}
        :unknown -> {30, 600}
      end

    {apply_lower, apply_upper} = apply_forecast(run)
    {media_lower + apply_lower, media_upper + apply_upper}
  end

  defp apply_forecast(run) do
    lessons = max(lesson_count(run), 1)
    {60 + lessons * 5, 300 + lessons * 25}
  end

  defp progress_pair(progress, fallback_total) do
    case progress_total(progress) do
      {completed, total} -> {integer_count(completed), integer_count(total)}
      nil -> {progress_completed(progress), positive_or_nil(fallback_total)}
    end
  end

  defp progress_total(progress) do
    progress
    |> value("stage_totals", [])
    |> List.wrap()
    |> Enum.find_value(fn total ->
      completed = value(total, "completed", nil)
      count = value(total, "total", nil)

      if is_number(completed) and is_number(count) and count >= 0,
        do: {completed, count},
        else: nil
    end)
  end

  defp progress_completed(progress) do
    counts = progress |> value("counts", %{}) |> string_map()

    ["plans_checked", "assets_staged", "sections_extracted"]
    |> Enum.find_value(0, fn key ->
      case value(counts, key, nil) do
        count when is_number(count) -> integer_count(count)
        _ -> nil
      end
    end)
  end

  defp lesson_planning_stats(%Run{} = run, progress) do
    planning = progress |> value("lesson_planning", %{}) |> string_map()
    counts = planning |> value("counts", %{}) |> string_map()
    lessons = selected_lessons(run)

    states =
      Enum.reduce(
        lessons,
        %{
          "pending" => 0,
          "queued" => 0,
          "running" => 0,
          "retrying" => 0,
          "completed" => 0,
          "failed" => 0,
          "cancelled" => 0
        },
        fn lesson, states -> Map.update!(states, lesson_planning_state(lesson), &(&1 + 1)) end
      )

    total = planning_count(planning, counts, states, "total", length(lessons))
    pending = planning_count(planning, counts, states, "pending", states["pending"])
    queued = planning_count(planning, counts, states, "queued", states["queued"])
    running = planning_count(planning, counts, states, "running", states["running"])
    retrying = planning_count(planning, counts, states, "retrying", states["retrying"])
    completed = planning_count(planning, counts, states, "completed", states["completed"])
    failed = planning_count(planning, counts, states, "failed", states["failed"])
    remaining = max(total - completed - failed, pending + queued + running + retrying)

    %{
      total: total,
      pending: pending,
      queued: queued,
      running: running,
      retrying: retrying,
      completed: completed,
      failed: failed,
      parallelism: configured_parallelism(run, planning, remaining),
      active_items:
        planning
        |> value("active_items", value(planning, "active_lessons", []))
        |> List.wrap()
    }
  end

  defp planning_count(planning, counts, states, key, fallback) do
    direct = value(planning, key, nil)
    nested = value(counts, key, nil)

    cond do
      is_number(direct) -> positive_or_zero(direct)
      is_number(nested) -> positive_or_zero(nested)
      is_number(Map.get(states, key)) -> positive_or_zero(Map.get(states, key))
      true -> positive_or_zero(fallback)
    end
  end

  defp configured_parallelism(run, planning, remaining) do
    configured =
      value(planning, "parallelism", nil) ||
        value(planning, "configured_parallelism", nil) ||
        Map.get(run, :lesson_planning_parallelism)

    configured =
      case configured do
        value when is_integer(value) and value > 0 ->
          value

        _ ->
          3
      end

    case positive_or_zero(remaining) do
      0 -> configured
      count -> min(configured, count)
    end
  end

  defp retry_delay_seconds(%{retrying: retrying, active_items: active_items})
       when retrying > 0 do
    active_items
    |> Enum.filter(fn item -> value(item, "state", nil) in ["retrying", :retrying] end)
    |> Enum.map(fn item ->
      attempt =
        value(item, "attempt", value(item, "planning_attempts", 1))
        |> positive_or_zero()
        |> max(1)

      min(round(:math.pow(2, attempt) * 10), 300)
    end)
    |> Enum.max(fn -> 20 end)
  end

  defp retry_delay_seconds(_planning), do: 0

  defp derived_work_state(%{retrying: count}) when count > 0, do: "retrying"
  defp derived_work_state(%{running: count}) when count > 0, do: "running"
  defp derived_work_state(%{queued: count}) when count > 0, do: "queued"
  defp derived_work_state(_planning), do: nil

  defp selected_lessons(%Run{units: units}) when is_list(units) do
    units
    |> Enum.reject(&(Map.get(&1, :selected) == false))
    |> Enum.flat_map(fn unit ->
      case Map.get(unit, :lessons) do
        lessons when is_list(lessons) -> Enum.reject(lessons, &(Map.get(&1, :selected) == false))
        _ -> []
      end
    end)
  end

  defp selected_lessons(_run), do: []

  defp lesson_planning_state(lesson) do
    case Map.get(lesson, :planning_state) do
      state when state in ["pending", :pending] ->
        if pending_regeneration?(lesson),
          do: "pending",
          else: status_derived_lesson_planning_state(Map.get(lesson, :status))

      state
      when state in [
             "queued",
             "running",
             "retrying",
             "completed",
             "failed",
             "cancelled"
           ] ->
        state

      state
      when state in [:queued, :running, :retrying, :completed, :failed, :cancelled] ->
        Atom.to_string(state)

      _ ->
        status_derived_lesson_planning_state(Map.get(lesson, :status))
    end
  end

  defp status_derived_lesson_planning_state(status)
       when status in [
              "ready_for_review",
              "approved",
              "needs_attention",
              "needs_repair",
              "compiled",
              "applied"
            ],
       do: "completed"

  defp status_derived_lesson_planning_state("failed"), do: "failed"
  defp status_derived_lesson_planning_state(_status), do: "pending"

  defp pending_regeneration?(lesson) do
    Map.get(lesson, :planning_operation) in ["regenerate", :regenerate] and
      is_binary(Map.get(lesson, :planning_request_id))
  end

  defp lesson_count(%Run{units: units}) when is_list(units) do
    units
    |> Enum.reject(&(Map.get(&1, :selected) == false))
    |> Enum.flat_map(fn unit ->
      case Map.get(unit, :lessons) do
        lessons when is_list(lessons) -> Enum.reject(lessons, &(Map.get(&1, :selected) == false))
        _ -> []
      end
    end)
    |> length()
  end

  defp lesson_count(_), do: 0

  defp selected_chapter_count(%Run{} = run) do
    run.scope_manifest
    |> string_map()
    |> value("selected_chapter_ids", [])
    |> List.wrap()
    |> length()
  end

  defp required_media_count(%Run{} = run, progress) do
    with ids when is_list(ids) <-
           run.result
           |> string_map()
           |> value("compile_checkpoint", %{})
           |> string_map()
           |> value("required_media_ids", nil) do
      length(ids)
    else
      _ ->
        progress
        |> value("counts", %{})
        |> string_map()
        |> value("source_assets_discovered", 0)
        |> positive_or_zero()
    end
  end

  defp duration_samples(timing) do
    timing
    |> value("item_durations_seconds", [])
    |> List.wrap()
    |> Enum.filter(&(is_number(&1) and &1 >= 0 and &1 <= 14_400))
    |> Enum.map(&(&1 * 1.0))
  end

  defp confidence(sample_count, completed) when sample_count >= 8 or completed >= 10, do: "high"
  defp confidence(sample_count, completed) when sample_count >= 3 or completed >= 3, do: "medium"
  defp confidence(_sample_count, _completed), do: "low"

  defp percentile(values, fraction) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * fraction) - 1, 0)
    Enum.at(sorted, index, 0.0)
  end

  defp waiting_estimate(milestone, lower, upper, total) do
    %{
      "state" => "waiting_for_user",
      "milestone" => milestone,
      "lower_seconds" => lower,
      "upper_seconds" => upper,
      "confidence" => "low",
      "completed" => nil,
      "total" => positive_or_nil(total),
      "stalled" => false
    }
  end

  defp estimated_range(milestone, lower, upper, completed, total, confidence) do
    %{
      "state" => "estimated",
      "milestone" => milestone,
      "lower_seconds" => max(round(lower), 0),
      "upper_seconds" => max(round(upper), max(round(lower), 0)),
      "confidence" => confidence,
      "completed" => completed,
      "total" => positive_or_nil(total)
    }
  end

  defp milestone(:preflighting), do: "scope_ready"
  defp milestone(:awaiting_scope), do: "scope_ready"
  defp milestone(status) when status in [:ingesting, :planning_outline], do: "outline_ready"

  defp milestone(status)
       when status in [:awaiting_outline_approval, :planning_lessons, :awaiting_lesson_approval],
       do: "lesson_plans_ready"

  defp milestone(status) when status in [:compiling, :staging_media, :applying, :completed],
    do: "course_created"

  defp milestone(_), do: nil

  defp stalled?(_status, "queued", _last_progress, _now), do: false

  defp stalled?(status, _work_state, last_progress, now) when status in @active_statuses do
    case elapsed_seconds(last_progress, now) do
      elapsed when is_integer(elapsed) -> elapsed > stall_threshold(status)
      _ -> false
    end
  end

  defp stalled?(_status, _work_state, _last_progress, _now), do: false

  defp stall_threshold(:preflighting), do: 10 * 60
  defp stall_threshold(:ingesting), do: 20 * 60
  defp stall_threshold(:planning_outline), do: 20 * 60
  defp stall_threshold(:planning_lessons), do: 15 * 60
  defp stall_threshold(:staging_media), do: 10 * 60
  defp stall_threshold(:applying), do: 35 * 60

  defp stage_started_at(run, timing) do
    datetime(value(timing, "stage_started_at", nil)) || inferred_stage_started_at(run)
  end

  defp inferred_stage_started_at(%Run{status: :preflighting} = run), do: run.started_at

  defp inferred_stage_started_at(%Run{status: :planning_lessons} = run),
    do: run.outline_approved_at

  defp inferred_stage_started_at(_run), do: nil

  defp last_progress_at(run, timing),
    do: datetime(value(timing, "last_progress_at", nil)) || run.updated_at || run.started_at

  defp elapsed_seconds(%DateTime{} = started_at, %DateTime{} = now),
    do: max(DateTime.diff(now, started_at, :second), 0)

  defp elapsed_seconds(_, _), do: nil

  defp datetime(%DateTime{} = datetime), do: datetime

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_), do: nil

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, maybe_existing_atom(key), default))

  defp value(_, _key, default), do: default

  defp maybe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp string_map(value) when is_map(value), do: value
  defp string_map(_), do: %{}

  defp integer_count(value) when is_float(value), do: trunc(value)
  defp integer_count(value) when is_integer(value), do: value
  defp integer_count(_), do: 0

  defp positive_or_zero(value) when is_number(value), do: max(integer_count(value), 0)
  defp positive_or_zero(_), do: 0

  defp positive_or_nil(value) when is_number(value) and value > 0, do: integer_count(value)
  defp positive_or_nil(_), do: nil

  defp unavailable_estimate(now) do
    %{
      "state" => "unavailable",
      "milestone" => nil,
      "lower_seconds" => nil,
      "upper_seconds" => nil,
      "confidence" => "low",
      "stage_elapsed_seconds" => nil,
      "stalled" => false,
      "last_progress_at" => nil,
      "calculated_at" => iso8601(now),
      "completed" => nil,
      "total" => nil,
      "work_state" => nil,
      "queue_wait_included" => false,
      "parallelism" => 1,
      "queued" => 0,
      "running" => 0,
      "retrying" => 0,
      "failed" => 0
    }
  end
end
