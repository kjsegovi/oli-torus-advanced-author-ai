defmodule Oli.Repo.Migrations.AddAiBackendToCourseImportRuns do
  use Ecto.Migration

  def change do
    alter table(:course_import_runs) do
      add :ai_backend, :string, null: false, default: "openai_api"
    end

    create constraint(:course_import_runs, :course_import_runs_ai_backend,
             check: "ai_backend IN ('openai_api', 'local_codex')"
           )
  end
end
