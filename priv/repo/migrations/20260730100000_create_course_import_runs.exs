defmodule Oli.Repo.Migrations.CreateCourseImportRuns do
  use Ecto.Migration

  @active_statuses "'preflighting', 'awaiting_scope', 'ingesting', 'planning_outline', 'awaiting_outline_approval', 'planning_lessons', 'awaiting_lesson_approval', 'compiling', 'applying'"
  @all_statuses @active_statuses <> ", 'completed', 'failed', 'cancelled'"

  def change do
    create table(:course_import_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :author_id, references(:authors, on_delete: :restrict), null: false
      add :target_root_container_resource_id, references(:resources, on_delete: :nilify_all)
      add :status, :string, null: false, default: "preflighting"
      add :source_url, :text, null: false
      add :book_slug, :string, null: false
      add :scope_manifest, :jsonb, null: false, default: fragment("'{}'::jsonb")

      add :progress, :jsonb,
        null: false,
        default: fragment("'{\"stage\": \"preflighting\", \"stageTotals\": []}'::jsonb")

      add :latest_plan_version, :integer, null: false, default: 0
      add :error, :map
      add :result, :map
      add :preflight_snapshot, :map
      add :outline_approved_by_author_id, references(:authors, on_delete: :nilify_all)
      add :outline_approved_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :failure_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_runs, :course_import_runs_valid_status,
             check: "status IN (#{@all_statuses})"
           )

    create index(:course_import_runs, [:project_id, :author_id])
    create index(:course_import_runs, [:project_id, :status])
    create index(:course_import_runs, [:author_id, :inserted_at])
    create index(:course_import_runs, [:target_root_container_resource_id])

    create unique_index(
             :course_import_runs,
             [:project_id, :target_root_container_resource_id],
             name: :course_import_runs_one_active_per_project,
             where: "status IN (#{@active_statuses})"
           )

    create table(:course_import_units, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :unit_name, :string, null: false
      add :order, :integer, null: false
      add :source_reference, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :source_sections_count, :integer, null: false, default: 0
      add :plan_payload, :map
      add :assessment_payload, :map
      add :selected, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:course_import_units, [:run_id])
    create unique_index(:course_import_units, [:run_id, :order])

    create table(:course_import_lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :unit_id, references(:course_import_units, type: :binary_id, on_delete: :delete_all),
        null: false

      add :order, :integer, null: false
      add :title, :string, null: false
      add :source_sections, {:array, :text}, null: false, default: []
      add :plan_mode, :string, null: false, default: "basic"
      add :status, :string, null: false, default: "pending"
      add :last_plan_version, :integer, null: false, default: 0
      add :source_excerpt, :text
      add :source_evidence_links, {:array, :text}, default: []
      add :selected, :boolean, default: true, null: false
      add :approved_by_author_id, references(:authors, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :last_repair_attempt_at, :utc_datetime_usec
      add :repair_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_lessons, :course_import_lessons_status,
             check:
               "status IN ('pending', 'ready_for_review', 'approved', 'needs_repair', 'failed', 'compiled', 'applied')"
           )

    create constraint(:course_import_lessons, :course_import_lessons_plan_mode,
             check: "plan_mode IN ('basic', 'advanced')"
           )

    create index(:course_import_lessons, [:run_id])
    create index(:course_import_lessons, [:unit_id])
    create unique_index(:course_import_lessons, [:run_id, :unit_id, :order])

    create table(:course_import_lesson_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :content_payload, :map, null: false, default: %{}
      add :questions_payload, :map, null: false, default: %{}
      add :checks_snapshot, :map, default: %{}
      add :created_by, :string, null: false, default: "ai"
      add :approved_by_user, :boolean, default: false
      add :approved_at, :utc_datetime_usec
      add :rejection_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:course_import_lesson_plans, [:lesson_id, :version])
    create index(:course_import_lesson_plans, [:lesson_id, :inserted_at])

    create table(:course_import_lesson_checks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :check_type, :string, null: false
      add :status, :string, null: false
      add :findings, :map, default: %{}
      add :repair_plan, :map
      add :repaired_plan_version, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_lesson_checks, :course_import_lesson_checks_type,
             check:
               "check_type IN ('source_fidelity', 'pedagogy_assessment', 'torus_accessibility')"
           )

    create constraint(:course_import_lesson_checks, :course_import_lesson_checks_status,
             check: "status IN ('passed', 'failed')"
           )

    create index(:course_import_lesson_checks, [:lesson_id])
    create unique_index(:course_import_lesson_checks, [:lesson_id, :version, :check_type])

    create table(:course_import_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event, :string, null: false
      add :recipient_hash, :string, null: false
      add :dedupe_key, :string, null: false
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:course_import_notifications, [:run_id, :dedupe_key])
    create index(:course_import_notifications, [:event])

    create constraint(:course_import_notifications, :course_import_notifications_event,
             check:
               "event IN ('outline_ready', 'lesson_plans_ready', 'import_completed', 'import_failed')"
           )
  end
end
