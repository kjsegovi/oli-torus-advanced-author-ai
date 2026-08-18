defmodule Oli.Repo.Migrations.NormalizeOpenstaxSimulationArtifactAttemptIndex do
  use Ecto.Migration

  @old_truncated_name "course_import_simulation_artifact_attempts_artifact_attempt_ind"
  @canonical_name "course_import_sim_artifact_attempt_unique"

  def up do
    execute("ALTER INDEX IF EXISTS #{@old_truncated_name} RENAME TO #{@canonical_name}")
  end

  def down do
    execute("ALTER INDEX IF EXISTS #{@canonical_name} RENAME TO #{@old_truncated_name}")
  end
end
