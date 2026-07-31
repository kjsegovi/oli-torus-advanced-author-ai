defmodule Oli.OpenStax.CourseImport.Lesson do
  @moduledoc """
  OpenStax lesson extracted from an outline and planned by the AI.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.OpenStax.CourseImport.{LessonCheck, LessonPlan, LessonSource, Run, Unit}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @planning_states [
    "pending",
    "queued",
    "running",
    "retrying",
    "completed",
    "failed",
    "cancelled"
  ]
  @planning_operations ["initial", "regenerate"]

  schema "course_import_lessons" do
    belongs_to :run, Run
    belongs_to :unit, Unit
    has_many :plans, LessonPlan, foreign_key: :lesson_id
    has_many :checks, LessonCheck, foreign_key: :lesson_id
    has_many :lesson_sources, LessonSource, foreign_key: :lesson_id

    belongs_to :approved_by_author, Author, type: :id

    field :order, :integer
    field :title, :string
    field :source_sections, {:array, :string}, default: []
    field :source_objectives, {:array, :string}, default: []
    field :plan_mode, :string, default: "basic"
    field :status, :string, default: "pending"
    field :last_plan_version, :integer, default: 0
    field :source_excerpt, :string
    field :source_evidence_links, {:array, :string}, default: []
    field :source_word_count, :integer, default: 0
    field :source_coverage, :map, default: %{}
    field :selected, :boolean, default: true
    field :approved_at, :utc_datetime_usec
    field :last_repair_attempt_at, :utc_datetime_usec
    field :repair_attempts, :integer, default: 0
    field :planning_state, :string, default: "pending"
    field :planning_operation, :string, default: "initial"
    field :planning_generation, :integer, default: 0
    field :planning_request_id, Ecto.UUID
    field :planning_position, :integer
    field :planning_oban_job_id, :integer
    field :planning_attempts, :integer, default: 0
    field :planning_base_plan_version, :integer, default: 0
    field :planning_queued_at, :utc_datetime_usec
    field :planning_started_at, :utc_datetime_usec
    field :planning_last_progress_at, :utc_datetime_usec
    field :planning_finished_at, :utc_datetime_usec
    field :planning_error, :map

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def planning_states, do: @planning_states
  def planning_operations, do: @planning_operations

  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [
      :run_id,
      :unit_id,
      :order,
      :title,
      :source_sections,
      :source_objectives,
      :plan_mode,
      :status,
      :last_plan_version,
      :source_excerpt,
      :source_evidence_links,
      :source_word_count,
      :source_coverage,
      :selected,
      :approved_by_author_id,
      :approved_at,
      :last_repair_attempt_at,
      :repair_attempts,
      :planning_state,
      :planning_operation,
      :planning_generation,
      :planning_request_id,
      :planning_position,
      :planning_oban_job_id,
      :planning_attempts,
      :planning_base_plan_version,
      :planning_queued_at,
      :planning_started_at,
      :planning_last_progress_at,
      :planning_finished_at,
      :planning_error
    ])
    |> validate_required([:run_id, :unit_id, :order, :title])
    |> validate_number(:order, greater_than: 0)
    |> validate_inclusion(:plan_mode, ["basic", "advanced"])
    |> validate_inclusion(:status, [
      "pending",
      "ready_for_review",
      "approved",
      "needs_attention",
      "needs_repair",
      "failed",
      "compiled",
      "applied"
    ])
    |> validate_number(:source_word_count, greater_than_or_equal_to: 0)
    |> validate_number(:last_plan_version, greater_than_or_equal_to: 0)
    |> validate_number(:repair_attempts, greater_than_or_equal_to: 0)
    |> validate_inclusion(:planning_state, @planning_states)
    |> validate_inclusion(:planning_operation, @planning_operations)
    |> validate_number(:planning_generation, greater_than_or_equal_to: 0)
    |> validate_number(:planning_position, greater_than: 0)
    |> validate_number(:planning_oban_job_id, greater_than: 0)
    |> validate_number(:planning_attempts, greater_than_or_equal_to: 0)
    |> validate_number(:planning_base_plan_version, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:unit_id)
    |> foreign_key_constraint(:approved_by_author_id)
    |> unique_constraint(:planning_request_id,
      name: :course_import_lessons_planning_request_id_unique_index
    )
    |> check_constraint(:status, name: :course_import_lessons_status)
    |> check_constraint(:source_word_count,
      name: :course_import_lessons_source_word_count
    )
    |> check_constraint(:planning_state, name: :course_import_lessons_planning_state)
    |> check_constraint(:planning_operation,
      name: :course_import_lessons_planning_operation
    )
    |> check_constraint(:planning_generation,
      name: :course_import_lessons_planning_generation
    )
    |> check_constraint(:planning_position,
      name: :course_import_lessons_planning_position
    )
    |> check_constraint(:planning_oban_job_id,
      name: :course_import_lessons_planning_oban_job_id
    )
    |> check_constraint(:planning_attempts,
      name: :course_import_lessons_planning_attempts
    )
    |> check_constraint(:planning_base_plan_version,
      name: :course_import_lessons_planning_base_plan_version
    )
  end
end
