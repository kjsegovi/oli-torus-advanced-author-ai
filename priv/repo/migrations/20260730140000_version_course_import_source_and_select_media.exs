defmodule Oli.Repo.Migrations.VersionCourseImportSourceAndSelectMedia do
  use Ecto.Migration

  def up do
    alter table(:course_import_runs) do
      add :source_schema_version, :integer, null: false, default: 1
      add :plan_schema_version, :integer, null: false, default: 2
    end

    create constraint(:course_import_runs, :course_import_runs_schema_versions,
             check: "source_schema_version >= 1 AND plan_schema_version >= 1"
           )

    alter table(:course_import_source_blocks) do
      add :source_key, :string
    end

    execute("""
    UPDATE course_import_source_blocks
    SET source_key = 'legacy-block-' || replace(id::text, '-', '')
    WHERE source_key IS NULL
    """)

    alter table(:course_import_source_blocks) do
      modify :source_key, :string, null: false
    end

    create unique_index(:course_import_source_blocks, [:run_id, :source_key])

    alter table(:course_import_source_assets) do
      add :source_key, :string
      add :required, :boolean, null: false, default: false
    end

    execute("""
    UPDATE course_import_source_assets
    SET source_key = 'legacy-media-' || replace(id::text, '-', '')
    WHERE source_key IS NULL
    """)

    alter table(:course_import_source_assets) do
      modify :source_key, :string, null: false
    end

    create unique_index(:course_import_source_assets, [:run_id, :source_key])
    create index(:course_import_source_assets, [:run_id, :required, :status])
  end

  def down do
    drop index(:course_import_source_assets, [:run_id, :required, :status])
    drop unique_index(:course_import_source_assets, [:run_id, :source_key])

    alter table(:course_import_source_assets) do
      remove :required
      remove :source_key
    end

    drop unique_index(:course_import_source_blocks, [:run_id, :source_key])

    alter table(:course_import_source_blocks) do
      remove :source_key
    end

    drop constraint(:course_import_runs, :course_import_runs_schema_versions)

    alter table(:course_import_runs) do
      remove :plan_schema_version
      remove :source_schema_version
    end
  end
end
