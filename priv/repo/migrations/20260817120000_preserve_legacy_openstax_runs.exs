defmodule Oli.Repo.Migrations.PreserveLegacyOpenstaxRuns do
  use Ecto.Migration

  @moduledoc """
  Keeps persisted legacy import rows valid while new-run changesets enforce
  source schema 3, plan schema 6, and parallel planning.

  The explicit DROP handles development and staging databases that applied the
  superseded exact-v6 constraint before the preservation policy was adopted.
  This migration never updates or deletes course-import data.
  """

  def up do
    drop_if_exists constraint(:course_import_runs, :course_import_runs_schema_versions)

    drop_if_exists(constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy))

    create constraint(:course_import_runs, :course_import_runs_schema_versions,
             check: "source_schema_version >= 1 AND plan_schema_version >= 1"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy,
             check: "lesson_planning_strategy IN ('serial_v1', 'parallel_v1')"
           )
  end

  def down do
    # Preservation is intentional in both directions. Reverting this migration
    # must not make pre-v6 rows invalid.
    drop_if_exists constraint(:course_import_runs, :course_import_runs_schema_versions)

    drop_if_exists(constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy))

    create constraint(:course_import_runs, :course_import_runs_schema_versions,
             check: "source_schema_version >= 1 AND plan_schema_version >= 1"
           )

    create constraint(:course_import_runs, :course_import_runs_lesson_planning_strategy,
             check: "lesson_planning_strategy IN ('serial_v1', 'parallel_v1')"
           )
  end
end
