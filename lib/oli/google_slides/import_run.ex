defmodule Oli.GoogleSlides.ImportRun do
  @moduledoc """
  Durable state for a single AI-assisted Google Slides lesson import.

  Import runs hold source and draft data until an author approves a lesson plan.
  They do not represent live course content; `result_revision_id` is populated
  only after the deterministic generation workflow succeeds.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleSlides.ImportAnalysisChunk
  alias Oli.Resources.{Resource, Revision}

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses [
    :analyzing,
    :awaiting_structure,
    :awaiting_budget,
    :awaiting_answers,
    :ready_for_review,
    :generating,
    :completed,
    :failed,
    :cancelled
  ]

  @create_fields [
    :project_id,
    :author_id,
    :target_container_resource_id,
    :presentation_url,
    :presentation_id,
    :presentation_revision,
    :presentation_fingerprint,
    :presentation_metadata,
    :source_snapshot,
    :analysis_version,
    :analysis_state,
    :options,
    :analysis_started_at
  ]

  @update_fields [
    :status,
    :presentation_id,
    :presentation_revision,
    :presentation_fingerprint,
    :presentation_metadata,
    :source_snapshot,
    :analysis_version,
    :analysis_state,
    :options,
    :questions,
    :answers,
    :lesson_plan,
    :plan_version,
    :approved_plan_version,
    :approved_by_author_id,
    :approved_at,
    :warnings,
    :validation_results,
    :result,
    :result_revision_id,
    :model_usage,
    :error,
    :analysis_started_at,
    :analysis_completed_at,
    :generation_started_at,
    :finished_at
  ]

  schema "google_slides_import_runs" do
    belongs_to :project, Project
    belongs_to :author, Author
    belongs_to :target_container_resource, Resource
    belongs_to :result_revision, Revision
    belongs_to :approved_by_author, Author
    has_many :analysis_chunks, ImportAnalysisChunk, foreign_key: :run_id

    field :status, Ecto.Enum, values: @statuses, default: :analyzing
    field :presentation_url, :string
    field :presentation_id, :string
    field :presentation_revision, :string
    field :presentation_fingerprint, :string
    field :presentation_metadata, :map
    field :source_snapshot, :map
    field :analysis_version, :integer, default: 1
    field :analysis_state, :map
    field :options, :map, default: %{}
    field :questions, {:array, :map}, default: []
    field :answers, :map, default: %{}
    field :lesson_plan, :map
    field :plan_version, :integer, default: 0
    field :approved_plan_version, :integer
    field :approved_at, :utc_datetime_usec
    field :warnings, {:array, :map}, default: []
    field :validation_results, :map
    field :result, :map
    field :model_usage, :map, default: %{}
    field :error, :map
    field :analysis_started_at, :utc_datetime_usec
    field :analysis_completed_at, :utc_datetime_usec
    field :generation_started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type status ::
          :analyzing
          | :awaiting_structure
          | :awaiting_budget
          | :awaiting_answers
          | :ready_for_review
          | :generating
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, @create_fields)
    |> put_change(:status, :analyzing)
    |> validate_required([
      :project_id,
      :author_id,
      :target_container_resource_id,
      :presentation_url,
      :status,
      :analysis_started_at
    ])
    |> validate_format(:presentation_url, ~r/^https:\/\/docs\.google\.com\/presentation\//,
      message: "must be a Google Slides presentation URL"
    )
    |> validate_number(:plan_version, greater_than_or_equal_to: 0)
    |> validate_number(:analysis_version, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:target_container_resource_id)
    |> unique_constraint(:target_container_resource_id,
      name: :google_slides_import_runs_one_active_per_target,
      message: "already has an active Google Slides import"
    )
  end

  @doc false
  def update_changeset(run, attrs) do
    run
    |> cast(attrs, @update_fields)
    |> validate_required([:status, :plan_version, :analysis_version])
    |> validate_number(:plan_version, greater_than_or_equal_to: 0)
    |> validate_number(:analysis_version, greater_than_or_equal_to: 1)
    |> validate_approved_version()
    |> validate_approval_complete()
    |> foreign_key_constraint(:result_revision_id)
    |> foreign_key_constraint(:approved_by_author_id)
    |> unique_constraint(:target_container_resource_id,
      name: :google_slides_import_runs_one_active_per_target,
      message: "already has an active Google Slides import"
    )
    |> check_constraint(:status, name: :google_slides_import_runs_valid_status)
    |> check_constraint(:plan_version, name: :google_slides_import_runs_valid_plan_version)
    |> check_constraint(:approved_plan_version,
      name: :google_slides_import_runs_complete_approval
    )
  end

  def statuses, do: @statuses

  defp validate_approved_version(changeset) do
    plan_version = get_field(changeset, :plan_version)
    approved_plan_version = get_field(changeset, :approved_plan_version)

    if approved_plan_version && approved_plan_version > plan_version do
      add_error(changeset, :approved_plan_version, "cannot exceed plan version")
    else
      changeset
    end
  end

  defp validate_approval_complete(changeset) do
    approval_fields = [
      get_field(changeset, :approved_plan_version),
      get_field(changeset, :approved_by_author_id),
      get_field(changeset, :approved_at)
    ]

    if Enum.all?(approval_fields, &is_nil/1) or Enum.all?(approval_fields, &(not is_nil(&1))) do
      changeset
    else
      add_error(
        changeset,
        :approved_plan_version,
        "must be recorded together with approving author and approval time"
      )
    end
  end
end
