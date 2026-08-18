defmodule Oli.OpenStax.CourseImport.Run do
  @moduledoc """
  Persistent state for a single OpenStax course import run.

  Runs are the durability boundary for an import lifecycle:
  link validation, outline planning, per-lesson planning approvals,
  and final lesson creation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    EnrichmentResearchSet,
    Media,
    Notification,
    SimulationArtifact,
    SimulationSpec,
    SourceAsset,
    SourceBlock,
    SourceSection,
    Unit
  }

  alias Oli.Resources.Resource

  @primary_key {:id, :binary_id, autogenerate: true}

  @statuses [
    :preflighting,
    :awaiting_scope,
    :ingesting,
    :staging_media,
    :planning_outline,
    :awaiting_outline_approval,
    :planning_lessons,
    :awaiting_lesson_approval,
    :compiling,
    :applying,
    :completed,
    :failed,
    :cancelled
  ]

  @lesson_planning_strategies [:parallel_v1]

  @create_fields [
    :project_id,
    :author_id,
    :target_root_container_resource_id,
    :status,
    :source_url,
    :book_slug,
    :scope_manifest,
    :progress,
    :latest_plan_version,
    :lesson_planning_strategy,
    :lesson_planning_generation,
    :lesson_planning_parallelism,
    :source_schema_version,
    :plan_schema_version,
    :error,
    :result,
    :preflight_snapshot,
    :started_at,
    :finished_at
  ]

  @update_fields [
    :status,
    :scope_manifest,
    :progress,
    :latest_plan_version,
    :lesson_planning_strategy,
    :lesson_planning_generation,
    :lesson_planning_parallelism,
    :source_schema_version,
    :plan_schema_version,
    :outline_approved_by_author_id,
    :outline_approved_at,
    :error,
    :result,
    :preflight_snapshot,
    :started_at,
    :finished_at,
    :failure_count
  ]

  schema "course_import_runs" do
    belongs_to :project, Project
    belongs_to :author, Author
    belongs_to :target_root_container_resource, Resource
    belongs_to :outline_approved_by_author, Author

    has_many :units, Unit, foreign_key: :run_id
    has_many :lessons, through: [:units, :lessons]
    has_many :notifications, Notification, foreign_key: :run_id
    has_many :source_sections, SourceSection, foreign_key: :run_id
    has_many :source_blocks, SourceBlock, foreign_key: :run_id
    has_many :source_assets, SourceAsset, foreign_key: :run_id
    has_many :media, Media, foreign_key: :run_id
    has_many :enrichment_proposals, EnrichmentProposal, foreign_key: :run_id
    has_many :enrichment_research_sets, EnrichmentResearchSet, foreign_key: :run_id
    has_many :simulation_specs, SimulationSpec, foreign_key: :run_id
    has_many :simulation_artifacts, SimulationArtifact, foreign_key: :run_id

    field :status, Ecto.Enum, values: @statuses, default: :preflighting
    field :source_url, :string
    field :book_slug, :string
    field :scope_manifest, :map, default: %{}
    field :progress, :map, default: %{}
    field :latest_plan_version, :integer, default: 0

    field :lesson_planning_strategy, Ecto.Enum,
      values: @lesson_planning_strategies,
      default: :parallel_v1

    field :lesson_planning_generation, :integer, default: 0
    field :lesson_planning_parallelism, :integer, default: 3
    field :source_schema_version, :integer, default: 3
    field :plan_schema_version, :integer, default: 6
    field :error, :map
    field :result, :map
    field :preflight_snapshot, :map
    field :outline_approved_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :failure_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @type status ::
          :preflighting
          | :awaiting_scope
          | :ingesting
          | :staging_media
          | :planning_outline
          | :awaiting_outline_approval
          | :planning_lessons
          | :awaiting_lesson_approval
          | :compiling
          | :applying
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def lesson_planning_strategies, do: @lesson_planning_strategies

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, @create_fields)
    |> validate_required([:project_id, :author_id, :source_url, :book_slug])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:source_url, min: 1)
    |> validate_inclusion(:lesson_planning_strategy, @lesson_planning_strategies)
    |> validate_number(:lesson_planning_generation, greater_than_or_equal_to: 0)
    |> validate_number(:lesson_planning_parallelism,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 8
    )
    |> validate_inclusion(:source_schema_version, [3])
    |> validate_inclusion(:plan_schema_version, [6])
    |> unique_constraint(:target_root_container_resource_id,
      name: :course_import_runs_one_active_per_project
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:target_root_container_resource_id)
    |> check_constraint(:source_schema_version, name: :course_import_runs_schema_versions)
    |> check_constraint(:lesson_planning_strategy,
      name: :course_import_runs_lesson_planning_strategy
    )
    |> check_constraint(:lesson_planning_generation,
      name: :course_import_runs_lesson_planning_generation
    )
    |> check_constraint(:lesson_planning_parallelism,
      name: :course_import_runs_lesson_planning_parallelism
    )
  end

  def update_changeset(run, attrs) do
    run
    |> cast(attrs, @update_fields)
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:latest_plan_version, greater_than_or_equal_to: 0)
    |> validate_inclusion(:lesson_planning_strategy, @lesson_planning_strategies)
    |> validate_number(:lesson_planning_generation, greater_than_or_equal_to: 0)
    |> validate_number(:lesson_planning_parallelism,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 8
    )
    |> validate_inclusion(:source_schema_version, [3])
    |> validate_inclusion(:plan_schema_version, [6])
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:target_root_container_resource_id,
      name: :course_import_runs_one_active_per_project
    )
    |> foreign_key_constraint(:outline_approved_by_author_id)
    |> check_constraint(:status, name: :course_import_runs_valid_status)
    |> check_constraint(:source_schema_version, name: :course_import_runs_schema_versions)
    |> check_constraint(:lesson_planning_strategy,
      name: :course_import_runs_lesson_planning_strategy
    )
    |> check_constraint(:lesson_planning_generation,
      name: :course_import_runs_lesson_planning_generation
    )
    |> check_constraint(:lesson_planning_parallelism,
      name: :course_import_runs_lesson_planning_parallelism
    )
  end
end
