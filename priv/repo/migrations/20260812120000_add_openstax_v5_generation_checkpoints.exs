defmodule Oli.Repo.Migrations.AddOpenStaxV5GenerationCheckpoints do
  use Ecto.Migration

  def change do
    alter table(:course_import_lessons) do
      add :generation_checkpoint, :map, null: false, default: %{}
    end
  end
end
