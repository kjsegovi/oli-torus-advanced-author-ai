defmodule Oli.OpenStax.CourseImport.LessonPlan do
  @moduledoc """
  Persisted plan version for an OpenStax lesson.

  The plan includes content and generated questions so authors can approve
  and modify each lesson before it is applied.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.Lesson

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_lesson_plans" do
    belongs_to :lesson, Lesson

    field :version, :integer
    field :content_payload, :map, default: %{}
    field :questions_payload, :map, default: %{}
    field :checks_snapshot, :map, default: %{}
    field :created_by, :string, default: "ai"
    field :approved_by_user, :boolean, default: false
    field :approved_at, :utc_datetime_usec
    field :rejection_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :lesson_id,
      :version,
      :content_payload,
      :questions_payload,
      :checks_snapshot,
      :created_by,
      :approved_by_user,
      :approved_at,
      :rejection_reason
    ])
    |> validate_required([:lesson_id, :version])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:created_by, ["ai", "author", "system"])
    |> foreign_key_constraint(:lesson_id)
    |> unique_constraint(:lesson_id_version,
      name: :course_import_lesson_plans_lesson_id_version_index
    )
  end
end
