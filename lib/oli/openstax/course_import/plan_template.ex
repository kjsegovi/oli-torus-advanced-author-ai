defmodule Oli.OpenStax.CourseImport.PlanTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "course_import_plan_templates" do
    field :cache_key, :string
    field :source_hash, :string
    field :authoring_mode, :string
    field :source_schema_version, :integer
    field :plan_schema_version, :integer
    field :content_schema_version, :integer
    field :prompt_bundle_hash, :string
    field :quality_policy_version, :string
    field :feature_policy_hash, :string
    field :model_bundle_hash, :string
    field :content_payload, :map
    field :questions_payload, :map, default: %{}
    field :generation_metadata, :map, default: %{}
    field :source_media_bindings, {:array, :map}, default: []
    field :approved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :cache_key,
      :source_hash,
      :authoring_mode,
      :source_schema_version,
      :plan_schema_version,
      :content_schema_version,
      :prompt_bundle_hash,
      :quality_policy_version,
      :feature_policy_hash,
      :model_bundle_hash,
      :content_payload,
      :questions_payload,
      :generation_metadata,
      :source_media_bindings,
      :approved_at
    ])
    |> validate_required([
      :cache_key,
      :source_hash,
      :authoring_mode,
      :source_schema_version,
      :plan_schema_version,
      :content_schema_version,
      :prompt_bundle_hash,
      :quality_policy_version,
      :feature_policy_hash,
      :model_bundle_hash,
      :content_payload,
      :approved_at
    ])
    |> unique_constraint(:cache_key)
  end
end
