defmodule Oli.OpenStax.CourseImport.AIPricing do
  @moduledoc "Versioned OpenStax importer pricing used for cost attribution and circuit breakers."

  @pricing_version "openai-2026-08-24"
  @long_context_threshold 272_000

  # Microdollars per token. These are equivalent to the published dollars per
  # one million tokens and keep integer event accounting precise.
  @rates %{
    "gpt-5.6-terra" => %{input: 2.0, cached_input: 0.2, output: 12.0},
    "gpt-5.6-luna" => %{input: 0.2, cached_input: 0.02, output: 1.2},
    "gpt-5.6-sol" => %{input: 5.0, cached_input: 0.5, output: 30.0}
  }

  def pricing_version, do: @pricing_version
  def rates, do: @rates

  @spec estimate_microdollars(String.t() | nil, String.t() | atom() | nil, map()) ::
          non_neg_integer()
  def estimate_microdollars(model, tier, usage) do
    rate = Map.get(@rates, model, %{input: 0.0, cached_input: 0.0, output: 0.0})
    input = number(usage, :input_tokens)
    cached = min(number(usage, :cached_input_tokens), input)
    uncached = max(input - cached, 0)
    cache_write = number(usage, :cache_write_tokens)
    output = number(usage, :output_tokens)
    tier_multiplier = tier_multiplier(tier)
    {input_multiplier, output_multiplier} = context_multipliers(input)
    regional_multiplier = regional_multiplier(usage)

    cost =
      (uncached * rate.input + cached * rate.cached_input +
         cache_write * rate.input * 1.25) * input_multiplier +
        output * rate.output * output_multiplier

    cost
    |> Kernel.*(tier_multiplier)
    |> Kernel.*(regional_multiplier)
    |> Float.ceil()
    |> trunc()
  end

  @spec estimate_max_microdollars(String.t() | nil, String.t() | atom() | nil, map()) ::
          non_neg_integer()
  def estimate_max_microdollars(model, tier, attrs) do
    estimate_microdollars(model, tier, %{
      input_tokens: number(attrs, :input_tokens),
      cached_input_tokens: 0,
      cache_write_tokens: 0,
      output_tokens: number(attrs, :max_output_tokens),
      regional_processing: Map.get(attrs, :regional_processing, false)
    })
  end

  defp context_multipliers(input) when input > @long_context_threshold, do: {2.0, 1.5}
  defp context_multipliers(_input), do: {1.0, 1.0}

  defp tier_multiplier(tier) do
    case to_string(tier || "standard") do
      "flex" -> 0.5
      value when value in ["fast", "priority"] -> 2.0
      _ -> 1.0
    end
  end

  defp regional_multiplier(usage) do
    case Map.get(usage, :regional_processing, Map.get(usage, "regional_processing", false)) do
      true -> 1.1
      _ -> 1.0
    end
  end

  defp number(map, key) do
    case Map.get(map, key, Map.get(map, to_string(key), 0)) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _ -> 0
    end
  end
end
