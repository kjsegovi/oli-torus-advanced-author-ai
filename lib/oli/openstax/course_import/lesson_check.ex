defmodule Oli.OpenStax.CourseImport.LessonCheck do
  @moduledoc """
  Durable result for one validation pass against a lesson plan version.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.Lesson

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @check_types ["source_fidelity", "pedagogy_assessment", "torus_accessibility"]
  @statuses ["passed", "failed"]

  schema "course_import_lesson_checks" do
    belongs_to :lesson, Lesson

    field :version, :integer
    field :check_type, :string
    field :status, :string
    field :findings, :map, default: %{}
    field :repair_plan, :map
    field :repaired_plan_version, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def check_types, do: @check_types

  def changeset(check, attrs) do
    check
    |> cast(attrs, [
      :lesson_id,
      :version,
      :check_type,
      :status,
      :findings,
      :repair_plan,
      :repaired_plan_version
    ])
    |> validate_required([:lesson_id, :version, :check_type, :status])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:check_type, @check_types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:lesson_id)
    |> unique_constraint([:lesson_id, :version, :check_type])
  end
end
