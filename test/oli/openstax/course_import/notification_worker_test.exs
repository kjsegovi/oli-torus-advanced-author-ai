defmodule Oli.OpenStax.CourseImport.NotificationWorkerTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  import Ecto.Query
  import Swoosh.TestAssertions

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Notification, Run}
  alias Oli.OpenStax.CourseImport.Worker.{NotificationDispatchWorker, NotificationWorker}
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture(%{email: "openstax-notifications@example.edu"})

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax notification project")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/notification-book"
      )

    {:ok, author: author, project: project, run: run}
  end

  test "terminal transition creates one durable, deduplicated notification job", %{run: run} do
    assert {:ok, %Run{status: :failed}} = CourseImport.mark_failed(run.id, :preflight, :timeout)

    [notification] = notifications_for(run.id)
    assert notification.event == "import_failed"
    assert notification.enqueued_at

    assert_enqueued(
      worker: NotificationWorker,
      args: %{"notification_id" => notification.id}
    )

    assert {:ok, %Run{status: :failed}} = CourseImport.mark_failed(run.id, :preflight, :timeout)
    assert [same_notification] = notifications_for(run.id)
    assert same_notification.id == notification.id

    assert [job] = all_enqueued(worker: NotificationWorker)
    assert job.args == %{"notification_id" => notification.id}
  end

  test "outbox delivery marks the notification delivered only after sending once", %{
    run: run
  } do
    notification = notification_fixture(run, "outline_ready")

    assert :ok = perform_job(NotificationWorker, %{"notification_id" => notification.id})

    delivered = Repo.get!(Notification, notification.id)
    assert delivered.delivered_at

    assert_email_sent(fn email ->
      email.subject =~ "OpenStax course outline is ready" and
        email.text_body =~ "run_id=#{run.id}" and
        email.headers["Message-ID"] ==
          "<openstax-course-import-#{notification.id}@oli.invalid>"
    end)

    assert :ok = perform_job(NotificationWorker, %{"notification_id" => notification.id})
    assert_no_email_sent()
  end

  test "recoverable review failures create a distinct deduplicated notification", %{run: run} do
    attention_run = %{
      run
      | status: :awaiting_lesson_approval,
        error: %{
          "phase" => "compile",
          "reason" => "invalid lesson",
          "recoverable" => true
        }
    }

    assert :ok = Oli.OpenStax.CourseImport.Outbox.dispatch(attention_run)
    assert :ok = Oli.OpenStax.CourseImport.Outbox.dispatch(attention_run)

    assert [notification] = notifications_for(run.id)
    assert notification.event == "import_needs_attention"
    assert [job] = all_enqueued(worker: NotificationWorker)
    assert job.args == %{"notification_id" => notification.id}
  end

  @tag capture_log: true
  test "missing outbox record returns a retryable worker error" do
    assert {:error, :notification_not_found} =
             perform_job(NotificationWorker, %{"notification_id" => Ecto.UUID.generate()})
  end

  test "dispatcher recovers a durable notification whose delivery job was not enqueued", %{
    run: run
  } do
    notification =
      run
      |> notification_fixture("lesson_plans_ready")
      |> Ecto.Changeset.change(enqueued_at: nil)
      |> Repo.update!()

    assert :ok = perform_job(NotificationDispatchWorker, %{})

    assert Repo.get!(Notification, notification.id).enqueued_at

    assert_enqueued(
      worker: NotificationWorker,
      args: %{"notification_id" => notification.id}
    )

    assert :ok = perform_job(NotificationDispatchWorker, %{})
    assert [_single_job] = all_enqueued(worker: NotificationWorker)
  end

  defp notification_fixture(run, event) do
    now = DateTime.utc_now()

    %Notification{}
    |> Notification.changeset(%{
      run_id: run.id,
      event: event,
      recipient_hash: "test-recipient-hash",
      dedupe_key: "#{run.id}:#{event}:manual",
      enqueued_at: now
    })
    |> Repo.insert!()
  end

  defp notifications_for(run_id) do
    Repo.all(
      from(notification in Notification,
        where: notification.run_id == ^run_id,
        order_by: [asc: notification.inserted_at]
      )
    )
  end
end
