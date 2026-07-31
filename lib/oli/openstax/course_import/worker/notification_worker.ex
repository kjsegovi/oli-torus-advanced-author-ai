defmodule Oli.OpenStax.CourseImport.Worker.NotificationWorker do
  @moduledoc """
  Durable outbox worker for course-import email notifications.

  A short database transaction leases the outbox row, then the mail adapter
  runs without holding a database connection or row lock. A deterministic
  Message-ID gives providers a stable key across crash retries. Delivery is
  intentionally at-least-once: a process crash after provider acceptance but
  before the durable `delivered_at` write can produce a duplicate rather than
  silently lose a completion or failure notification.
  """

  use Oban.Worker,
    queue: :course_import,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.Mailer
  alias Oli.OpenStax.CourseImport.{Notification, Run}
  alias Oli.Repo

  @claim_ttl_seconds 120

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    case claim_delivery(notification_id) do
      {:ok, :already_delivered} ->
        :ok

      {:ok, delivery} ->
        deliver(delivery)

      {:error, reason} ->
        Logger.warning(
          "OpenStax course import notification #{notification_id} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp claim_delivery(notification_id) do
    Repo.transaction(fn ->
      notification =
        Repo.one(
          from(notification in Notification,
            where: notification.id == ^notification_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:notification_not_found)

      cond do
        notification.delivered_at ->
          :already_delivered

        active_claim?(notification.delivery_claimed_at) ->
          Repo.rollback(:notification_delivery_in_progress)

        true ->
          claimed_at = DateTime.utc_now()

          notification
          |> Notification.changeset(%{delivery_claimed_at: claimed_at})
          |> Repo.update!()

          build_delivery(notification)
      end
    end)
  end

  defp build_delivery(notification) do
    run = Repo.get(Run, notification.run_id) || Repo.rollback(:run_not_found)
    author = Repo.get(Author, run.author_id) || Repo.rollback(:author_not_found)
    project = Repo.get(Project, run.project_id) || Repo.rollback(:project_not_found)

    if not is_binary(author.email) or String.trim(author.email) == "" do
      Repo.rollback(:recipient_unavailable)
    end

    resume_url =
      OliWeb.Endpoint.url() <>
        "/workspaces/course_author/#{project.slug}/curriculum/import/openstax?run_id=#{run.id}"

    email_body =
      [
        notification_message(notification.event, run),
        "",
        "Resume or review this import:",
        resume_url
      ]
      |> Enum.join("\n")

    email =
      Oli.Email.create_text_email(
        author.email,
        notification_subject(notification.event, run.book_slug),
        email_body
      )
      |> Swoosh.Email.header("Message-ID", message_id(notification.id))

    %{email: email, notification_id: notification.id}
  end

  defp deliver(%{email: email, notification_id: notification_id}) do
    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        now = DateTime.utc_now()

        Repo.update_all(
          from(notification in Notification,
            where: notification.id == ^notification_id and is_nil(notification.delivered_at)
          ),
          set: [delivered_at: now, delivery_claimed_at: nil, updated_at: now]
        )

        :ok

      {:error, reason} ->
        release_claim(notification_id)
        {:error, {:mail_delivery_failed, reason}}
    end
  rescue
    exception ->
      release_claim(notification_id)
      reraise exception, __STACKTRACE__
  end

  defp active_claim?(nil), do: false

  defp active_claim?(claimed_at) do
    DateTime.compare(
      claimed_at,
      DateTime.add(DateTime.utc_now(), -@claim_ttl_seconds, :second)
    ) == :gt
  end

  defp release_claim(notification_id) do
    Repo.update_all(
      from(notification in Notification,
        where: notification.id == ^notification_id and is_nil(notification.delivered_at)
      ),
      set: [delivery_claimed_at: nil, updated_at: DateTime.utc_now()]
    )
  end

  defp message_id(notification_id),
    do: "<openstax-course-import-#{notification_id}@oli.invalid>"

  defp notification_subject("outline_ready", slug),
    do: "Your OpenStax course outline is ready (#{slug})"

  defp notification_subject("lesson_plans_ready", slug),
    do: "Your OpenStax lesson plans are ready (#{slug})"

  defp notification_subject("import_needs_attention", slug),
    do: "Your OpenStax course import needs review (#{slug})"

  defp notification_subject("import_completed", slug),
    do: "Your OpenStax course import is complete (#{slug})"

  defp notification_subject("import_failed", slug),
    do: "Your OpenStax course import needs attention (#{slug})"

  defp notification_message("outline_ready", _run),
    do: "The unit and lesson outline is ready for your review."

  defp notification_message("lesson_plans_ready", _run),
    do: "The lesson plans, questions, and quality checks are ready for your approval."

  defp notification_message("import_needs_attention", run),
    do:
      "The import needs another review: #{get_in(run.error || %{}, ["message"]) || "A recoverable validation issue occurred."}"

  defp notification_message("import_completed", _run),
    do: "The approved course was created successfully."

  defp notification_message("import_failed", run),
    do: "The import stopped: #{get_in(run.error || %{}, ["message"]) || "Unknown error"}"

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)
end
