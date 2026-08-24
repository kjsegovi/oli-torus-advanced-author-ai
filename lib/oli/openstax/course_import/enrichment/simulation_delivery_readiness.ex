defmodule Oli.OpenStax.CourseImport.Enrichment.SimulationDeliveryReadiness do
  @moduledoc """
  Caches an end-to-end readiness check for generated-simulation delivery.

  The probe traverses the public iframe origin and validates both a known body
  and the authoritative simulation response headers.
  """

  use GenServer

  require Logger

  alias Oli.HTTP
  alias Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.S3Media

  @readiness_body "<!doctype html><title>Torus simulation delivery ready</title>\n"
  @readiness_hash @readiness_body
                  |> then(&:crypto.hash(:sha256, &1))
                  |> Base.encode16(case: :lower)
  @readiness_key "generated-simulations/storage-v2/readiness/sha256/#{@readiness_hash}/index.html"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ready?() :: boolean()
  def ready? do
    if required?() do
      GenServer.call(__MODULE__, :ready?, 1_000)
    else
      true
    end
  catch
    :exit, _reason -> false
  end

  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  catch
    :exit, _reason -> :ok
  end

  def readiness_body, do: @readiness_body
  def readiness_key, do: @readiness_key
  def readiness_hash, do: @readiness_hash

  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts \\ []) do
    origin = Keyword.get(opts, :origin, configured_origin())
    fetch = Keyword.get(opts, :fetch, &fetch/1)
    parent_origins = Keyword.get(opts, :parent_origins, configured_parent_origins())

    with true <- is_binary(origin) and String.trim(origin) != "",
         url <- String.trim_trailing(origin, "/") <> "/" <> @readiness_key,
         {:ok, response} <- fetch.(url),
         :ok <- validate_response(response, parent_origins) do
      :ok
    else
      false -> {:error, :simulation_origin_missing}
      {:error, _} = error -> error
      _ -> {:error, :simulation_readiness_invalid}
    end
  end

  defp validate_response(%{status_code: status}, _parent_origins) when status != 200,
    do: {:error, {:simulation_readiness_http_status, status}}

  defp validate_response(%{status_code: 200, body: body}, _parent_origins)
       when body != @readiness_body,
       do: {:error, :simulation_readiness_body_invalid}

  defp validate_response(%{status_code: 200, headers: headers}, parent_origins),
    do: S3Media.validate_response_headers(headers, parent_origins: parent_origins)

  defp validate_response(_response, _parent_origins),
    do: {:error, :simulation_readiness_invalid}

  @impl true
  def init(opts) do
    state = %{
      ready?: not required?(),
      last_error: nil,
      interval_ms: Keyword.get(opts, :interval_ms, configured_interval_ms()),
      fetch: Keyword.get(opts, :fetch)
    }

    {:ok, state, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state), do: check_and_schedule(state)

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl true
  def handle_cast(:refresh, state), do: check_and_schedule(state)

  @impl true
  def handle_info(:probe, state), do: check_and_schedule(state)

  defp check_and_schedule(state) do
    opts = if is_function(state.fetch, 1), do: [fetch: state.fetch], else: []
    result = if required?(), do: probe(opts), else: :ok
    ready? = result == :ok

    if ready? != state.ready? do
      log_transition(ready?, result)
    end

    Process.send_after(self(), :probe, state.interval_ms)
    {:noreply, %{state | ready?: ready?, last_error: error_reason(result)}}
  end

  defp fetch(url) do
    case HTTP.http().get(url, [],
           follow_redirect: false,
           timeout: 5_000,
           recv_timeout: 5_000
         ) do
      {:ok, response} ->
        {:ok,
         %{
           status_code: response.status_code,
           headers: response.headers,
           body: response.body
         }}

      {:error, reason} ->
        {:error, {:simulation_readiness_request_failed, reason}}
    end
  end

  defp log_transition(true, _result),
    do: Logger.info("Generated simulation delivery is ready")

  defp log_transition(false, result),
    do: Logger.warning("Generated simulation delivery is unavailable: #{inspect(result)}")

  defp error_reason(:ok), do: nil
  defp error_reason({:error, reason}), do: reason

  defp required? do
    Application.get_env(:oli, :openstax_generated_simulation_readiness_required, false) == true
  end

  defp configured_origin,
    do: Application.get_env(:oli, :openstax_generated_simulation_origin)

  defp configured_parent_origins do
    Application.get_env(:oli, :openstax_generated_simulation_frame_ancestors, [])
  end

  defp configured_interval_ms do
    Application.get_env(:oli, :openstax_generated_simulation_readiness_interval_ms, 30_000)
  end
end
