defmodule Oli.OpenStax.CourseImport.PubSub do
  @moduledoc """
  PubSub helpers for OpenStax import run updates.

  Consumers can subscribe to a run topic and react to lightweight metadata
  changes. The payload intentionally remains small; callers should reload runs
  through authorization-aware context functions for details.
  """

  alias Oli.OpenStax.CourseImport.Run
  alias Phoenix.PubSub

  @pubsub Oli.PubSub

  @spec run_topic(Ecto.UUID.t()) :: String.t()
  def run_topic(run_id), do: "openstax_course_import:run:#{run_id}"

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(run_id), do: PubSub.subscribe(@pubsub, run_topic(run_id))

  @spec broadcast(Run.t()) :: :ok
  def broadcast(%Run{} = run) do
    payload = %{
      run_id: run.id,
      status: run.status,
      project_id: run.project_id,
      author_id: run.author_id,
      target_root_container_resource_id: run.target_root_container_resource_id,
      updated_at: run.updated_at,
      book_slug: run.book_slug
    }

    message = {:openstax_course_import_run_updated, payload}
    PubSub.broadcast(@pubsub, run_topic(run.id), message)
  end
end
