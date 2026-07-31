defmodule Oli.OpenStax.CourseImport.TelemetryTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{LessonPlan, Telemetry}

  @events [
    [:oli, :openstax, :course_import, :source_persisted],
    [:oli, :openstax, :course_import, :plan_checked],
    [:oli, :openstax, :course_import, :lesson_job_enqueued],
    [:oli, :openstax, :course_import, :lesson_job_started],
    [:oli, :openstax, :course_import, :lesson_job_retrying],
    [:oli, :openstax, :course_import, :lesson_job_completed],
    [:oli, :openstax, :course_import, :lesson_job_failed],
    [:oli, :openstax, :course_import, :lesson_batch_finished],
    [:oli, :openstax, :course_import, :media_staged],
    [:oli, :openstax, :course_import, :compile_failed]
  ]

  setup do
    handler_id = "openstax-rich-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits bounded source, coverage, repair, media, and compile measurements" do
    run_id = Ecto.UUID.generate()
    lesson_id = Ecto.UUID.generate()

    assert :ok = Telemetry.source_persisted(run_id, %{sections: 1, blocks: 42, assets: 2})

    plan = %LessonPlan{
      version: 3,
      created_by: "system",
      checks_snapshot: %{
        "status" => "passed",
        "results" => [
          %{
            "check_type" => "source_fidelity",
            "findings" => %{
              "included_block_count" => 36,
              "available_block_count" => 42,
              "instructional_word_count" => 1_650
            }
          }
        ]
      }
    }

    assert :ok = Telemetry.plan_checked(run_id, lesson_id, plan, true)

    assert :ok = Telemetry.lesson_job_enqueued(run_id, lesson_id, 2, "regenerate")
    assert :ok = Telemetry.lesson_job_started(run_id, lesson_id, 1, 4.5)
    assert :ok = Telemetry.lesson_job_retrying(run_id, lesson_id, 1, :provider_timeout)
    assert :ok = Telemetry.lesson_job_completed(run_id, lesson_id, 2, 75.25)
    assert :ok = Telemetry.lesson_job_failed(run_id, lesson_id, 4, :provider_unauthorized)
    assert :ok = Telemetry.lesson_batch_finished(run_id, 2, :failed, 190.0, 1)

    assert :ok =
             Telemetry.media_staged(run_id, %{
               total: 2,
               staged: 1,
               reused: 1,
               skipped: 0,
               bytes_staged: 2_048
             })

    assert :ok =
             Telemetry.compile_failed(run_id, {:invalid_plan, "private source text"}, [lesson_id])

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :source_persisted],
                    %{sections: 1, blocks: 42, assets: 2}, %{run_id: ^run_id}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :plan_checked],
                    %{validation_passed: 1, repair_attempted: 1, instructional_words: 1_650},
                    %{run_id: ^run_id, lesson_id: ^lesson_id}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_job_enqueued],
                    %{count: 1},
                    %{
                      run_id: ^run_id,
                      lesson_id: ^lesson_id,
                      generation: 2,
                      operation: :regenerate
                    }}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_job_started],
                    %{count: 1, attempt: 1, queue_wait_seconds: 4.5},
                    %{run_id: ^run_id, lesson_id: ^lesson_id}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_job_retrying],
                    %{count: 1, attempt: 1},
                    %{run_id: ^run_id, lesson_id: ^lesson_id, reason: :provider_timeout}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_job_completed],
                    %{count: 1, attempts: 2, duration_seconds: 75.25},
                    %{run_id: ^run_id, lesson_id: ^lesson_id}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_job_failed],
                    %{count: 1, attempt: 4},
                    %{run_id: ^run_id, lesson_id: ^lesson_id, reason: :provider_unauthorized}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :lesson_batch_finished],
                    %{count: 1, duration_seconds: 190.0, failed_lessons: 1},
                    %{run_id: ^run_id, generation: 2, outcome: :failed}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :media_staged],
                    %{total: 2, staged: 1, reused: 1}, %{run_id: ^run_id}}

    assert_receive {:telemetry, [:oli, :openstax, :course_import, :compile_failed],
                    %{count: 1, affected_lessons: 1}, %{run_id: ^run_id, reason: :invalid_plan}}
  end
end
