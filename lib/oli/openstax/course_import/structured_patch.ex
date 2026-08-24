defmodule Oli.OpenStax.CourseImport.StructuredPatch do
  @moduledoc """
  Applies bounded RFC-6902-style repair patches to AI candidates.

  Each role owns a small set of generated roots. Source-owned and server-owned
  fields are absent from every allowlist, so a repair cannot mutate them even
  when a model is shown the complete source and candidate context.
  """

  @max_operations 40

  @allowed_roots %{
    basic_content_architect:
      ~w(title orientation content_groups question_slots generated_alt_text synthesis),
    advanced_experience_architect:
      ~w(title orientation content_groups question_slots generated_alt_text synthesis experience_blueprint),
    advanced_activity_writer: ~w(activities),
    simulation_opportunity_designer: ~w(opportunities)
  }

  @spec apply(map(), term(), atom()) :: {:ok, map()} | {:error, [map()]}
  def apply(candidate, %{"patch" => operations}, owner)
      when is_map(candidate) and is_list(operations) and is_atom(owner) do
    allowed = Map.get(@allowed_roots, owner, [])

    cond do
      allowed == [] ->
        {:error, [finding("unknown_patch_owner", "$", "Use a registered repair owner.")]}

      operations == [] ->
        {:error, [finding("empty_repair_patch", "$.patch", "Return at least one operation.")]}

      length(operations) > @max_operations ->
        {:error,
         [
           finding(
             "repair_patch_too_large",
             "$.patch",
             "Return no more than #{@max_operations} operations."
           )
         ]}

      true ->
        operations
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, candidate}, fn {operation, index}, {:ok, value} ->
          case apply_operation(value, operation, allowed, index) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, finding} -> {:halt, {:error, [finding]}}
          end
        end)
    end
  end

  def apply(_candidate, _response, _owner) do
    {:error,
     [
       finding(
         "invalid_repair_patch",
         "$.patch",
         "Return JSON with one bounded patch array; do not return the complete candidate."
       )
     ]}
  end

  def allowed_roots(owner), do: Map.get(@allowed_roots, owner, [])
  def max_operations, do: @max_operations

  defp apply_operation(candidate, operation, allowed, index) when is_map(operation) do
    operation = stringify_keys(operation)
    op = operation["op"]
    path = operation["path"]

    with true <- op in ["add", "replace", "remove"],
         {:ok, tokens} <- pointer_tokens(path),
         true <- allowed_path?(tokens, allowed),
         {:ok, updated} <- update(candidate, tokens, op, operation["value"]) do
      {:ok, updated}
    else
      false ->
        {:error,
         finding(
           "forbidden_repair_patch",
           "$.patch[#{index}]",
           "Use add, replace, or remove only on the role's generated fields."
         )}

      {:error, reason} ->
        {:error,
         finding(
           "invalid_repair_patch_operation",
           "$.patch[#{index}]",
           inspect(reason)
         )}
    end
  end

  defp apply_operation(_candidate, _operation, _allowed, index),
    do:
      {:error,
       finding(
         "invalid_repair_patch_operation",
         "$.patch[#{index}]",
         "Each operation must be an object."
       )}

  defp pointer_tokens(path) when is_binary(path) do
    case String.split(path, "/", trim: false) do
      ["" | tokens] when tokens != [] ->
        {:ok,
         Enum.map(tokens, fn token ->
           token |> String.replace("~1", "/") |> String.replace("~0", "~")
         end)}

      _tokens ->
        {:error, :invalid_json_pointer}
    end
  end

  defp pointer_tokens(_path), do: {:error, :missing_json_pointer}

  defp allowed_path?([root | _rest], allowed), do: root in allowed
  defp allowed_path?(_tokens, _allowed), do: false

  defp update(value, [key], "add", replacement) when is_map(value),
    do: {:ok, Map.put(value, key, replacement)}

  defp update(value, [key], "replace", replacement) when is_map(value) do
    if Map.has_key?(value, key),
      do: {:ok, Map.put(value, key, replacement)},
      else: {:error, {:path_not_found, key}}
  end

  defp update(value, [key], "remove", _replacement) when is_map(value) do
    if Map.has_key?(value, key),
      do: {:ok, Map.delete(value, key)},
      else: {:error, {:path_not_found, key}}
  end

  defp update(value, [token], "add", replacement) when is_list(value) do
    with {:ok, index} <- list_index(token, length(value), :add) do
      {:ok, List.insert_at(value, index, replacement)}
    end
  end

  defp update(value, [token], "replace", replacement) when is_list(value) do
    with {:ok, index} <- list_index(token, length(value), :existing) do
      {:ok, List.replace_at(value, index, replacement)}
    end
  end

  defp update(value, [token], "remove", _replacement) when is_list(value) do
    with {:ok, index} <- list_index(token, length(value), :existing) do
      {:ok, List.delete_at(value, index)}
    end
  end

  defp update(value, [token | rest], op, replacement) when is_map(value) do
    case Map.fetch(value, token) do
      {:ok, child} ->
        with {:ok, updated} <- update(child, rest, op, replacement) do
          {:ok, Map.put(value, token, updated)}
        end

      :error ->
        {:error, {:path_not_found, token}}
    end
  end

  defp update(value, [token | rest], op, replacement) when is_list(value) do
    with {:ok, index} <- list_index(token, length(value), :existing),
         {:ok, updated} <- update(Enum.at(value, index), rest, op, replacement) do
      {:ok, List.replace_at(value, index, updated)}
    end
  end

  defp update(_value, _tokens, _op, _replacement), do: {:error, :path_not_traversable}

  defp list_index("-", length, :add), do: {:ok, length}

  defp list_index(token, length, mode) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 and mode == :add and index <= length -> {:ok, index}
      {index, ""} when index >= 0 and mode == :existing and index < length -> {:ok, index}
      _parsed -> {:error, {:invalid_list_index, token}}
    end
  end

  defp finding(code, path, repair),
    do: %{"code" => code, "path" => path, "severity" => "repair", "repair" => repair}

  defp stringify_keys(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)
end
