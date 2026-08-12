defmodule Oli.Repo.Migrations.AddGenerationMetadataToCourseImportLessonPlans do
  use Ecto.Migration

  def change do
    alter table(:course_import_lesson_plans) do
      add :generation_metadata, :map, null: false, default: %{}
    end
  end
end
