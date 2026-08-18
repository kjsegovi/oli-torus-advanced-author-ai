defmodule Oli.OpenStax.CourseImport.Enrichment.Generator do
  @moduledoc """
  Provider-neutral boundary for producing dependency-free simulation source.

  Generated source is untrusted. A successful result must still pass through
  `Oli.OpenStax.CourseImport.Enrichment.Sandbox` before it may be staged. A
  bundle that declares CAPI inputs or outputs must use the exact synchronous
  `<script src="torus-capi-bridge.js"></script>` tag as its first script; the
  sandbox supplies that system-owned file after validating the typed manifest.
  """

  alias Oli.OpenStax.CourseImport.Enrichment.Generator.Disabled
  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @type bundle :: %{
          required(:files) => %{required(String.t()) => binary()},
          required(:manifest) => map(),
          optional(:capi_manifest) => map(),
          optional(:metadata) => map()
        }

  @callback available?() :: boolean()
  @callback runtime_profile() :: :audited_static | :untrusted_generated
  @callback generate(EnrichmentProposal.t(), keyword()) ::
              {:ok, bundle()} | {:error, term()}

  @optional_callbacks runtime_profile: 0

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    adapter = adapter(opts)

    function_exported?(adapter, :available?, 0) and adapter.available?() == true and
      generation_profile_supported?(adapter)
  rescue
    _ -> false
  end

  @doc "Returns whether an adapter declares a supported generation trust profile."
  @spec runtime_safe?(module()) :: boolean()
  def runtime_safe?(adapter), do: generation_profile_supported?(adapter)

  defp generation_profile_supported?(adapter) when is_atom(adapter) do
    function_exported?(adapter, :runtime_profile, 0) and
      adapter.runtime_profile() in [:audited_static, :untrusted_generated]
  rescue
    _ -> false
  end

  defp generation_profile_supported?(_adapter), do: false

  @spec generate(EnrichmentProposal.t(), keyword()) :: {:ok, bundle()} | {:error, term()}
  def generate(proposal, opts \\ [])

  def generate(%EnrichmentProposal{} = proposal, opts) do
    adapter = adapter(opts)

    if available?(Keyword.put(opts, :generator, adapter)) and
         function_exported?(adapter, :generate, 2) do
      adapter.generate(proposal, Keyword.delete(opts, :generator))
    else
      {:error, :generator_unavailable}
    end
  rescue
    _ -> {:error, :generator_failed}
  end

  def generate(_, _), do: {:error, :invalid_input}

  defp adapter(opts) do
    Keyword.get(opts, :generator) ||
      Application.get_env(:oli, :openstax_enrichment_generator, Disabled)
  end
end
