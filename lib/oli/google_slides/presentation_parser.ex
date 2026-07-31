defmodule Oli.GoogleSlides.PresentationParser do
  @moduledoc """
  Parses raw Google Slides API JSON into intermediate slide structs.
  """

  alias Oli.GoogleDocs.SlidesClient
  alias Oli.GoogleSlides.GraphicExporter

  defmodule Slide do
    @moduledoc false
    defstruct [
      :index,
      :object_id,
      :title,
      :title_from_placeholder,
      :paragraphs,
      :list_items,
      :content_blocks,
      :images,
      :raw_elements,
      :notes_text
    ]
  end

  defmodule ImageRef do
    @moduledoc false
    defstruct [:object_id, :content_url, :width, :height, :inline_bytes, :inline_content_type]
  end

  @ordered_glyph_types ~w(DECIMAL ZERO_DECIMAL UPPER_ALPHA ALPHA UPPER_ROMAN ROMAN)

  @spec parse(map(), keyword()) :: {:ok, [Slide.t()], [map()]}
  def parse(presentation_json, opts \\ []) do
    access_token = Keyword.get(opts, :access_token)
    warnings = []

    slides =
      presentation_json
      |> SlidesClient.get_slides()
      |> Enum.with_index(1)
      |> Enum.map(fn {slide, index} ->
        build_slide(slide, index, presentation_json, access_token)
      end)

    {:ok, slides, warnings}
  end

  defp build_slide(slide, index, presentation_json, access_token) do
    elements = Map.get(slide, "pageElements", [])
    {title, title_from_placeholder, content_blocks} = extract_content_blocks(elements)
    {paragraphs, list_items} = derive_text_fields(content_blocks)
    images = images_from_blocks(content_blocks)

    notes_text =
      case access_token do
        token when is_binary(token) ->
          case SlidesClient.get_speaker_notes_text(slide, presentation_json, token) do
            {:ok, text} -> text
            _ -> ""
          end

        _ ->
          ""
      end

    %Slide{
      index: index,
      object_id:
        stable_slide_id(
          Map.get(slide, "objectId"),
          Map.get(presentation_json, "presentationId"),
          index
        ),
      title: title || "",
      title_from_placeholder: title_from_placeholder,
      paragraphs: paragraphs,
      list_items: list_items,
      content_blocks: content_blocks,
      images: images,
      raw_elements: elements,
      notes_text: notes_text
    }
  end

  defp extract_content_blocks(elements) do
    flattened = flatten_page_elements(elements)

    {title, title_from_placeholder, blocks} =
      Enum.reduce(flattened, {nil, false, []}, fn element, {title, from_ph, blocks} ->
        case content_from_element(element, title, from_ph) do
          {:title, text, from_ph} ->
            {text, from_ph, blocks}

          {:blocks, new_blocks, title, from_ph} ->
            {title, from_ph, blocks ++ new_blocks}

          {:skip, title, from_ph} ->
            {title, from_ph, blocks}
        end
      end)

    {title || "", title_from_placeholder, blocks}
  end

  defp content_from_element(
         %{"shape" => %{"placeholder" => %{"type" => "TITLE"}, "text" => text}} = _element,
         title,
         from_ph
       ) do
    case parse_shape_content(text) do
      [] ->
        {:skip, title, from_ph}

      blocks ->
        text_content = blocks_to_plain_text(blocks)

        if title in [nil, ""] do
          {:title, text_content, true}
        else
          {:blocks, blocks, title, from_ph}
        end
    end
  end

  defp content_from_element(%{"shape" => shape} = element, title, from_ph) do
    cond do
      shape_has_text?(shape) ->
        case parse_shape_content(Map.get(shape, "text")) do
          [] -> {:skip, title, from_ph}
          blocks -> {:blocks, attach_object_id(blocks, element), title, from_ph}
        end

      layout_placeholder_shape?(shape) ->
        {:skip, title, from_ph}

      exportable_decorative_shape?(shape) ->
        {:blocks, [shape_graphic_block(element, shape)], title, from_ph}

      true ->
        accessibility_block(element, title, from_ph)
    end
  end

  defp content_from_element(%{"table" => table} = element, title, from_ph) do
    case extract_table_text(table) do
      "" ->
        accessibility_block(element, title, from_ph)

      content ->
        {:blocks, attach_object_id([%{type: "table", text: content}], element), title, from_ph}
    end
  end

  defp content_from_element(
         %{"objectId" => object_id, "image" => %{"contentUrl" => url}} = element,
         title,
         from_ph
       )
       when is_binary(url) and url != "" do
    size = Map.get(element, "size", %{})
    transform = Map.get(element, "transform", %{})

    ref =
      %ImageRef{
        object_id: object_id,
        content_url: url,
        width: size_value(size, "width"),
        height: size_value(size, "height")
      }
      |> Map.put(:transform, transform)

    {:blocks, [%{type: "image", ref: ref}], title, from_ph}
  end

  defp content_from_element(
         %{"objectId" => object_id, "sheetsChart" => %{"contentUrl" => url}} = element,
         title,
         from_ph
       )
       when is_binary(url) and url != "" do
    size = Map.get(element, "size", %{})

    ref =
      %ImageRef{
        object_id: object_id,
        content_url: url,
        width: size_value(size, "width"),
        height: size_value(size, "height")
      }

    {:blocks, [%{type: "image", ref: ref, alt: "Chart"}], title, from_ph}
  end

  defp content_from_element(
         %{"objectId" => object_id, "video" => video} = element,
         title,
         from_ph
       ) do
    case video_src(video) do
      src when is_binary(src) ->
        size = Map.get(element, "size", %{})

        block = %{
          type: "video",
          object_id: object_id,
          src: src,
          provider: Map.get(video, "source"),
          provider_media_id: Map.get(video, "id"),
          alt: Map.get(element, "description") || Map.get(element, "title") || "Slide video",
          height: video_height(size)
        }

        {:blocks, [block], title, from_ph}

      _ ->
        accessibility_block(element, title, from_ph)
    end
  end

  defp content_from_element(%{"wordArt" => %{"renderedText" => text}} = element, title, from_ph)
       when is_binary(text) and text != "" do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:skip, title, from_ph}
    else
      {:blocks, attach_object_id([%{type: "word_art", text: trimmed}], element), title, from_ph}
    end
  end

  defp content_from_element(%{"objectId" => object_id, "line" => line} = element, title, from_ph) do
    svg = GraphicExporter.line_svg(element, line)
    size = Map.get(element, "size", %{})

    ref = %ImageRef{
      object_id: object_id,
      inline_bytes: svg,
      inline_content_type: "image/svg+xml",
      width: size_value(size, "width"),
      height: size_value(size, "height")
    }

    {:blocks, [%{type: "image", ref: ref, alt: "Line"}], title, from_ph}
  end

  defp content_from_element(element, title, from_ph),
    do: accessibility_block(element, title, from_ph)

  defp flatten_page_elements(elements) when is_list(elements) do
    Enum.flat_map(elements, fn
      %{"elementGroup" => %{"children" => children}} when is_list(children) ->
        flatten_page_elements(children)

      element ->
        [element]
    end)
  end

  defp flatten_page_elements(_), do: []

  defp parse_shape_content(%{"textElements" => _} = text) do
    paragraphs = paragraphs_from_text_elements(text)
    lists_map = Map.get(text, "lists", %{})

    blocks =
      paragraphs
      |> paragraphs_to_blocks(lists_map)

    case blocks do
      [] ->
        case flatten_text_runs(text) do
          "" -> []
          flat -> blocks_from_plain_text(flat)
        end

      blocks ->
        blocks
    end
  end

  defp parse_shape_content(_), do: []

  defp paragraphs_from_text_elements(%{"textElements" => elements}) when is_list(elements) do
    {paragraphs, current} =
      Enum.reduce(elements, {[], nil}, fn element, {acc, current} ->
        cond do
          Map.has_key?(element, "paragraphMarker") ->
            acc = if current, do: acc ++ [finalize_paragraph(current)], else: acc
            marker = element["paragraphMarker"]

            {acc,
             %{
               bullet: Map.get(marker, "bullet"),
               style: Map.get(marker, "style", %{}),
               content: ""
             }}

          Map.has_key?(element, "textRun") ->
            content = get_in(element, ["textRun", "content"]) || ""

            case current do
              nil -> {acc, %{bullet: nil, style: %{}, content: content}}
              cur -> {acc, %{cur | content: cur.content <> content}}
            end

          true ->
            {acc, current}
        end
      end)

    paragraphs = if current, do: paragraphs ++ [finalize_paragraph(current)], else: paragraphs

    Enum.map(paragraphs, fn para ->
      %{
        content: para.content,
        bullet: para.bullet,
        heading_tag: heading_tag_from_style(para.style)
      }
    end)
  end

  defp paragraphs_from_text_elements(_), do: []

  defp finalize_paragraph(%{content: content} = para) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_trailing("\n")

    Map.put(para, :content, trimmed)
  end

  defp paragraphs_to_blocks(paragraphs, lists_map) do
    paragraphs
    |> Enum.reduce([], fn para, acc ->
      cond do
        para.bullet && para.content != "" ->
          list_id = Map.get(para.bullet, "listId")
          list_type = list_type_for(para.bullet, lists_map)

          case acc do
            [%{type: "list", list_id: ^list_id} = list | rest] ->
              [%{list | items: list.items ++ [para.content]} | rest]

            _ ->
              [
                %{
                  type: "list",
                  list_type: list_type,
                  list_id: list_id,
                  items: [para.content]
                }
                | acc
              ]
          end

        para.heading_tag && para.content != "" ->
          [%{type: "heading", tag: para.heading_tag, text: para.content} | acc]

        para.content != "" ->
          [%{type: "paragraph", text: para.content} | acc]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp blocks_from_plain_text(text) do
    {paragraphs, list_items} = split_list_items(text)

    list_blocks =
      if list_items == [] do
        []
      else
        [%{type: "list", list_type: "ul", list_id: nil, items: list_items}]
      end

    paragraph_blocks = Enum.map(paragraphs, &%{type: "paragraph", text: &1})
    paragraph_blocks ++ list_blocks
  end

  defp split_list_items(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {non_list, list} =
      Enum.split_with(lines, fn line ->
        not Regex.match?(~r/^([•\-\*]|\d+\.)\s+/, line)
      end)

    list_items =
      list
      |> Enum.map(fn line ->
        line
        |> String.replace(~r/^([•\-\*]|\d+\.)\s+/, "")
        |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    paragraphs = if non_list == [], do: [], else: [Enum.join(non_list, "\n")]
    {paragraphs, list_items}
  end

  defp list_type_for(%{"listId" => list_id}, lists) do
    case get_in(lists, [list_id, "nestingLevel", "0", "glyphFormat", "type"]) do
      type when type in @ordered_glyph_types -> "ol"
      _ -> "ul"
    end
  end

  defp list_type_for(_, _), do: "ul"

  defp heading_tag_from_style(%{"namedStyleType" => style_type}) do
    case style_type do
      "TITLE" -> "h1"
      "SUBTITLE" -> "h2"
      "HEADING_1" -> "h3"
      "HEADING_2" -> "h4"
      "HEADING_3" -> "h5"
      "HEADING_4" -> "h6"
      "HEADING_5" -> "h6"
      "HEADING_6" -> "h6"
      _ -> nil
    end
  end

  defp heading_tag_from_style(_), do: nil

  defp flatten_text_runs(%{"textElements" => elements}) when is_list(elements) do
    elements
    |> Enum.flat_map(fn
      %{"textRun" => %{"content" => content}} when is_binary(content) -> [content]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  defp flatten_text_runs(_), do: ""

  defp extract_table_text(%{"tableRows" => rows}) when is_list(rows) do
    rows
    |> Enum.map(fn
      %{"tableCells" => cells} ->
        cells
        |> Enum.map(fn
          %{"text" => text} -> flatten_text_runs(text)
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" | ")

      _ ->
        ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_table_text(_), do: ""

  defp derive_text_fields(content_blocks) do
    Enum.reduce(content_blocks, {[], []}, fn block, {paragraphs, list_items} ->
      case block do
        %{type: "paragraph", text: text} ->
          {paragraphs ++ [text], list_items}

        %{type: "heading", text: text} ->
          {paragraphs ++ [text], list_items}

        %{type: "table", text: text} ->
          {paragraphs ++ [text], list_items}

        %{type: "list", items: items} ->
          {paragraphs, list_items ++ items}

        %{type: "word_art", text: text} ->
          {paragraphs ++ [text], list_items}

        %{type: "video", alt: alt} when is_binary(alt) ->
          {paragraphs ++ [alt], list_items}

        _ ->
          {paragraphs, list_items}
      end
    end)
  end

  defp images_from_blocks(content_blocks) do
    content_blocks
    |> Enum.flat_map(fn
      %{type: "image", ref: ref} -> [ref]
      _ -> []
    end)
  end

  defp shape_has_text?(shape) do
    case get_in(shape, ["text", "textElements"]) do
      elements when is_list(elements) ->
        elements
        |> flatten_text_runs_from_elements()
        |> String.trim()
        |> case do
          "" -> false
          _ -> true
        end

      _ ->
        false
    end
  end

  defp flatten_text_runs_from_elements(elements) do
    elements
    |> Enum.flat_map(fn
      %{"textRun" => %{"content" => content}} when is_binary(content) -> [content]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp layout_placeholder_shape?(shape) do
    Map.has_key?(shape, "placeholder")
  end

  defp exportable_decorative_shape?(shape) do
    shape_has_visible_fill?(shape) or shape_has_visible_outline?(shape)
  end

  defp shape_has_visible_fill?(shape) do
    case get_in(shape, ["shapeProperties", "shapeBackgroundFill"]) do
      %{"propertyState" => "NOT_RENDERED"} ->
        false

      %{"solidFill" => _} ->
        true

      _ ->
        false
    end
  end

  defp shape_has_visible_outline?(shape) do
    case get_in(shape, ["shapeProperties", "outline"]) do
      %{"propertyState" => "NOT_RENDERED"} ->
        false

      %{"outlineFill" => %{"solidFill" => _}} ->
        true

      _ ->
        false
    end
  end

  defp shape_graphic_block(element, shape) do
    svg = GraphicExporter.shape_svg(element, shape)
    object_id = Map.get(element, "objectId") || "shape-#{:erlang.phash2(svg)}"
    size = Map.get(element, "size", %{})

    ref = %ImageRef{
      object_id: object_id,
      inline_bytes: svg,
      inline_content_type: "image/svg+xml",
      width: size_value(size, "width"),
      height: size_value(size, "height")
    }

    %{type: "image", ref: ref, alt: Map.get(element, "description") || "Shape"}
  end

  defp accessibility_block(element, title, from_ph) do
    text =
      [Map.get(element, "title"), Map.get(element, "description")]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" — ")

    if text == "" do
      {:skip, title, from_ph}
    else
      {:blocks, attach_object_id([%{type: "paragraph", text: text}], element), title, from_ph}
    end
  end

  defp attach_object_id(blocks, %{"objectId" => object_id})
       when is_list(blocks) and is_binary(object_id) and object_id != "" do
    Enum.map(blocks, &Map.put(&1, :object_id, object_id))
  end

  defp attach_object_id(blocks, _element), do: blocks

  defp video_src(%{"source" => "YOUTUBE", "id" => id}) when is_binary(id) and id != "" do
    "https://www.youtube.com/watch?v=#{id}"
  end

  defp video_src(%{"source" => "DRIVE", "url" => url}) when is_binary(url) and url != "" do
    url
  end

  defp video_src(%{"source" => "DRIVE", "id" => id}) when is_binary(id) and id != "" do
    "https://drive.google.com/file/d/#{id}/preview"
  end

  defp video_src(%{"url" => url}) when is_binary(url) and url != "" do
    url
  end

  defp video_src(_), do: nil

  defp video_height(size) do
    case size_value(size, "height") do
      height when is_number(height) and height > 0 ->
        height
        |> Kernel./(9525.0)
        |> min(360.0)
        |> max(180.0)
        |> trunc()

      _ ->
        280
    end
  end

  defp blocks_to_plain_text(blocks) do
    blocks
    |> Enum.map(fn
      %{type: "paragraph", text: text} -> text
      %{type: "heading", text: text} -> text
      %{type: "table", text: text} -> text
      %{type: "list", items: items} -> Enum.join(items, "\n")
      %{type: "word_art", text: text} -> text
      %{type: "video", alt: alt} when is_binary(alt) -> alt
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp size_value(size, dimension) when dimension in ["width", "height"] do
    case Map.get(size, dimension) do
      %{"magnitude" => magnitude} when is_number(magnitude) -> magnitude
      _ -> nil
    end
  end

  defp size_value(_, _), do: nil

  defp stable_slide_id(object_id, _presentation_id, _index)
       when is_binary(object_id) and object_id != "",
       do: object_id

  defp stable_slide_id(_object_id, presentation_id, index)
       when is_binary(presentation_id) and presentation_id != "",
       do: "#{presentation_id}:slide:#{index}"

  defp stable_slide_id(_object_id, _presentation_id, index), do: "slide:#{index}"
end
