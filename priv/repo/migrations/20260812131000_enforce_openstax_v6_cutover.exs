defmodule Oli.Repo.Migrations.EnforceOpenstaxV6Cutover do
  use Ecto.Migration

  def up do
    drop constraint(:course_import_runs, :course_import_runs_schema_versions)
    drop constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy)

    create constraint(:course_import_runs, :course_import_runs_schema_versions,
             check: "source_schema_version = 3 AND plan_schema_version = 6"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy,
             check: "lesson_planning_strategy = 'parallel_v1'"
           )
  end

  def down do
    drop constraint(:course_import_runs, :course_import_runs_schema_versions)
    drop constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy)

    create constraint(:course_import_runs, :course_import_runs_schema_versions,
             check: "source_schema_version >= 1 AND plan_schema_version >= 1"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy,
             check: "lesson_planning_strategy IN ('serial_v1', 'parallel_v1')"
           )
  end
end
