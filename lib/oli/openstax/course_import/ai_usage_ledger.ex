defmodule Oli.OpenStax.CourseImport.AIUsageLedger do
  @moduledoc "Persists and replays request-level OpenStax AI work with cost attribution."

  import Ecto.Query

  alias Oli.OpenStax.CourseImport.{AICostGuard, AIPricing, AIUsageEvent}
  alias Oli.Repo

  @spec request_context(keyword(), atom() | String.t(), map()) :: map()
  def request_context(opts, role, attrs \\ %{}) do
    base = %{
      request_type: :generate,
      feature: :openstax_course_import,
      phase: role,
      run_id: Keyword.get(opts, :run_id),
      lesson_id: Keyword.get(opts, :lesson_id),
      authoring_mode: Keyword.get(opts, :authoring_mode),
      role: to_string(role),
      candidate_number: Map.get(attrs, :candidate_number, 1),
      planning_request_id:
        Map.get(attrs, :planning_request_id, Keyword.get(opts, :planning_request_id)),
      operation_id: Map.get(attrs, :operation_id),
      cost_scope: Map.get(attrs, :cost_scope, :lesson),
      max_output_tokens: Map.get(attrs, :max_output_tokens),
      retry_category: Map.get(attrs, :retry_category),
      finding_fingerprint: Map.get(attrs, :finding_fingerprint),
      cache_status: Map.get(attrs, :cache_status)
    }

    base = Map.put(base, :request_key, request_key(base))

    base
    |> Map.put(:before_provider_request, before_provider_request(base))
    |> Map.put(:usage_recorder, recorder(base))
  end

  @spec recorder(map()) :: (term(), map() -> :ok | {:error, term()})
  def recorder(context) do
    fn outcome, metadata ->
      case record(context, outcome, metadata) do
        {:ok, _event} -> :ok
        :ignored -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec before_provider_request(map()) :: (map() -> {:ok, term()} | {:error, term()})
  def before_provider_request(context) do
    fn request -> prepare(context, request) end
  end

  @spec prepare(map(), map()) :: {:ok, :proceed | {:replay, map()}} | {:error, term()}
  def prepare(context, request) when is_map(context) and is_map(request) do
    case replay(context[:request_key], request[:request_payload_hash]) do
      {:ok, replayed} ->
        {:ok, {:replay, replayed}}

      :miss ->
        case AICostGuard.reserve(context, request) do
          {:ok, _reservation} -> {:ok, :proceed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def prepare(_context, _request), do: {:ok, :proceed}

  @spec record(map(), term(), map()) :: {:ok, AIUsageEvent.t()} | {:error, term()} | :ignored
  def record(context, outcome, metadata) do
    if is_binary(context[:run_id]) or is_binary(context[:lesson_id]) do
      usage = stringify(metadata)
      tier = usage["service_tier"] || "standard"
      model = usage["model"]

      response_payload = response_payload(usage)
      estimated_cost = AIPricing.estimate_microdollars(model, tier, usage)

      attrs = %{
        run_id: context[:run_id],
        lesson_id: context[:lesson_id],
        authoring_mode: context[:authoring_mode],
        role: context[:role] || to_string(context[:phase] || "unknown"),
        phase: to_string(context[:phase] || context[:role] || "unknown"),
        provider: string(usage["provider"]),
        model: model,
        model_snapshot: usage["model_snapshot"] || model,
        service_tier: string(tier),
        reasoning_effort: usage["reasoning_effort"],
        candidate_number: context[:candidate_number] || 1,
        request_key: context[:request_key],
        provider_attempt: provider_attempt(context[:request_key]),
        request_id: usage["request_id"],
        request_payload_hash: usage["request_payload_hash"],
        response_payload: response_payload,
        replayed_from_event_id: usage["replayed_from_event_id"],
        input_tokens: number(usage["input_tokens"]),
        cached_input_tokens: number(usage["cached_input_tokens"]),
        cache_write_tokens: number(usage["cache_write_tokens"]),
        output_tokens: number(usage["output_tokens"]),
        reasoning_tokens: number(usage["reasoning_tokens"]),
        estimated_cost_microdollars: estimated_cost,
        pricing_version: AIPricing.pricing_version(),
        outcome: outcome_name(outcome),
        retry_category: context[:retry_category] || retry_category(outcome),
        finding_fingerprint: context[:finding_fingerprint],
        cache_status: context[:cache_status] || usage["cache_status"],
        latency_ms: number_or_nil(usage["latency_ms"]),
        metadata:
          Map.drop(
            usage,
            ~w(input_tokens cached_input_tokens cache_write_tokens output_tokens reasoning_tokens response_content)
          )
      }

      Repo.transaction(fn ->
        event = %AIUsageEvent{} |> AIUsageEvent.changeset(attrs) |> Repo.insert!()

        cost_outcome = if outcome_name(outcome) == "succeeded", do: :succeeded, else: :failed

        case AICostGuard.settle(context, estimated_cost, cost_outcome) do
          :ok -> event
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, event} -> {:ok, event}
        {:error, reason} -> {:error, reason}
      end
    else
      :ignored
    end
  rescue
    error -> {:error, error}
  end

  defp outcome_name(:ok), do: "succeeded"
  defp outcome_name({:error, _reason}), do: "failed"
  defp outcome_name(value), do: to_string(value)

  defp retry_category({:error, reason}) do
    text = inspect(reason)

    cond do
      String.contains?(text, "429") -> "rate_limited"
      String.contains?(text, ["timeout", "recv_timeout", "connect_timeout"]) -> "timeout"
      String.contains?(text, ["500", "502", "503", "504"]) -> "provider_unavailable"
      true -> "provider_error"
    end
  end

  defp retry_category(_outcome), do: nil

  defp replay(request_key, request_payload_hash)
       when is_binary(request_key) and is_binary(request_payload_hash) do
    AIUsageEvent
    |> where(
      [event],
      event.request_key == ^request_key and
        event.request_payload_hash == ^request_payload_hash and
        event.outcome == "succeeded" and
        not is_nil(event.response_payload)
    )
    |> order_by([event], desc: event.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> replay_result()
  rescue
    _error -> :miss
  end

  defp replay(_request_key, _request_payload_hash), do: :miss

  defp replay_result(%AIUsageEvent{} = event) do
    content = event.response_payload["content"] || event.response_payload[:content]

    if is_binary(content) do
      {:ok,
       %{
         content: content,
         metadata:
           event.response_payload
           |> Map.get("metadata", %{})
           |> stringify()
           |> Map.put("cache_status", "durable_replay")
           |> Map.put("replayed_from_event_id", event.id)
       }}
    else
      :miss
    end
  end

  defp replay_result(nil), do: :miss

  defp provider_attempt(request_key) when is_binary(request_key) do
    AIUsageEvent
    |> where([event], event.request_key == ^request_key)
    |> Repo.aggregate(:count)
    |> Kernel.+(1)
  end

  defp provider_attempt(_request_key), do: 1

  defp response_payload(%{"response_content" => content} = usage) when is_binary(content) do
    %{
      "content" => content,
      "metadata" => Map.drop(usage, ["response_content", "error"])
    }
  end

  defp response_payload(_usage), do: nil

  defp request_key(context) do
    {
      context[:run_id],
      context[:lesson_id],
      context[:planning_request_id],
      context[:operation_id],
      context[:role],
      context[:candidate_number],
      context[:finding_fingerprint]
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(value) when is_float(value) and value >= 0, do: trunc(value)
  defp number(_value), do: 0

  defp number_or_nil(nil), do: nil
  defp number_or_nil(value), do: number(value)

  defp string(nil), do: nil
  defp string(value), do: to_string(value)
end
