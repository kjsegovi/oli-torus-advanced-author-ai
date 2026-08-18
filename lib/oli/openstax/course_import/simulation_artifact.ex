defmodule Oli.OpenStax.CourseImport.SimulationArtifact do
  @moduledoc """
  An immutable generated-simulation bundle version and its validation record.

  The row stores trusted storage identity rather than model-authored iframe
  URLs. A compiler must resolve an approved row through the configured artifact
  storage provider.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    Lesson,
    Run,
    SimulationArtifactAttempt,
    SimulationSpec
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(generating ready_for_review validation_failed approved rejected cancelled failed superseded)
  @validation_statuses ~w(pending passed failed)
  @storage_states ~w(unstaged staged promoted discarded)

  schema "course_import_simulation_artifacts" do
    belongs_to :proposal, EnrichmentProposal
    belongs_to :project, Project, type: :id
    belongs_to :run, Run
    belongs_to :lesson, Lesson
    belongs_to :simulation_spec, SimulationSpec
    belongs_to :approved_by_author, Author, type: :id
    belongs_to :decided_by_author, Author, type: :id

    has_many :attempts, SimulationArtifactAttempt, foreign_key: :artifact_id

    field :version, :integer
    field :status, :string, default: "generating"
    field :generator_name, :string
    field :generator_version, :string
    field :generation_metadata, :map, default: %{}
    field :bundle_manifest, :map, default: %{}
    field :capi_manifest, :map, default: %{}
    field :accessibility_metadata, :map, default: %{}
    field :validation_status, :string, default: "pending"
    field :validation_version, :integer, default: 0
    field :validation_payload, :map, default: %{}
    field :content_hash, :string
    field :byte_size, :integer
    field :storage_state, :string, default: "unstaged"
    field :storage_provider, :string
    field :storage_key, :string
    field :storage_origin, :string
    field :failure, :map
    field :generated_at, :utc_datetime_usec
    field :staged_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :approval_history, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def validation_statuses, do: @validation_statuses
  def storage_states, do: @storage_states

  def create_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :proposal_id,
      :project_id,
      :run_id,
      :lesson_id,
      :simulation_spec_id,
      :version,
      :status,
      :generator_name,
      :generator_version,
      :generation_metadata
    ])
    |> validate_required([
      :proposal_id,
      :project_id,
      :run_id,
      :lesson_id,
      :version,
      :status
    ])
    |> common_validations()
    |> unique_constraint(:version,
      name: :course_import_simulation_artifacts_proposal_version_index
    )
    |> unique_constraint(:proposal_id,
      name: :course_import_simulation_artifacts_one_active_index
    )
    |> foreign_key_constraint(:proposal_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
    |> foreign_key_constraint(:simulation_spec_id)
  end

  def preview_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :status,
      :generator_name,
      :generator_version,
      :generation_metadata,
      :bundle_manifest,
      :capi_manifest,
      :accessibility_metadata,
      :validation_status,
      :validation_version,
      :validation_payload,
      :content_hash,
      :byte_size,
      :storage_state,
      :storage_provider,
      :storage_key,
      :storage_origin,
      :failure,
      :generated_at,
      :staged_at
    ])
    |> common_validations()
    |> validate_preview_fields()
  end

  def decision_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :status,
      :storage_state,
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
      name: :course_import_simulation_artifacts_one_approved_index
    )
  end

  def ready_for_approval?(%__MODULE__{} = artifact) do
    artifact.status == "ready_for_review" and
      artifact.validation_status == "passed" and
      artifact.validation_version > 0 and
      valid_hash?(artifact.content_hash) and
      is_integer(artifact.byte_size) and artifact.byte_size >= 0 and
      artifact.storage_state in ["staged", "promoted"] and
      present?(artifact.storage_provider) and
      present?(artifact.storage_key) and
      content_addressed?(artifact.storage_key, artifact.content_hash) and
      present?(artifact.storage_origin) and
      accessibility_metadata_valid?(artifact.accessibility_metadata)
  end

  def resolvable?(%__MODULE__{} = artifact) do
    artifact.status == "approved" and ready_payload?(artifact)
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:validation_status, @validation_statuses)
    |> validate_inclusion(:storage_state, @storage_states)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:validation_version, greater_than_or_equal_to: 0)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_format(:content_hash, ~r/^[0-9a-f]{64}$/)
    |> check_constraint(:status, name: :course_import_simulation_artifacts_status)
    |> check_constraint(:validation_status,
      name: :course_import_simulation_artifacts_validation_status
    )
    |> check_constraint(:storage_state,
      name: :course_import_simulation_artifacts_storage_state
    )
    |> check_constraint(:version, name: :course_import_simulation_artifacts_bounds)
    |> check_constraint(:status, name: :course_import_simulation_artifacts_preview)
    |> check_constraint(:status, name: :course_import_simulation_artifacts_approval)
  end

  defp validate_preview_fields(changeset) do
    case get_field(changeset, :status) do
      status when status in ["ready_for_review", "approved", "superseded"] ->
        changeset
        |> validate_required([
          :validation_status,
          :validation_version,
          :content_hash,
          :byte_size,
          :storage_state,
          :storage_provider,
          :storage_key,
          :storage_origin
        ])
        |> validate_metadata_map(:bundle_manifest)
        |> validate_metadata_map(:accessibility_metadata)

      _ ->
        changeset
    end
  end

  defp validate_metadata_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value) and map_size(value) > 0,
        do: [],
        else: [{field, "must not be empty"}]
    end)
  end

  defp ready_payload?(artifact) do
    artifact.validation_status == "passed" and artifact.validation_version > 0 and
      valid_hash?(artifact.content_hash) and
      artifact.storage_state in ["staged", "promoted"] and
      present?(artifact.storage_provider) and present?(artifact.storage_key) and
      content_addressed?(artifact.storage_key, artifact.content_hash) and
      present?(artifact.storage_origin) and
      accessibility_metadata_valid?(artifact.accessibility_metadata)
  end

  defp accessibility_metadata_valid?(metadata) when is_map(metadata) do
    present?(metadata["title"] || metadata[:title]) and
      present?(metadata["description"] || metadata[:description])
  end

  defp accessibility_metadata_valid?(_), do: false

  defp valid_hash?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp valid_hash?(_), do: false

  defp content_addressed?(storage_key, content_hash)
       when is_binary(storage_key) and is_binary(content_hash) do
    String.contains?(String.downcase(storage_key), String.downcase(content_hash))
  end

  defp content_addressed?(_, _), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
