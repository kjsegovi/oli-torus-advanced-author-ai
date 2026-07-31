defmodule Oli.GoogleSlides.GenAI do
  @moduledoc """
  Shared GenAI access for the Google Slides import pipeline.

  Model resolution order:

  1. Global `FeatureConfig` for `:google_slides_import`
  2. `ServiceConfig` named `"google_slides_import"`
  3. Ephemeral model built from `OPENAI_API_KEY` in the environment
  4. Default seeded `ServiceConfig` named `"standard-no-backup"`

  Arbitrary persisted models are never selected: course material must only be
  sent through an explicitly named/assigned route or the documented
  environment fallback.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Oli.GenAI.Completions
  alias Oli.GenAI.Completions.{Message, RegisteredModel, ServiceConfig}
  alias Oli.GenAI.FeatureConfig
  alias Oli.Repo

  @service_name "google_slides_import"
  @fallback_service_name "standard-no-backup"
  @default_openai_url "https://api.openai.com"
  @default_openai_model "gpt-4o-mini"
  @default_openai_recv_timeout 120_000

  @spec configured?() :: boolean()
  def configured? do
    case resolve_service_config() do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Resolves the routing configuration used by the durable import planner.

  Persisted service configurations retain their primary, secondary, and backup
  routing policy. Legacy model-only and environment fallbacks are wrapped in a
  synthetic primary-only configuration so they still pass through the common
  GenAI execution boundary.
  """
  @spec resolve_service_config() :: {:ok, ServiceConfig.t()} | {:error, :not_configured}
  def resolve_service_config do
    with {:error, :not_configured} <- feature_service_config(),
         {:error, :not_configured} <- named_service_config(@service_name),
         {:error, :not_configured} <- env_openai_model(),
         {:error, :not_configured} <- named_service_config(@fallback_service_name) do
      {:error, :not_configured}
    else
      {:ok, %ServiceConfig{} = service_config} ->
        ensure_tool_capable(service_config)

      {:ok, %RegisteredModel{} = model} ->
        {:ok, synthetic_service_config(model)}
    end
  end

  defp feature_service_config do
    case FeatureConfig.load_for(nil, :google_slides_import) do
      {:ok,
       %ServiceConfig{
         primary_model: %RegisteredModel{provider: provider}
       } = service_config}
      when provider == :open_ai ->
        {:ok, service_config}

      _ ->
        {:error, :not_configured}
    end
  rescue
    _ -> {:error, :not_configured}
  end

  @spec resolve_model() :: {:ok, RegisteredModel.t()} | {:error, :not_configured}
  def resolve_model do
    case resolve_service_config() do
      {:ok, %ServiceConfig{primary_model: %RegisteredModel{} = model}} -> {:ok, model}
      _ -> {:error, :not_configured}
    end
  end

  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    with {:ok, model} <- resolve_model() do
      messages =
        case Keyword.get(opts, :system) do
          nil -> [Message.new(:user, prompt)]
          system -> [Message.new(:system, system), Message.new(:user, prompt)]
        end

      case Completions.generate(messages, [], model) do
        {:ok, %{content: content}} when is_binary(content) ->
          {:ok, content}

        other ->
          Logger.debug("Google Slides GenAI completion failed: #{inspect(other)}")
          {:error, other}
      end
    end
  end

  @spec strip_code_fence(String.t()) :: String.t()
  def strip_code_fence(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/```\s*$/, "")
    |> String.trim()
  end

  defp named_service_config(name) do
    case Repo.get_by(ServiceConfig, name: name)
         |> Repo.preload([:primary_model, :secondary_model, :backup_model]) do
      %ServiceConfig{
        primary_model: %RegisteredModel{provider: provider}
      } = service_config
      when provider == :open_ai ->
        {:ok, service_config}

      _ ->
        {:error, :not_configured}
    end
  rescue
    _ -> {:error, :not_configured}
  end

  defp ensure_tool_capable(%ServiceConfig{} = service_config) do
    models = [
      service_config.primary_model,
      service_config.secondary_model,
      service_config.backup_model
    ]

    if Enum.all?(models, fn
         nil -> true
         %RegisteredModel{provider: :open_ai} -> true
         _ -> false
       end) do
      {:ok, service_config}
    else
      {:error, :not_configured}
    end
  end

  defp ensure_tool_capable(_service_config), do: {:error, :not_configured}

  defp synthetic_service_config(%RegisteredModel{} = model) do
    model =
      if is_nil(model.id) do
        %{model | id: -1}
      else
        model
      end

    %ServiceConfig{
      id: -1,
      name: "google-slides-import-fallback",
      primary_model: model,
      secondary_model: nil,
      backup_model: nil
    }
  end

  defp env_openai_model do
    case System.get_env("OPENAI_API_KEY") |> blank_to_nil() do
      nil ->
        {:error, :not_configured}

      api_key ->
        {:ok,
         %RegisteredModel{
           name: "google-slides-import-env",
           provider: :open_ai,
           model: openai_model_name(),
           url_template: System.get_env("OPENAI_API_URL") || @default_openai_url,
           api_key: api_key,
           secondary_api_key: System.get_env("OPENAI_ORG_KEY"),
           timeout:
             env_integer(
               "GOOGLE_SLIDES_IMPORT_OPENAI_TIMEOUT",
               env_integer("OPENAI_TIMEOUT", 8_000)
             ),
           recv_timeout:
             env_integer(
               "GOOGLE_SLIDES_IMPORT_OPENAI_RECV_TIMEOUT",
               env_integer("OPENAI_RECV_TIMEOUT", @default_openai_recv_timeout)
             ),
           pool_class: :slow,
           # This synthetic route has no secondary or backup model. Opening its
           # breaker after one transient error only prevents Oban from making
           # the remaining attempts and replaces the provider error with
           # :all_breakers_open. The durable import worker owns retries for this
           # fallback; configured multi-model routes retain their breaker policy.
           routing_breaker_error_rate_threshold: 0.0,
           routing_breaker_429_threshold: 0.0,
           routing_breaker_latency_p95_ms: 0
         }}
    end
  end

  defp openai_model_name do
    System.get_env("GOOGLE_SLIDES_IMPORT_OPENAI_MODEL") ||
      System.get_env("OPENAI_MODEL") ||
      @default_openai_model
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
