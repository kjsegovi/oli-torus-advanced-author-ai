defmodule Oli.OpenStax.CourseImport.Unit do
  @moduledoc """
  OpenStax unit extracted from the source book scope.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.{Lesson, Run}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_units" do
    belongs_to :run, Run
    has_many :lessons, Lesson

    field :unit_name, :string
    field :order, :integer
    field :source_reference, :map, default: %{}
    field :status, :string, default: "pending"
    field :source_sections_count, :integer, default: 0
    field :plan_payload, :map
    field :assessment_payload, :map
    field :selected, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(unit, attrs) do
    unit
    |> cast(attrs, [
      :run_id,
      :unit_name,
      :order,
      :source_reference,
      :status,
      :source_sections_count,
      :plan_payload,
      :assessment_payload,
      :selected
    ])
    |> validate_required([:run_id, :unit_name, :order])
    |> validate_number(:order, greater_than: 0)
    |> validate_inclusion(:status, [
      "pending",
      "ready_for_review",
      "approved",
      "failed",
      "skipped"
    ])
    |> validate_number(:source_sections_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:run_id)
  end
end
