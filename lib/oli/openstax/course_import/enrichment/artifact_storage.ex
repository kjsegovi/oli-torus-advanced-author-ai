defmodule Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage do
  @moduledoc """
  Storage boundary for immutable, content-addressed simulation bundles.

  A provider returns storage identity only. Learner-facing URLs are resolved
  later from an approved artifact so model-authored URLs cannot enter content.
  """

  alias Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.Disabled
  alias Oli.OpenStax.CourseImport.SimulationArtifact

  @type staged_identity :: %{
          required(:storage_provider) => String.t(),
          required(:storage_key) => String.t(),
          required(:storage_origin) => String.t(),
          required(:storage_state) => String.t(),
          required(:byte_size) => non_neg_integer()
        }

  @callback available?() :: boolean()
  @callback cleanup_available?() :: boolean()
  @callback prepare(SimulationArtifact.t(), map(), keyword()) ::
              {:ok, staged_identity()} | {:error, term()}
  @callback stage(SimulationArtifact.t(), map(), keyword()) ::
              {:ok, staged_identity()} | {:error, term()}
  @callback resolve(SimulationArtifact.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback discard(SimulationArtifact.t(), keyword()) :: :ok | {:error, term()}

  @optional_callbacks cleanup_available?: 0

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    adapter = adapter(opts)
    function_exported?(adapter, :available?, 0) and adapter.available?() == true
  rescue
    _ -> false
  end

  @spec stage(SimulationArtifact.t(), map(), keyword()) ::
          {:ok, staged_identity()} | {:error, term()}
  def stage(artifact, bundle, opts \\ [])

  def stage(%SimulationArtifact{} = artifact, bundle, opts) when is_map(bundle) do
    call(:stage, [artifact, bundle], opts)
  end

  def stage(_, _, _), do: {:error, :invalid_input}

  @spec prepare(SimulationArtifact.t(), map(), keyword()) ::
          {:ok, staged_identity()} | {:error, term()}
  def prepare(artifact, bundle, opts \\ [])

  def prepare(%SimulationArtifact{} = artifact, bundle, opts) when is_map(bundle) do
    call(:prepare, [artifact, bundle], opts)
  end

  def prepare(_, _, _), do: {:error, :invalid_input}

  @spec resolve(SimulationArtifact.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(artifact, opts \\ [])

  def resolve(%SimulationArtifact{} = artifact, opts) do
    call(:resolve, [artifact], opts)
  end

  def resolve(_, _), do: {:error, :invalid_input}

  @spec discard(SimulationArtifact.t(), keyword()) :: :ok | {:error, term()}
  def discard(artifact, opts \\ [])

  def discard(%SimulationArtifact{} = artifact, opts) do
    call_cleanup(:discard, [artifact], opts)
  end

  def discard(_, _), do: {:error, :invalid_input}

  defp call(function, args, opts) do
    adapter = adapter(opts)
    arity = length(args) + 1

    if available?(Keyword.put(opts, :artifact_storage, adapter)) and
         function_exported?(adapter, function, arity) do
      apply(adapter, function, args ++ [Keyword.delete(opts, :artifact_storage)])
    else
      {:error, :artifact_storage_unavailable}
    end
  rescue
    _ -> {:error, :artifact_storage_failed}
  end

  defp call_cleanup(function, args, opts) do
    adapter = adapter(opts)
    arity = length(args) + 1

    cleanup_available? =
      if function_exported?(adapter, :cleanup_available?, 0),
        do: adapter.cleanup_available?() == true,
        else: function_exported?(adapter, :available?, 0) and adapter.available?() == true

    if cleanup_available? and function_exported?(adapter, function, arity) do
      apply(adapter, function, args ++ [Keyword.delete(opts, :artifact_storage)])
    else
      {:error, :artifact_storage_unavailable}
    end
  rescue
    _ -> {:error, :artifact_storage_failed}
  end

  defp adapter(opts) do
    Keyword.get(opts, :artifact_storage) ||
      Application.get_env(:oli, :openstax_enrichment_artifact_storage, Disabled)
  end
end
