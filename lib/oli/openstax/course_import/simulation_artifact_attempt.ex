defmodule Oli.OpenStax.CourseImport.SimulationArtifactAttempt do
  @moduledoc """
  An append-only record of one generated simulation candidate and its outcome.

  Attempt rows intentionally retain hashes, bounded validation findings, model
  usage, and criticism without retaining model-authored source. There is no
  update changeset: a repair always creates a new row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.SimulationArtifact

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(validation_failed critic_rejected critic_failed accepted cancelled)

  schema "course_import_simulation_artifact_attempts" do
    belongs_to :artifact, SimulationArtifact

    field :attempt_number, :integer
    field :status, :string
    field :source_hash, :string
    field :content_hash, :string
    field :generator_name, :string
    field :generator_version, :string
    field :findings, {:array, :map}, default: []
    field :validation_summary, :map, default: %{}
    field :criticism, :map, default: %{}
    field :model_usage, :map, default: %{}
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :artifact_id,
      :attempt_number,
      :status,
      :source_hash,
      :content_hash,
      :generator_name,
      :generator_version,
      :findings,
      :validation_summary,
      :criticism,
      :model_usage,
      :completed_at
    ])
    |> validate_required([:artifact_id, :attempt_number, :status, :completed_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_length(:findings, max: 30)
    |> validate_hash(:source_hash)
    |> validate_hash(:content_hash)
    |> validate_map(:validation_summary)
    |> validate_map(:criticism)
    |> validate_map(:model_usage)
    |> foreign_key_constraint(:artifact_id)
    |> unique_constraint([:artifact_id, :attempt_number],
      name: :course_import_sim_artifact_attempt_unique
    )
    |> check_constraint(:status,
      name: :course_import_simulation_artifact_attempts_status
    )
    |> check_constraint(:attempt_number,
      name: :course_import_simulation_artifact_attempts_bounds
    )
  end

  defp validate_hash(changeset, field) do
    validate_format(changeset, field, ~r/^[0-9a-f]{64}$/)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
