defmodule Oli.OpenStax.CourseImport.Enrichment.Research do
  @moduledoc """
  Provider-neutral boundary for curated enrichment research.

  Implementations return evidence for author review; they never directly place
  or iframe a resource.
  """

  alias Oli.OpenStax.CourseImport.Enrichment.Research.Disabled
  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @type result :: %{
          required(:evidence) => map(),
          optional(:resource_title) => String.t(),
          optional(:resource_url) => String.t(),
          optional(:delivery_mode) => String.t()
        }

  @callback available?() :: boolean()
  @callback research(EnrichmentProposal.t(), keyword()) ::
              {:ok, result()} | {:error, term()}

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    adapter = adapter(opts)
    function_exported?(adapter, :available?, 0) and adapter.available?() == true
  rescue
    _ -> false
  end

  @spec research(EnrichmentProposal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def research(proposal, opts \\ [])

  def research(%EnrichmentProposal{} = proposal, opts) do
    adapter = adapter(opts)

    if available?(Keyword.put(opts, :research, adapter)) and
         function_exported?(adapter, :research, 2) do
      adapter.research(proposal, Keyword.delete(opts, :research))
    else
      {:error, :research_unavailable}
    end
  rescue
    _ -> {:error, :research_failed}
  end

  def research(_, _), do: {:error, :invalid_input}

  defp adapter(opts) do
    Keyword.get(opts, :research) ||
      Application.get_env(:oli, :openstax_enrichment_research, Disabled)
  end
end
