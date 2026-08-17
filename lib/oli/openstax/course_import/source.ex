defmodule Oli.OpenStax.CourseImport.Source do
  @moduledoc """
  OpenStax source discovery and ingestion.

  Only canonical pages belonging to the submitted book are retained. Network
  calls have explicit connect/receive timeouts and response-size ceilings.
  """

  alias Oli.OpenStax.CourseImport.{Parser, SourceAST}

  @max_response_bytes 2_000_000
  @connect_timeout 5_000
  @receive_timeout 15_000
  @fetch_concurrency 8
  @max_fetch_concurrency 12
  # Discovery runs in a short-lived preflight job. A book landing page can
  # expose every section URL, so probing each URL one at a time would exceed
  # the job budget when OpenStax is slow or unavailable.
  # Keep this fallback deliberately small and parallel; the landing-page links
  # are still sufficient for the non-preloaded-state discovery path.
  @discovery_candidate_limit 12
  @discovery_fetch_concurrency 4
  @max_discovery_fetch_concurrency 8
  @max_discovery_fetch_timeout 25_000
  @user_agent "OLI-Torus-OpenStax-Importer/1.0"
  @excluded_page_slugs ~w(index preface answer-key references)
  @conceptual_questions_suffix "-conceptual-questions"
  @trusted_media_hosts ~w(openstax.org assets.openstax.org)

  @type snapshot :: %{required(String.t()) => term()}

  @spec discover(String.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def discover(source_url, opts \\ []) do
    with {:ok, book_slug} <- Parser.parse_openstax_url(source_url),
         {:ok, body} <- fetch_discovery_url(source_url, opts),
         {:ok, document} <- Floki.parse_document(body) do
      first_links = extract_book_links(document, body, book_slug)

      with {:ok, expanded_body} <-
             fetch_discovery_page(first_links, book_slug, opts),
           book = extract_preloaded_book(expanded_body, book_slug),
           links <-
             merge_links(
               extract_tree_links(book, book_slug),
               first_links ++ extract_links_from_optional_body(expanded_body, book_slug)
             ),
           chapters when chapters != [] <- group_chapters(links, book_slug) do
        {:ok,
         %{
           "book_slug" => book_slug,
           "source_url" => source_url,
           "title" => preloaded_book_title(book) || page_title(document, book_slug),
           "license" => attribution(book_slug, source_url, expanded_body),
           "chapters" => chapters,
           "discovered_at" => DateTime.to_iso8601(DateTime.utc_now())
         }}
      else
        [] -> {:error, :no_chapters_discovered}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_openstax_url} -> {:error, :invalid_openstax_url}
      {:error, _} = error -> error
    end
  end

  @spec ingest(snapshot(), [String.t()], keyword()) :: {:ok, snapshot()} | {:error, term()}
  def ingest(snapshot, selected_ids, opts \\ [])

  def ingest(
        %{"book_slug" => book_slug, "chapters" => chapters} = snapshot,
        selected_ids,
        opts
      )
      when is_binary(book_slug) and is_list(chapters) and is_list(selected_ids) do
    selected = MapSet.new(selected_ids)

    chapters =
      chapters
      |> Enum.filter(&MapSet.member?(selected, &1["id"]))
      |> Enum.sort_by(&Map.get(&1, "order", 0))

    with false <- Enum.empty?(chapters),
         {:ok, ingested} <- ingest_chapters(chapters, book_slug, opts) do
      {:ok,
       snapshot
       |> Map.put("chapters", ingested)
       |> Map.put("selected_chapter_ids", selected_ids)
       |> Map.put("ingested_at", DateTime.to_iso8601(DateTime.utc_now()))}
    else
      true -> {:error, :no_chapters_selected}
      {:error, _} = error -> error
    end
  end

  def ingest(_, _, _), do: {:error, :invalid_scope_snapshot}

  @doc false
  def parse_section_page(body, url, opts \\ [])

  def parse_section_page(body, url, opts)
      when is_binary(body) and is_binary(url) and is_list(opts) do
    with {:ok, document} <- Floki.parse_document(body),
         {:ok, root} <- instructional_root(document, opts) do
      title =
        root
        |> Floki.find("[data-type='document-title'], h1, h2")
        |> List.first()
        |> node_text()
        |> case do
          "" ->
            document
            |> Floki.find("main h1, article h1, h1")
            |> List.first()
            |> node_text()

          title ->
            title
        end

      objectives =
        root
        |> Floki.find(
          "[data-type='learning-objectives'] li, .learning-objectives li, #learning-objectives li"
        )
        |> Enum.map(&node_text/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      content_blocks =
        if conceptual_questions_url?(url) do
          conceptual_question_blocks(root, url)
        else
          semantic_content_blocks(root, url)
        end
        |> attach_heading_paths()

      media = collect_media(content_blocks)
      word_count = semantic_word_count(content_blocks)
      excerpt = render_source_preview(content_blocks)

      {:ok,
       %{
         "title" => fallback_title(title, url),
         "url" => url,
         "excerpt" => excerpt,
         "learning_objectives" => objectives,
         "content_blocks" => content_blocks,
         "media" => media,
         "word_count" => word_count,
         "content_hash" => content_hash(content_blocks),
         "source_kind" =>
           if(conceptual_questions_url?(url),
             do: "conceptual_questions",
             else: "instructional"
           ),
         "source_metadata" => %{
           "source_kind" =>
             if(conceptual_questions_url?(url),
               do: "conceptual_questions",
               else: "instructional"
             )
         },
         "coverage" => %{
           "complete" => true,
           "block_count" => semantic_block_count(content_blocks),
           "top_level_block_count" => length(content_blocks),
           "media_count" => length(media),
           "assessment_question_count" =>
             Enum.count(content_blocks, &(&1["kind"] == "assessment_question")),
           "word_count" => word_count
         }
       }}
    end
  end

  defp conceptual_question_blocks(root, url) do
    title_blocks =
      root
      |> Floki.find("[data-type='document-title'], h2, h3[data-type='title']")
      |> Enum.take(1)
      |> Enum.flat_map(fn
        {tag, attributes, _children} = node ->
          level =
            case tag do
              "h2" -> 2
              _ -> 2
            end

          maybe_text_block("heading", node, attributes, [1], %{"level" => level})

        _ ->
          []
      end)

    question_nodes =
      root
      |> Floki.find("[data-type='exercise'], [data-type='injected-exercise']")
      |> case do
        [] ->
          case Floki.find(root, "[data-type='problem']") do
            [] -> Floki.find(root, "ol > li")
            problems -> problems
          end

        exercises ->
          exercises
      end

    questions =
      question_nodes
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {node, index} ->
        prompt = conceptual_question_text(node)

        if prompt == "" do
          []
        else
          attributes = node_attributes(node)
          locator = source_locator(attributes, ["question", index])
          content_digest = sha256(prompt)
          source_tags = source_tags(attributes)

          [
            %{
              "id" =>
                stable_id(
                  "question",
                  url,
                  "#{locator["dom_id"] || locator["dom_path"]}|#{content_digest}"
                ),
              "kind" => "assessment_question",
              "order" => index,
              "text" => prompt,
              "question_number" => index,
              "source_locator" => locator,
              "content_hash" => content_digest,
              "source_reference" => attribute(attributes, "data-injected-from-nickname"),
              "source_tags" => source_tags,
              "related_section_slugs" => related_section_slugs(source_tags),
              "learning_objective_tags" =>
                Enum.filter(source_tags, &String.starts_with?(&1, "lo:"))
            }
            |> compact_map()
          ]
        end
      end)

    (title_blocks ++ questions)
    |> annotate_blocks_preserving_ids(url)
  end

  defp conceptual_question_text(node) do
    question_stems = Floki.find(node, "[data-type='question-stem']")
    problem_nodes = Floki.find(node, "[data-type='problem']")

    text =
      cond do
        question_stems != [] -> Enum.map_join(question_stems, " ", &node_text/1)
        problem_nodes != [] -> Enum.map_join(problem_nodes, " ", &node_text/1)
        true -> node_text(node)
      end

    text
    |> String.replace(~r/^\s*\d+\s*[.)]\s*/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp node_attributes({_tag, attributes, _children}) when is_list(attributes), do: attributes
  defp node_attributes(_), do: []

  defp source_tags(attributes) do
    attributes
    |> attribute("data-tags")
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
  end

  defp related_section_slugs(tags) do
    tags
    |> Enum.flat_map(fn
      "module-slug:" <> module_reference ->
        case String.split(module_reference, ":", trim: true) do
          [] -> []
          parts -> [List.last(parts)]
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp annotate_blocks_preserving_ids(blocks, url) do
    annotated = annotate_blocks(blocks, url)

    blocks
    |> Enum.zip(annotated)
    |> Enum.map(fn
      {%{"id" => id}, block} when is_binary(id) and id != "" -> Map.put(block, "id", id)
      {_source, block} -> block
    end)
  end

  defp instructional_root(document, opts) do
    case Floki.find(document, "[data-book-content=true]") do
      [_book_content | _] = book_content ->
        nested_footnotes = Floki.find(book_content, "[data-type='footnote-refs']")

        related_footnotes =
          document
          |> Floki.find("[data-type='footnote-refs']")
          |> Enum.reject(&Enum.member?(nested_footnotes, &1))

        {:ok, book_content ++ related_footnotes}

      [] ->
        if Keyword.get(opts, :strict_book_content, false) do
          {:error, :missing_canonical_book_content}
        else
          case Floki.find(document, "main article, article") do
            [article | _] ->
              {:ok, [article]}

            [] ->
              case Floki.find(document, "main") do
                [main | _] -> {:ok, [main]}
                [] -> {:ok, document}
              end
          end
        end
    end
  end

  defp semantic_content_blocks(root, url) do
    root
    |> root_children()
    |> semantic_nodes(url, [])
    |> annotate_blocks(url)
  end

  defp root_children(nodes) do
    nodes
    |> List.wrap()
    |> Enum.flat_map(fn
      {tag, attributes, children} = node ->
        if tag in ~w(html body main article) or
             attribute(attributes, "data-book-content") == "true",
           do: children,
           else: [node]

      node ->
        [node]
    end)
  end

  defp semantic_nodes(nodes, url, parent_path) do
    nodes
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {node, index} ->
      semantic_node(node, url, parent_path ++ [index])
    end)
  end

  defp semantic_node({tag, attributes, children} = node, url, path) do
    cond do
      tag in ~w(script style nav footer header button noscript svg) ->
        []

      objectives_node?(attributes) ->
        [
          semantic_block("objectives", attributes, path, %{
            "text" => node_text(node),
            "items" => objective_items(node),
            "ast" => SourceAST.blocks(node, url),
            "blocks" => semantic_nodes(children, url, path)
          })
        ]

      footnotes_node?(attributes) ->
        [
          semantic_block("footnotes", attributes, path, %{
            "text" => node_text(node),
            "ast" => SourceAST.blocks(node, url),
            "blocks" => semantic_nodes(children, url, path)
          })
        ]

      typed_callout?(attributes) ->
        [
          semantic_block("callout", attributes, path, %{
            "text" => node_text(node),
            "callout_type" => callout_type(attributes),
            "title" => first_text(node, "h2, h3"),
            "subtitle" => first_text(node, "h4"),
            "ast" => SourceAST.blocks(node, url),
            "blocks" => semantic_nodes(children, url, path)
          })
        ]

      exercise_node?(attributes) ->
        [exercise_block(node, attributes, url, path)]

      SourceAST.equation?(tag, attributes) ->
        [equation_block(node, attributes, url, path)]

      figure_node?(tag, attributes) ->
        [figure_block(node, attributes, url, path)]

      tag in ~w(h2 h3 h4) ->
        maybe_text_block(
          "heading",
          node,
          attributes,
          path,
          %{
            "level" => String.to_integer(String.trim_leading(tag, "h")),
            "ast" => SourceAST.blocks(node, url)
          }
        )

      tag == "p" ->
        maybe_text_block("paragraph", node, attributes, path, %{
          "media" => extract_media(node, url),
          "ast" => SourceAST.blocks(node, url)
        })

      tag in ~w(ul ol) ->
        [list_block(node, tag, attributes, url, path)]

      tag == "pre" ->
        maybe_text_block("code", node, attributes, path, %{
          "language" => code_language(node),
          "ast" => SourceAST.blocks(node, url)
        })

      tag == "table" ->
        [table_block(node, attributes, url, path)]

      tag == "blockquote" ->
        maybe_text_block("quote", node, attributes, path, %{
          "ast" => SourceAST.blocks(node, url)
        })

      tag == "figcaption" ->
        maybe_text_block("caption", node, attributes, path, %{
          "ast" => SourceAST.blocks(node, url)
        })

      tag in ~w(img picture video audio) ->
        [media_block(node, attributes, url, path)]

      true ->
        semantic_nodes(children, url, path)
    end
  end

  defp semantic_node(_, _url, _path), do: []

  defp maybe_text_block(kind, node, attributes, path, fields) do
    case node_text(node) do
      "" ->
        []

      text ->
        [
          semantic_block(
            kind,
            attributes,
            path,
            fields
            |> Map.put("text", text)
            |> compact_map()
          )
        ]
    end
  end

  defp semantic_block(kind, attributes, path, fields) do
    %{
      "kind" => kind,
      "source_locator" => source_locator(attributes, path)
    }
    |> Map.merge(fields)
    |> compact_map()
  end

  defp source_locator(attributes, path) do
    %{
      "dom_id" => attribute(attributes, "id"),
      "dom_path" => Enum.join(path, ".")
    }
    |> compact_map()
  end

  defp objectives_node?(attributes) do
    attribute(attributes, "data-type") == "learning-objectives" or
      attribute(attributes, "id") == "learning-objectives" or
      class_member?(attributes, "learning-objectives")
  end

  defp objective_items(node) do
    node
    |> Floki.find("li")
    |> Enum.map(&node_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp footnotes_node?(attributes),
    do: attribute(attributes, "data-type") == "footnote-refs"

  defp typed_callout?(attributes) do
    attribute(attributes, "data-type") == "note" or
      Enum.any?(
        ~w(global-tech industry-spotlight concepts-practice),
        &class_member?(attributes, &1)
      )
  end

  defp callout_type(attributes) do
    cond do
      class_member?(attributes, "global-tech") -> "global_issue"
      class_member?(attributes, "industry-spotlight") -> "industry_spotlight"
      class_member?(attributes, "concepts-practice") -> "concepts_in_practice"
      true -> "note"
    end
  end

  defp exercise_node?(attributes) do
    attribute(attributes, "data-type") in [
      "example",
      "exercise",
      "injected-exercise",
      "practice",
      "problem-set"
    ] or class_member?(attributes, "os-exercise")
  end

  defp exercise_block(node, attributes, url, path) do
    problem =
      first_text(
        node,
        "[data-type='problem'], [data-type='question-stem'], .problem, .question-stem"
      )

    solution =
      first_text(
        node,
        "[data-type='solution'], [data-type='answer'], .solution, .answer"
      )

    title = first_text(node, "[data-type='title'], h3, h4")

    text = node_text(node)

    semantic_block("exercise", attributes, path, %{
      "exercise_type" => attribute(attributes, "data-type") || "exercise",
      "title" => title,
      "problem" => problem,
      "solution" => solution,
      "ast" => SourceAST.blocks(node, url),
      "text" =>
        [title, problem, solution, text]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.join(" ")
    })
  end

  defp figure_node?(tag, attributes) do
    tag == "figure" or
      attribute(attributes, "data-type") == "figure" or
      class_member?(attributes, "os-figure")
  end

  defp figure_block(node, attributes, url, path) do
    media = extract_media(node, url)
    caption = all_text(node, "figcaption")

    semantic_block("figure", attributes, path, %{
      "text" =>
        [caption | Enum.map(media, & &1["alt"])]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" "),
      "caption" => caption,
      "credit" => figure_credit(node, caption),
      "license" => all_text(node, "[data-type='license'], .os-license"),
      "ast" => SourceAST.blocks(node, url),
      "media" => media
    })
  end

  defp figure_credit(node, caption) do
    explicit_credit =
      all_text(
        node,
        "[data-type='credit'], .os-credit, .os-figure-source, .os-caption-source"
      )

    case String.trim(explicit_credit) do
      "" -> caption_credit(caption)
      credit -> credit
    end
  end

  defp caption_credit(caption) when is_binary(caption) do
    case Regex.run(
           ~r/\b(?:credit|attribution)\s*:\s*.+?(?=\)\s*$|$)/iu,
           caption
         ) do
      [credit] -> String.trim(credit)
      _ -> ""
    end
  end

  defp caption_credit(_), do: ""

  defp media_block(node, attributes, url, path) do
    media = extract_media(node, url)

    semantic_block("media", attributes, path, %{
      "text" =>
        media
        |> Enum.map(& &1["alt"])
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" "),
      "ast" => SourceAST.blocks(node, url),
      "media" => media
    })
  end

  defp extract_media({tag, _attributes, _children} = node, url)
       when tag in ~w(img video audio) do
    [media_descriptor(node, url)]
    |> Enum.reject(&is_nil/1)
  end

  defp extract_media(node, url) do
    node
    |> Floki.find("img, video, audio")
    |> Enum.map(&media_descriptor(&1, url))
    |> Enum.reject(&is_nil/1)
  end

  defp media_descriptor({tag, attributes, _children} = node, url) do
    src =
      attribute(attributes, "src") ||
        attribute(attributes, "data-src") ||
        attribute(attributes, "data-original") ||
        node
        |> Floki.find("source[src]")
        |> List.first()
        |> case do
          {_source_tag, source_attributes, _source_children} ->
            attribute(source_attributes, "src")

          _ ->
            nil
        end

    resolved_src = resolve_media_url(src, url)

    alternate_source_urls =
      [attribute(attributes, "data-src"), attribute(attributes, "data-original")] ++
        srcset_urls(attribute(attributes, "srcset")) ++
        (node
         |> Floki.find("source[src], source[srcset]")
         |> Enum.flat_map(fn {_tag, source_attributes, _children} ->
           [attribute(source_attributes, "src")] ++
             srcset_urls(attribute(source_attributes, "srcset"))
         end))

    alternate_source_urls =
      alternate_source_urls
      |> Enum.map(&resolve_media_url(&1, url))
      |> Enum.reject(&(&1 in [nil, resolved_src]))
      |> Enum.uniq()

    descriptor =
      %{
        "kind" => tag,
        "src" => resolved_src,
        "alternate_source_urls" => alternate_source_urls,
        "alt" => attribute(attributes, "alt"),
        "title" => attribute(attributes, "title"),
        "width" => attribute(attributes, "width"),
        "height" => attribute(attributes, "height"),
        "srcset" => attribute(attributes, "srcset")
      }
      |> compact_map()

    if map_size(descriptor) > 1 or Map.has_key?(descriptor, "src"),
      do: descriptor,
      else: nil
  end

  defp media_descriptor(_, _url), do: nil

  defp srcset_urls(srcset) when is_binary(srcset) do
    srcset
    |> String.split(",", trim: true)
    |> Enum.map(fn candidate ->
      candidate
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp srcset_urls(_srcset), do: []

  defp resolve_media_url(nil, _page_url), do: nil

  defp resolve_media_url(src, page_url) do
    case URI.merge(page_url, String.trim(src)) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) ->
        URI.to_string(uri)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp list_block({_tag, _attributes, children}, tag, attributes, url, path) do
    items =
      children
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {{_li_tag, _li_attributes, _li_children} = item, index}
        when elem(item, 0) == "li" ->
          [list_item(item, url, path ++ [index])]

        _ ->
          []
      end)

    semantic_block("list", attributes, path, %{
      "ordered" => tag == "ol",
      "text" => Enum.map_join(items, " ", &Map.get(&1, "text", "")),
      "ast" => SourceAST.blocks({tag, attributes, children}, url),
      "items" => items
    })
  end

  defp list_item({_tag, _attributes, children}, url, path) do
    {nested_lists, text_children} =
      Enum.split_with(children, fn
        {tag, _attributes, _children} -> tag in ~w(ul ol)
        _ -> false
      end)

    %{
      "text" => node_text({"span", [], text_children}),
      "children" => semantic_nodes(nested_lists, url, path)
    }
    |> compact_map()
  end

  defp table_block(node, attributes, url, path) do
    rows =
      node
      |> Floki.find("tr")
      |> Enum.map(fn row ->
        row
        |> Floki.find("th, td")
        |> Enum.map(&node_text/1)
      end)
      |> Enum.reject(&(&1 == []))

    semantic_block("table", attributes, path, %{
      "text" => node_text(node),
      "ast" => SourceAST.blocks(node, url),
      "rows" => rows
    })
  end

  defp equation_block(node, attributes, url, path) do
    %{"src" => source, "subtype" => subtype} = SourceAST.equation_payload(node)

    semantic_block("equation", attributes, path, %{
      "text" => source,
      "latex" => if(subtype == "latex", do: source),
      "mathml" => if(subtype == "mathml", do: source),
      "subtype" => subtype,
      "ast" => SourceAST.blocks(node, url)
    })
  end

  defp code_language(node) do
    node
    |> Floki.find("code")
    |> List.first()
    |> case do
      {_tag, attributes, _children} ->
        attributes
        |> attribute("class")
        |> to_string()
        |> String.split()
        |> Enum.find_value(fn
          "language-" <> language -> language
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp first_text(node, selector) do
    node
    |> Floki.find(selector)
    |> List.first()
    |> node_text()
  end

  defp all_text(node, selector) do
    node
    |> Floki.find(selector)
    |> Enum.map(&node_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp annotate_blocks(blocks, url, semantic_path \\ []) do
    blocks
    |> Enum.with_index(1)
    |> Enum.map(fn {block, index} ->
      block_path = semantic_path ++ [index]
      locator = Map.get(block, "source_locator", %{})
      identity = locator["dom_id"] || locator["dom_path"] || Enum.join(block_path, ".")
      block_hash = semantic_content_hash(block)
      block_id = stable_id("block", url, "#{identity}|#{block["kind"]}|#{block_hash}")

      block
      |> Map.put("id", block_id)
      |> Map.put("content_hash", block_hash)
      |> Map.put("order", index)
      |> annotate_nested_blocks(url, block_path)
      |> annotate_list_items(url, block_id)
      |> annotate_media(url, block_id)
    end)
  end

  defp annotate_nested_blocks(block, url, block_path) do
    case Map.get(block, "blocks") do
      blocks when is_list(blocks) ->
        Map.put(block, "blocks", annotate_blocks(blocks, url, block_path))

      _ ->
        block
    end
  end

  defp annotate_list_items(block, url, block_id) do
    case {Map.get(block, "kind"), Map.get(block, "items")} do
      {"list", items} when is_list(items) ->
        annotated =
          items
          |> Enum.with_index(1)
          |> Enum.map(fn {item, index} ->
            item_id = stable_id("item", url, "#{block_id}|#{index}")

            item
            |> Map.put("id", item_id)
            |> Map.put("order", index)
            |> case do
              %{"children" => children} = item when is_list(children) ->
                Map.put(item, "children", annotate_blocks(children, url, [index]))

              item ->
                item
            end
          end)

        Map.put(block, "items", annotated)

      _ ->
        block
    end
  end

  defp annotate_media(block, url, block_id) do
    case Map.get(block, "media") do
      media when is_list(media) ->
        annotated =
          media
          |> Enum.with_index(1)
          |> Enum.map(fn {descriptor, index} ->
            descriptor_hash = semantic_content_hash(descriptor)

            descriptor
            |> Map.put(
              "id",
              stable_id(
                "media",
                url,
                "#{block_id}|#{index}|#{descriptor["src"]}|#{descriptor_hash}"
              )
            )
            |> Map.put("source_block_id", block_id)
            |> Map.put("content_hash", descriptor_hash)
          end)

        Map.put(block, "media", annotated)

      _ ->
        block
    end
  end

  defp stable_id(prefix, url, identity) do
    digest =
      :crypto.hash(:sha256, "#{url}|#{identity}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 24)

    "openstax-#{prefix}-#{digest}"
  end

  defp attach_heading_paths(blocks, base_path \\ []) do
    {blocks, _heading_state} =
      Enum.map_reduce(blocks, [], fn block, heading_state ->
        {block, heading_state} =
          case block do
            %{"kind" => "heading", "level" => level, "text" => text} ->
              heading_state =
                heading_state
                |> Enum.reject(fn {existing_level, _text} -> existing_level >= level end)
                |> Kernel.++([{level, text}])

              {block, heading_state}

            _ ->
              {block, heading_state}
          end

        heading_path = base_path ++ Enum.map(heading_state, &elem(&1, 1))

        block =
          block
          |> Map.put("heading_path", heading_path)
          |> attach_nested_heading_paths(heading_path)
          |> attach_list_heading_paths(heading_path)

        {block, heading_state}
      end)

    blocks
  end

  defp attach_nested_heading_paths(block, heading_path) do
    case Map.get(block, "blocks") do
      blocks when is_list(blocks) ->
        Map.put(block, "blocks", attach_heading_paths(blocks, heading_path))

      _ ->
        block
    end
  end

  defp attach_list_heading_paths(block, heading_path) do
    case {Map.get(block, "kind"), Map.get(block, "items")} do
      {"list", items} when is_list(items) ->
        items =
          Enum.map(items, fn item ->
            case Map.get(item, "children") do
              children when is_list(children) ->
                Map.put(item, "children", attach_heading_paths(children, heading_path))

              _ ->
                item
            end
          end)

        Map.put(block, "items", items)

      _ ->
        block
    end
  end

  defp collect_media(blocks) do
    blocks
    |> Enum.flat_map(fn block ->
      direct_media =
        block
        |> Map.get("media", [])
        |> Enum.map(&attach_media_evidence(&1, block))

      direct_media ++
        collect_media(Map.get(block, "blocks", [])) ++
        collect_list_media(Map.get(block, "items", []))
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp attach_media_evidence(media, block) do
    media
    |> Map.put("source_block_id", block["id"])
    |> Map.put("evidence_block_ids", [block["id"]])
    |> Map.put("heading_path", block["heading_path"] || [])
    |> put_if_present("caption", block["caption"])
    |> put_if_present("credit", block["credit"])
    |> put_if_present("license", block["license"])
    |> Map.put("rights_status", media_rights_status(media["src"]))
  end

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put_new(map, key, value)

  defp media_rights_status(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        if String.downcase(host) in @trusted_media_hosts, do: "approved", else: "blocked"

      _ ->
        "blocked"
    end
  rescue
    _ -> "blocked"
  end

  defp media_rights_status(_), do: "blocked"

  defp collect_list_media(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = item -> collect_media(Map.get(item, "children", []))
      _item -> []
    end)
  end

  defp semantic_word_count(blocks) do
    blocks
    |> Enum.map_join(" ", &semantic_text/1)
    |> count_words()
  end

  defp semantic_text(%{"kind" => "objectives"} = block),
    do: Enum.join(Map.get(block, "items", []), " ")

  defp semantic_text(%{"kind" => kind} = block) when kind in ~w(callout footnotes) do
    case Map.get(block, "blocks", []) do
      [] -> Map.get(block, "text", "")
      blocks -> Enum.map_join(blocks, " ", &semantic_text/1)
    end
  end

  defp semantic_text(%{"kind" => "list"} = block) do
    block
    |> Map.get("items", [])
    |> Enum.map_join(" ", fn item ->
      Map.get(item, "text", "") <>
        " " <> Enum.map_join(Map.get(item, "children", []), " ", &semantic_text/1)
    end)
  end

  defp semantic_text(%{"kind" => kind} = block) when kind in ~w(figure media) do
    [
      Map.get(block, "caption"),
      Map.get(block, "text"),
      block
      |> Map.get("media", [])
      |> Enum.map_join(" ", &Map.get(&1, "alt", ""))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp semantic_text(block), do: Map.get(block, "text", "")

  defp count_words(text) do
    ~r/[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/u
    |> Regex.scan(text)
    |> length()
  end

  defp semantic_block_count(blocks) do
    Enum.reduce(blocks, 0, fn block, count ->
      count + 1 +
        semantic_block_count(Map.get(block, "blocks", [])) +
        list_child_block_count(Map.get(block, "items", []))
    end)
  end

  defp list_child_block_count(items) do
    items
    |> List.wrap()
    |> Enum.reduce(0, fn
      %{} = item, count ->
        count + semantic_block_count(Map.get(item, "children", []))

      _item, count ->
        count
    end)
  end

  defp content_hash(blocks) do
    :crypto.hash(:sha256, :erlang.term_to_binary(blocks, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp sha256(text) when is_binary(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp semantic_content_hash(value) do
    value
    |> drop_generated_identity()
    |> then(&:crypto.hash(:sha256, :erlang.term_to_binary(&1, [:deterministic])))
    |> Base.encode16(case: :lower)
  end

  defp drop_generated_identity(%{} = value) do
    value
    |> Map.drop(["id", "order", "content_hash"])
    |> Map.new(fn {key, nested} -> {key, drop_generated_identity(nested)} end)
  end

  defp drop_generated_identity(value) when is_list(value),
    do: Enum.map(value, &drop_generated_identity/1)

  defp drop_generated_identity(value), do: value

  defp render_source_preview(blocks) do
    blocks
    |> Enum.flat_map(&source_preview_parts/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp source_preview_parts(%{"kind" => "heading", "text" => text}),
    do: ["### #{text}"]

  defp source_preview_parts(%{"kind" => "objectives"} = block) do
    ["### Learning Objectives" | Enum.map(Map.get(block, "items", []), &"- #{&1}")]
  end

  defp source_preview_parts(%{"kind" => "callout"} = block) do
    marker =
      ["Callout: #{block["callout_type"]}", block["title"], block["subtitle"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" — ")

    [marker | Enum.flat_map(Map.get(block, "blocks", []), &source_preview_parts/1)]
  end

  defp source_preview_parts(%{"kind" => "footnotes"} = block),
    do: ["Footnotes:" | Enum.flat_map(Map.get(block, "blocks", []), &source_preview_parts/1)]

  defp source_preview_parts(%{"kind" => "list"} = block) do
    block
    |> Map.get("items", [])
    |> Enum.flat_map(fn item ->
      [
        "- #{item["text"]}"
        | Enum.flat_map(Map.get(item, "children", []), &source_preview_parts/1)
      ]
    end)
  end

  defp source_preview_parts(%{"kind" => "code", "text" => text}),
    do: ["Code example:\n#{text}"]

  defp source_preview_parts(%{"kind" => "figure"} = block) do
    caption = block["caption"] || block["text"]

    alt =
      block
      |> Map.get("media", [])
      |> Enum.map(& &1["alt"])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    ["Figure context: #{caption}", if(alt == "", do: nil, else: "Alt text: #{alt}")]
  end

  defp source_preview_parts(%{"kind" => "media"} = block),
    do: ["Media context: #{block["text"]}"]

  defp source_preview_parts(%{"kind" => "table", "text" => text}),
    do: ["Table: #{text}"]

  defp source_preview_parts(%{"kind" => "quote", "text" => text}),
    do: ["Note: #{text}"]

  defp source_preview_parts(%{"kind" => "caption", "text" => text}),
    do: ["Figure context: #{text}"]

  defp source_preview_parts(%{"text" => text}), do: [text]
  defp source_preview_parts(_), do: []

  defp attribute(attributes, name) when is_list(attributes) do
    Enum.find_value(attributes, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp attribute(_, _), do: nil

  defp class_member?(attributes, class_name) do
    attributes
    |> attribute("class")
    |> to_string()
    |> String.split()
    |> Enum.member?(class_name)
  end

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)
  end

  defp ingest_chapters(chapters, book_slug, opts) do
    work_items =
      chapters
      |> Enum.with_index()
      |> Enum.flat_map(fn {chapter, chapter_index} ->
        section_specs = Map.get(chapter, "sections", [])

        instructional =
          section_specs
          |> Enum.reject(&assessment_source_spec?/1)
          |> source_work_items(chapter_index, :instructional)

        assessment =
          (Enum.filter(section_specs, &assessment_source_spec?/1) ++
             Map.get(chapter, "assessment_sources", []))
          |> Enum.uniq_by(& &1["url"])
          |> source_work_items(chapter_index, :assessment)

        instructional ++ assessment
      end)

    with {:ok, sections} <- ingest_sections(work_items, book_slug, opts) do
      instructional_by_chapter =
        sections
        |> Enum.filter(&(&1.source_role == :instructional))
        |> Enum.group_by(& &1.chapter_index)
        |> Map.new(fn {chapter_index, values} ->
          ordered_sections =
            values
            |> Enum.sort_by(& &1.section_index)
            |> Enum.map(& &1.section)

          {chapter_index, ordered_sections}
        end)

      assessment_by_chapter =
        sections
        |> Enum.filter(&(&1.source_role == :assessment))
        |> Enum.group_by(& &1.chapter_index)
        |> Map.new(fn {chapter_index, values} ->
          assessment_sources =
            values
            |> Enum.sort_by(& &1.section_index)
            |> Enum.map(& &1.section)

          {chapter_index, assessment_sources}
        end)

      ingested =
        chapters
        |> Enum.with_index()
        |> Enum.map(fn {chapter, chapter_index} ->
          instructional_sections = Map.get(instructional_by_chapter, chapter_index, [])

          assessment_sections =
            assessment_by_chapter
            |> Map.get(chapter_index, [])
            |> Enum.with_index(1)
            |> Enum.map(fn {section, index} ->
              section
              |> Map.put("source_kind", "conceptual_questions")
              |> Map.put("order", length(instructional_sections) + index)
            end)

          chapter
          # Assessment pages share the normalized source-section storage
          # path, but remain explicitly marked and are removed by Parser
          # before lesson grouping.
          |> Map.put("sections", instructional_sections ++ assessment_sections)
          |> Map.put(
            "assessment_sources",
            Enum.map(assessment_sections, &assessment_source_metadata/1)
          )
          |> Map.put("selected", true)
        end)

      {:ok, ingested}
    end
  end

  defp source_work_items(sections, chapter_index, source_role) do
    sections
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {section, section_index} ->
      %{
        chapter_index: chapter_index,
        section_index: section_index,
        source_role: source_role,
        section: section
      }
    end)
  end

  defp assessment_source_metadata(section) do
    %{
      "title" => section["title"],
      "url" => section["url"],
      "order" => section["order"],
      "source_kind" => "conceptual_questions",
      "question_count" => get_in(section, ["coverage", "assessment_question_count"]) || 0
    }
  end

  defp assessment_source_spec?(section) do
    section["source_kind"] == "conceptual_questions" or
      get_in(section, ["source_metadata", "source_kind"]) == "conceptual_questions" or
      conceptual_questions_url?(section["url"])
  end

  defp ingest_sections(work_items, book_slug, opts) do
    task_timeout =
      Keyword.get(
        opts,
        :fetch_task_timeout,
        Keyword.get(opts, :connect_timeout, @connect_timeout) +
          Keyword.get(opts, :receive_timeout, @receive_timeout) + 5_000
      )

    results =
      Task.async_stream(
        work_items,
        &ingest_section(&1, book_slug, opts),
        ordered: true,
        max_concurrency: fetch_concurrency(opts),
        timeout: task_timeout,
        on_timeout: :kill_task
      )

    work_items
    |> Stream.zip(results)
    |> Enum.reduce_while({:ok, []}, fn
      {_work_item, {:ok, {:ok, ingested}}}, {:ok, acc} ->
        {:cont, {:ok, [ingested | acc]}}

      {%{section: section}, {:ok, {:error, reason}}}, _acc ->
        {:halt, {:error, {:section_fetch_failed, section["url"], reason}}}

      {%{section: section}, {:exit, reason}}, _acc ->
        {:halt, {:error, {:section_fetch_failed, section["url"], {:task_exit, reason}}}}
    end)
    |> case do
      {:ok, ingested} -> {:ok, Enum.reverse(ingested)}
      {:error, _} = error -> error
    end
  end

  defp ingest_section(%{section: section} = work_item, book_slug, opts) do
    url = section["url"]

    with :ok <- validate_canonical_page(url, book_slug),
         {:ok, body} <- fetch(url, opts),
         {:ok, parsed} <- parse_section_page(body, url, opts) do
      merged =
        section
        |> Map.merge(parsed)
        |> Map.put("title", parsed["title"] || section["title"])

      {:ok, Map.put(work_item, :section, merged)}
    end
  end

  defp fetch_concurrency(opts) do
    case Keyword.get(opts, :fetch_concurrency, @fetch_concurrency) do
      concurrency when is_integer(concurrency) and concurrency > 0 ->
        min(concurrency, @max_fetch_concurrency)

      _ ->
        @fetch_concurrency
    end
  end

  defp fetch(url, opts) do
    client = Keyword.get(opts, :http_client, HTTPoison)
    max_bytes = Keyword.get(opts, :max_response_bytes, @max_response_bytes)
    receive_timeout = Keyword.get(opts, :receive_timeout, @receive_timeout)

    request_opts = [
      timeout: Keyword.get(opts, :connect_timeout, @connect_timeout),
      recv_timeout: receive_timeout,
      # Do not let an otherwise valid OpenStax URL redirect the crawler outside
      # the canonical same-book allowlist.
      hackney: [follow_redirect: false]
    ]

    headers = [{"user-agent", @user_agent}]

    if client == HTTPoison do
      fetch_streaming(url, headers, request_opts, max_bytes, receive_timeout)
    else
      fetch_buffered(client, url, headers, request_opts, max_bytes)
    end
  rescue
    exception -> {:error, {:http_exception, Exception.message(exception)}}
  end

  defp fetch_buffered(client, url, headers, request_opts, max_bytes) do
    case call_client(client, url, headers, request_opts) do
      {:ok, %{status_code: status, body: body} = response}
      when status in 200..299 and is_binary(body) ->
        with :ok <- validate_content_length(Map.get(response, :headers, []), max_bytes),
             :ok <- validate_body_size(body, max_bytes) do
          {:ok, body}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, inspect(reason)}}

      other ->
        {:error, {:invalid_http_response, inspect(other)}}
    end
  end

  defp call_client(client, url, headers, request_opts) when is_function(client, 3),
    do: client.(url, headers, request_opts)

  defp call_client(client, url, headers, request_opts),
    do: client.get(url, headers, request_opts)

  defp fetch_streaming(url, headers, request_opts, max_bytes, receive_timeout) do
    stream_opts = request_opts ++ [stream_to: self(), async: :once]

    case HTTPoison.get(url, headers, stream_opts) do
      {:ok, %HTTPoison.AsyncResponse{} = response} ->
        HTTPoison.stream_next(response)
        collect_stream(response, max_bytes, receive_timeout, nil, [], 0)

      {:error, reason} ->
        {:error, {:http_error, inspect(reason)}}

      other ->
        {:error, {:invalid_http_response, inspect(other)}}
    end
  end

  defp collect_stream(response, max_bytes, receive_timeout, status, chunks, size) do
    receive do
      %HTTPoison.AsyncStatus{id: id, code: code} when id == response.id ->
        if code in 200..299 do
          HTTPoison.stream_next(response)
          collect_stream(response, max_bytes, receive_timeout, code, chunks, size)
        else
          stop_stream(response)
          {:error, {:unexpected_status, code}}
        end

      %HTTPoison.AsyncHeaders{id: id, headers: headers} when id == response.id ->
        case validate_content_length(headers, max_bytes) do
          :ok ->
            HTTPoison.stream_next(response)
            collect_stream(response, max_bytes, receive_timeout, status, chunks, size)

          {:error, _} = error ->
            stop_stream(response)
            error
        end

      %HTTPoison.AsyncChunk{id: id, chunk: chunk} when id == response.id ->
        next_size = size + byte_size(chunk)

        if next_size <= max_bytes do
          HTTPoison.stream_next(response)

          collect_stream(
            response,
            max_bytes,
            receive_timeout,
            status,
            [chunk | chunks],
            next_size
          )
        else
          stop_stream(response)
          {:error, {:response_too_large, next_size, max_bytes}}
        end

      %HTTPoison.AsyncEnd{id: id} when id == response.id ->
        if status in 200..299 do
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          {:error, {:invalid_http_response, "stream ended before an HTTP status"}}
        end
    after
      receive_timeout ->
        stop_stream(response)
        {:error, {:http_error, "stream receive timeout"}}
    end
  end

  defp stop_stream(%HTTPoison.AsyncResponse{id: id}) do
    :hackney.stop_async(id)
    :ok
  rescue
    _ -> :ok
  end

  defp validate_content_length(headers, max_bytes) do
    declared_size =
      headers
      |> List.wrap()
      |> Enum.flat_map(fn
        {name, value} ->
          if String.downcase(to_string(name)) == "content-length" do
            case Integer.parse(String.trim(to_string(value))) do
              {size, ""} when size >= 0 -> [size]
              _ -> []
            end
          else
            []
          end

        _ ->
          []
      end)
      |> Enum.max(fn -> nil end)

    if is_integer(declared_size) and declared_size > max_bytes,
      do: {:error, {:response_too_large, declared_size, max_bytes}},
      else: :ok
  end

  defp validate_body_size(body, max_bytes) do
    if byte_size(body) <= max_bytes,
      do: :ok,
      else: {:error, {:response_too_large, byte_size(body), max_bytes}}
  end

  defp fetch_discovery_page(links, book_slug, opts) do
    candidate_urls =
      Enum.map(links, & &1["url"]) ++
        [
          "https://openstax.org/books/#{book_slug}/pages/1-introduction",
          "https://openstax.org/books/#{book_slug}/pages/preface"
        ]

    candidate_urls
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(discovery_candidate_limit(opts))
    |> Enum.chunk_every(discovery_fetch_concurrency(opts))
    |> Enum.reduce_while({:ok, nil}, fn urls, _acc ->
      case fetch_discovery_batch(urls, opts) do
        {:ok, body} -> {:halt, {:ok, body}}
        :not_found -> {:cont, {:ok, nil}}
      end
    end)
  end

  # Both the initial book page and the optional preloaded-state probes must
  # finish well inside PreflightWorker's three-minute Oban timeout. Returning
  # a normal error lets the worker exhaust its bounded retries and transition
  # the run to :failed, which releases the active-import/root-change guard.
  defp fetch_discovery_url(url, opts) do
    task = Task.async(fn -> fetch(url, opts) end)

    case Task.yield(task, discovery_fetch_timeout(opts)) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:discovery_fetch_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :discovery_fetch_timeout}
    end
  end

  defp fetch_discovery_batch(urls, opts) do
    urls
    |> Task.async_stream(
      &fetch(&1, opts),
      ordered: false,
      max_concurrency: discovery_fetch_concurrency(opts),
      timeout: discovery_fetch_timeout(opts),
      on_timeout: :kill_task
    )
    |> Enum.reduce(nil, fn
      {:ok, {:ok, body}}, nil -> body
      _result, body -> body
    end)
    |> case do
      body when is_binary(body) -> {:ok, body}
      nil -> :not_found
    end
  end

  defp discovery_candidate_limit(opts) do
    opts
    |> Keyword.get(:discovery_candidate_limit, @discovery_candidate_limit)
    |> positive_integer_or(@discovery_candidate_limit)
    |> min(@discovery_candidate_limit)
  end

  defp discovery_fetch_concurrency(opts) do
    opts
    |> Keyword.get(:discovery_fetch_concurrency, @discovery_fetch_concurrency)
    |> positive_integer_or(@discovery_fetch_concurrency)
    |> min(@max_discovery_fetch_concurrency)
  end

  defp discovery_fetch_timeout(opts) do
    opts
    |> Keyword.get(
      :discovery_fetch_task_timeout,
      Keyword.get(
        opts,
        :fetch_task_timeout,
        Keyword.get(opts, :connect_timeout, @connect_timeout) +
          Keyword.get(opts, :receive_timeout, @receive_timeout) + 5_000
      )
    )
    |> positive_integer_or(@max_discovery_fetch_timeout)
    |> min(@max_discovery_fetch_timeout)
  end

  defp positive_integer_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, default), do: default

  defp extract_links_from_optional_body(nil, _book_slug), do: []

  defp extract_links_from_optional_body(body, book_slug) do
    case Floki.parse_document(body) do
      {:ok, document} -> extract_book_links(document, body, book_slug)
      _ -> []
    end
  end

  defp extract_book_links(document, raw_body, book_slug) do
    anchor_links =
      document
      |> Floki.find("a[href]")
      |> Enum.map(fn node ->
        href = node |> Floki.attribute("href") |> List.first()
        %{"url" => canonicalize_href(href, book_slug), "title" => node_text(node)}
      end)

    raw_links =
      raw_body
      |> String.replace("\\/", "/")
      |> then(
        &Regex.scan(
          ~r{["']((?:https://openstax\.org)?/books/#{Regex.escape(book_slug)}/pages/[a-z0-9][a-z0-9-]*)["']},
          &1,
          capture: :all_but_first
        )
      )
      |> List.flatten()
      |> Enum.map(&%{"url" => canonicalize_href(&1, book_slug), "title" => ""})

    (anchor_links ++ raw_links)
    |> Enum.filter(&canonical_page?(&1["url"], book_slug))
    |> Enum.uniq_by(& &1["url"])
  end

  defp merge_links(primary, secondary) do
    (primary ++ secondary)
    |> Enum.reduce(%{}, fn link, acc ->
      Map.update(acc, link["url"], link, fn existing ->
        if existing["title"] in [nil, ""], do: link, else: existing
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1["url"])
  end

  defp extract_preloaded_book(nil, _book_slug), do: nil

  defp extract_preloaded_book(body, book_slug) when is_binary(body) do
    with {:ok, document} <- Floki.parse_document(body),
         script when is_binary(script) <-
           document
           |> Floki.find("script")
           |> Enum.map(fn
             {_, _, children} -> Floki.text(children)
             _ -> ""
           end)
           |> Enum.find(&String.contains?(&1, "window.__PRELOADED_STATE__")),
         json when is_binary(json) <- preloaded_state_json(script),
         {:ok, state} <- Jason.decode(json),
         %{"slug" => ^book_slug, "tree" => tree} = book when is_map(tree) <-
           get_in(state, ["content", "book"]) do
      book
    else
      _ -> nil
    end
  end

  defp preloaded_state_json(script) do
    case Regex.run(
           ~r/window\.__PRELOADED_STATE__\s*=\s*(\{.*\})\s*;?\s*$/s,
           script,
           capture: :all_but_first
         ) do
      [json] -> json
      _ -> nil
    end
  end

  defp extract_tree_links(%{"tree" => tree}, book_slug) when is_map(tree) do
    tree
    |> collect_chapter_nodes()
    |> Enum.flat_map(&chapter_tree_links(&1, book_slug))
  end

  defp extract_tree_links(_, _book_slug), do: []

  defp collect_chapter_nodes(%{"toc_type" => "chapter"} = node), do: [node]

  defp collect_chapter_nodes(%{"contents" => contents}) when is_list(contents),
    do: Enum.flat_map(contents, &collect_chapter_nodes/1)

  defp collect_chapter_nodes(_), do: []

  defp chapter_tree_links(chapter, book_slug) do
    chapter_title = clean_tree_title(chapter["title"])

    chapter
    |> Map.get("contents", [])
    |> tree_descendants()
    |> Enum.filter(fn page ->
      page["toc_target_type"] in ["intro", "numbered-section", "conceptual-questions"] or
        conceptual_questions_slug?(page["slug"])
    end)
    |> Enum.map(fn page ->
      source_kind =
        if conceptual_questions_slug?(page["slug"]),
          do: "conceptual_questions",
          else: "instructional"

      title =
        cond do
          page["toc_target_type"] == "intro" -> chapter_title
          source_kind == "conceptual_questions" -> "Conceptual Questions"
          true -> clean_tree_title(page["title"])
        end

      %{
        "url" => canonicalize_href(Map.get(page, "slug", ""), book_slug),
        "title" => title,
        "source_kind" => source_kind
      }
    end)
    |> Enum.filter(&canonical_page?(&1["url"], book_slug))
  end

  defp tree_descendants(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn
      %{} = node -> [node | tree_descendants(Map.get(node, "contents", []))]
      _ -> []
    end)
  end

  defp tree_descendants(_), do: []

  defp clean_tree_title(nil), do: ""

  defp clean_tree_title(title) when is_binary(title) do
    case Floki.parse_fragment(title) do
      {:ok, nodes} ->
        nodes
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        title |> String.replace(~r/<[^>]+>/, " ") |> String.trim()
    end
  end

  defp preloaded_book_title(%{"title" => title}) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      title -> title
    end
  end

  defp preloaded_book_title(_), do: nil

  defp group_chapters(links, book_slug) do
    links
    |> Enum.map(&with_page_parts(&1, book_slug))
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.chapter)
    |> Enum.sort_by(fn {chapter, _} -> chapter end)
    |> Enum.map(fn {chapter_number, sections} ->
      sections = Enum.sort_by(sections, &{&1.section_order, &1.url})
      instructional_sections = Enum.reject(sections, &(&1.source_kind == "conceptual_questions"))
      assessment_sources = Enum.filter(sections, &(&1.source_kind == "conceptual_questions"))
      intro = Enum.find(instructional_sections, &(&1.section_order == 0))
      first_instructional = List.first(instructional_sections)
      first_assessment = List.first(assessment_sources)

      %{
        "id" => "chapter-#{chapter_number}",
        "title" => chapter_title(chapter_number, intro),
        "order" => chapter_number,
        "url" =>
          (intro && intro.url) ||
            (first_instructional && first_instructional.url) ||
            (first_assessment && first_assessment.url),
        "selected" => true,
        "sections" =>
          Enum.map(instructional_sections, fn section ->
            %{
              "title" => section.title,
              "url" => section.url,
              "order" => section.section_order,
              "source_kind" => "instructional"
            }
          end),
        "assessment_sources" =>
          Enum.map(assessment_sources, fn section ->
            %{
              "title" => section.title,
              "url" => section.url,
              "order" => section.section_order,
              "source_kind" => "conceptual_questions"
            }
          end)
      }
    end)
    |> Enum.reject(&(&1["sections"] == []))
  end

  defp with_page_parts(%{"url" => url, "title" => title} = link, book_slug) do
    prefix = "/books/#{book_slug}/pages/"
    page_slug = URI.parse(url).path |> String.replace_prefix(prefix, "")

    case Regex.named_captures(
           ~r/^(?<chapter>\d+)(?:-(?<section>\d+))?-(?<rest>.+)$/,
           page_slug
         ) do
      %{"chapter" => chapter, "section" => section} ->
        source_kind =
          if link["source_kind"] == "conceptual_questions" or
               conceptual_questions_slug?(page_slug),
             do: "conceptual_questions",
             else: "instructional"

        cond do
          source_kind == "conceptual_questions" ->
            %{
              chapter: String.to_integer(chapter),
              section_order: 10_000,
              source_kind: source_kind,
              title: fallback_title(title, url),
              url: url
            }

          section != "" or String.downcase(page_slug) == "#{chapter}-introduction" ->
            %{
              chapter: String.to_integer(chapter),
              section_order: if(section == "", do: 0, else: String.to_integer(section)),
              source_kind: source_kind,
              title: fallback_title(title, url),
              url: url
            }

          true ->
            nil
        end

      nil ->
        nil
    end
  end

  defp conceptual_questions_slug?(slug) when is_binary(slug),
    do: String.ends_with?(String.downcase(slug), @conceptual_questions_suffix)

  defp conceptual_questions_slug?(_), do: false

  defp conceptual_questions_url?(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/")
    |> List.last()
    |> conceptual_questions_slug?()
  end

  defp conceptual_questions_url?(_), do: false

  defp chapter_title(chapter_number, nil), do: "Chapter #{chapter_number}"

  defp chapter_title(chapter_number, intro) do
    title =
      intro.title
      |> String.replace(~r/^\s*(?:Ch\.\s*)?#{chapter_number}\s*/i, "")
      |> String.trim()

    if title == "" or Regex.match?(~r/^Introduction\s*[-–:]?\s*$/i, title),
      do: "Chapter #{chapter_number}",
      else: "Chapter #{chapter_number}: #{title}"
  end

  defp validate_canonical_page(url, book_slug) do
    if canonical_page?(url, book_slug), do: :ok, else: {:error, :noncanonical_source_url}
  end

  defp canonical_page?(url, book_slug) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "openstax.org",
        userinfo: nil,
        port: port,
        query: nil,
        fragment: nil,
        path: path
      }
      when port in [nil, 443] ->
        Regex.match?(
          ~r{\A/books/#{Regex.escape(book_slug)}/pages/[a-z0-9][a-z0-9-]*\z},
          path || ""
        ) and
          page_slug_allowed?(path)

      _ ->
        false
    end
  end

  defp canonical_page?(_, _), do: false

  defp page_slug_allowed?(path) do
    slug = path |> String.split("/") |> List.last()
    slug not in @excluded_page_slugs
  end

  defp canonicalize_href(nil, _book_slug), do: nil

  defp canonicalize_href(href, book_slug) when is_binary(href) do
    href = href |> String.trim() |> String.replace("\\/", "/")

    uri =
      cond do
        String.starts_with?(href, "/") ->
          URI.parse("https://openstax.org#{href}")

        Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, href) ->
          URI.parse("https://openstax.org/books/#{book_slug}/pages/#{href}")

        true ->
          URI.parse(href)
      end

    %URI{uri | query: nil, fragment: nil}
    |> URI.to_string()
  rescue
    _ -> nil
  end

  defp page_title(document, book_slug) do
    document
    |> Floki.find("main h1, h1")
    |> List.first()
    |> node_text()
    |> case do
      "" ->
        book_slug
        |> String.replace("-", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)

      title ->
        title
    end
  end

  defp node_text(nil), do: ""

  defp node_text(node) do
    node
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp fallback_title(title, url) when is_binary(title) do
    case String.trim(title) do
      "" -> fallback_title(nil, url)
      value -> value
    end
  end

  defp fallback_title(_, url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
    |> String.split("/")
    |> List.last()
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp attribution(book_slug, source_url, source_body) do
    {license, license_type, license_url} = detected_license(source_body)

    %{
      "license" => license,
      "license_type" => license_type,
      "license_url" => license_url,
      "provider" => "OpenStax",
      "source_url" => source_url,
      "book_slug" => book_slug
    }
  end

  defp detected_license(source_body) when is_binary(source_body) do
    normalized = String.downcase(source_body)

    if String.contains?(normalized, [
         "creativecommons.org/licenses/by-nc-sa/4.0",
         "cc by-nc-sa 4.0",
         "cc by nc-sa 4.0"
       ]) do
      {"CC BY-NC-SA 4.0", "cc_by_nc_sa", "https://creativecommons.org/licenses/by-nc-sa/4.0/"}
    else
      {"CC BY 4.0", "cc_by", "https://creativecommons.org/licenses/by/4.0/"}
    end
  end

  defp detected_license(_source_body),
    do: {"CC BY 4.0", "cc_by", "https://creativecommons.org/licenses/by/4.0/"}
end
