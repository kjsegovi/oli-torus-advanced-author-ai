defmodule Oli.Repo.Migrations.PreventConcurrentSimulationGeneration do
  use Ecto.Migration

  def change do
    create unique_index(
             :course_import_simulation_artifacts,
             [:proposal_id],
             where: "status IN ('generating', 'ready_for_review')",
             name: :course_import_simulation_artifacts_one_active_index
           )
  end
end
