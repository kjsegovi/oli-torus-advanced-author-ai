defmodule Oli.Repo.Migrations.AllowUnapprovedSupersededSimulationArtifacts do
  use Ecto.Migration

  def up do
    drop constraint(
           :course_import_simulation_artifacts,
           :course_import_simulation_artifacts_approval
         )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_approval,
             check: """
             status != 'approved' OR (
               approved_by_author_id IS NOT NULL AND approved_at IS NOT NULL
             )
             """
           )
  end

  def down do
    drop constraint(
           :course_import_simulation_artifacts,
           :course_import_simulation_artifacts_approval
         )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_approval,
             check: """
             status NOT IN ('approved', 'superseded') OR (
               approved_by_author_id IS NOT NULL AND approved_at IS NOT NULL
             )
             """
           )
  end
end
