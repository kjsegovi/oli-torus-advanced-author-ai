defmodule Oli.OpenStax.CourseImport.Enrichment.Failure do
  @moduledoc false

  @allowed_keys ~w(code stage retryable provider exception_class top_stack_location)
  @max_value_length 160

  @doc """
  Reduces provider failures to a small, source-free persistence payload.

  Provider response bodies, prompts, generated source, exception messages, and
  stack traces are intentionally discarded.
  """
  @spec sanitize(term(), String.t() | atom() | nil) :: map()
  def sanitize(reason, default_stage \\ nil)

  def sanitize(reason, default_stage) when is_atom(reason) or is_binary(reason) do
    %{
      "code" => safe_code(reason),
      "stage" => safe_value(default_stage, "unknown"),
      "retryable" => false
    }
  end

  def sanitize(%{} = reason, default_stage) do
    sanitized =
      reason
      |> stringify_keys()
      |> Map.take(@allowed_keys)
      |> Enum.reduce(%{}, fn
        {"retryable", value}, acc -> Map.put(acc, "retryable", value == true)
        {"code", value}, acc -> Map.put(acc, "code", safe_code(value))
        {key, value}, acc -> Map.put(acc, key, safe_value(value, nil))
      end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    sanitized
    |> Map.put_new("code", "provider_failure")
    |> Map.put_new("stage", safe_value(default_stage, "unknown"))
    |> Map.put_new("retryable", false)
  end

  def sanitize(_reason, default_stage) do
    %{
      "code" => "provider_failure",
      "stage" => safe_value(default_stage, "unknown"),
      "retryable" => false
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp safe_value(nil, fallback), do: fallback

  defp safe_value(value, fallback) when is_atom(value) or is_binary(value) do
    value = value |> to_string() |> String.trim() |> String.slice(0, @max_value_length)
    if value == "", do: fallback, else: value
  end

  defp safe_value(_value, fallback), do: fallback

  defp safe_code(value) when is_atom(value), do: value |> Atom.to_string() |> safe_code()

  defp safe_code(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[a-z0-9][a-z0-9_:-]{0,79}$/, value),
      do: value,
      else: "provider_failure"
  end

  defp safe_code(_), do: "provider_failure"
end
