defmodule Oli.OpenStax.CourseImport.SourceASTRenderer do
  @moduledoc """
  Typed renderer from the normalized OpenStax source AST to native Torus/Janus
  elements. It never serializes source nodes through Markdown.
  """

  alias Oli.GoogleSlides.Adaptive.PartBuilders
  alias Oli.OpenStax.CourseImport.ExternalMediaResolver

  @text_types ~w(p h1 h2 h3 h4 h5 h6 ul ol table blockquote code formula)

  @spec render([map()] | map(), keyword()) :: {:ok, [map()]} | {:attention, [map()]}
  def render(nodes, opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :basic)

    nodes
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {node, index}, {:ok, rendered} ->
      case render_node(node, index, mode, opts) do
        {:ok, values} -> {:cont, {:ok, rendered ++ List.wrap(values)}}
        {:attention, findings} -> {:halt, {:attention, List.wrap(findings)}}
      end
    end)
  end

  defp render_node(%{"type" => "p"} = node, index, mode, opts) do
    links = supported_links(node)

    with {:ok, media} <- render_external_links(links, index, mode, opts) do
      remaining = remove_links(node, MapSet.new(Enum.map(links, & &1["href"])))

      leading =
        if meaningful?(remaining), do: render_native(remaining, index, mode, opts), else: []

      {:ok, List.wrap(leading) ++ media}
    end
  end

  defp render_node(%{"type" => type} = node, index, mode, opts)
       when type in ["video", "audio"] do
    metadata = Map.merge(source_context(opts), node)

    case ExternalMediaResolver.resolve(node["src"] || "", metadata, opts) do
      {:ok, resolved} -> {:ok, media_elements(resolved, index, mode, opts)}
      {:attention, finding} -> {:attention, [finding]}
      :unsupported -> {:ok, render_native(node, index, mode, opts)}
    end
  end

  defp render_node(node, index, mode, opts),
    do: {:ok, List.wrap(render_native(node, index, mode, opts))}

  defp render_external_links(links, base_index, mode, opts) do
    links
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {link, link_index}, {:ok, rendered} ->
      metadata =
        source_context(opts)
        |> Map.merge(%{"title" => inline_text(link), "label" => inline_text(link)})

      case ExternalMediaResolver.resolve(link["href"], metadata, opts) do
        {:ok, resolved} ->
          index = base_index * 100 + link_index
          {:cont, {:ok, rendered ++ media_elements(resolved, index, mode, opts)}}

        {:attention, finding} ->
          {:halt, {:attention, [finding]}}

        :unsupported ->
          {:cont, {:ok, rendered}}
      end
    end)
  end

  defp render_native(node, index, :basic, opts) when is_map(node) do
    node
    |> stringify_keys()
    |> resolve_image(opts)
    |> stabilize("#{stable_key(opts)}:#{index}")
  end

  defp render_native(%{"type" => "img"} = node, index, :advanced, opts) do
    node = resolve_image(node, opts)

    node["src"]
    |> PartBuilders.image_part(
      y: y_position(index, opts),
      height: Keyword.get(opts, :media_height, 280),
      alt: node["alt"] || "Source image"
    )
    |> Map.put("id", stable_id("image", "#{stable_key(opts)}:#{index}"))
  end

  defp render_native(%{"type" => type} = node, index, :advanced, opts)
       when type in @text_types do
    normalized =
      node
      |> stringify_keys()
      |> normalize_heading()
      |> stabilize("#{stable_key(opts)}:#{index}")

    text_flow([normalized], index, opts)
  end

  defp render_native(node, index, :advanced, opts) when is_map(node) do
    normalized = node |> stringify_keys() |> stabilize("#{stable_key(opts)}:#{index}")
    text_flow([normalized], index, opts)
  end

  defp render_native(_node, _index, _mode, _opts), do: []

  defp media_elements(resolved, index, :basic, opts) do
    video = %{
      "id" => stable_id("video", "#{stable_key(opts)}:#{index}"),
      "type" => "video",
      "src" => [%{"url" => resolved.src, "contenttype" => content_type(resolved.src)}],
      "captions" => resolved.subtitles,
      "alt" => resolved.alt,
      "children" => [%{"text" => ""}]
    }

    [video | basic_fallback(resolved, index, opts)]
  end

  defp media_elements(resolved, index, :advanced, opts) do
    video =
      resolved.src
      |> PartBuilders.video_part(
        y: y_position(index, opts),
        height: Keyword.get(opts, :media_height, 280),
        alt: resolved.alt,
        subtitles: resolved.subtitles
      )
      |> Map.put("id", stable_id("video", "#{stable_key(opts)}:#{index}"))

    [video, advanced_fallback(resolved, index, opts)]
  end

  defp basic_fallback(resolved, index, opts) do
    link = %{
      "type" => "a",
      "href" => resolved.fallback["url"],
      "linkType" => "url",
      "target" => "_blank",
      "children" => [%{"text" => resolved.fallback["label"]}]
    }

    children =
      [%{"text" => "Accessible fallback: "}, link] ++
        if(is_binary(resolved.transcript),
          do: [%{"text" => " Transcript: #{resolved.transcript}"}],
          else: []
        )

    [
      %{
        "id" => stable_id("media-fallback", "#{stable_key(opts)}:#{index}"),
        "type" => "p",
        "children" => children
      }
    ]
  end

  defp advanced_fallback(resolved, index, opts) do
    children =
      [
        %{"text" => "Accessible fallback: "},
        %{
          "type" => "a",
          "href" => resolved.fallback["url"],
          "linkType" => "url",
          "target" => "_blank",
          "children" => [%{"text" => resolved.fallback["label"]}]
        }
      ] ++
        if(is_binary(resolved.transcript),
          do: [%{"text" => " Transcript: #{resolved.transcript}"}],
          else: []
        )

    text_flow(
      [%{"type" => "p", "children" => children}],
      1,
      Keyword.put(opts, :y, y_position(index, opts) + Keyword.get(opts, :media_height, 280) + 16)
    )
    |> Map.put("id", stable_id("media-fallback", "#{stable_key(opts)}:#{index}"))
  end

  defp text_flow(nodes, index, opts) do
    %{
      "id" => stable_id("source-flow", "#{stable_key(opts)}:#{index}"),
      "type" => "janus-text-flow",
      "custom" => %{
        "customCssClass" => "",
        "height" => Keyword.get(opts, :text_height, 96),
        "maxScore" => 1,
        "nodes" => nodes,
        "overrideHeight" => false,
        "overrideWidth" => true,
        "palette" => %{
          "backgroundColor" => "rgba(255,255,255,0)",
          "borderColor" => "rgba(255,255,255,0)",
          "borderRadius" => 0,
          "borderStyle" => "solid",
          "borderWidth" => "0.1px",
          "useHtmlProps" => true
        },
        "requiresManualGrading" => false,
        "visible" => true,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y_position(index, opts),
        "z" => 0
      }
    }
  end

  defp supported_links(node) do
    node
    |> descendants()
    |> Enum.filter(fn
      %{"type" => "a", "href" => href} -> ExternalMediaResolver.supported?(href)
      _node -> false
    end)
    |> Enum.uniq_by(& &1["href"])
  end

  defp descendants(%{"children" => children} = node),
    do: [node | Enum.flat_map(List.wrap(children), &descendants/1)]

  defp descendants(node) when is_map(node), do: [node]
  defp descendants(_node), do: []

  defp remove_links(%{"type" => "a", "href" => href}, href_set) do
    if MapSet.member?(href_set, href),
      do: %{"text" => ""},
      else: %{"type" => "a", "href" => href, "children" => [%{"text" => href}]}
  end

  defp remove_links(%{"children" => children} = node, href_set) do
    normalized =
      children
      |> List.wrap()
      |> Enum.map(&remove_links(&1, href_set))
      |> Enum.reject(&is_nil/1)

    Map.put(node, "children", normalized)
  end

  defp remove_links(node, _href_set), do: node

  defp meaningful?(node), do: node |> inline_text() |> String.trim() != ""

  defp inline_text(%{"text" => text}) when is_binary(text), do: text

  defp inline_text(%{"children" => children}),
    do: Enum.map_join(List.wrap(children), "", &inline_text/1)

  defp inline_text(_node), do: ""

  defp resolve_image(%{"type" => "img", "src" => src} = node, opts) do
    case Keyword.get(opts, :media_lookup, %{})[src] do
      nil -> node
      resolved -> Map.merge(node, stringify_keys(resolved))
    end
  end

  defp resolve_image(node, _opts), do: node

  defp normalize_heading(%{"type" => type} = node) when type in ["h1", "h2"],
    do: Map.put(node, "type", "h3")

  defp normalize_heading(%{"type" => "h3"} = node), do: Map.put(node, "type", "h4")
  defp normalize_heading(%{"type" => "h4"} = node), do: Map.put(node, "type", "h5")

  defp normalize_heading(%{"type" => type} = node) when type in ["h5", "h6"],
    do: Map.put(node, "type", "h6")

  defp normalize_heading(node), do: node

  defp stabilize(value, key) when is_map(value) do
    value = stringify_keys(value)

    value =
      if is_binary(value["type"]) and not Map.has_key?(value, "text"),
        do: Map.put_new(value, "id", stable_id(value["type"], key)),
        else: value

    case value["children"] do
      children when is_list(children) ->
        children =
          children
          |> Enum.with_index(1)
          |> Enum.map(fn {child, index} -> stabilize(child, "#{key}:#{index}") end)

        Map.put(value, "children", children)

      _children ->
        value
    end
  end

  defp stabilize(value, _key), do: value

  defp source_context(opts), do: Keyword.get(opts, :source_context, %{}) |> stringify_keys()

  defp stable_key(opts), do: Keyword.get(opts, :stable_key, "openstax-source")

  defp y_position(index, opts) do
    base = Keyword.get(opts, :y, 0)
    gap = Keyword.get(opts, :vertical_gap, 112)
    base + (index - 1) * gap
  end

  defp stable_id(prefix, material) do
    digest = :crypto.hash(:sha256, to_string(material)) |> Base.encode16(case: :lower)
    "#{prefix}-#{binary_part(digest, 0, 20)}"
  end

  defp content_type(url) do
    path = URI.parse(url).path |> to_string() |> String.downcase()

    cond do
      String.ends_with?(path, ".webm") -> "video/webm"
      String.ends_with?(path, ".ogg") -> "video/ogg"
      true -> "video/mp4"
    end
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp stringify_keys(value), do: value
end
