defmodule Oli.OpenStax.CourseImport.Enrichment.Sandbox.Disabled do
  @moduledoc """
  Fail-closed sandbox used when no isolated container runtime is configured.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Sandbox

  @impl true
  def available?, do: false

  @impl true
  def build_and_validate(_bundle, _opts), do: {:error, :sandbox_unavailable}
end
