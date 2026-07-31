defmodule Oli.OpenStax.CourseImport.Notification do
  @moduledoc """
  Dedupe record for email notifications emitted by a course import run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Oli.OpenStax.CourseImport.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "course_import_notifications" do
    belongs_to :run, Run

    field :event, :string
    field :recipient_hash, :string
    field :dedupe_key, :string
    field :enqueued_at, :utc_datetime_usec
    field :delivery_claimed_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :run_id,
      :event,
      :recipient_hash,
      :dedupe_key,
      :enqueued_at,
      :delivery_claimed_at,
      :delivered_at
    ])
    |> validate_required([:run_id, :event, :recipient_hash, :dedupe_key])
    |> validate_inclusion(:event, [
      "outline_ready",
      "lesson_plans_ready",
      "import_needs_attention",
      "import_completed",
      "import_failed"
    ])
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :dedupe_key])
  end
end
