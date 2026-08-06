defmodule Oli.OpenStax.CourseImport.Enrichment.Sandbox do
  @moduledoc """
  Disposable execution boundary for building and validating untrusted bundles.

  Implementations must provide no Torus credentials, no outbound network, a
  bounded lifetime and resources, and complete disposal after each build.
  """

  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.Disabled

  @type validated_bundle :: %{
          required(:files) => %{required(String.t()) => binary()},
          required(:content_hash) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:bundle_manifest) => map(),
          required(:validation_payload) => map(),
          required(:accessibility_metadata) => map(),
          optional(:capi_manifest) => map()
        }

  @callback available?() :: boolean()
  @callback build_and_validate(map(), keyword()) ::
              {:ok, validated_bundle()} | {:error, term()}

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    adapter = adapter(opts)
    function_exported?(adapter, :available?, 0) and adapter.available?() == true
  rescue
    _ -> false
  end

  @spec build_and_validate(map(), keyword()) ::
          {:ok, validated_bundle()} | {:error, term()}
  def build_and_validate(bundle, opts \\ [])

  def build_and_validate(bundle, opts) when is_map(bundle) do
    adapter = adapter(opts)

    if available?(Keyword.put(opts, :sandbox, adapter)) and
         function_exported?(adapter, :build_and_validate, 2) do
      adapter.build_and_validate(bundle, Keyword.delete(opts, :sandbox))
    else
      {:error, :sandbox_unavailable}
    end
  rescue
    _ -> {:error, :sandbox_failed}
  end

  def build_and_validate(_, _), do: {:error, :invalid_input}

  defp adapter(opts) do
    Keyword.get(opts, :sandbox) ||
      Application.get_env(:oli, :openstax_enrichment_sandbox, Disabled)
  end
end
