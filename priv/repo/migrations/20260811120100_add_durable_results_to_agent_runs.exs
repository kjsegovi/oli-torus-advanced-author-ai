defmodule Oli.Repo.Migrations.AddDurableResultsToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :terminal_status, :string
      add :terminal_reason, :text
      add :metadata, :map, null: false, default: %{}
    end
  end
end
