defmodule Oli.Repo.Migrations.CutOverOpenstaxImporterV7 do
  use Ecto.Migration

  def up do
    alter table(:course_import_runs) do
      modify :source_schema_version, :integer, null: false, default: 4
      modify :plan_schema_version, :integer, null: false, default: 7
    end

    create table(:course_import_ai_usage_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all)

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all)

      add :authoring_mode, :string
      add :role, :string, null: false
      add :provider, :string
      add :model, :string
      add :model_snapshot, :string
      add :service_tier, :string
      add :reasoning_effort, :string
      add :candidate_number, :integer, null: false, default: 1
      add :request_id, :string
      add :input_tokens, :bigint, null: false, default: 0
      add :cached_input_tokens, :bigint, null: false, default: 0
      add :cache_write_tokens, :bigint, null: false, default: 0
      add :output_tokens, :bigint, null: false, default: 0
      add :reasoning_tokens, :bigint, null: false, default: 0
      add :estimated_cost_microdollars, :bigint, null: false, default: 0
      add :pricing_version, :string, null: false
      add :outcome, :string, null: false
      add :retry_category, :string
      add :finding_fingerprint, :string
      add :cache_status, :string
      add :latency_ms, :integer
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:course_import_ai_usage_events, [:run_id, :lesson_id])
    create index(:course_import_ai_usage_events, [:role, :model])
    create index(:course_import_ai_usage_events, [:inserted_at])

    create table(:course_import_plan_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cache_key, :string, null: false
      add :source_hash, :string, null: false
      add :authoring_mode, :string, null: false
      add :source_schema_version, :integer, null: false
      add :plan_schema_version, :integer, null: false
      add :content_schema_version, :integer, null: false
      add :prompt_bundle_hash, :string, null: false
      add :quality_policy_version, :string, null: false
      add :feature_policy_hash, :string, null: false
      add :model_bundle_hash, :string, null: false
      add :content_payload, :map, null: false
      add :questions_payload, :map, null: false, default: %{}
      add :generation_metadata, :map, null: false, default: %{}
      add :source_media_bindings, {:array, :map}, null: false, default: []
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:course_import_plan_templates, [:cache_key])
    create index(:course_import_plan_templates, [:source_hash, :authoring_mode])
  end

  def down do
    drop table(:course_import_plan_templates)
    drop table(:course_import_ai_usage_events)

    alter table(:course_import_runs) do
      modify :source_schema_version, :integer, null: false, default: 3
      modify :plan_schema_version, :integer, null: false, default: 6
    end
  end
end
