defmodule Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.Disabled do
  @moduledoc """
  Fail-closed storage adapter used until a media-bucket provider is configured.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

  @impl true
  def available?, do: false

  @impl true
  def cleanup_available?, do: false

  @impl true
  def stage(_artifact, _bundle, _opts), do: {:error, :artifact_storage_unavailable}

  @impl true
  def prepare(_artifact, _bundle, _opts), do: {:error, :artifact_storage_unavailable}

  @impl true
  def resolve(_artifact, _opts), do: {:error, :artifact_storage_unavailable}

  @impl true
  def discard(_artifact, _opts), do: {:error, :artifact_storage_unavailable}
end
