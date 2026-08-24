defmodule Oli.OpenStax.CourseImport.AIUsageEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "course_import_ai_usage_events" do
    field :run_id, :binary_id
    field :lesson_id, :binary_id
    field :authoring_mode, :string
    field :role, :string
    field :provider, :string
    field :model, :string
    field :model_snapshot, :string
    field :service_tier, :string
    field :reasoning_effort, :string
    field :candidate_number, :integer, default: 1
    field :request_key, :string
    field :phase, :string
    field :provider_attempt, :integer, default: 1
    field :request_id, :string
    field :request_payload_hash, :string
    field :response_payload, :map
    field :replayed_from_event_id, :binary_id
    field :input_tokens, :integer, default: 0
    field :cached_input_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :reasoning_tokens, :integer, default: 0
    field :estimated_cost_microdollars, :integer, default: 0
    field :pricing_version, :string
    field :outcome, :string
    field :retry_category, :string
    field :finding_fingerprint, :string
    field :cache_status, :string
    field :latency_ms, :integer
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([:role, :pricing_version, :outcome])
    |> validate_number(:candidate_number, greater_than: 0)
    |> validate_number(:provider_attempt, greater_than: 0)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cached_input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cache_write_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:reasoning_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_cost_microdollars, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:lesson_id)
  end
end
