defmodule Oli.OpenStax.CourseImport.FullSource do
  @moduledoc """
  Current-AST source disposition rules shared by Basic and Advanced v7.

  Required instructional blocks are represented exactly once. Only importer-
  classified navigation, duplicate boilerplate, or unsafe media may be omitted.
  """

  @deterministic_reason_kinds %{
    "navigation" => MapSet.new(["navigation"]),
    "duplicated_boilerplate" => MapSet.new(["duplicated_boilerplate", "boilerplate"]),
    "unsafe_media" => MapSet.new(["unsafe_media"])
  }

  @doc "Returns true only for an importer-classified deterministic omission."
  @spec deterministic_exclusion?(map(), map()) :: boolean()
  def deterministic_exclusion?(lesson, %{"id" => id, "reason_code" => reason_code})
      when is_map(lesson) and is_binary(id) and is_binary(reason_code) do
    coverage = lesson["source_coverage"] || lesson[:source_coverage] || %{}

    deterministic_ids =
      coverage["deterministically_omittable_block_ids"] ||
        coverage[:deterministically_omittable_block_ids] || []

    expected_kinds = Map.get(@deterministic_reason_kinds, reason_code, MapSet.new())

    block_kind =
      lesson
      |> Map.get("source_blocks", Map.get(lesson, :source_blocks, []))
      |> recursive_blocks()
      |> Enum.find_value(fn block -> if block["id"] == id, do: block["kind"] end)

    id in List.wrap(deterministic_ids) and MapSet.member?(expected_kinds, block_kind)
  end

  def deterministic_exclusion?(_lesson, _exclusion), do: false

  defp recursive_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        direct =
          if present?(block["id"] || block[:id]) and present?(block["kind"] || block[:kind]),
            do: [%{"id" => block["id"] || block[:id], "kind" => block["kind"] || block[:kind]}],
            else: []

        direct ++
          recursive_blocks(block["blocks"] || block[:blocks]) ++
          recursive_item_blocks(block["items"] || block[:items])

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp recursive_item_blocks(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = item -> recursive_blocks(item["children"] || item[:children])
      _ -> []
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
