defmodule Oli.Repo.Migrations.CreateCourseImportEnrichments do
  use Ecto.Migration

  @proposal_kinds "'article', 'video', 'existing_simulation', 'generated_simulation', 'external_resource'"
  @proposal_states "'proposed', 'approved', 'rejected', 'cancelled', 'omitted'"
  @delivery_modes "'annotated_link', 'iframe_candidate', 'generated_simulation'"
  @research_states "'not_started', 'running', 'completed', 'failed'"

  @artifact_states "'generating', 'ready_for_review', 'validation_failed', 'approved', 'rejected', 'cancelled', 'failed', 'superseded'"
  @validation_states "'pending', 'passed', 'failed'"
  @storage_states "'unstaged', 'staged', 'promoted', 'discarded'"

  def change do
    create table(:course_import_enrichment_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all), null: false

      add :run_id,
          references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :rank, :integer, null: false
      add :version, :integer, null: false, default: 1
      add :state, :string, null: false, default: "proposed"
      add :delivery_mode, :string, null: false, default: "annotated_link"
      add :instructional_rationale, :text, null: false
      add :objective_ids, {:array, :text}, null: false, default: []
      add :source_evidence, :map, null: false, default: %{}
      add :placement, :map, null: false, default: %{}
      add :learner_task, :text, null: false
      add :resource_title, :text
      add :resource_url, :text
      add :research_status, :string, null: false, default: "not_started"
      add :research_version, :integer, null: false, default: 0
      add :research_evidence, :map, null: false, default: %{}
      add :research_failure, :map
      add :metadata, :map, null: false, default: %{}
      add :approved_by_author_id, references(:authors, on_delete: :nilify_all)
      add :approved_version, :integer
      add :approved_at, :utc_datetime_usec
      add :decided_by_author_id, references(:authors, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      add :decision_reason, :text
      add :approval_history, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_kind,
             check: "kind IN (#{@proposal_kinds})"
           )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_state,
             check: "state IN (#{@proposal_states})"
           )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_delivery_mode,
             check: "delivery_mode IN (#{@delivery_modes})"
           )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_research_status,
             check: "research_status IN (#{@research_states})"
           )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_bounds,
             check:
               "rank BETWEEN 1 AND 3 AND version > 0 AND research_version >= 0 AND (approved_version IS NULL OR approved_version > 0)"
           )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_approval,
             check: """
             state <> 'approved' OR (
               approved_by_author_id IS NOT NULL AND
               approved_at IS NOT NULL AND
               approved_version = version
             )
             """
           )

    create unique_index(:course_import_enrichment_proposals, [:lesson_id, :rank],
             name: :course_import_enrichment_proposals_lesson_rank_index
           )

    create index(:course_import_enrichment_proposals, [:run_id, :state])
    create index(:course_import_enrichment_proposals, [:project_id, :inserted_at])
    create index(:course_import_enrichment_proposals, [:lesson_id, :state])

    create table(:course_import_simulation_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:course_import_enrichment_proposals,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :project_id, references(:projects, on_delete: :delete_all), null: false

      add :run_id,
          references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :status, :string, null: false, default: "generating"
      add :generator_name, :string
      add :generator_version, :string
      add :generation_metadata, :map, null: false, default: %{}
      add :bundle_manifest, :map, null: false, default: %{}
      add :capi_manifest, :map, null: false, default: %{}
      add :accessibility_metadata, :map, null: false, default: %{}
      add :validation_status, :string, null: false, default: "pending"
      add :validation_version, :integer, null: false, default: 0
      add :validation_payload, :map, null: false, default: %{}
      add :content_hash, :string
      add :byte_size, :bigint
      add :storage_state, :string, null: false, default: "unstaged"
      add :storage_provider, :string
      add :storage_key, :text
      add :storage_origin, :text
      add :failure, :map
      add :generated_at, :utc_datetime_usec
      add :staged_at, :utc_datetime_usec
      add :approved_by_author_id, references(:authors, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :decided_by_author_id, references(:authors, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      add :decision_reason, :text
      add :approval_history, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_status,
             check: "status IN (#{@artifact_states})"
           )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_validation_status,
             check: "validation_status IN (#{@validation_states})"
           )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_storage_state,
             check: "storage_state IN (#{@storage_states})"
           )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_bounds,
             check:
               "version > 0 AND validation_version >= 0 AND (byte_size IS NULL OR byte_size >= 0)"
           )

    create constraint(
             :course_import_simulation_artifacts,
             :course_import_simulation_artifacts_preview,
             check: """
             status NOT IN ('ready_for_review', 'approved', 'superseded') OR (
               validation_status = 'passed' AND
               validation_version > 0 AND
               content_hash ~ '^[0-9a-f]{64}$' AND
               byte_size IS NOT NULL AND
               storage_state IN ('staged', 'promoted') AND
               storage_provider IS NOT NULL AND
               storage_key IS NOT NULL AND
               position(lower(content_hash) in lower(storage_key)) > 0 AND
               storage_origin IS NOT NULL
             )
             """
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

    create unique_index(:course_import_simulation_artifacts, [:proposal_id, :version],
             name: :course_import_simulation_artifacts_proposal_version_index
           )

    create unique_index(:course_import_simulation_artifacts, [:proposal_id],
             name: :course_import_simulation_artifacts_one_approved_index,
             where: "status = 'approved'"
           )

    create index(:course_import_simulation_artifacts, [:run_id, :status])
    create index(:course_import_simulation_artifacts, [:lesson_id, :status])
    create index(:course_import_simulation_artifacts, [:project_id, :inserted_at])
    create index(:course_import_simulation_artifacts, [:content_hash])
    create index(:course_import_simulation_artifacts, [:storage_state, :inserted_at])
  end
end
