defmodule Oli.OpenStax.CourseImport.Enrichment.Research.Disabled do
  @moduledoc """
  Non-blocking research adapter used when curated research is unavailable.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Research

  @impl true
  def available?, do: false

  @impl true
  def research(_proposal, _opts), do: {:error, :research_unavailable}
end
