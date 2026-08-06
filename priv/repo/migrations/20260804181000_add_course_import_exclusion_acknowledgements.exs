defmodule Oli.Repo.Migrations.AddCourseImportExclusionAcknowledgements do
  use Ecto.Migration

  def change do
    alter table(:course_import_lesson_plans) do
      add :exclusion_acknowledgements, {:array, :map}, null: false, default: []
    end
  end
end
