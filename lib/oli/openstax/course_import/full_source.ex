defmodule Oli.OpenStax.CourseImport.FullSource do
  @moduledoc """
  Carries every substantive OpenStax source block into schema-v4 instruction.

  Model-authored evidence references are useful for placement, but they are not
  proof that learner-facing content was preserved. This module deterministically
  appends any missing source text to the nearest cited instructional section so
  refinement cannot silently become summarization.
  """

  @refined_schema_version 4
  @deterministic_reason_kinds %{
    "navigation" => MapSet.new(["navigation"]),
    "duplicated_boilerplate" => MapSet.new(["duplicated_boilerplate", "boilerplate"]),
    "unsafe_media" => MapSet.new(["unsafe_media"])
  }

  @spec preserve_sections(map(), [map()], integer()) :: [map()]
  def preserve_sections(lesson, sections, schema_version)

  def preserve_sections(lesson, sections, schema_version)
      when is_map(lesson) and is_list(sections) and
             schema_version >= @refined_schema_version do
    lesson
    |> substantive_text_blocks()
    |> Enum.reduce(sections, &preserve_block/2)
  end

  def preserve_sections(_lesson, sections, _schema_version) when is_list(sections), do: sections
  def preserve_sections(_lesson, _sections, _schema_version), do: []

  @spec substantive_text_blocks(map()) :: [map()]
  def substantive_text_blocks(lesson) when is_map(lesson) do
    blocks = recursive_blocks(lesson["source_blocks"] || lesson[:source_blocks])
    available_ids = MapSet.new(blocks, & &1["id"])

    deterministic_ids =
      get_in(lesson, ["source_coverage", "deterministically_omittable_block_ids"])
      |> List.wrap()
      |> MapSet.new()

    substantive_ids =
      case get_in(lesson, ["source_coverage", "substantive_block_ids"]) do
        ids when is_list(ids) and ids != [] ->
          ids |> MapSet.new() |> MapSet.intersection(available_ids)

        _ ->
          MapSet.difference(available_ids, deterministic_ids)
      end

    blocks
    |> Enum.filter(fn block ->
      MapSet.member?(substantive_ids, block["id"]) and
        not MapSet.member?(deterministic_ids, block["id"]) and present?(block["text"])
    end)
  end

  def substantive_text_blocks(_lesson), do: []

  @spec normalized_text(term()) :: String.t()
  def normalized_text(value) when is_binary(value) do
    value
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def normalized_text(_value), do: ""

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

  defp preserve_block(block, sections) do
    if source_text_present?(sections, block["text"]) do
      sections
    else
      case Enum.find_index(sections, fn section ->
             block["id"] in List.wrap(section["evidence_block_ids"])
           end) do
        nil -> append_to_carry_through_section(sections, block)
        index -> List.update_at(sections, index, &append_block(&1, block))
      end
    end
  end

  defp source_text_present?(sections, source_text) do
    source = normalized_text(source_text)
    rendered = sections |> Enum.map_join(" ", &section_text/1) |> normalized_text()
    source != "" and String.contains?(rendered, source)
  end

  defp section_text(section) do
    [
      section["heading"],
      section["title"],
      section["explanation"],
      section["body"]
      | List.wrap(section["examples"])
    ]
    |> Enum.map_join(" ", &text_value/1)
  end

  defp text_value(value) when is_binary(value), do: value

  defp text_value(value) when is_map(value) do
    value
    |> Map.take(["title", "scenario", "steps", "conclusion", "body", "text"])
    |> Map.values()
    |> Enum.map_join(" ", &text_value/1)
  end

  defp text_value(value) when is_list(value), do: Enum.map_join(value, " ", &text_value/1)
  defp text_value(_value), do: ""

  defp append_block(section, block) do
    section
    |> Map.update("explanation", block["text"], &append_text(&1, block["text"]))
    |> Map.update(
      "evidence_block_ids",
      [block["id"]],
      &Enum.uniq(List.wrap(&1) ++ [block["id"]])
    )
  end

  defp append_to_carry_through_section(sections, block) do
    carry_id = unique_carry_id(sections)

    case Enum.find_index(sections, &(&1["full_source_carry_through"] == true)) do
      nil ->
        sections ++
          [
            %{
              "id" => carry_id,
              "heading" => "OpenStax source material retained in full",
              "explanation" => block["text"],
              "examples" => [],
              "evidence_block_ids" => [block["id"]],
              "source_evidence_links" => [],
              "full_source_carry_through" => true
            }
          ]

      index ->
        List.update_at(sections, index, &append_block(&1, block))
    end
  end

  defp unique_carry_id(sections) do
    ids = MapSet.new(sections, & &1["id"])

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "full-source-carry-through-#{index}"
      if MapSet.member?(ids, candidate), do: nil, else: candidate
    end)
  end

  defp append_text(existing, addition) do
    [existing, addition]
    |> Enum.filter(&present?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp recursive_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        id = block["id"] || block[:id]
        kind = block["kind"] || block[:kind]
        text = block["text"] || block[:text] || ""

        direct =
          if present?(id) and present?(kind),
            do: [%{"id" => id, "kind" => kind, "text" => text}],
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
