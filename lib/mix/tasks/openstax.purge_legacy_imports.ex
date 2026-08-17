defmodule Mix.Tasks.Openstax.PurgeLegacyImports do
  use Mix.Task

  @shortdoc "Purges pre-v6 OpenStax imports in development or test"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Oli.OpenStax.CourseImport.LegacyPurge.purge_all() do
      {:ok, summary} ->
        Mix.shell().info(
          "Purged #{summary.runs} legacy OpenStax runs across #{summary.projects} projects; " <>
            "removed #{summary.resources} curriculum resources and #{summary.activities} orphaned activities."
        )

      {:error, reason} ->
        Mix.raise("OpenStax legacy purge failed: #{inspect(reason)}")
    end
  end
end
