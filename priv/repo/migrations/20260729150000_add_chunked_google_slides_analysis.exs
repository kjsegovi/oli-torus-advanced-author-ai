defmodule Oli.Repo.Migrations.AddChunkedGoogleSlidesAnalysis do
  use Ecto.Migration

  @active_statuses "'analyzing', 'awaiting_structure', 'awaiting_budget', 'awaiting_answers', 'ready_for_review', 'generating'"
  @all_statuses @active_statuses <> ", 'completed', 'failed', 'cancelled'"

  def up do
    alter table(:google_slides_import_runs) do
      add :analysis_version, :integer, null: false, default: 1
      add :analysis_state, :jsonb
    end

    drop constraint(:google_slides_import_runs, :google_slides_import_runs_valid_status)

    create constraint(:google_slides_import_runs, :google_slides_import_runs_valid_status,
             check: "status IN (#{@all_statuses})"
           )

    drop index(:google_slides_import_runs, [:project_id, :target_container_resource_id],
           name: :google_slides_import_runs_one_active_per_target
         )

    create unique_index(
             :google_slides_import_runs,
             [:project_id, :target_container_resource_id],
             name: :google_slides_import_runs_one_active_per_target,
             where: "status IN (#{@active_statuses})"
           )

    create table(:google_slides_import_analysis_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id,
          references(:google_slides_import_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ordinal, :integer, null: false
      add :slide_ids, {:array, :string}, null: false, default: []
      add :object_ids, {:array, :string}, null: false, default: []
      add :source_fragment, :jsonb, null: false
      add :status, :string, null: false, default: "pending"
      add :usage, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :attempt_count, :integer, null: false, default: 0
      add :error, :jsonb

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:google_slides_import_analysis_chunks, [:run_id, :ordinal])
    create index(:google_slides_import_analysis_chunks, [:run_id, :status])

    create constraint(
             :google_slides_import_analysis_chunks,
             :google_slides_import_analysis_chunks_valid_status,
             check: "status IN ('pending', 'processing', 'completed', 'failed')"
           )

    create constraint(
             :google_slides_import_analysis_chunks,
             :google_slides_import_analysis_chunks_valid_ordinal,
             check: "ordinal >= 0 AND attempt_count >= 0"
           )
  end

  def down do
    drop table(:google_slides_import_analysis_chunks)

    drop index(:google_slides_import_runs, [:project_id, :target_container_resource_id],
           name: :google_slides_import_runs_one_active_per_target
         )

    drop constraint(:google_slides_import_runs, :google_slides_import_runs_valid_status)

    create constraint(:google_slides_import_runs, :google_slides_import_runs_valid_status,
             check:
               "status IN ('analyzing', 'awaiting_answers', 'ready_for_review', 'generating', 'completed', 'failed', 'cancelled')"
           )

    create unique_index(
             :google_slides_import_runs,
             [:project_id, :target_container_resource_id],
             name: :google_slides_import_runs_one_active_per_target,
             where:
               "status IN ('analyzing', 'awaiting_answers', 'ready_for_review', 'generating')"
           )

    alter table(:google_slides_import_runs) do
      remove :analysis_state
      remove :analysis_version
    end
  end
end
