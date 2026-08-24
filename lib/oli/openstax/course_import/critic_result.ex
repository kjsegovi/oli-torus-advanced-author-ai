defmodule Oli.OpenStax.CourseImport.CriticResult do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_critic_results" do
    field :cache_key, :string
    field :result, :map
    field :last_used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [:cache_key, :result, :last_used_at])
    |> validate_required([:cache_key, :result, :last_used_at])
    |> unique_constraint(:cache_key)
  end
end
