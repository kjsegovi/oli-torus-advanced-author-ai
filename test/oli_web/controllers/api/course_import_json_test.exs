defmodule OliWeb.Api.CourseImportJSONTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Lesson, LessonPlan, Run, Unit}
  alias OliWeb.Api.CourseImportJSON

  test "serializes a resumable run checkpoint with nested course plan data" do
    plan = %LessonPlan{
      id: "plan-1",
      version: 2,
      content_payload: %{
        "objective" => "Explain recursion",
        "coverage_manifest" => %{
          "included_block_ids" => ["block-1", "block-2"]
        }
      },
      questions_payload: %{"items" => [%{"prompt" => "What is a base case?"}]},
      checks_snapshot: %{"status" => "passed"},
      created_by: "author",
      approved_by_user: true
    }

    lesson = %Lesson{
      id: "lesson-1",
      unit_id: "unit-1",
      order: 1,
      title: "Recursion",
      source_sections: ["4.2 Recursion"],
      source_evidence_links: ["https://openstax.org/books/example/pages/4-2-recursion"],
      source_word_count: 1_240,
      source_coverage: %{
        "complete" => true,
        "block_count" => 18,
        "media_count" => 2,
        "source_block_ids" => ["block-1", "block-2"]
      },
      plan_mode: "advanced",
      status: "ready_for_review",
      selected: true,
      last_plan_version: 2,
      planning_state: "retrying",
      planning_operation: "regenerate",
      planning_generation: 2,
      planning_request_id: "f2d1f7f5-1976-4f89-91ec-118b823eb340",
      planning_position: 4,
      planning_oban_job_id: 73,
      planning_attempts: 2,
      planning_base_plan_version: 2,
      plans: [plan]
    }

    unit = %Unit{
      id: "unit-1",
      unit_name: "Functions",
      order: 1,
      source_reference: %{"chapter" => "4"},
      selected: true,
      lessons: [lesson]
    }

    run = %Run{
      id: "run-1",
      project_id: 42,
      source_url: "https://openstax.org/details/books/introduction-computer-science",
      book_slug: "introduction-computer-science",
      status: :awaiting_lesson_approval,
      scope_manifest: %{"selected_unit_ids" => ["unit-1"]},
      progress: %{
        "stage" => "awaiting_lesson_approval",
        "counts" => %{
          "sections_extracted" => 1,
          "source_blocks_extracted" => 18,
          "source_assets_discovered" => 3,
          "assets_staged" => 1
        },
        "stage_totals" => [
          %{"label" => "Required media staged", "completed" => 1, "total" => 1}
        ]
      },
      source_schema_version: 2,
      plan_schema_version: 3,
      lesson_planning_strategy: :parallel_v1,
      lesson_planning_generation: 2,
      lesson_planning_parallelism: 3,
      result: %{
        "compile_checkpoint" => %{"required_media_ids" => ["media-1"]}
      },
      units: [unit]
    }

    serialized = CourseImportJSON.run(run)

    assert serialized.status == "awaiting_lesson_approval"
    assert serialized.time_estimate["state"] == "waiting_for_user"
    assert serialized.time_estimate["milestone"] == "lesson_plans_ready"
    assert serialized.updated_at == nil
    assert serialized.source_schema_version == 2
    assert serialized.plan_schema_version == 3
    assert serialized.source_word_count == 1_240
    assert serialized.source_coverage["source_block_count"] == 18
    assert serialized.source_coverage["source_blocks_covered"] == 2
    assert serialized.source_coverage["plans_validated"] == 1
    assert serialized.source_coverage["lessons_approved"] == 1
    assert serialized.media_counts == %{"discovered" => 3, "required" => 1, "staged" => 1}

    assert serialized.lesson_planning == %{
             "strategy" => "parallel_v1",
             "generation" => 2,
             "configured_parallelism" => 3,
             "effective_parallelism" => 1,
             "counts" => %{
               "total" => 1,
               "pending" => 0,
               "queued" => 0,
               "running" => 0,
               "retrying" => 1,
               "completed" => 0,
               "failed" => 0,
               "cancelled" => 0
             },
             "active_lessons" => [
               %{
                 "id" => "lesson-1",
                 "title" => "Recursion",
                 "state" => "retrying",
                 "operation" => "regenerate",
                 "position" => 4,
                 "attempt" => 2,
                 "queued_at" => nil,
                 "started_at" => nil,
                 "last_progress_at" => nil
               }
             ]
           }

    assert serialized.counts == %{
             "sections_extracted" => 1,
             "source_blocks_extracted" => 18,
             "source_blocks_covered" => 2,
             "source_blocks_excluded" => 0,
             "source_assets_discovered" => 3,
             "assets_staged" => 1,
             "plans_validated" => 1,
             "lessons_approved" => 1,
             "lessons_total" => 1
           }

    assert [serialized_unit] = serialized.units
    assert serialized_unit.unit_name == "Functions"
    assert [serialized_lesson] = serialized_unit.lessons
    assert serialized_lesson.plan_mode == "advanced"
    assert serialized_lesson.source_word_count == 1_240
    assert serialized_lesson.source_media_count == 2
    assert serialized_lesson.planning_state == "retrying"
    assert serialized_lesson.planning_operation == "regenerate"
    assert serialized_lesson.planning_generation == 2

    assert serialized_lesson.planning_request_id ==
             "f2d1f7f5-1976-4f89-91ec-118b823eb340"

    assert serialized_lesson.planning_position == 4
    assert serialized_lesson.planning_oban_job_id == 73
    assert serialized_lesson.planning_attempts == 2
    assert serialized_lesson.planning_base_plan_version == 2

    assert serialized_lesson.plans == [
             %{
               id: "plan-1",
               version: 2,
               content_payload: %{
                 "objective" => "Explain recursion",
                 "coverage_manifest" => %{
                   "included_block_ids" => ["block-1", "block-2"]
                 }
               },
               questions_payload: %{"items" => [%{"prompt" => "What is a base case?"}]},
               checks_snapshot: %{"status" => "passed"},
               created_by: "author",
               approved_by_user: true,
               approved_at: nil,
               rejection_reason: nil
             }
           ]
  end

  test "serializes an unloaded association as an empty collection" do
    run = %Run{id: "run-1", status: :preflighting}

    assert CourseImportJSON.run(run).units == []
    assert CourseImportJSON.run(run).time_estimate["milestone"] == "scope_ready"
  end
end
