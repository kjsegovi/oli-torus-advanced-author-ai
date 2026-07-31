defmodule Oli.Repo.Migrations.HardenCourseImportNotifications do
  use Ecto.Migration

  def up do
    alter table(:course_import_notifications) do
      add :delivery_claimed_at, :utc_datetime_usec
    end

    drop constraint(:course_import_notifications, :course_import_notifications_event)

    create constraint(:course_import_notifications, :course_import_notifications_event,
             check:
               "event IN ('outline_ready', 'lesson_plans_ready', 'import_needs_attention', 'import_completed', 'import_failed')"
           )

    create index(:course_import_notifications, [:delivery_claimed_at],
             where: "delivered_at IS NULL"
           )
  end

  def down do
    drop index(:course_import_notifications, [:delivery_claimed_at],
           where: "delivered_at IS NULL"
         )

    drop constraint(:course_import_notifications, :course_import_notifications_event)

    execute("""
    DELETE FROM course_import_notifications
    WHERE event = 'import_needs_attention'
    """)

    create constraint(:course_import_notifications, :course_import_notifications_event,
             check:
               "event IN ('outline_ready', 'lesson_plans_ready', 'import_completed', 'import_failed')"
           )

    alter table(:course_import_notifications) do
      remove :delivery_claimed_at
    end
  end
end
