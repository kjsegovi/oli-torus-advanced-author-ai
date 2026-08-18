defmodule Oli.OpenStax.CourseImport.EnrichmentResearchSet do
  @moduledoc """
  Immutable, versioned evidence reviewed for one generated simulation.

  The record stores source metadata and claim-level paraphrases, never copied
  page bodies. An exact approved content hash gates downstream spec design.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    Lesson,
    Run,
    SimulationSpec
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(researching evidence_review approved rejected failed superseded)
  @domains ~w(chemistry physics biology mathematics astronomy computer_science)

  schema "course_import_enrichment_research_sets" do
    belongs_to :proposal, EnrichmentProposal
    belongs_to :project, Project, type: :id
    belongs_to :run, Run
    belongs_to :lesson, Lesson
    belongs_to :approved_by_author, Author, type: :id
    belongs_to :decided_by_author, Author, type: :id

    has_many :simulation_specs, SimulationSpec, foreign_key: :research_set_id

    field :version, :integer
    field :status, :string, default: "researching"
    field :domain, :string
    field :query, :string
    field :source_evidence, :map, default: %{}
    field :retrieved_sources, {:array, :map}, default: []
    field :proposed_sources, {:array, :map}, default: []
    field :claims, {:array, :map}, default: []
    field :search_count, :integer, default: 0
    field :source_count, :integer, default: 0
    field :provider, :string
    field :model, :string
    field :prompt_version, :string, default: "simulation-research-v1"
    field :source_hash, :string
    field :content_hash, :string
    field :accessed_at, :utc_datetime_usec
    field :validation_payload, :map, default: %{}
    field :failure, :map
    field :approved_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :approval_history, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def domains, do: @domains

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :proposal_id,
      :project_id,
      :run_id,
      :lesson_id,
      :version,
      :status,
      :domain,
      :query,
      :source_evidence,
      :provider,
      :model,
      :prompt_version
    ])
    |> validate_required([
      :proposal_id,
      :project_id,
      :run_id,
      :lesson_id,
      :version,
      :status,
      :domain,
      :query
    ])
    |> common_validations()
    |> unique_constraint([:proposal_id, :version],
      name: :course_import_enrichment_research_sets_proposal_version_index
    )
    |> foreign_key_constraint(:proposal_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
  end

  def result_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :status,
      :retrieved_sources,
      :proposed_sources,
      :claims,
      :search_count,
      :source_count,
      :provider,
      :model,
      :source_hash,
      :content_hash,
      :accessed_at,
      :validation_payload,
      :failure
    ])
    |> common_validations()
    |> validate_result()
  end

  def decision_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :status,
      :approved_by_author_id,
      :approved_at,
      :decided_by_author_id,
      :decided_at,
      :decision_reason,
      :approval_history
    ])
    |> common_validations()
    |> foreign_key_constraint(:approved_by_author_id)
    |> foreign_key_constraint(:decided_by_author_id)
    |> unique_constraint(:proposal_id,
      name: :course_import_enrichment_research_sets_one_approved_index
    )
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:domain, @domains)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:search_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> validate_number(:source_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 12)
    |> validate_format(:source_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:content_hash, ~r/^[0-9a-f]{64}$/)
    |> check_constraint(:status, name: :course_import_enrichment_research_sets_status)
    |> check_constraint(:version, name: :course_import_enrichment_research_sets_bounds)
  end

  defp validate_result(changeset) do
    case get_field(changeset, :status) do
      "evidence_review" ->
        changeset
        |> validate_required([
          :retrieved_sources,
          :proposed_sources,
          :claims,
          :source_hash,
          :content_hash,
          :accessed_at,
          :validation_payload
        ])
        |> validate_length(:retrieved_sources, min: 2, max: 12)
        |> validate_length(:proposed_sources, min: 2, max: 8)
        |> validate_length(:claims, min: 1)

      _ ->
        changeset
    end
  end
end
