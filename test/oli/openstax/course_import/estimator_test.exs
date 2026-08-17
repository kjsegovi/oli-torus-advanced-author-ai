defmodule Oli.OpenStax.CourseImport.EstimatorTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Estimator, Lesson, Run, Unit}

  @now ~U[2026-07-31 19:00:00Z]

  test "estimates preflight time to the chapter-selection checkpoint" do
    run = %Run{
      status: :preflighting,
      started_at: DateTime.add(@now, -60, :second),
      progress: %{
        "work_state" => "queued",
        "timing" => %{
          "stage_started_at" => "2026-07-31T18:59:00Z",
          "last_progress_at" => "2026-07-31T18:59:00Z"
        }
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["state"] == "estimated"
    assert estimate["milestone"] == "scope_ready"
    assert estimate["lower_seconds"] == 5
    assert estimate["upper_seconds"] == 60
    assert estimate["stage_elapsed_seconds"] == 60
    assert estimate["work_state"] == "queued"
    refute estimate["stalled"]
  end

  test "uses completed item timings to refine lesson planning" do
    run = %Run{
      status: :planning_lessons,
      progress: %{
        "work_state" => "running",
        "stage_totals" => [
          %{"label" => "Lesson plans checked", "completed" => 4, "total" => 10}
        ],
        "timing" => %{
          "stage_started_at" => "2026-07-31T18:50:00Z",
          "last_progress_at" => "2026-07-31T18:58:00Z",
          "item_durations_seconds" => [60.0, 90.0, 120.0]
        }
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["state"] == "estimated"
    assert estimate["milestone"] == "lesson_plans_ready"
    assert estimate["completed"] == 4
    assert estimate["total"] == 10
    assert estimate["confidence"] == "medium"
    assert estimate["parallelism"] == 3
    assert estimate["lower_seconds"] < 6 * 45
    assert estimate["upper_seconds"] >= estimate["lower_seconds"]
  end

  test "estimates parallel lesson planning in waves and includes a known retry delay" do
    run = %Run{
      status: :planning_lessons,
      lesson_planning_strategy: :parallel_v1,
      lesson_planning_parallelism: 3,
      progress: %{
        "lesson_planning" => %{
          "counts" => %{
            "total" => 10,
            "completed" => 4,
            "pending" => 2,
            "queued" => 1,
            "running" => 2,
            "retrying" => 1,
            "failed" => 0
          },
          "active_items" => [
            %{"lesson_id" => "lesson-5", "state" => "retrying", "attempt" => 2}
          ]
        },
        "timing" => %{
          "stage_started_at" => "2026-07-31T18:50:00Z",
          "last_progress_at" => "2026-07-31T18:58:00Z",
          "item_durations_seconds" => [60.0, 90.0, 120.0]
        }
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["parallelism"] == 3
    assert estimate["completed"] == 4
    assert estimate["total"] == 10
    assert estimate["queued"] == 1
    assert estimate["running"] == 2
    assert estimate["retrying"] == 1
    assert estimate["work_state"] == "retrying"
    assert estimate["retry_delay_seconds"] == 40

    # Six remaining lessons require two waves, rather than six serial item durations.
    assert estimate["lower_seconds"] == 166
    assert estimate["upper_seconds"] == 400
  end

  test "does not count terminally failed lessons as unfinished ETA waves" do
    run = %Run{
      status: :planning_lessons,
      lesson_planning_strategy: :parallel_v1,
      lesson_planning_parallelism: 3,
      progress: %{
        "lesson_planning" => %{
          "total" => 11,
          "completed" => 4,
          "pending" => 3,
          "queued" => 1,
          "running" => 2,
          "retrying" => 0,
          "failed" => 1
        },
        "timing" => %{
          "stage_started_at" => "2026-07-31T18:50:00Z",
          "last_progress_at" => "2026-07-31T18:58:00Z",
          "item_durations_seconds" => [60.0, 90.0, 120.0]
        }
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["completed"] == 4
    assert estimate["failed"] == 1
    assert estimate["total"] == 11

    # Six unfinished lessons require two waves; the failed lesson is already terminal.
    assert estimate["lower_seconds"] == 126
    assert estimate["upper_seconds"] == 360
  end

  test "forecasts lesson generation before outline approval without counting review time" do
    run = %Run{
      status: :awaiting_outline_approval,
      units: [unit_with_lessons(3)]
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["state"] == "waiting_for_user"
    assert estimate["milestone"] == "lesson_plans_ready"
    assert estimate["lower_seconds"] == 45
    assert estimate["upper_seconds"] == 240
    assert estimate["total"] == 3
    refute estimate["stalled"]
  end

  test "marks review and create-course gates as paused" do
    review = Estimator.estimate(%Run{status: :awaiting_lesson_approval}, now: @now)

    assert review["state"] == "waiting_for_user"
    assert review["milestone"] == "lesson_plans_ready"
    assert review["lower_seconds"] == nil

    compiling =
      Estimator.estimate(
        %Run{
          status: :compiling,
          units: [unit_with_lessons(2)],
          progress: %{"counts" => %{"source_assets_discovered" => 2}}
        },
        now: @now
      )

    assert compiling["state"] == "waiting_for_user"
    assert compiling["milestone"] == "course_created"
    assert compiling["lower_seconds"] > 0
    assert compiling["upper_seconds"] >= compiling["lower_seconds"]
  end

  test "flags an active stage only after its progress checkpoint is stale" do
    run = %Run{
      status: :planning_lessons,
      progress: %{
        "stage_totals" => [%{"completed" => 0, "total" => 4}],
        "timing" => %{
          "stage_started_at" => "2026-07-31T10:00:00Z",
          "last_progress_at" => "2026-07-31T10:00:00Z"
        }
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["stalled"]
    assert estimate["last_progress_at"] == "2026-07-31T10:00:00Z"
  end

  test "does not call a queued worker stalled" do
    run = %Run{
      status: :planning_lessons,
      progress: %{
        "work_state" => "queued",
        "stage_totals" => [%{"completed" => 0, "total" => 4}],
        "timing" => %{
          "stage_started_at" => "2026-07-31T10:00:00Z",
          "last_progress_at" => "2026-07-31T10:00:00Z"
        }
      }
    }

    refute Estimator.estimate(run, now: @now)["stalled"]
  end

  test "infers the current lesson-planning start from outline approval" do
    run = %Run{
      status: :planning_lessons,
      outline_approved_at: DateTime.add(@now, -600, :second),
      updated_at: DateTime.add(@now, -30, :second),
      progress: %{
        "stage_totals" => [%{"completed" => 2, "total" => 4}]
      }
    }

    estimate = Estimator.estimate(run, now: @now)

    assert estimate["stage_elapsed_seconds"] == 600
    assert estimate["completed"] == 2
    assert estimate["total"] == 4
  end

  test "reports terminal runs without a continuing countdown" do
    complete = Estimator.estimate(%Run{status: :completed}, now: @now)
    failed = Estimator.estimate(%Run{status: :failed}, now: @now)

    assert complete["state"] == "completed"
    assert complete["lower_seconds"] == 0
    assert complete["upper_seconds"] == 0

    assert failed["state"] == "stopped"
    assert failed["lower_seconds"] == nil
    refute failed["stalled"]
  end

  test "uses the supplied clock for an unavailable estimate" do
    assert Estimator.estimate(:not_a_run, now: @now)["calculated_at"] ==
             DateTime.to_iso8601(@now)
  end

  defp unit_with_lessons(count) do
    %Unit{
      selected: true,
      lessons:
        Enum.map(1..count, fn index ->
          %Lesson{id: "lesson-#{index}", title: "Lesson #{index}", selected: true}
        end)
    }
  end
end
