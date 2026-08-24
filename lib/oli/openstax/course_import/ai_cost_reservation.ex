defmodule Oli.OpenStax.CourseImport.AICostReservation do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_ai_cost_reservations" do
    field :run_id, :binary_id
    field :lesson_id, :binary_id
    field :request_key, :string
    field :role, :string
    field :model, :string
    field :service_tier, :string
    field :reserved_microdollars, :integer
    field :actual_microdollars, :integer, default: 0
    field :status, :string, default: "reserved"
    field :metadata, :map, default: %{}
    field :settled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([
      :run_id,
      :request_key,
      :role,
      :model,
      :service_tier,
      :reserved_microdollars,
      :status
    ])
    |> validate_inclusion(:status, ["reserved", "settled", "released"])
    |> validate_number(:reserved_microdollars, greater_than_or_equal_to: 0)
    |> validate_number(:actual_microdollars, greater_than_or_equal_to: 0)
    |> unique_constraint(:request_key)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
    |> check_constraint(:status, name: :ai_cost_reservation_status)
  end
end
