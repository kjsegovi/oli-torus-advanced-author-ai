defmodule Oli.OpenStax.CourseImport.Media do
  @moduledoc """
  Durable staging state for one source asset and its project media item.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.Authoring.Course.Project
  alias Oli.Authoring.MediaLibrary.MediaItem
  alias Oli.OpenStax.CourseImport.{Run, SourceAsset}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(discovered staging staged reused skipped failed)

  schema "course_import_media" do
    belongs_to :run, Run
    belongs_to :source_asset, SourceAsset
    belongs_to :project, Project, type: :id
    belongs_to :media_item, MediaItem, type: :id

    field :status, :string, default: "discovered"
    field :source_url, :string
    field :final_source_url, :string
    field :media_url, :string
    field :file_name, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :attempts, :integer, default: 0
    field :failure_reason, :map
    field :staged_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(media, attrs) do
    media
    |> cast(attrs, [
      :run_id,
      :source_asset_id,
      :project_id,
      :media_item_id,
      :status,
      :source_url,
      :final_source_url,
      :media_url,
      :file_name,
      :mime_type,
      :byte_size,
      :sha256,
      :attempts,
      :failure_reason,
      :staged_at
    ])
    |> validate_required([:run_id, :source_asset_id, :project_id, :status, :source_url])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> unique_constraint(:source_asset_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:source_asset_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:media_item_id)
    |> check_constraint(:status, name: :course_import_media_status)
    |> check_constraint(:byte_size, name: :course_import_media_sizes)
  end
end
