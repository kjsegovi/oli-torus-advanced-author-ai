defmodule Oli.Repo.Migrations.CreateOpenstaxSimulationGovernance do
  use Ecto.Migration

  @proposal_states "'proposed', 'researching', 'evidence_review', 'designing', 'artifact_review', 'approved', 'rejected', 'cancelled', 'omitted', 'failed'"
  @research_states "'researching', 'evidence_review', 'approved', 'rejected', 'failed', 'superseded'"
  @spec_states "'designing', 'ready_for_review', 'approved', 'rejected', 'failed', 'superseded'"

  def up do
    drop_if_exists(
      constraint(
        :course_import_enrichment_proposals,
        :course_import_enrichment_proposals_state
      )
    )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_state,
             check: "state IN (#{@proposal_states})"
           )

    create table(:course_import_enrichment_research_sets, primary_key: false) do
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
      add :status, :string, null: false, default: "researching"
      add :domain, :string, null: false
      add :query, :text, null: false
      add :source_evidence, :map, null: false, default: %{}
      add :retrieved_sources, {:array, :map}, null: false, default: []
      add :proposed_sources, {:array, :map}, null: false, default: []
      add :claims, {:array, :map}, null: false, default: []
      add :search_count, :integer, null: false, default: 0
      add :source_count, :integer, null: false, default: 0
      add :provider, :string
      add :model, :string
      add :prompt_version, :string, null: false, default: "simulation-research-v1"
      add :source_hash, :string
      add :content_hash, :string
      add :accessed_at, :utc_datetime_usec
      add :validation_payload, :map, null: false, default: %{}
      add :failure, :map
      add :approved_by_author_id, references(:authors, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec
      add :decided_by_author_id, references(:authors, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      add :decision_reason, :text
      add :approval_history, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :course_import_enrichment_research_sets,
             :course_import_enrichment_research_sets_status,
             check: "status IN (#{@research_states})"
           )

    create constraint(
             :course_import_enrichment_research_sets,
             :course_import_enrichment_research_sets_bounds,
             check:
               "version > 0 AND search_count BETWEEN 0 AND 4 AND source_count BETWEEN 0 AND 12"
           )

    create unique_index(:course_import_enrichment_research_sets, [:proposal_id, :version],
             name: :course_import_enrichment_research_sets_proposal_version_index
           )

    create unique_index(:course_import_enrichment_research_sets, [:proposal_id],
             name: :course_import_enrichment_research_sets_one_approved_index,
             where: "status = 'approved'"
           )

    create index(:course_import_enrichment_research_sets, [:run_id, :status])
    create index(:course_import_enrichment_research_sets, [:proposal_id, :status])

    create table(:course_import_simulation_specs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:course_import_enrichment_proposals,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :research_set_id,
          references(:course_import_enrichment_research_sets,
            type: :binary_id,
            on_delete: :restrict
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
      add :status, :string, null: false, default: "designing"
      add :spec_payload, :map, null: false, default: %{}
      add :evidence_hash, :string, null: false
      add :content_hash, :string
      add :provider, :string
      add :model, :string
      add :prompt_version, :string, null: false, default: "simulation-spec-v1"
      add :repair_count, :integer, null: false, default: 0
      add :criticism, :map, null: false, default: %{}
      add :validation_payload, :map, null: false, default: %{}
      add :failure, :map
      add :approved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :course_import_simulation_specs,
             :course_import_simulation_specs_status,
             check: "status IN (#{@spec_states})"
           )

    create constraint(
             :course_import_simulation_specs,
             :course_import_simulation_specs_bounds,
             check: "version > 0 AND repair_count BETWEEN 0 AND 3"
           )

    create unique_index(:course_import_simulation_specs, [:proposal_id, :version],
             name: :course_import_simulation_specs_proposal_version_index
           )

    create unique_index(:course_import_simulation_specs, [:proposal_id],
             name: :course_import_simulation_specs_one_approved_index,
             where: "status = 'approved'"
           )

    create index(:course_import_simulation_specs, [:research_set_id, :status])
    create index(:course_import_simulation_specs, [:run_id, :status])

    alter table(:course_import_simulation_artifacts) do
      add :simulation_spec_id,
          references(:course_import_simulation_specs, type: :binary_id, on_delete: :restrict)
    end

    create index(:course_import_simulation_artifacts, [:simulation_spec_id])
  end

  def down do
    drop_if_exists index(:course_import_simulation_artifacts, [:simulation_spec_id])

    alter table(:course_import_simulation_artifacts) do
      remove :simulation_spec_id
    end

    drop table(:course_import_simulation_specs)
    drop table(:course_import_enrichment_research_sets)

    drop_if_exists(
      constraint(
        :course_import_enrichment_proposals,
        :course_import_enrichment_proposals_state
      )
    )

    create constraint(
             :course_import_enrichment_proposals,
             :course_import_enrichment_proposals_state,
             check: "state IN ('proposed', 'approved', 'rejected', 'cancelled', 'omitted')"
           )
  end
end
