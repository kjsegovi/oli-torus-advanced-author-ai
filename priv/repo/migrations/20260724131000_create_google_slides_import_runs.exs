defmodule Oli.Repo.Migrations.CreateGoogleSlidesImportRuns do
  use Ecto.Migration

  @active_statuses "'analyzing', 'awaiting_answers', 'ready_for_review', 'generating'"
  @all_statuses @active_statuses <> ", 'completed', 'failed', 'cancelled'"

  def change do
    create table(:google_slides_import_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :author_id, references(:authors, on_delete: :nothing), null: false

      add :target_container_resource_id, references(:resources, on_delete: :nothing), null: false

      add :result_revision_id, references(:revisions, on_delete: :nilify_all)

      add :status, :string, null: false, default: "analyzing"
      add :presentation_url, :text, null: false
      add :presentation_id, :string
      add :presentation_revision, :string
      add :presentation_fingerprint, :string
      add :presentation_metadata, :jsonb
      add :source_snapshot, :jsonb
      add :options, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :questions, {:array, :map}, null: false, default: []
      add :answers, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :lesson_plan, :jsonb
      add :plan_version, :integer, null: false, default: 0
      add :approved_plan_version, :integer
      add :approved_by_author_id, references(:authors, on_delete: :nothing)
      add :approved_at, :utc_datetime_usec
      add :warnings, {:array, :map}, null: false, default: []
      add :validation_results, :jsonb
      add :result, :jsonb
      add :model_usage, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :error, :jsonb
      add :analysis_started_at, :utc_datetime_usec
      add :analysis_completed_at, :utc_datetime_usec
      add :generation_started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:google_slides_import_runs, :google_slides_import_runs_valid_status,
             check: "status IN (#{@all_statuses})"
           )

    create constraint(:google_slides_import_runs, :google_slides_import_runs_valid_plan_version,
             check:
               "plan_version >= 0 AND (approved_plan_version IS NULL OR approved_plan_version <= plan_version)"
           )

    create constraint(
             :google_slides_import_runs,
             :google_slides_import_runs_complete_approval,
             check:
               "(approved_plan_version IS NULL AND approved_by_author_id IS NULL AND approved_at IS NULL) OR " <>
                 "(approved_plan_version IS NOT NULL AND approved_by_author_id IS NOT NULL AND approved_at IS NOT NULL)"
           )

    create index(:google_slides_import_runs, [:project_id, :inserted_at])
    create index(:google_slides_import_runs, [:author_id, :inserted_at])
    create index(:google_slides_import_runs, [:approved_by_author_id])
    create index(:google_slides_import_runs, [:presentation_id])
    create index(:google_slides_import_runs, [:presentation_fingerprint])
    create index(:google_slides_import_runs, [:result_revision_id])

    create unique_index(
             :google_slides_import_runs,
             [:project_id, :target_container_resource_id],
             name: :google_slides_import_runs_one_active_per_target,
             where: "status IN (#{@active_statuses})"
           )
  end
end
