defmodule Oli.OpenStax.CourseImport.SourceAsset do
  @moduledoc """
  A remote media reference discovered in an OpenStax semantic source block.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.{Media, Run, SourceBlock, SourceSection}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(discovered staging staged reused skipped failed)

  schema "course_import_source_assets" do
    belongs_to :run, Run
    belongs_to :source_section, SourceSection
    belongs_to :source_block, SourceBlock
    has_one :media, Media, foreign_key: :source_asset_id

    field :source_key, :string
    field :order, :integer
    field :asset_type, :string, default: "image"
    field :source_url, :string
    field :alt_text, :string
    field :caption, :string
    field :declared_mime_type, :string
    field :source_locator, :map, default: %{}
    field :status, :string, default: "discovered"
    field :required, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :run_id,
      :source_section_id,
      :source_block_id,
      :source_key,
      :order,
      :asset_type,
      :source_url,
      :alt_text,
      :caption,
      :declared_mime_type,
      :source_locator,
      :status,
      :required,
      :metadata
    ])
    |> validate_required([
      :run_id,
      :source_section_id,
      :source_key,
      :order,
      :asset_type,
      :source_url,
      :status
    ])
    |> validate_number(:order, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:run_id, :source_key])
    |> unique_constraint([:source_section_id, :order])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:source_section_id)
    |> foreign_key_constraint(:source_block_id)
    |> check_constraint(:order, name: :course_import_source_assets_order)
    |> check_constraint(:status, name: :course_import_source_assets_status)
  end
end
