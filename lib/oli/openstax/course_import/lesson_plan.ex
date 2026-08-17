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
    field :generation_metadata, :map, default: %{}
    field :checks_snapshot, :map, default: %{}
    field :created_by, :string, default: "ai"
    field :approved_by_user, :boolean, default: false
    field :approved_at, :utc_datetime_usec
    field :rejection_reason, :string
    field :exclusion_acknowledgements, {:array, :map}, default: []

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
      :generation_metadata,
      :checks_snapshot,
      :created_by,
      :approved_by_user,
      :approved_at,
      :rejection_reason,
      :exclusion_acknowledgements
    ])
    |> validate_required([:lesson_id, :version])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:created_by, ["ai", "author", "system"])
    |> validate_change(:content_payload, &validate_current_contract/2)
    |> foreign_key_constraint(:lesson_id)
    |> unique_constraint(:lesson_id_version,
      name: :course_import_lesson_plans_lesson_id_version_index
    )
  end

  defp validate_current_contract(:content_payload, content) when is_map(content) do
    mode = content["authoring_mode"] || content[:authoring_mode]
    version = content["schema_version"] || content[:schema_version]

    if {mode, version} in [{"basic", 5}, {"advanced", 6}] do
      []
    else
      [
        content_payload:
          "must use the current OpenStax contract: Basic schema 5 or Advanced schema 6"
      ]
    end
  end

  defp validate_current_contract(:content_payload, _content),
    do: [content_payload: "must be a current OpenStax plan map"]
end
