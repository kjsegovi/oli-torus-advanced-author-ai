defmodule Oli.Repo.Migrations.AddCourseImportNotificationEnqueuedAt do
  use Ecto.Migration

  def change do
    alter table(:course_import_notifications) do
      add :enqueued_at, :utc_datetime_usec
    end
  end
end
