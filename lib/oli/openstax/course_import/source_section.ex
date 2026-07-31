defmodule Oli.OpenStax.CourseImport.SourceSection do
  @moduledoc """
  Durable metadata for one canonical OpenStax section in an import run.

  Learner-facing source text is stored in ordered `SourceBlock` rows rather
  than on the run checkpoint, keeping status polling bounded.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.{Run, SourceAsset, SourceBlock}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_source_sections" do
    belongs_to :run, Run
    has_many :blocks, SourceBlock, foreign_key: :source_section_id
    has_many :assets, SourceAsset, foreign_key: :source_section_id

    field :canonical_url, :string
    field :section_slug, :string
    field :title, :string
    field :order, :integer
    field :chapter_id, :string
    field :chapter_order, :integer
    field :section_order, :integer
    field :learning_objectives, {:array, :string}, default: []
    field :normalized_word_count, :integer, default: 0
    field :content_hash, :string
    field :retrieved_at, :utc_datetime_usec
    field :attribution_payload, :map, default: %{}
    field :source_coverage, :map, default: %{}
    field :source_metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(section, attrs) do
    section
    |> cast(attrs, [
      :run_id,
      :canonical_url,
      :section_slug,
      :title,
      :order,
      :chapter_id,
      :chapter_order,
      :section_order,
      :learning_objectives,
      :normalized_word_count,
      :content_hash,
      :retrieved_at,
      :attribution_payload,
      :source_coverage,
      :source_metadata
    ])
    |> validate_required([:run_id, :canonical_url, :title, :order, :content_hash])
    |> validate_number(:order, greater_than: 0)
    |> validate_number(:normalized_word_count, greater_than_or_equal_to: 0)
    |> validate_length(:content_hash, is: 64)
    |> unique_constraint([:run_id, :canonical_url])
    |> unique_constraint([:run_id, :order])
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:order, name: :course_import_source_sections_order)
  end
end
