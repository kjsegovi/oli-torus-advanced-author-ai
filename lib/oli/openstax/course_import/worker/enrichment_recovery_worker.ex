defmodule Oli.OpenStax.CourseImport.Worker.EnrichmentRecoveryWorker do
  @moduledoc """
  Reconciles provider workflows left non-terminal by a node crash or exhausted
  job before orphan storage cleanup runs.
  """

  use Oban.Worker,
    queue: :course_import_enrichment,
    max_attempts: 3,
    unique: [period: 900, fields: [:worker], states: [:available, :executing, :retryable]]

  alias Oli.OpenStax.CourseImport.Enrichment

  @stale_after_seconds 3_600

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    case Enrichment.reconcile_stale_workflows(cutoff) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
