defmodule Oli.OpenStax.CourseImport.SourceBlock do
  @moduledoc """
  An ordered semantic block retained from an OpenStax source section.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.{LessonSource, Run, SourceAsset, SourceSection}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_source_blocks" do
    belongs_to :run, Run
    belongs_to :source_section, SourceSection
    has_many :lesson_sources, LessonSource, foreign_key: :source_block_id
    has_many :assets, SourceAsset, foreign_key: :source_block_id

    field :source_key, :string
    field :order, :integer
    field :heading_path, {:array, :string}, default: []
    field :block_kind, :string
    field :normalized_text, :string
    field :source_locator, :map, default: %{}
    field :token_estimate, :integer, default: 0
    field :content_hash, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(block, attrs) do
    block
    |> cast(attrs, [
      :run_id,
      :source_section_id,
      :source_key,
      :order,
      :heading_path,
      :block_kind,
      :normalized_text,
      :source_locator,
      :token_estimate,
      :content_hash,
      :metadata
    ])
    |> validate_required([
      :run_id,
      :source_section_id,
      :source_key,
      :order,
      :block_kind,
      :normalized_text,
      :content_hash
    ])
    |> validate_number(:order, greater_than: 0)
    |> validate_number(:token_estimate, greater_than_or_equal_to: 0)
    |> validate_length(:content_hash, is: 64)
    |> unique_constraint([:run_id, :source_key])
    |> unique_constraint([:source_section_id, :order])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:source_section_id)
    |> check_constraint(:order, name: :course_import_source_blocks_order)
  end
end
