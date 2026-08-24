defmodule Oli.Repo.Migrations.VersionSimulationArtifactStorageIdentity do
  use Ecto.Migration

  def up do
    alter table(:course_import_simulation_artifacts) do
      add :storage_bucket, :text
      add :storage_identity_version, :integer
      add :storage_payload, :map
    end

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_storage_identity_version,
             check: "storage_identity_version IS NULL OR storage_identity_version IN (1, 2)"
           )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_storage_identity_pair,
             check:
               "(storage_bucket IS NULL AND storage_identity_version IS NULL) OR " <>
                 "(storage_bucket IS NOT NULL AND storage_identity_version IS NOT NULL)"
           )

    create index(:course_import_simulation_artifacts, [
             :storage_provider,
             :storage_identity_version
           ])
  end

  def down do
    drop_if_exists index(:course_import_simulation_artifacts, [
                     :storage_provider,
                     :storage_identity_version
                   ])

    drop constraint(
           :course_import_simulation_artifacts,
           :course_import_simulation_artifacts_storage_identity_pair
         )

    drop constraint(
           :course_import_simulation_artifacts,
           :course_import_simulation_artifacts_storage_identity_version
         )

    alter table(:course_import_simulation_artifacts) do
      remove :storage_payload
      remove :storage_bucket
      remove :storage_identity_version
    end
  end
end
