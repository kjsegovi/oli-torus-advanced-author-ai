defmodule Oli.OpenStax.CourseImport.SourceAST do
  @moduledoc """
  Converts canonical OpenStax HTML into a lossless, provider-neutral subset of
  Torus page content. The extractor owns source wording; later AI stages may
  organize these nodes but must never rewrite or discard them.
  """

  @ignored_tags ~w(script style nav footer header button noscript svg)
  @inline_tags ~w(a abbr b cite code del em i kbd mark q s samp small span strong sub sup time u var)

  @spec blocks(term(), String.t()) :: [map()]
  def blocks(node, page_url) do
    node
    |> List.wrap()
    |> Enum.flat_map(&block_node(&1, page_url))
  end

  @spec equation?(String.t(), list()) :: boolean()
  def equation?(tag, attributes) do
    tag == "math" or attribute(attributes, "data-type") in ["equation", "formula"] or
      class_member?(attributes, "equation") or class_member?(attributes, "os-equation") or
      class_member?(attributes, "math")
  end

  @spec equation_source(term()) :: String.t()
  def equation_source(node), do: equation_payload(node)["src"] || ""

  @spec equation_payload(term()) :: map()
  def equation_payload({tag, attributes, _children} = node) do
    explicit_latex =
      attribute(attributes, "data-latex") ||
        attribute(attributes, "alttext") ||
        attribute(attributes, "alt") ||
        annotation_source(node)

    cond do
      present?(explicit_latex) ->
        %{"subtype" => "latex", "src" => String.trim(explicit_latex)}

      math = first_math_node(node, tag) ->
        %{"subtype" => "mathml", "src" => Floki.raw_html(math)}

      true ->
        %{"subtype" => "latex", "src" => node |> Floki.text() |> normalize_text()}
    end
  end

  def equation_payload(_node), do: %{"subtype" => "latex", "src" => ""}

  defp block_node(text, _page_url) when is_binary(text) do
    case normalize_text(text) do
      "" -> []
      value -> [paragraph([%{"text" => value}])]
    end
  end

  defp block_node({tag, attributes, children} = node, page_url) do
    cond do
      tag in @ignored_tags ->
        []

      equation?(tag, attributes) ->
        case equation_payload(node) do
          %{"src" => ""} ->
            []

          %{"src" => source, "subtype" => subtype} ->
            [
              %{
                "type" => "formula",
                "subtype" => subtype,
                "src" => source,
                "children" => [%{"text" => ""}]
              }
            ]
        end

      tag in ~w(h1 h2 h3 h4 h5 h6) ->
        [text_container(tag, inline_nodes(children, page_url))]

      tag == "p" ->
        case inline_nodes(children, page_url) do
          [] -> []
          inline -> [paragraph(inline)]
        end

      tag in ~w(ul ol) ->
        [list_node(tag, children, page_url)]

      tag == "table" ->
        [table_node(node, page_url)]

      tag == "pre" ->
        case normalize_text(Floki.text(node)) do
          "" ->
            []

          code ->
            [
              %{
                "type" => "code",
                "language" => code_language(node),
                "code" => code,
                "children" => [%{"text" => ""}]
              }
            ]
        end

      tag == "blockquote" ->
        [text_container("blockquote", [paragraph(inline_or_text(children, page_url))])]

      tag == "figure" or attribute(attributes, "data-type") == "figure" ->
        figure_nodes(node, page_url)

      tag in ~w(img picture video audio) ->
        media_nodes(node, page_url)

      tag == "figcaption" ->
        [text_container("p", inline_or_text(children, page_url))]

      tag in @inline_tags ->
        case inline_node(node, page_url, %{}) do
          [] -> []
          inline -> [paragraph(inline)]
        end

      true ->
        blocks(children, page_url)
    end
  end

  defp block_node(_node, _page_url), do: []

  defp paragraph(children), do: %{"type" => "p", "children" => ensure_children(children)}

  defp text_container(type, children),
    do: %{"type" => type, "children" => ensure_children(children)}

  defp inline_or_text(children, page_url) do
    case inline_nodes(children, page_url) do
      [] -> [%{"text" => normalize_text(Floki.text(children))}]
      nodes -> nodes
    end
  end

  defp inline_nodes(children, page_url) do
    children
    |> List.wrap()
    |> Enum.flat_map(&inline_node(&1, page_url, %{}))
    |> merge_adjacent_text()
    |> Enum.reject(&empty_text?/1)
  end

  defp inline_node(text, _page_url, marks) when is_binary(text) do
    case normalize_inline_text(text) do
      "" -> []
      value -> [Map.merge(%{"text" => value}, marks)]
    end
  end

  defp inline_node({tag, attributes, children} = node, page_url, marks) do
    cond do
      equation?(tag, attributes) ->
        case equation_payload(node) do
          %{"src" => ""} ->
            []

          %{"src" => source, "subtype" => subtype} ->
            [
              %{
                "type" => "formula_inline",
                "subtype" => subtype,
                "src" => source,
                "children" => [%{"text" => ""}]
              }
            ]
        end

      tag == "br" ->
        [%{"text" => "\n"}]

      tag == "a" ->
        case safe_link(attribute(attributes, "href"), page_url) do
          nil ->
            inline_children(children, page_url, marks)

          href ->
            [
              %{
                "type" => "a",
                "href" => href,
                "linkType" => "url",
                "target" => "_blank",
                "children" => ensure_children(inline_children(children, page_url, marks))
              }
            ]
        end

      tag in ~w(strong b) ->
        inline_children(children, page_url, Map.put(marks, "bold", true))

      tag in ~w(em i) ->
        inline_children(children, page_url, Map.put(marks, "italic", true))

      tag == "code" ->
        inline_children(children, page_url, Map.put(marks, "code", true))

      tag == "u" ->
        inline_children(children, page_url, Map.put(marks, "underline", true))

      tag in ~w(s del) ->
        inline_children(children, page_url, Map.put(marks, "strikethrough", true))

      tag == "sub" ->
        inline_children(children, page_url, Map.put(marks, "subscript", true))

      tag == "sup" ->
        inline_children(children, page_url, Map.put(marks, "superscript", true))

      tag in @inline_tags ->
        inline_children(children, page_url, marks)

      true ->
        inline_children(children, page_url, marks)
    end
  end

  defp inline_node(_node, _page_url, _marks), do: []

  defp inline_children(children, page_url, marks),
    do: children |> List.wrap() |> Enum.flat_map(&inline_node(&1, page_url, marks))

  defp list_node(type, children, page_url) do
    items =
      children
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.flat_map(fn {"li", _attributes, item_children} ->
        {nested, direct} =
          Enum.split_with(item_children, &match?({tag, _, _} when tag in ["ul", "ol"], &1))

        direct_children = inline_nodes(direct, page_url)

        [
          %{"type" => "li", "children" => ensure_children(direct_children)}
          | Enum.map(nested, &list_node(elem(&1, 0), elem(&1, 2), page_url))
        ]
      end)

    %{"type" => type, "children" => items}
  end

  defp table_node(node, page_url) do
    rows =
      node
      |> Floki.find("tr")
      |> Enum.map(fn row ->
        cells =
          row
          |> Floki.find("th, td")
          |> Enum.map(fn {type, _attributes, children} ->
            %{"type" => type, "children" => [paragraph(inline_or_text(children, page_url))]}
          end)

        %{"type" => "tr", "children" => cells}
      end)

    %{"type" => "table", "children" => rows}
  end

  defp figure_nodes(node, page_url) do
    media = node |> Floki.find("img, video, audio") |> Enum.flat_map(&media_nodes(&1, page_url))
    caption = node |> Floki.find("figcaption") |> Enum.flat_map(&block_node(&1, page_url))
    media ++ caption
  end

  defp media_nodes({tag, attributes, _children} = node, page_url)
       when tag in ~w(img video audio) do
    src =
      attribute(attributes, "src") ||
        node
        |> Floki.find("source[src]")
        |> List.first()
        |> case do
          {_tag, attrs, _children} -> attribute(attrs, "src")
          _ -> nil
        end

    case safe_media(src, page_url) do
      nil ->
        []

      url when tag == "img" ->
        [
          %{
            "type" => "img",
            "src" => url,
            "alt" => attribute(attributes, "alt") || "",
            "children" => [%{"text" => ""}]
          }
        ]

      url ->
        [%{"type" => tag, "src" => url, "children" => [%{"text" => ""}]}]
    end
  end

  defp media_nodes({"picture", _attributes, children}, page_url), do: blocks(children, page_url)
  defp media_nodes(_node, _page_url), do: []

  defp annotation_source(node) do
    node
    |> Floki.find(
      "annotation[encoding='application/x-tex'], annotation[encoding='application/tex']"
    )
    |> List.first()
    |> case do
      nil -> nil
      annotation -> normalize_text(Floki.text(annotation))
    end
  end

  defp first_math_node(node, "math"), do: node

  defp first_math_node(node, _tag) do
    node
    |> Floki.find("math")
    |> List.first()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp code_language(node) do
    node
    |> Floki.find("code")
    |> List.first()
    |> case do
      {_tag, attrs, _children} ->
        attrs
        |> attribute("class")
        |> to_string()
        |> String.split()
        |> Enum.find_value("text", fn
          "language-" <> language -> language
          _ -> nil
        end)

      _ ->
        "text"
    end
  end

  defp safe_link(nil, _page_url), do: nil

  defp safe_link(href, page_url) do
    case URI.merge(page_url, String.trim(href)) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri when is_binary(host) ->
        URI.to_string(uri)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp safe_media(src, page_url), do: safe_link(src, page_url)

  defp class_member?(attributes, class_name) do
    attributes
    |> attribute("class")
    |> to_string()
    |> String.split()
    |> Enum.member?(class_name)
  end

  defp attribute(attributes, key),
    do: Enum.find_value(attributes, fn {name, value} -> if name == key, do: value end)

  defp ensure_children([]), do: [%{"text" => ""}]
  defp ensure_children(children), do: children

  defp empty_text?(%{"text" => ""}), do: true
  defp empty_text?(_node), do: false

  defp merge_adjacent_text(nodes) do
    Enum.reduce(nodes, [], fn node, acc ->
      case {node, acc} do
        {%{"text" => text} = current, [%{"text" => previous} = head | tail]} ->
          if Map.delete(current, "text") == Map.delete(head, "text") do
            [Map.put(head, "text", previous <> text) | tail]
          else
            [node | acc]
          end

        _ ->
          [node | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_inline_text(text), do: String.replace(text, ~r/[\t\r\n ]+/u, " ")
  defp normalize_text(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
