defmodule Oli.OpenStax.CourseImport.SimulationSpec do
  @moduledoc "Immutable, validated design contract for one simulation bundle version."

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    EnrichmentResearchSet,
    Lesson,
    Run,
    SimulationArtifact
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(designing ready_for_review approved rejected failed superseded)

  schema "course_import_simulation_specs" do
    belongs_to :proposal, EnrichmentProposal
    belongs_to :research_set, EnrichmentResearchSet
    belongs_to :project, Project, type: :id
    belongs_to :run, Run
    belongs_to :lesson, Lesson

    has_many :simulation_artifacts, SimulationArtifact, foreign_key: :simulation_spec_id

    field :version, :integer
    field :status, :string, default: "designing"
    field :spec_payload, :map, default: %{}
    field :evidence_hash, :string
    field :content_hash, :string
    field :provider, :string
    field :model, :string
    field :prompt_version, :string, default: "simulation-spec-v1"
    field :repair_count, :integer, default: 0
    field :criticism, :map, default: %{}
    field :validation_payload, :map, default: %{}
    field :failure, :map
    field :approved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :proposal_id,
      :research_set_id,
      :project_id,
      :run_id,
      :lesson_id,
      :version,
      :status,
      :spec_payload,
      :evidence_hash,
      :content_hash,
      :provider,
      :model,
      :prompt_version,
      :repair_count,
      :criticism,
      :validation_payload,
      :failure,
      :approved_at
    ])
    |> validate_required([
      :proposal_id,
      :research_set_id,
      :project_id,
      :run_id,
      :lesson_id,
      :version,
      :status,
      :evidence_hash
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:repair_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
    |> validate_format(:evidence_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:content_hash, ~r/^[0-9a-f]{64}$/)
    |> validate_ready_payload()
    |> unique_constraint([:proposal_id, :version],
      name: :course_import_simulation_specs_proposal_version_index
    )
    |> unique_constraint(:proposal_id,
      name: :course_import_simulation_specs_one_approved_index
    )
    |> foreign_key_constraint(:proposal_id)
    |> foreign_key_constraint(:research_set_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
    |> check_constraint(:status, name: :course_import_simulation_specs_status)
    |> check_constraint(:version, name: :course_import_simulation_specs_bounds)
  end

  defp validate_ready_payload(changeset) do
    if get_field(changeset, :status) in ["ready_for_review", "approved"] do
      changeset
      |> validate_required([:spec_payload, :content_hash, :validation_payload])
      |> validate_change(:spec_payload, fn :spec_payload, value ->
        if is_map(value) and map_size(value) > 0,
          do: [],
          else: [spec_payload: "must not be empty"]
      end)
    else
      changeset
    end
  end
end
