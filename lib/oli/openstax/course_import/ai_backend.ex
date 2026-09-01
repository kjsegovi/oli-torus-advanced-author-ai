defmodule Oli.OpenStax.CourseImport.AIBackend do
  @moduledoc """
  Resolves the immutable AI transport selected for an OpenStax import run.

  The local Codex option is deliberately development-only and loopback-only.
  It never falls back to an API-backed service configuration.
  """

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}
  alias Oli.OpenStax.CourseImport.Enrichment.Research.CodexWebSearch
  alias Oli.OpenStax.CourseImport.Run

  @default_proxy_url "http://127.0.0.1:4001"
  @default_model "codex-proxy/gpt-5.6-terra"

  @type backend :: :openai_api | :local_codex
  @type configuration_error ::
          {:local_codex_configuration_error, :disabled | :non_loopback_url | :missing_proxy_token}
  @type readiness ::
          %{ready?: true, code: :ready, message: String.t()}
          | %{ready?: false, code: atom(), message: String.t()}

  @spec poc_enabled?() :: boolean()
  def poc_enabled? do
    Application.get_env(:oli, :env) == :dev and
      Application.get_env(:oli, :openstax_codex_poc_enabled, false) == true
  end

  @spec validate_start(backend(), keyword()) :: :ok | {:error, term()}
  def validate_start(backend, opts \\ [])

  def validate_start(:openai_api, _opts), do: :ok

  def validate_start(:local_codex, opts) do
    with true <- poc_enabled?(),
         %{ready?: true} <- readiness(opts) do
      :ok
    else
      false -> {:error, :local_codex_disabled}
      %{code: code} -> {:error, {:local_codex_unavailable, code}}
    end
  end

  def validate_start(_backend, _opts), do: {:error, :invalid_ai_backend}

  @spec readiness(keyword()) :: readiness()
  def readiness(opts \\ []) do
    case runtime_configuration() do
      {:ok, runtime} ->
        request_readiness(runtime, opts)

      {:error, {:local_codex_configuration_error, reason}} ->
        unavailable(reason, configuration_message(reason))
    end
  rescue
    _ -> unavailable(:unreachable, "The Codex bridge is unreachable.")
  end

  @spec planner_options(backend()) :: keyword()
  def planner_options(:local_codex) do
    [
      ai_backend: :local_codex,
      service_config_loader: &runtime_service_config/0
    ]
  end

  def planner_options(_backend), do: [ai_backend: :openai_api]

  @spec service_config(:local_codex) ::
          {:ok, ServiceConfig.t()} | {:error, configuration_error()}
  def service_config(:local_codex), do: runtime_service_config()

  @spec simulation_spec_services(backend()) ::
          {:ok, map() | nil} | {:error, configuration_error()}
  def simulation_spec_services(:local_codex) do
    with {:ok, base} <- runtime_service_config() do
      {:ok, %{designer: base, critic: base}}
    end
  end

  def simulation_spec_services(_backend), do: {:ok, nil}

  @spec generator_options(backend()) ::
          {:ok, keyword()} | {:error, configuration_error()}
  def generator_options(:local_codex) do
    with {:ok, service} <- runtime_service_config() do
      {:ok, [service: service, ai_backend: :local_codex]}
    end
  end

  def generator_options(_backend), do: {:ok, [ai_backend: :openai_api]}

  @spec artifact_critic_options(backend()) ::
          {:ok, keyword()} | {:error, configuration_error()}
  def artifact_critic_options(:local_codex) do
    with {:ok, service} <- runtime_service_config() do
      {:ok, [artifact_critic_service: service, ai_backend: :local_codex]}
    end
  end

  def artifact_critic_options(_backend), do: {:ok, [ai_backend: :openai_api]}

  @spec research_options(backend()) ::
          {:ok, keyword()} | {:error, configuration_error()}
  def research_options(:local_codex) do
    with {:ok, %{proxy_url: url, token: token}} <- runtime_configuration() do
      {:ok,
       [
         research: CodexWebSearch,
         proxy_url: url,
         model: @default_model,
         authorization_headers: authorization_headers(token),
         ai_backend: :local_codex
       ]}
    end
  end

  def research_options(_backend), do: {:ok, [ai_backend: :openai_api]}

  @spec logical_provider(String.t() | nil, atom() | String.t() | nil) :: String.t()
  def logical_provider("codex-proxy/" <> _model, _fallback), do: "codex_cli"
  def logical_provider(_model, fallback) when is_atom(fallback), do: Atom.to_string(fallback)
  def logical_provider(_model, fallback) when is_binary(fallback), do: fallback
  def logical_provider(_model, _fallback), do: "unknown"

  @spec billing_source(String.t() | nil) :: String.t()
  def billing_source("codex-proxy/" <> _model), do: "chatgpt_plan"
  def billing_source(_model), do: "usage_based_api"

  @spec display_name(backend()) :: String.t()
  def display_name(:local_codex), do: "Local Codex (POC)"
  def display_name(_backend), do: "OpenAI API"

  @spec backend(Run.t() | map()) :: backend()
  def backend(%{ai_backend: backend}) when backend in [:openai_api, :local_codex], do: backend
  def backend(_run), do: :openai_api

  @spec proxy_url() :: String.t()
  def proxy_url do
    Application.get_env(:oli, :openstax_codex_proxy_url, @default_proxy_url)
    |> to_string()
    |> String.trim_trailing("/")
  end

  @spec proxy_token() :: String.t() | nil
  def proxy_token do
    case Application.get_env(:oli, :openstax_codex_proxy_token) do
      token when is_binary(token) ->
        case String.trim(token) do
          "" -> nil
          token -> token
        end

      _ ->
        nil
    end
  end

  defp authorization_headers(token), do: [{"Authorization", "Bearer #{token}"}]

  defp runtime_service_config do
    with {:ok, %{proxy_url: url, token: token}} <- runtime_configuration() do
      {:ok, build_service_config(token, url)}
    end
  end

  defp runtime_configuration do
    url = proxy_url()
    token = proxy_token()

    cond do
      not poc_enabled?() -> {:error, configuration_error(:disabled)}
      not loopback_url?(url) -> {:error, configuration_error(:non_loopback_url)}
      is_nil(token) -> {:error, configuration_error(:missing_proxy_token)}
      true -> {:ok, %{proxy_url: url, token: token}}
    end
  end

  defp configuration_error(reason), do: {:local_codex_configuration_error, reason}

  defp configuration_message(:disabled), do: "Local Codex is disabled for this environment."
  defp configuration_message(:non_loopback_url), do: "The Codex bridge must use a loopback URL."

  defp configuration_message(:missing_proxy_token),
    do: "The Codex bridge token is not configured."

  defp build_service_config(token, url) do
    model = %RegisteredModel{
      id: -9_001,
      name: "openstax-local-codex",
      provider: :open_ai,
      model: @default_model,
      url_template: url,
      api_key: token,
      timeout: 30_000,
      recv_timeout: 310_000,
      pool_class: :slow,
      max_concurrent: 1,
      routing_breaker_error_rate_threshold: 0.0,
      routing_breaker_429_threshold: 0.0,
      routing_breaker_latency_p95_ms: 0
    }

    %ServiceConfig{
      id: -9_001,
      name: "openstax-local-codex",
      primary_model: model,
      secondary_model: nil,
      backup_model: nil
    }
  end

  defp request_readiness(runtime, opts) do
    url = runtime.proxy_url <> "/health"
    headers = authorization_headers(runtime.token)

    case Keyword.get(opts, :request_fun) do
      fun when is_function(fun, 2) ->
        normalize_readiness_response(fun.(url, headers))

      fun when is_function(fun, 1) ->
        normalize_readiness_response(fun.(url))

      _ ->
        case Application.get_env(:oli, :openstax_codex_readiness_fun) do
          fun when is_function(fun, 2) ->
            normalize_readiness_response(fun.(url, headers))

          fun when is_function(fun, 1) ->
            normalize_readiness_response(fun.(url))

          _ ->
            http_readiness(url, headers)
        end
    end
  end

  defp http_readiness(url, headers) do
    case HTTPoison.get(url, headers,
           timeout: 2_000,
           recv_timeout: 2_000
         ) do
      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        normalize_readiness_response({:ok, status, body})

      {:error, _reason} ->
        unavailable(:unreachable, "The Codex bridge is unreachable.")
    end
  end

  defp normalize_readiness_response({:ok, 200, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ok" => true, "auth_method" => "chatgpt"}} ->
        %{ready?: true, code: :ready, message: "Codex is ready and authenticated with ChatGPT."}

      {:ok, %{"code" => code}} ->
        unavailable(readiness_code(code), readiness_message(code))

      _ ->
        unavailable(:invalid_response, "The Codex bridge returned an invalid readiness response.")
    end
  end

  defp normalize_readiness_response({:ok, status, body}) when status == 503 do
    code =
      case Jason.decode(body) do
        {:ok, %{"code" => value}} -> readiness_code(value)
        _ -> :not_ready
      end

    unavailable(code, readiness_message(code))
  end

  defp normalize_readiness_response(%{ready?: ready?} = response) when is_boolean(ready?),
    do: response

  defp normalize_readiness_response(_response),
    do: unavailable(:unreachable, "The Codex bridge is unreachable.")

  defp readiness_code(code) when is_atom(code), do: code

  defp readiness_code(code) when is_binary(code) do
    case code do
      "codex_missing" -> :codex_missing
      "not_authenticated" -> :not_authenticated
      "api_key_authenticated" -> :api_key_authenticated
      "login_status_timeout" -> :login_status_timeout
      _ -> :not_ready
    end
  end

  defp readiness_code(_code), do: :not_ready

  defp readiness_message(code) when code in [:codex_missing, "codex_missing"],
    do: "The Codex executable was not found."

  defp readiness_message(code) when code in [:not_authenticated, "not_authenticated"],
    do: "Codex is not authenticated. Run codex login with ChatGPT."

  defp readiness_message(code) when code in [:api_key_authenticated, "api_key_authenticated"],
    do: "Codex is authenticated with an API key; ChatGPT authentication is required."

  defp readiness_message(code) when code in [:login_status_timeout, "login_status_timeout"],
    do: "Codex authentication status timed out."

  defp readiness_message(_code), do: "The Codex bridge is not ready."

  defp unavailable(code, message), do: %{ready?: false, code: code, message: message}

  defp loopback_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost", "::1"] ->
        true

      _ ->
        false
    end
  end
end
