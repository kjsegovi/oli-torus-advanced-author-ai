defmodule Oli.OpenStax.CourseImport.Enrichment.Generator.Disabled do
  @moduledoc """
  Fail-closed generator used when isolated generation has not been configured.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Generator

  @impl true
  def available?, do: false

  @impl true
  def runtime_profile, do: :untrusted_generated

  @impl true
  def generate(_proposal, _opts), do: {:error, :generator_unavailable}
end
