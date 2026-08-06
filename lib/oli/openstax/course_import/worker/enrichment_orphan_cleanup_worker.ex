defmodule Oli.OpenStax.CourseImport.Worker.EnrichmentOrphanCleanupWorker do
  @moduledoc """
  Removes staged simulation bundles that were never approved and have aged
  beyond the author-review retention window.
  """

  use Oban.Worker,
    queue: :course_import_enrichment,
    max_attempts: 3,
    unique: [period: 3_600, fields: [:worker], states: [:available, :executing, :retryable]]

  alias Oli.OpenStax.CourseImport.Enrichment

  @retention_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    case Enrichment.cleanup_all_orphaned_artifacts(cutoff) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
