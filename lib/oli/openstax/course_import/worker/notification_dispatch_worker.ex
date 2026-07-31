defmodule Oli.OpenStax.CourseImport.Worker.NotificationDispatchWorker do
  @moduledoc """
  Recovers undelivered course-import outbox rows whose delivery job was never
  enqueued or is stale after a discarded/crashed job.
  """

  use Oban.Worker,
    queue: :course_import,
    max_attempts: 3,
    unique: [
      period: 240,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Oli.OpenStax.CourseImport.Notification
  alias Oli.OpenStax.CourseImport.Worker.NotificationWorker
  alias Oli.Repo

  @batch_size 100
  @stale_after_minutes 10

  @impl Oban.Worker
  def perform(_job) do
    stale_before = DateTime.add(DateTime.utc_now(), -@stale_after_minutes, :minute)

    Repo.transaction(fn ->
      from(notification in Notification,
        where:
          is_nil(notification.delivered_at) and
            (is_nil(notification.enqueued_at) or notification.enqueued_at < ^stale_before),
        order_by: [asc: notification.inserted_at],
        limit: @batch_size,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()
      |> Enum.each(&enqueue!/1)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue!(notification) do
    case Oban.insert(NotificationWorker.new(%{"notification_id" => notification.id})) do
      {:ok, _job} ->
        notification
        |> Notification.changeset(%{enqueued_at: DateTime.utc_now()})
        |> Repo.update!()

      {:error, reason} ->
        Repo.rollback({:notification_job_enqueue_failed, notification.id, reason})
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 15)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
