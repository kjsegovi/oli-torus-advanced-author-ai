defmodule Oli.Repo.Migrations.AddParallelCourseImportLessonPlanning do
  use Ecto.Migration

  @run_strategies "'serial_v1', 'parallel_v1'"
  @planning_states "'pending', 'queued', 'running', 'retrying', 'completed', 'failed', 'cancelled'"
  @planning_operations "'initial', 'regenerate'"

  def up do
    alter table(:course_import_runs) do
      add :lesson_planning_strategy, :string
      add :lesson_planning_generation, :integer, null: false, default: 0
      add :lesson_planning_parallelism, :integer, null: false, default: 3
    end

    execute("""
    UPDATE course_import_runs
    SET lesson_planning_strategy = 'serial_v1'
    WHERE lesson_planning_strategy IS NULL
    """)

    alter table(:course_import_runs) do
      modify :lesson_planning_strategy, :string, null: false, default: "parallel_v1"
    end

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy,
             check: "lesson_planning_strategy IN (#{@run_strategies})"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_generation,
             check: "lesson_planning_generation >= 0"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_parallelism,
             check: "lesson_planning_parallelism BETWEEN 1 AND 8"
           )

    alter table(:course_import_lessons) do
      add :planning_state, :string
      add :planning_operation, :string, null: false, default: "initial"
      add :planning_generation, :integer, null: false, default: 0
      add :planning_request_id, :binary_id
      add :planning_position, :integer
      add :planning_oban_job_id, :bigint
      add :planning_attempts, :integer, null: false, default: 0
      add :planning_base_plan_version, :integer, null: false, default: 0
      add :planning_queued_at, :utc_datetime_usec
      add :planning_started_at, :utc_datetime_usec
      add :planning_last_progress_at, :utc_datetime_usec
      add :planning_finished_at, :utc_datetime_usec
      add :planning_error, :map
    end

    execute("""
    UPDATE course_import_lessons AS lesson
    SET planning_state = CASE
      WHEN lesson.last_plan_version > 0 OR EXISTS (
        SELECT 1
        FROM course_import_lesson_plans AS plan
        WHERE plan.lesson_id = lesson.id
      ) THEN 'completed'
      ELSE 'pending'
    END
    WHERE lesson.planning_state IS NULL
    """)

    execute("""
    WITH ranked_lessons AS (
      SELECT
        lesson.id,
        ROW_NUMBER() OVER (
          PARTITION BY lesson.run_id
          ORDER BY unit."order", lesson."order", lesson.id
        ) AS planning_position
      FROM course_import_lessons AS lesson
      INNER JOIN course_import_units AS unit ON unit.id = lesson.unit_id
    )
    UPDATE course_import_lessons AS lesson
    SET planning_position = ranked_lessons.planning_position
    FROM ranked_lessons
    WHERE lesson.id = ranked_lessons.id
    """)

    alter table(:course_import_lessons) do
      modify :planning_state, :string, null: false, default: "pending"
    end

    create constraint(:course_import_lessons, :course_import_lessons_planning_state,
             check: "planning_state IN (#{@planning_states})"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_operation,
             check: "planning_operation IN (#{@planning_operations})"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_generation,
             check: "planning_generation >= 0"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_position,
             check: "planning_position IS NULL OR planning_position > 0"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_oban_job_id,
             check: "planning_oban_job_id IS NULL OR planning_oban_job_id > 0"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_attempts,
             check: "planning_attempts >= 0"
           )

    create constraint(:course_import_lessons, :course_import_lessons_planning_base_plan_version,
             check: "planning_base_plan_version >= 0"
           )

    create index(
             :course_import_lessons,
             [:run_id, :planning_generation, :planning_state],
             name: :course_import_lessons_planning_window
           )

    create index(
             :course_import_lessons,
             [:run_id, :planning_position],
             name: :course_import_lessons_planning_position_idx,
             where: "planning_position IS NOT NULL"
           )

    create unique_index(
             :course_import_lessons,
             [:planning_request_id],
             name: :course_import_lessons_planning_request_id_unique_index,
             where: "planning_request_id IS NOT NULL"
           )

    create index(
             :course_import_lessons,
             [:planning_oban_job_id],
             name: :course_import_lessons_planning_oban_job_id_idx,
             where: "planning_oban_job_id IS NOT NULL"
           )
  end

  def down do
    drop index(:course_import_lessons, [:planning_oban_job_id],
           name: :course_import_lessons_planning_oban_job_id_idx,
           where: "planning_oban_job_id IS NOT NULL"
         )

    drop index(:course_import_lessons, [:planning_request_id],
           name: :course_import_lessons_planning_request_id_unique_index,
           where: "planning_request_id IS NOT NULL"
         )

    drop index(:course_import_lessons, [:run_id, :planning_position],
           name: :course_import_lessons_planning_position_idx,
           where: "planning_position IS NOT NULL"
         )

    drop index(:course_import_lessons, [:run_id, :planning_generation, :planning_state],
           name: :course_import_lessons_planning_window
         )

    alter table(:course_import_lessons) do
      remove :planning_error
      remove :planning_finished_at
      remove :planning_last_progress_at
      remove :planning_started_at
      remove :planning_queued_at
      remove :planning_base_plan_version
      remove :planning_attempts
      remove :planning_oban_job_id
      remove :planning_position
      remove :planning_request_id
      remove :planning_generation
      remove :planning_operation
      remove :planning_state
    end

    alter table(:course_import_runs) do
      remove :lesson_planning_parallelism
      remove :lesson_planning_generation
      remove :lesson_planning_strategy
    end
  end
end
