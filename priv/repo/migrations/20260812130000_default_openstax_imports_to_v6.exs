defmodule Oli.Repo.Migrations.DefaultOpenstaxImportsToV6 do
  use Ecto.Migration

  def up do
    alter table(:course_import_runs) do
      modify :source_schema_version, :integer, null: false, default: 3
      modify :plan_schema_version, :integer, null: false, default: 6
    end
  end

  def down do
    alter table(:course_import_runs) do
      modify :source_schema_version, :integer, null: false, default: 1
      modify :plan_schema_version, :integer, null: false, default: 2
    end
  end
end
