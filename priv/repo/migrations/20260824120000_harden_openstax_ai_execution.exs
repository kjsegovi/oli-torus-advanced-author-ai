defmodule Oli.Repo.Migrations.HardenOpenstaxAiExecution do
  use Ecto.Migration

  def change do
    alter table(:course_import_ai_usage_events) do
      add :request_key, :string
      add :phase, :string
      add :provider_attempt, :integer, null: false, default: 1
      add :request_payload_hash, :string
      add :response_payload, :map
      add :replayed_from_event_id, :binary_id
    end

    create index(:course_import_ai_usage_events, [:request_key])
    create index(:course_import_ai_usage_events, [:request_id])

    create table(:course_import_ai_cost_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all)

      add :request_key, :string, null: false
      add :role, :string, null: false
      add :model, :string, null: false
      add :service_tier, :string, null: false
      add :reserved_microdollars, :bigint, null: false
      add :actual_microdollars, :bigint, null: false, default: 0
      add :status, :string, null: false, default: "reserved"
      add :metadata, :map, null: false, default: %{}
      add :settled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:course_import_ai_cost_reservations, [:request_key])
    create index(:course_import_ai_cost_reservations, [:run_id, :status])
    create index(:course_import_ai_cost_reservations, [:lesson_id, :status])
    create index(:course_import_ai_cost_reservations, [:inserted_at])

    create constraint(:course_import_ai_cost_reservations, :ai_cost_reservation_status,
             check: "status IN ('reserved', 'settled', 'released')"
           )

    create table(:course_import_critic_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cache_key, :string, null: false
      add :result, :map, null: false
      add :last_used_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:course_import_critic_results, [:cache_key])
    create index(:course_import_critic_results, [:last_used_at])
  end
end
