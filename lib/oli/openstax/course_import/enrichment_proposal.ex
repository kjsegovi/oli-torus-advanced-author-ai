defmodule Oli.OpenStax.CourseImport.EnrichmentProposal do
  @moduledoc """
  A durable, author-governed enrichment proposal for one imported lesson.

  Proposals remain separate from model-authored lesson payloads. The planner
  may identify a proposal by id, but only this record carries research and
  approval state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{Lesson, Run, SimulationArtifact}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(article video existing_simulation generated_simulation external_resource)
  @states ~w(proposed approved rejected cancelled omitted)
  @delivery_modes ~w(annotated_link iframe_candidate generated_simulation)
  @research_statuses ~w(not_started running completed failed)

  @proposal_fields [
    :project_id,
    :run_id,
    :lesson_id,
    :kind,
    :rank,
    :version,
    :state,
    :delivery_mode,
    :instructional_rationale,
    :objective_ids,
    :source_evidence,
    :placement,
    :learner_task,
    :resource_title,
    :resource_url,
    :research_status,
    :research_version,
    :research_evidence,
    :research_failure,
    :metadata
  ]

  schema "course_import_enrichment_proposals" do
    belongs_to :project, Project, type: :id
    belongs_to :run, Run
    belongs_to :lesson, Lesson
    belongs_to :approved_by_author, Author, type: :id
    belongs_to :decided_by_author, Author, type: :id

    has_many :simulation_artifacts, SimulationArtifact, foreign_key: :proposal_id

    field :kind, :string
    field :rank, :integer
    field :version, :integer, default: 1
    field :state, :string, default: "proposed"
    field :delivery_mode, :string, default: "annotated_link"
    field :instructional_rationale, :string
    field :objective_ids, {:array, :string}, default: []
    field :source_evidence, :map, default: %{}
    field :placement, :map, default: %{}
    field :learner_task, :string
    field :resource_title, :string
    field :resource_url, :string
    field :research_status, :string, default: "not_started"
    field :research_version, :integer, default: 0
    field :research_evidence, :map, default: %{}
    field :research_failure, :map
    field :metadata, :map, default: %{}
    field :approved_version, :integer
    field :approved_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :approval_history, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds
  def states, do: @states
  def delivery_modes, do: @delivery_modes
  def research_statuses, do: @research_statuses

  def create_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, @proposal_fields)
    |> validate_proposal()
  end

  def revision_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :kind,
      :rank,
      :version,
      :state,
      :delivery_mode,
      :instructional_rationale,
      :objective_ids,
      :source_evidence,
      :placement,
      :learner_task,
      :resource_title,
      :resource_url,
      :research_status,
      :research_version,
      :research_evidence,
      :research_failure,
      :metadata,
      :approved_by_author_id,
      :approved_version,
      :approved_at,
      :decided_by_author_id,
      :decided_at,
      :decision_reason,
      :approval_history
    ])
    |> validate_proposal()
  end

  def research_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :research_status,
      :research_version,
      :research_evidence,
      :research_failure,
      :resource_title,
      :resource_url,
      :delivery_mode
    ])
    |> validate_inclusion(:research_status, @research_statuses)
    |> validate_number(:research_version, greater_than_or_equal_to: 0)
    |> validate_resource_url()
    |> check_constraint(:research_status,
      name: :course_import_enrichment_proposals_research_status
    )
    |> check_constraint(:delivery_mode,
      name: :course_import_enrichment_proposals_delivery_mode
    )
    |> check_constraint(:rank, name: :course_import_enrichment_proposals_bounds)
  end

  def decision_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :state,
      :approved_by_author_id,
      :approved_version,
      :approved_at,
      :decided_by_author_id,
      :decided_at,
      :decision_reason,
      :approval_history
    ])
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:approved_by_author_id)
    |> foreign_key_constraint(:decided_by_author_id)
    |> check_constraint(:state, name: :course_import_enrichment_proposals_state)
    |> check_constraint(:state, name: :course_import_enrichment_proposals_approval)
    |> check_constraint(:approved_version, name: :course_import_enrichment_proposals_bounds)
  end

  defp validate_proposal(changeset) do
    changeset
    |> validate_required([
      :project_id,
      :run_id,
      :lesson_id,
      :kind,
      :rank,
      :version,
      :state,
      :delivery_mode,
      :instructional_rationale,
      :learner_task
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:delivery_mode, @delivery_modes)
    |> validate_inclusion(:research_status, @research_statuses)
    |> validate_number(:rank, greater_than_or_equal_to: 1, less_than_or_equal_to: 3)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:research_version, greater_than_or_equal_to: 0)
    |> validate_length(:instructional_rationale, min: 1, max: 10_000)
    |> validate_length(:learner_task, min: 1, max: 10_000)
    |> validate_resource_url()
    |> unique_constraint(:rank,
      name: :course_import_enrichment_proposals_lesson_rank_index
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
    |> check_constraint(:kind, name: :course_import_enrichment_proposals_kind)
    |> check_constraint(:state, name: :course_import_enrichment_proposals_state)
    |> check_constraint(:delivery_mode,
      name: :course_import_enrichment_proposals_delivery_mode
    )
    |> check_constraint(:research_status,
      name: :course_import_enrichment_proposals_research_status
    )
    |> check_constraint(:rank, name: :course_import_enrichment_proposals_bounds)
    |> check_constraint(:state, name: :course_import_enrichment_proposals_approval)
  end

  defp validate_resource_url(changeset) do
    validate_change(changeset, :resource_url, fn :resource_url, value ->
      case URI.parse(value) do
        %URI{scheme: "https", host: host, userinfo: nil, port: port}
        when is_binary(host) and host != "" and (is_nil(port) or port == 443) ->
          []

        _ ->
          [resource_url: "must be an absolute HTTPS URL"]
      end
    end)
  end
end
