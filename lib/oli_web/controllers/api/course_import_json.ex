defmodule OliWeb.Api.CourseImportJSON do
  @moduledoc false

  alias Oli.OpenStax.CourseImport.{Estimator, Lesson, LessonPlan, Run, Unit}

  def run(%Run{} = run) do
    source_summary = source_summary(run)
    lesson_planning = lesson_planning_summary(run)

    %{
      id: run.id,
      project_id: run.project_id,
      source_url: run.source_url,
      book_slug: run.book_slug,
      status: to_string(run.status),
      scope_manifest: run.scope_manifest || %{},
      progress: run.progress || %{},
      time_estimate: Estimator.estimate(run),
      latest_plan_version: run.latest_plan_version,
      source_schema_version: run.source_schema_version,
      plan_schema_version: run.plan_schema_version,
      source_word_count: source_summary.source_word_count,
      source_coverage: source_summary.source_coverage,
      media_counts: source_summary.media_counts,
      counts: source_summary.counts,
      lesson_planning: lesson_planning,
      error: run.error,
      result: run.result,
      preflight_snapshot: run.preflight_snapshot,
      started_at: run.started_at,
      updated_at: run.updated_at,
      finished_at: run.finished_at,
      failure_count: run.failure_count,
      outline_approved_at: run.outline_approved_at,
      units: associations(run.units, &unit/1)
    }
  end

  defp unit(%Unit{} = unit) do
    %{
      id: unit.id,
      unit_name: unit.unit_name,
      order: unit.order,
      source_reference: unit.source_reference || %{},
      source_sections_count: unit.source_sections_count,
      status: unit.status,
      selected: unit.selected,
      plan_payload: unit.plan_payload,
      assessment_payload: unit.assessment_payload,
      lessons: associations(unit.lessons, &lesson/1)
    }
  end

  defp lesson(%Lesson{} = lesson) do
    %{
      id: lesson.id,
      unit_id: lesson.unit_id,
      order: lesson.order,
      title: lesson.title,
      source_sections: lesson.source_sections || [],
      source_objectives: lesson.source_objectives || [],
      source_excerpt: lesson.source_excerpt,
      source_evidence_links: lesson.source_evidence_links || [],
      source_word_count: lesson.source_word_count,
      source_coverage: lesson.source_coverage || %{},
      source_media_count: get_in(lesson.source_coverage || %{}, ["media_count"]) || 0,
      plan_mode: lesson.plan_mode,
      status: lesson.status,
      selected: lesson.selected,
      last_plan_version: lesson.last_plan_version,
      approved_at: lesson.approved_at,
      repair_attempts: lesson.repair_attempts,
      planning_state: planning_state(lesson),
      planning_operation: map_field(lesson, :planning_operation),
      planning_generation: map_field(lesson, :planning_generation),
      planning_request_id: map_field(lesson, :planning_request_id),
      planning_position: map_field(lesson, :planning_position),
      planning_oban_job_id: map_field(lesson, :planning_oban_job_id),
      planning_attempts: map_field(lesson, :planning_attempts, 0),
      planning_base_plan_version: map_field(lesson, :planning_base_plan_version),
      planning_queued_at: map_field(lesson, :planning_queued_at),
      planning_started_at: map_field(lesson, :planning_started_at),
      planning_last_progress_at: map_field(lesson, :planning_last_progress_at),
      planning_finished_at: map_field(lesson, :planning_finished_at),
      planning_error: map_field(lesson, :planning_error),
      plans: associations(lesson.plans, &plan/1)
    }
  end

  defp lesson_planning_summary(%Run{} = run) do
    lessons = selected_lessons(run)

    counts =
      Enum.reduce(
        lessons,
        %{
          "total" => length(lessons),
          "pending" => 0,
          "queued" => 0,
          "running" => 0,
          "retrying" => 0,
          "completed" => 0,
          "failed" => 0,
          "cancelled" => 0
        },
        fn lesson, counts ->
          Map.update!(counts, planning_state(lesson), &(&1 + 1))
        end
      )

    configured_parallelism = configured_parallelism(run)
    remaining = counts["pending"] + counts["queued"] + counts["running"] + counts["retrying"]
    active = counts["queued"] + counts["running"] + counts["retrying"]

    %{
      "strategy" => run |> map_field(:lesson_planning_strategy, "serial_v1") |> to_string(),
      "generation" => map_field(run, :lesson_planning_generation, 0),
      "configured_parallelism" => configured_parallelism,
      "effective_parallelism" =>
        effective_parallelism(run, configured_parallelism, active, remaining),
      "counts" => counts,
      "active_lessons" =>
        lessons
        |> Enum.filter(&(planning_state(&1) in ["queued", "running", "retrying"]))
        |> Enum.sort_by(&planning_sort_key/1)
        |> Enum.map(&active_lesson/1)
    }
  end

  defp active_lesson(lesson) do
    %{
      "id" => lesson.id,
      "title" => lesson.title,
      "state" => planning_state(lesson),
      "operation" => map_field(lesson, :planning_operation),
      "position" => map_field(lesson, :planning_position),
      "attempt" => map_field(lesson, :planning_attempts, 0),
      "queued_at" => map_field(lesson, :planning_queued_at),
      "started_at" => map_field(lesson, :planning_started_at),
      "last_progress_at" => map_field(lesson, :planning_last_progress_at)
    }
  end

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

  defp configured_parallelism(run) do
    case map_field(run, :lesson_planning_parallelism) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        if map_field(run, :lesson_planning_strategy) in ["parallel_v1", :parallel_v1],
          do: 3,
          else: 1
    end
  end

  defp effective_parallelism(run, configured, active, remaining) do
    persisted = get_in(run.progress || %{}, ["counts", "effective_parallelism"])

    cond do
      is_integer(persisted) and persisted >= 0 -> min(persisted, configured)
      active > 0 -> min(active, configured)
      remaining > 0 -> 1
      true -> 0
    end
  end

  defp planning_state(lesson) do
    case map_field(lesson, :planning_state) do
      state when state in ["pending", :pending] ->
        if pending_regeneration?(lesson), do: "pending", else: legacy_planning_state(lesson)

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
        legacy_planning_state(lesson)
    end
  end

  defp legacy_planning_state(%Lesson{status: status})
       when status in [
              "ready_for_review",
              "approved",
              "needs_attention",
              "needs_repair",
              "compiled",
              "applied"
            ],
       do: "completed"

  defp legacy_planning_state(%Lesson{status: "failed"}), do: "failed"
  defp legacy_planning_state(_lesson), do: "pending"

  defp pending_regeneration?(lesson) do
    map_field(lesson, :planning_operation) in ["regenerate", :regenerate] and
      is_binary(map_field(lesson, :planning_request_id))
  end

  defp planning_sort_key(lesson) do
    {map_field(lesson, :planning_position, 2_147_483_647), lesson.order || 2_147_483_647,
     lesson.title || ""}
  end

  defp map_field(map, field, default \\ nil)
  defp map_field(map, field, default) when is_map(map), do: Map.get(map, field, default)
  defp map_field(_map, _field, default), do: default

  defp plan(%LessonPlan{} = plan) do
    %{
      id: plan.id,
      version: plan.version,
      content_payload: plan.content_payload || %{},
      questions_payload: plan.questions_payload || %{},
      checks_snapshot: plan.checks_snapshot || %{},
      created_by: plan.created_by,
      approved_by_user: plan.approved_by_user,
      approved_at: plan.approved_at,
      rejection_reason: plan.rejection_reason
    }
  end

  defp associations(%Ecto.Association.NotLoaded{}, _serializer), do: []
  defp associations(nil, _serializer), do: []
  defp associations(values, serializer) when is_list(values), do: Enum.map(values, serializer)

  defp source_summary(%Run{} = run) do
    lessons =
      case run.units do
        units when is_list(units) ->
          Enum.flat_map(units, fn
            %Unit{lessons: lessons} when is_list(lessons) -> lessons
            _ -> []
          end)

        _ ->
          []
      end

    required_media_ids =
      get_in(run.result || %{}, ["compile_checkpoint", "required_media_ids"]) || []

    persisted_counts = get_in(run.progress || %{}, ["counts"]) || %{}
    latest_plans = Enum.map(lessons, &latest_plan/1)

    covered_block_ids =
      latest_plans
      |> Enum.flat_map(&plan_covered_block_ids/1)
      |> Enum.uniq()

    excluded_block_ids =
      latest_plans
      |> Enum.flat_map(&plan_excluded_block_ids/1)
      |> Enum.uniq()

    source_block_ids =
      lessons
      |> Enum.flat_map(fn lesson ->
        get_in(lesson.source_coverage || %{}, ["source_block_ids"]) || []
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    source_blocks_extracted =
      persisted_count(
        persisted_counts,
        "source_blocks_extracted",
        Enum.reduce(
          lessons,
          0,
          &(&2 + (get_in(&1.source_coverage || %{}, ["block_count"]) || 0))
        )
      )

    sections_extracted =
      persisted_count(
        persisted_counts,
        "sections_extracted",
        lessons
        |> Enum.flat_map(&(&1.source_sections || []))
        |> Enum.uniq()
        |> length()
      )

    plans_validated =
      Enum.count(latest_plans, fn
        %LessonPlan{checks_snapshot: %{"status" => "passed"}} -> true
        _ -> false
      end)

    lessons_approved =
      Enum.count(latest_plans, fn
        %LessonPlan{approved_by_user: true} -> true
        _ -> false
      end)

    assets_staged =
      persisted_count(persisted_counts, "assets_staged", staged_media_count(run.progress))

    source_assets_discovered =
      persisted_count(
        persisted_counts,
        "source_assets_discovered",
        Enum.reduce(
          lessons,
          0,
          &(&2 + (get_in(&1.source_coverage || %{}, ["media_count"]) || 0))
        )
      )

    counts = %{
      "sections_extracted" => sections_extracted,
      "source_blocks_extracted" => source_blocks_extracted,
      "source_blocks_covered" => length(covered_block_ids),
      "source_blocks_excluded" => length(excluded_block_ids),
      "source_assets_discovered" => source_assets_discovered,
      "assets_staged" => assets_staged,
      "plans_validated" => plans_validated,
      "lessons_approved" => lessons_approved,
      "lessons_total" => length(lessons)
    }

    %{
      source_word_count: Enum.reduce(lessons, 0, &(&2 + (&1.source_word_count || 0))),
      source_coverage: %{
        "sections_extracted" => sections_extracted,
        "lesson_count" => length(lessons),
        "complete_lesson_count" =>
          Enum.count(lessons, &(get_in(&1.source_coverage || %{}, ["complete"]) == true)),
        "source_block_count" => source_blocks_extracted,
        "source_block_ids_available" => length(source_block_ids),
        "source_blocks_covered" => length(covered_block_ids),
        "source_blocks_excluded" => length(excluded_block_ids),
        "plans_validated" => plans_validated,
        "lessons_approved" => lessons_approved
      },
      media_counts: %{
        "discovered" => source_assets_discovered,
        "required" =>
          persisted_count(
            persisted_counts,
            "source_assets_required",
            length(required_media_ids)
          ),
        "staged" => assets_staged
      },
      counts: counts
    }
  end

  defp latest_plan(%Lesson{plans: %Ecto.Association.NotLoaded{}}), do: nil
  defp latest_plan(%Lesson{plans: nil}), do: nil

  defp latest_plan(%Lesson{plans: plans}) when is_list(plans) do
    Enum.max_by(plans, & &1.version, fn -> nil end)
  end

  defp plan_covered_block_ids(%LessonPlan{content_payload: content}) when is_map(content) do
    content
    |> Map.get("coverage_manifest", %{})
    |> Map.get("included_block_ids", [])
    |> Enum.filter(&is_binary/1)
  end

  defp plan_covered_block_ids(_), do: []

  defp plan_excluded_block_ids(%LessonPlan{content_payload: content}) when is_map(content) do
    content
    |> Map.get("coverage_manifest", %{})
    |> Map.get("excluded_blocks", [])
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp plan_excluded_block_ids(_), do: []

  defp persisted_count(counts, key, fallback) do
    case Map.get(counts, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> fallback
    end
  end

  defp staged_media_count(progress) do
    (progress || %{})
    |> Map.get("stage_totals", [])
    |> Enum.find_value(0, fn
      %{"label" => "Required media staged", "completed" => completed}
      when is_integer(completed) ->
        completed

      _ ->
        nil
    end)
  end
end
