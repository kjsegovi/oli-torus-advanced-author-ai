defmodule Oli.Repo.Migrations.CreateOpenstaxSimulationArtifactAttempts do
  use Ecto.Migration

  @statuses "'validation_failed', 'critic_rejected', 'critic_failed', 'accepted', 'cancelled'"

  def change do
    create table(:course_import_simulation_artifact_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_id,
          references(:course_import_simulation_artifacts,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :attempt_number, :integer, null: false
      add :status, :string, null: false
      add :source_hash, :string
      add :content_hash, :string
      add :generator_name, :string
      add :generator_version, :string
      add :findings, {:array, :map}, null: false, default: []
      add :validation_summary, :map, null: false, default: %{}
      add :criticism, :map, null: false, default: %{}
      add :model_usage, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(
             :course_import_simulation_artifact_attempts,
             :course_import_simulation_artifact_attempts_status,
             check: "status IN (#{@statuses})"
           )

    create constraint(
             :course_import_simulation_artifact_attempts,
             :course_import_simulation_artifact_attempts_bounds,
             check: "attempt_number > 0"
           )

    create unique_index(
             :course_import_simulation_artifact_attempts,
             [:artifact_id, :attempt_number],
             name: :course_import_sim_artifact_attempt_unique
           )

    create index(:course_import_simulation_artifact_attempts, [:artifact_id, :inserted_at])
  end
end
