defmodule Oli.Repo.Migrations.AddCourseImportLessonSourceObjectives do
  use Ecto.Migration

  def change do
    alter table(:course_import_lessons) do
      add :source_objectives, {:array, :text}, null: false, default: []
    end
  end
end
