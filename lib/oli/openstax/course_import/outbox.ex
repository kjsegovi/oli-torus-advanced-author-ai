defmodule Oli.OpenStax.CourseImport.Outbox do
  @moduledoc false

  import Ecto.Query

  alias Oli.Accounts.Author
  alias Oli.OpenStax.CourseImport.{Notification, Run}
  alias Oli.OpenStax.CourseImport.Worker.NotificationWorker
  alias Oli.Repo

  @events %{
    awaiting_outline_approval: "outline_ready",
    awaiting_lesson_approval: "lesson_plans_ready",
    completed: "import_completed",
    failed: "import_failed"
  }

  @doc """
  Persists the notification intent in the caller's transaction.

  State transitions call this before commit so a process crash between the
  transition and job dispatch cannot lose the email event. Delivery job
  dispatch remains recoverable through `NotificationDispatchWorker`.
  """
  @spec persist(Run.t()) :: :ok | {:error, term()}
  def persist(%Run{} = run) do
    case event_for_run(run) do
      {:ok, event} -> persist_event(run, event)
      :error -> :ok
    end
  end

  @doc """
  Ensures the durable notification has a delivery job.

  This is intentionally safe to call after every state transition. Both the
  outbox row and the Oban job are deduplicated.
  """
  @spec dispatch(Run.t()) :: :ok | {:error, term()}
  def dispatch(%Run{} = run) do
    case event_for_run(run) do
      {:ok, event} ->
        with :ok <- persist_event(run, event),
             %Notification{} = notification <- get_notification(run, event) do
          enqueue(notification)
        else
          nil -> :ok
          {:error, _} = error -> error
        end

      :error ->
        :ok
    end
  end

  defp persist_event(run, event) do
    case Repo.get(Author, run.author_id) do
      %Author{email: email} when is_binary(email) ->
        case String.trim(email) do
          "" ->
            :ok

          normalized_email ->
            now = DateTime.utc_now()

            attrs = %{
              id: Ecto.UUID.generate(),
              run_id: run.id,
              event: event,
              recipient_hash:
                :crypto.hash(:sha256, String.downcase(normalized_email))
                |> Base.encode16(case: :lower),
              dedupe_key: dedupe_key(run, event),
              inserted_at: now,
              updated_at: now
            }

            case Repo.insert_all(Notification, [attrs],
                   on_conflict: :nothing,
                   conflict_target: [:run_id, :dedupe_key]
                 ) do
              {_count, _rows} -> :ok
            end
        end

      _ ->
        :ok
    end
  rescue
    exception -> {:error, {:notification_outbox_failed, Exception.message(exception)}}
  end

  defp get_notification(run, event) do
    Repo.one(
      from(notification in Notification,
        where:
          notification.run_id == ^run.id and
            notification.dedupe_key == ^dedupe_key(run, event)
      )
    )
  end

  defp enqueue(%Notification{delivered_at: delivered_at}) when not is_nil(delivered_at), do: :ok

  defp enqueue(notification) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      locked =
        Repo.one!(
          from(candidate in Notification,
            where: candidate.id == ^notification.id,
            lock: "FOR UPDATE"
          )
        )

      if locked.delivered_at do
        :ok
      else
        case Oban.insert(NotificationWorker.new(%{"notification_id" => locked.id})) do
          {:ok, _job} ->
            locked
            |> Notification.changeset(%{enqueued_at: now})
            |> Repo.update!()

            :ok

          {:error, reason} ->
            Repo.rollback({:notification_job_enqueue_failed, reason})
        end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_for_run(%Run{
         status: :awaiting_lesson_approval,
         error: %{"recoverable" => true}
       }),
       do: {:ok, "import_needs_attention"}

  defp event_for_run(%Run{status: status}), do: Map.fetch(@events, status)

  defp dedupe_key(%Run{} = run, "import_needs_attention") do
    failure_fingerprint =
      run.error
      |> Map.take(["phase", "reason", "source_media_ids", "lesson_ids"])
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "#{run.id}:import_needs_attention:#{failure_fingerprint}"
  end

  defp dedupe_key(
         %Run{
           id: run_id,
           lesson_planning_generation: generation,
           error: %{"phase" => "lesson_planning"}
         },
         "import_failed"
       ),
       do: "#{run_id}:import_failed:lesson_planning:#{generation}"

  defp dedupe_key(%Run{id: run_id}, event), do: "#{run_id}:#{event}"
end
