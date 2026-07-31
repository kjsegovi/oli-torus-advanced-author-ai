defmodule OliWeb.Api.CourseImportParams do
  @moduledoc false

  @selection_keys ["chapters", "selected_chapter_ids", "selected_unit_ids", "selected_chapters"]

  @doc """
  Extracts selected OpenStax chapter ids from supported JSON request shapes.

  `chapters` is the preferred public field. The two id-list fields are kept as
  compatibility aliases for clients that shipped before the chapter cards API.
  A chapter can be an id, a chapter object (`id`/`chapter_id` plus `selected`),
  or a checkbox map keyed by chapter id.
  """
  @spec selected_chapter_ids(map()) :: [String.t()]
  def selected_chapter_ids(params) when is_map(params) do
    params
    |> selection_value()
    |> normalize_selection()
    |> Enum.uniq()
  end

  def selected_chapter_ids(_), do: []

  @doc """
  Normalizes supported lesson-plan edit request shapes without separating a
  top-level `questions_payload` from its sibling `content_payload`.
  """
  @spec lesson_plan_payload(map()) :: map()
  def lesson_plan_payload(params) when is_map(params) do
    cond do
      is_map(params["plan"]) ->
        params["plan"]

      is_map(params["content_payload"]) or is_map(params["questions_payload"]) ->
        params
        |> Map.take(["content_payload", "questions_payload"])
        |> Enum.reduce(%{}, fn
          {key, value}, payload when is_map(value) -> Map.put(payload, key, value)
          _entry, payload -> payload
        end)

      true ->
        Map.take(params, ["objective", "narrative", "questions_payload", "questions"])
    end
  end

  def lesson_plan_payload(_), do: %{}

  defp selection_value(params) do
    nested_scope = Map.get(params, "scope", %{})

    Enum.find_value(@selection_keys, [], fn key ->
      Map.get(params, key) || if(is_map(nested_scope), do: Map.get(nested_scope, key))
    end)
  end

  defp normalize_selection(nil), do: []

  defp normalize_selection(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_entry/1)
  end

  defp normalize_selection(values) when is_map(values) do
    case chapter_id(values) do
      nil ->
        values
        |> Enum.sort_by(fn {id, _selected} -> to_string(id) end)
        |> Enum.flat_map(fn {id, selected} ->
          if selected?(selected), do: normalize_entry(id), else: []
        end)

      _ ->
        normalize_entry(values)
    end
  end

  defp normalize_selection(value), do: normalize_entry(value)

  defp normalize_entry(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      id -> [id]
    end
  end

  defp normalize_entry(%{} = chapter) do
    if selected?(Map.get(chapter, "selected", Map.get(chapter, :selected, true))) do
      case chapter_id(chapter) do
        nil -> []
        id -> normalize_entry(id)
      end
    else
      []
    end
  end

  defp normalize_entry(_), do: []

  defp chapter_id(chapter) do
    Map.get(chapter, "id") ||
      Map.get(chapter, :id) ||
      Map.get(chapter, "chapter_id") ||
      Map.get(chapter, :chapter_id)
  end

  defp selected?(value) when value in [false, nil, 0, "0", "false", "off"], do: false
  defp selected?(_), do: true
end
