defmodule Oli.GoogleSlides.ImportWorkflow.SourceInventory do
  @moduledoc """
  Produces a deterministic, bounded-data description of every Slides page element.

  The inventory is intentionally structural rather than stylistic. It preserves
  stable object identity, safe semantic summaries, and enough geometry to review
  a hybrid import, but never copies raw page elements, media blobs, expiring
  content URLs, presentation themes, or slide/background colors.
  """

  @summary_text_limit 400

  @type entry :: map()

  @spec build(String.t() | nil, list()) :: [entry()]
  def build(slide_id, elements) when is_list(elements) do
    slide_id = stable_slide_id(slide_id)

    elements
    |> walk_elements(slide_id, nil, 0, [])
    |> Enum.with_index()
    |> Enum.map(fn {entry, order} -> Map.put(entry, "order", order) end)
  end

  def build(slide_id, _elements), do: build(slide_id, [])

  @spec count(list()) :: non_neg_integer()
  def count(elements) when is_list(elements) do
    Enum.reduce(elements, 0, fn element, count ->
      count + 1 + count(group_children(element))
    end)
  end

  def count(_elements), do: 0

  @spec source_type_counts([entry()]) :: map()
  def source_type_counts(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, counts ->
      Map.update(counts, entry["sourceType"] || "unknown", 1, &(&1 + 1))
    end)
  end

  defp walk_elements(elements, slide_id, parent_object_id, depth, parent_path) do
    elements
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} ->
      path = parent_path ++ [index]
      source_type = source_type(element)
      object_id = stable_object_id(element, slide_id, path, source_type)
      object_id_source = if valid_id?(element["objectId"]), do: "google", else: "synthetic"

      entry =
        %{
          "inventoryId" => "#{slide_id}:#{path_string(path)}:#{object_id}",
          "slideId" => slide_id,
          "objectId" => object_id,
          "objectIdSource" => object_id_source,
          "parentObjectId" => parent_object_id,
          "depth" => depth,
          "path" => path_string(path),
          "sourceType" => source_type,
          "container" => source_type == "group",
          "suggestedDisposition" => suggested_disposition(source_type, element),
          "fidelity" => fidelity(source_type, element),
          "reviewRequired" => review_required?(source_type, element),
          "meaningful" => meaningful?(source_type, element),
          "decorative" => decorative?(source_type, element),
          "summary" => summary(source_type, element),
          "geometry" => geometry(element)
        }
        |> reject_empty_values()

      [entry | walk_elements(group_children(element), slide_id, object_id, depth + 1, path)]
    end)
  end

  defp source_type(element) when is_map(element) do
    cond do
      is_map(element["elementGroup"]) -> "group"
      is_map(element["shape"]) -> "shape"
      is_map(element["table"]) -> "table"
      is_map(element["image"]) -> "image"
      is_map(element["video"]) -> "video"
      is_map(element["line"]) -> "line"
      is_map(element["wordArt"]) -> "word_art"
      is_map(element["sheetsChart"]) -> "sheets_chart"
      is_map(element["speakerSpotlight"]) -> "speaker_spotlight"
      true -> "unknown"
    end
  end

  defp source_type(_element), do: "unknown"

  defp suggested_disposition("group", _element), do: "decomposed_children"

  defp suggested_disposition("shape", element) do
    cond do
      shape_text(element) != "" -> "native_semantic"
      exportable_shape?(element) -> "visual_fallback"
      accessibility_text(element) != "" -> "native_semantic"
      true -> "unsupported"
    end
  end

  defp suggested_disposition("table", element) do
    if table_content(element) != "" or accessibility_text(element) != "",
      do: "native_semantic",
      else: "unsupported"
  end

  defp suggested_disposition("image", element) do
    cond do
      valid_url?(get_in(element, ["image", "contentUrl"])) -> "native_media"
      accessibility_text(element) != "" -> "native_semantic"
      true -> "unsupported"
    end
  end

  defp suggested_disposition("video", element) do
    cond do
      linkable_video?(element["video"]) -> "linked_media"
      accessibility_text(element) != "" -> "native_semantic"
      true -> "unsupported"
    end
  end

  defp suggested_disposition("line", _element), do: "visual_fallback"

  defp suggested_disposition("word_art", element) do
    if word_art_text(element) != "" or accessibility_text(element) != "",
      do: "native_semantic",
      else: "unsupported"
  end

  defp suggested_disposition("sheets_chart", element) do
    cond do
      valid_url?(get_in(element, ["sheetsChart", "contentUrl"])) -> "visual_fallback"
      accessibility_text(element) != "" -> "native_semantic"
      true -> "unsupported"
    end
  end

  # Slides speaker spotlights and unknown/future element types currently have
  # no deterministic export path. Their metadata remains visible in the
  # review ledger, but the author must explicitly omit them until support is
  # implemented.
  defp suggested_disposition(type, _element) when type in ["speaker_spotlight", "unknown"],
    do: "unsupported"

  defp suggested_disposition(_type, _element), do: "unsupported"

  defp fidelity(source_type, element) do
    case suggested_disposition(source_type, element) do
      "decomposed_children" -> "decomposed"
      "native_semantic" -> "semantic"
      "native_media" -> "content"
      "linked_media" -> "linked"
      "visual_fallback" -> "rasterized"
      _unsupported -> "unsupported"
    end
  end

  defp review_required?(_type, _element), do: true

  # Empty layout placeholders describe the template rather than authored lesson
  # content. They remain inventoried, but are the only elements we can safely
  # mark decorative without asking the author.
  defp decorative?("shape", %{"shape" => %{"placeholder" => _}} = element),
    do: shape_text(element) == "" and accessibility_text(element) == ""

  defp decorative?(_type, _element), do: false

  defp meaningful?("group", _element), do: false
  defp meaningful?(type, element), do: not decorative?(type, element)

  defp summary("group", element) do
    %{"childCount" => length(group_children(element))}
    |> add_accessibility(element)
  end

  defp summary("shape", element) do
    shape = element["shape"] || %{}

    %{
      "shapeType" => bounded_text(shape["shapeType"]),
      "placeholderType" => bounded_text(get_in(shape, ["placeholder", "type"])),
      "text" => bounded_text(shape_text(element))
    }
    |> add_accessibility(element)
  end

  defp summary("table", element) do
    table = element["table"] || %{}
    rows = table["tableRows"] || []

    %{
      "rowCount" => numeric_count(table["rows"]) || length(rows),
      "columnCount" => numeric_count(table["columns"]) || maximum_column_count(rows),
      "text" => bounded_text(table_text(rows))
    }
    |> add_accessibility(element)
  end

  defp summary("image", element), do: add_accessibility(%{}, element)

  defp summary("video", element) do
    video = element["video"] || %{}

    %{
      "provider" => bounded_text(video["source"]),
      "providerMediaId" => bounded_text(video["id"])
    }
    |> add_accessibility(element)
  end

  defp summary("line", element) do
    line = element["line"] || %{}

    %{
      "lineCategory" => bounded_text(line["lineCategory"])
    }
    |> add_accessibility(element)
  end

  defp summary("word_art", element) do
    %{"text" => bounded_text(get_in(element, ["wordArt", "renderedText"]))}
    |> add_accessibility(element)
  end

  defp summary("sheets_chart", element) do
    chart = element["sheetsChart"] || %{}

    %{
      "chartId" => scalar_identifier(chart["chartId"]),
      "spreadsheetId" => bounded_text(chart["spreadsheetId"])
    }
    |> add_accessibility(element)
  end

  defp summary("speaker_spotlight", element), do: add_accessibility(%{}, element)

  defp summary("unknown", element) do
    known_structural_keys =
      element
      |> Map.keys()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 in ["objectId", "size", "transform", "title", "description"]))
      |> Enum.sort()
      |> Enum.take(20)

    %{"structuralKeys" => known_structural_keys}
    |> add_accessibility(element)
  end

  defp summary(_type, element), do: add_accessibility(%{}, element)

  defp add_accessibility(summary, element) do
    summary
    |> Map.put("title", bounded_text(element["title"]))
    |> Map.put("description", bounded_text(element["description"]))
    |> reject_empty_values()
  end

  defp geometry(element) do
    size = element["size"] || %{}
    transform = element["transform"] || %{}

    %{
      "width" => dimension(size["width"]),
      "height" => dimension(size["height"]),
      "transform" =>
        %{
          "scaleX" => finite_number(transform["scaleX"]),
          "scaleY" => finite_number(transform["scaleY"]),
          "shearX" => finite_number(transform["shearX"]),
          "shearY" => finite_number(transform["shearY"]),
          "translateX" => finite_number(transform["translateX"]),
          "translateY" => finite_number(transform["translateY"]),
          "unit" => bounded_text(transform["unit"])
        }
        |> reject_empty_values()
    }
    |> reject_empty_values()
  end

  defp dimension(%{"magnitude" => magnitude} = dimension) when is_number(magnitude) do
    %{
      "magnitude" => finite_number(magnitude),
      "unit" => bounded_text(dimension["unit"])
    }
    |> reject_empty_values()
  end

  defp dimension(_dimension), do: nil

  defp shape_text(%{"shape" => shape}) do
    shape
    |> Map.get("text", %{})
    |> text_from_text_elements()
  end

  defp shape_text(_element), do: ""

  defp table_text(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(fn row ->
      row
      |> Map.get("tableCells", [])
      |> Enum.map(fn cell -> text_from_text_elements(cell["text"] || %{}) end)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  defp table_text(_rows), do: ""

  defp table_content(%{"table" => table}) when is_map(table),
    do: table_text(table["tableRows"] || [])

  defp table_content(_element), do: ""

  defp word_art_text(element) do
    element
    |> get_in(["wordArt", "renderedText"])
    |> bounded_text()
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp exportable_shape?(element) do
    shape = element["shape"] || %{}

    visible_fill?(get_in(shape, ["shapeProperties", "shapeBackgroundFill"])) or
      visible_outline?(get_in(shape, ["shapeProperties", "outline"]))
  end

  defp visible_fill?(%{"propertyState" => "NOT_RENDERED"}), do: false
  defp visible_fill?(%{"solidFill" => _}), do: true
  defp visible_fill?(_fill), do: false

  defp visible_outline?(%{"propertyState" => "NOT_RENDERED"}), do: false
  defp visible_outline?(%{"outlineFill" => %{"solidFill" => _}}), do: true
  defp visible_outline?(_outline), do: false

  defp linkable_video?(%{"source" => "YOUTUBE", "id" => id}), do: valid_id?(id)
  defp linkable_video?(%{"source" => "DRIVE", "url" => url}), do: valid_url?(url)
  defp linkable_video?(%{"source" => "DRIVE", "id" => id}), do: valid_id?(id)
  defp linkable_video?(%{"url" => url}), do: valid_url?(url)
  defp linkable_video?(_video), do: false

  defp text_from_text_elements(%{"textElements" => elements}) when is_list(elements) do
    elements
    |> Enum.flat_map(fn
      %{"textRun" => %{"content" => content}} when is_binary(content) -> [content]
      %{"autoText" => %{"content" => content}} when is_binary(content) -> [content]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  defp text_from_text_elements(_text), do: ""

  defp accessibility_text(element) do
    [element["title"], element["description"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp maximum_column_count(rows) when is_list(rows) do
    rows
    |> Enum.map(fn row -> row |> Map.get("tableCells", []) |> length() end)
    |> Enum.max(fn -> 0 end)
  end

  defp maximum_column_count(_rows), do: 0

  defp numeric_count(value) when is_integer(value) and value >= 0, do: value
  defp numeric_count(_value), do: nil

  defp group_children(%{"elementGroup" => %{"children" => children}}) when is_list(children),
    do: children

  defp group_children(_element), do: []

  defp stable_slide_id(slide_id) when is_binary(slide_id) and slide_id != "", do: slide_id
  defp stable_slide_id(_slide_id), do: "slide:unknown"

  defp stable_object_id(element, slide_id, path, source_type) do
    case element do
      %{"objectId" => object_id} when is_binary(object_id) and object_id != "" ->
        object_id

      _ ->
        "#{slide_id}:element:#{path_string(path)}:#{source_type}"
    end
  end

  defp valid_id?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_url?(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp valid_url?(_value), do: false

  defp path_string(path), do: Enum.join(path, ".")

  defp bounded_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @summary_text_limit)
  end

  defp bounded_text(_value), do: nil

  defp scalar_identifier(value) when is_binary(value), do: bounded_text(value)
  defp scalar_identifier(value) when is_integer(value), do: value
  defp scalar_identifier(_value), do: nil

  defp finite_number(value) when is_integer(value), do: value

  defp finite_number(value) when is_float(value) do
    if value == value and value not in [:infinity, :neg_infinity], do: value
  end

  defp finite_number(_value), do: nil

  defp reject_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, empty} when empty == %{} -> true
      {_key, empty} when empty == [] -> true
      _ -> false
    end)
  end
end
