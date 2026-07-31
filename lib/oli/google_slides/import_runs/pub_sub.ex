defmodule Oli.GoogleSlides.ImportRuns.PubSub do
  @moduledoc """
  PubSub topics and lifecycle notifications for Google Slides import runs.

  Events intentionally contain only lightweight run metadata. Consumers should
  reload the authorized run before rendering source snapshots or lesson plans.
  """

  alias Oli.GoogleSlides.ImportRun
  alias Phoenix.PubSub

  @pubsub Oli.PubSub

  @spec run_topic(Ecto.UUID.t()) :: String.t()
  def run_topic(run_id), do: "google_slides_import:run:#{run_id}"

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(run_id), do: PubSub.subscribe(@pubsub, run_topic(run_id))

  @spec broadcast(ImportRun.t()) :: :ok
  def broadcast(%ImportRun{} = run) do
    payload = %{
      run_id: run.id,
      project_id: run.project_id,
      author_id: run.author_id,
      target_container_resource_id: run.target_container_resource_id,
      status: run.status,
      plan_version: run.plan_version,
      approved_plan_version: run.approved_plan_version,
      result_revision_id: run.result_revision_id,
      updated_at: run.updated_at
    }

    message = {:google_slides_import_run_updated, payload}

    PubSub.broadcast(@pubsub, run_topic(run.id), message)
  end
end
