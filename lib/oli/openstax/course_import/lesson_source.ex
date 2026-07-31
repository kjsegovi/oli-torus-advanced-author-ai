defmodule Oli.OpenStax.CourseImport.LessonSource do
  @moduledoc """
  Ordered evidence mapping from a planned lesson to a retained source block.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.{Lesson, Run, SourceBlock}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_lesson_sources" do
    belongs_to :run, Run
    belongs_to :lesson, Lesson
    belongs_to :source_block, SourceBlock

    field :order, :integer
    field :purpose, :string, default: "instruction"
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(lesson_source, attrs) do
    lesson_source
    |> cast(attrs, [:run_id, :lesson_id, :source_block_id, :order, :purpose, :metadata])
    |> validate_required([:run_id, :lesson_id, :source_block_id, :order, :purpose])
    |> validate_number(:order, greater_than: 0)
    |> unique_constraint([:lesson_id, :source_block_id])
    |> unique_constraint([:lesson_id, :order])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
    |> foreign_key_constraint(:source_block_id)
    |> check_constraint(:order, name: :course_import_lesson_sources_order)
  end
end
