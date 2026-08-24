defmodule Oli.GenAI.Execution do
  @moduledoc """
  Executes GenAI requests using routing plans, counters, and breakers.

  This module wraps provider calls, applies routing decisions, and emits telemetry.
  """

  alias Oli.GenAI.AdmissionControl
  alias Oli.GenAI.Breaker
  alias Oli.GenAI.Router
  alias Oli.GenAI.Telemetry
  alias Oli.GenAI.Completions
  alias Oli.GenAI.Completions.ServiceConfig

  @doc """
  Executes a synchronous completion request with routing.
  """
  def generate(request_ctx, messages, functions, %ServiceConfig{} = service_config, opts \\ []) do
    case generate_with_metadata(request_ctx, messages, functions, service_config, opts) do
      {:ok, %{content: content}} -> {:ok, content}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Executes a synchronous completion request with routing and returns execution metadata.
  """
  def generate_with_metadata(
        request_ctx,
        messages,
        functions,
        %ServiceConfig{} = service_config,
        opts \\ []
      ) do
    with {:ok, plan} <- Router.route(request_ctx, service_config) do
      completer = Keyword.get(opts, :completions_mod, Completions)
      request_type = Map.get(request_ctx, :request_type, :generate)
      notify_plan(Keyword.get(opts, :on_plan), plan)

      try do
        case prepare_provider_request(request_ctx, messages, functions, plan) do
          {:ok, {:proceed, request_metadata}} ->
            execute_with_fallback(
              :generate,
              completer,
              messages,
              functions,
              plan,
              service_config,
              Map.put(
                request_ctx,
                :request_payload_hash,
                request_metadata.request_payload_hash
              ),
              request_type,
              true
            )

          {:ok, {:replay, %{content: content, metadata: metadata}}} ->
            {:ok, %{content: content, metadata: metadata}}

          {:error, reason} ->
            {:error, reason}
        end
      after
        release_admission!(plan)
      end
    end
  end

  @doc """
  Executes a streaming completion request with routing.
  """
  def stream(
        request_ctx,
        messages,
        functions,
        %ServiceConfig{} = service_config,
        response_handler_fn,
        opts \\ []
      ) do
    with {:ok, plan} <- Router.route(request_ctx, service_config) do
      completer = Keyword.get(opts, :completions_mod, Completions)
      request_type = Map.get(request_ctx, :request_type, :stream)
      notify_plan(Keyword.get(opts, :on_plan), plan)

      try do
        execute_with_fallback(
          :stream,
          completer,
          messages,
          functions,
          plan,
          service_config,
          request_ctx,
          request_type,
          false,
          response_handler_fn
        )
      after
        release_admission!(plan)
      end
    end
  end

  defp execute_with_fallback(
         :generate,
         completer,
         messages,
         functions,
         plan,
         service_config,
         request_ctx,
         request_type,
         include_metadata?
       ) do
    execute_generate(
      completer,
      messages,
      functions,
      plan,
      service_config,
      request_ctx,
      request_type,
      include_metadata?
    )
  end

  defp execute_with_fallback(
         :stream,
         completer,
         messages,
         functions,
         plan,
         service_config,
         _request_ctx,
         request_type,
         _include_metadata?,
         response_handler_fn
       ) do
    execute_stream(
      completer,
      messages,
      functions,
      plan,
      service_config,
      response_handler_fn,
      request_type
    )
  end

  defp execute_generate(
         completer,
         messages,
         functions,
         plan,
         service_config,
         request_ctx,
         request_type,
         include_metadata?
       ) do
    start_ms = System.monotonic_time(:millisecond)

    result =
      if function_exported?(completer, :generate_with_metadata, 3) do
        completer.generate_with_metadata(messages, functions, plan.selected_model)
      else
        completer.generate(messages, functions, plan.selected_model)
      end

    latency_ms = System.monotonic_time(:millisecond) - start_ms

    breaker_result = breaker_result(result)
    report_breaker(breaker_result, plan.selected_model, latency_ms)
    emit_provider_telemetry(breaker_result, latency_ms, plan, request_type, service_config)

    case {include_metadata?, result} do
      {true, {:ok, %{content: content, response: response}}} ->
        metadata =
          generation_metadata(plan, service_config)
          |> Map.merge(provider_metadata(response, plan, latency_ms))

        case notify_usage(request_ctx, :ok, Map.put(metadata, :response_content, content)) do
          :ok -> {:ok, %{content: content, metadata: metadata}}
          {:error, reason} -> {:error, {:ai_usage_persistence_failed, reason}}
        end

      {true, {:ok, content}} ->
        metadata =
          generation_metadata(plan, service_config)
          |> Map.merge(provider_metadata(content, plan, latency_ms))

        case notify_usage(request_ctx, :ok, Map.put(metadata, :response_content, content)) do
          :ok -> {:ok, %{content: content, metadata: metadata}}
          {:error, reason} -> {:error, {:ai_usage_persistence_failed, reason}}
        end

      {true, {:error, reason}} ->
        metadata =
          generation_metadata(plan, service_config)
          |> Map.put(:latency_ms, latency_ms)
          |> Map.put(:error, inspect(reason))

        case notify_usage(request_ctx, {:error, reason}, metadata) do
          :ok ->
            {:error, reason}

          {:error, persistence_reason} ->
            {:error, {:ai_usage_persistence_failed, persistence_reason}}
        end

      _ ->
        result
    end
  end

  defp execute_stream(
         completer,
         messages,
         functions,
         plan,
         service_config,
         response_handler_fn,
         request_type
       ) do
    start_ms = System.monotonic_time(:millisecond)
    error_key = {:genai_stream_error, make_ref()}
    Process.put(error_key, false)

    wrapped_handler = fn chunk ->
      if chunk == :error or match?({:error, _}, chunk) or chunk == {:error} do
        Process.put(error_key, true)
      end

      response_handler_fn.(chunk)
    end

    result = completer.stream(messages, functions, plan.selected_model, wrapped_handler)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    error_seen? = Process.get(error_key, false)
    Process.delete(error_key)

    result =
      if error_seen? do
        {:error, :stream_error}
      else
        result
      end

    report_breaker(result, plan.selected_model, latency_ms)
    emit_provider_telemetry(result, latency_ms, plan, request_type, service_config)
    result
  end

  defp report_breaker(result, registered_model, latency_ms) do
    {outcome, http_status, _error_category} = outcome_details(result)

    Breaker.report(registered_model.id, %{
      outcome: outcome,
      http_status: http_status,
      latency_ms: latency_ms,
      thresholds: breaker_thresholds(registered_model)
    })
  end

  defp outcome_details({:ok, _}), do: {:ok, nil, nil}

  defp outcome_details({:error, reason}) do
    {http_status, error_category} = error_details(reason)

    {:error, http_status, error_category}
  end

  defp outcome_details(:ok), do: {:ok, nil, nil}
  defp outcome_details(_), do: {:error, nil, :unknown}

  defp error_details(:timeout), do: {nil, :timeout}
  defp error_details(:stream_error), do: {nil, :stream_error}
  defp error_details(:connect_timeout), do: {nil, :timeout}
  defp error_details(:recv_timeout), do: {nil, :timeout}
  defp error_details({:timeout, _}), do: {nil, :timeout}

  defp error_details(%{status: status}) when is_integer(status) do
    {status, http_status_category(status)}
  end

  defp error_details(%{http_status: status}) when is_integer(status) do
    {status, http_status_category(status)}
  end

  defp error_details(%{status_code: status}) when is_integer(status) do
    {status, http_status_category(status)}
  end

  defp error_details({:http_error, status}) when is_integer(status) do
    {status, http_status_category(status)}
  end

  defp error_details(_), do: {nil, :unknown}

  defp http_status_category(429), do: :rate_limited
  defp http_status_category(_status), do: :http_error

  defp breaker_thresholds(registered_model) do
    %{
      error_rate_threshold:
        default_if_nil(registered_model.routing_breaker_error_rate_threshold, 0.2),
      rate_limit_threshold: default_if_nil(registered_model.routing_breaker_429_threshold, 0.1),
      latency_p95_ms: default_if_nil(registered_model.routing_breaker_latency_p95_ms, 6000),
      open_cooldown_ms: default_if_nil(registered_model.routing_open_cooldown_ms, 30_000),
      half_open_probe_count: default_if_nil(registered_model.routing_half_open_probe_count, 3)
    }
  end

  defp default_if_nil(nil, fallback), do: fallback
  defp default_if_nil(value, _fallback), do: value

  defp release_admission!(%{admission: :bypass}), do: :ok

  defp release_admission!(%{pool_name: pool_name, selected_model: %{id: model_id}} = plan) do
    AdmissionControl.release_pool(pool_name)

    if Map.get(plan, :model_admitted, false) do
      AdmissionControl.release_model(model_id)
    end
  end

  defp release_admission!(_), do: :ok

  defp generation_metadata(plan, %ServiceConfig{id: service_config_id}) do
    %{
      model: plan.selected_model.model,
      provider: plan.selected_model.provider,
      registered_model_id: plan.selected_model.id,
      service_config_id: service_config_id,
      service_tier: plan.selected_model.service_tier || to_string(plan.tier),
      reasoning_effort: plan.selected_model.reasoning_effort || "medium",
      prompt_cache_key: plan.selected_model.prompt_cache_key,
      max_output_tokens: plan.selected_model.max_output_tokens
    }
  end

  defp breaker_result({:ok, %{content: content}}), do: {:ok, content}
  defp breaker_result(result), do: result

  defp provider_metadata(response, plan, latency_ms) when is_map(response) do
    usage = Map.get(response, "usage", Map.get(response, :usage, %{})) || %{}

    input_details =
      Map.get(usage, "input_tokens_details", Map.get(usage, :input_tokens_details, %{})) || %{}

    prompt_details =
      Map.get(usage, "prompt_tokens_details", Map.get(usage, :prompt_tokens_details, %{})) || %{}

    output_details =
      Map.get(usage, "output_tokens_details", Map.get(usage, :output_tokens_details, %{})) || %{}

    input_tokens =
      number(usage, ["input_tokens", :input_tokens, "prompt_tokens", :prompt_tokens])

    cached_tokens =
      number(input_details, ["cached_tokens", :cached_tokens]) ||
        number(prompt_details, ["cached_tokens", :cached_tokens]) || 0

    %{
      request_id: Map.get(response, "id") || Map.get(response, :id),
      service_tier:
        Map.get(response, "service_tier") || Map.get(response, :service_tier) ||
          plan.selected_model.service_tier || to_string(plan.tier),
      input_tokens: input_tokens || 0,
      cached_input_tokens: cached_tokens,
      cache_write_tokens: number(input_details, ["cache_write_tokens", :cache_write_tokens]) || 0,
      output_tokens:
        number(usage, ["output_tokens", :output_tokens, "completion_tokens", :completion_tokens]) ||
          0,
      reasoning_tokens: number(output_details, ["reasoning_tokens", :reasoning_tokens]) || 0,
      cache_status: if(cached_tokens > 0, do: "hit", else: "miss"),
      latency_ms: latency_ms
    }
  end

  defp provider_metadata(_response, _plan, latency_ms),
    do: %{
      input_tokens: 0,
      cached_input_tokens: 0,
      cache_write_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      cache_status: "unknown",
      latency_ms: latency_ms
    }

  defp number(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        value when is_float(value) and value >= 0 -> trunc(value)
        _ -> nil
      end
    end)
  end

  defp number(_map, _keys), do: nil

  defp prepare_provider_request(request_ctx, messages, functions, plan) do
    payload = {messages, functions}
    payload_binary = :erlang.term_to_binary(payload, [:deterministic])

    request = %{
      model: plan.selected_model.model,
      service_tier: plan.selected_model.service_tier || to_string(plan.tier),
      input_tokens: max(div(byte_size(payload_binary) + 3, 4), 1),
      max_output_tokens:
        plan.selected_model.max_output_tokens || request_ctx[:max_output_tokens] || 4_000,
      request_payload_hash:
        payload_binary
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }

    case Map.get(request_ctx, :before_provider_request) do
      callback when is_function(callback, 1) ->
        case callback.(request) do
          {:ok, :proceed} -> {:ok, {:proceed, request}}
          other -> other
        end

      _ ->
        {:ok, {:proceed, request}}
    end
  rescue
    error -> {:error, {:ai_request_preparation_failed, error}}
  end

  defp notify_usage(request_ctx, outcome, metadata) do
    case Map.get(request_ctx, :usage_recorder) do
      recorder when is_function(recorder, 2) ->
        recorder.(
          outcome,
          Map.put_new(metadata, :request_payload_hash, request_ctx[:request_payload_hash])
        )

      _ ->
        :ok
    end
  rescue
    error -> {:error, error}
  end

  defp emit_provider_telemetry(result, latency_ms, plan, request_type, service_config) do
    {outcome, http_status, error_category} = outcome_details(result)

    Telemetry.provider_stop(
      %{duration_ms: latency_ms},
      %{
        service_config_id: service_config.id,
        registered_model_id: plan.selected_model.id,
        provider: plan.selected_model.provider,
        model: plan.selected_model.model,
        tier: plan.tier,
        pool_name: plan.pool_name,
        pool_class: plan.selected_model.pool_class || :slow,
        reason: plan.reason,
        outcome: outcome,
        http_status: http_status,
        error_category: error_category,
        request_type: request_type
      }
    )
  end

  defp notify_plan(nil, _plan), do: :ok
  defp notify_plan(callback, plan) when is_function(callback, 1), do: callback.(plan)
end
