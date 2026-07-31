defmodule Oli.GoogleSlides.ImportAnalysisChunk do
  @moduledoc """
  A bounded, durable source fragment used by the resumable Slides planner.

  Chunks contain source evidence only. They never contain provider messages,
  secrets, or unsanitized provider errors.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.GoogleSlides.ImportRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [:pending, :processing, :completed, :failed]

  schema "google_slides_import_analysis_chunks" do
    belongs_to :run, ImportRun, type: :binary_id

    field :ordinal, :integer
    field :slide_ids, {:array, :string}, default: []
    field :object_ids, {:array, :string}, default: []
    field :source_fragment, :map
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :usage, :map, default: %{}
    field :attempt_count, :integer, default: 0
    field :error, :map

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :run_id,
      :ordinal,
      :slide_ids,
      :object_ids,
      :source_fragment,
      :status,
      :usage,
      :attempt_count,
      :error
    ])
    |> validate_required([:run_id, :ordinal, :source_fragment, :status])
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :ordinal])
    |> check_constraint(:status, name: :google_slides_import_analysis_chunks_valid_status)
    |> check_constraint(:ordinal, name: :google_slides_import_analysis_chunks_valid_ordinal)
  end
end
