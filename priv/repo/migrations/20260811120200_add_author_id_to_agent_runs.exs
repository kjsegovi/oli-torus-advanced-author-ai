defmodule Oli.Repo.Migrations.AddAuthorIdToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :author_id, references(:authors, on_delete: :nilify_all), null: true
    end

    create index(:agent_runs, [:author_id])
  end
end
