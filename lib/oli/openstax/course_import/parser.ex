defmodule Oli.OpenStax.CourseImport.Parser do
  @moduledoc """
  Validates OpenStax entry URLs and converts an ingested source snapshot into
  the provider-neutral course outline consumed by the planner.
  """

  @details_path ~r{\A/details/books/(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)/?\z}
  @exceptional_word_threshold 3_000
  @exceptional_average_chunk_word_threshold 900
  @exceptional_chunk_threshold 10
  @max_pedagogical_chunks_per_lesson 4
  @current_plan_schema_version 6
  @deterministically_omittable_block_kinds ~w(
    navigation duplicated_boilerplate boilerplate unsafe_media
  )

  @type outline :: %{required(String.t()) => term()}
  @type parse_error :: :invalid_openstax_url

  @spec parse_openstax_url(String.t()) :: {:ok, String.t()} | {:error, parse_error}
  def parse_openstax_url(url) when is_binary(url) do
    uri = url |> String.trim() |> URI.parse()

    with %URI{scheme: "https", host: "openstax.org", path: path, userinfo: nil} <- uri,
         true <- uri.port in [nil, 443],
         true <- uri.query in [nil, ""],
         true <- uri.fragment in [nil, ""],
         %{"slug" => slug} <- Regex.named_captures(@details_path, path || "") do
      {:ok, slug}
    else
      _ -> {:error, :invalid_openstax_url}
    end
  end

  def parse_openstax_url(_), do: {:error, :invalid_openstax_url}

  @spec verify_book_url(String.t()) :: {:ok, String.t()} | {:error, parse_error}
  def verify_book_url(url), do: parse_openstax_url(url)

  @doc """
  Builds the schema 6 run outline. Source sections are never merged; only an
  exceptional section may be split at an existing pedagogical boundary.
  """
  @spec build_outline(map()) :: {:ok, outline()} | {:error, term()}
  def build_outline(snapshot), do: build_outline(snapshot, plan_schema_version: 6)

  @spec build_outline(map(), keyword()) :: {:ok, outline()} | {:error, term()}
  def build_outline(%{"book_slug" => book_slug, "chapters" => chapters} = snapshot, opts)
      when is_list(opts) and is_binary(book_slug) and is_list(chapters) do
    if Keyword.get(opts, :plan_schema_version) == @current_plan_schema_version do
      selected_chapters = Enum.filter(chapters, &Map.get(&1, "selected", true))

      case selected_chapters do
        [] ->
          {:error, :no_chapters_selected}

        chapters ->
          units =
            chapters
            |> Enum.sort_by(&Map.get(&1, "order", 0))
            |> Enum.with_index(1)
            |> Enum.map(fn {chapter, unit_order} ->
              {assessment_sources, sections} =
                chapter
                |> Map.get("sections", [])
                |> Enum.filter(&valid_section?/1)
                |> Enum.split_with(&assessment_source?/1)

              lessons =
                sections
                |> section_groups()
                |> Enum.with_index(1)
                |> Enum.map(fn {lesson_sections, lesson_order} ->
                  build_lesson(lesson_sections, lesson_order)
                end)

              %{
                "unit_name" => Map.get(chapter, "title", "Unit #{unit_order}"),
                "order" => unit_order,
                "source_reference" => %{
                  "chapter_id" => chapter["id"],
                  "source_url" => chapter["url"],
                  "assessment_source_urls" => Enum.map(assessment_sources, & &1["url"])
                },
                "assessment_evidence" => assessment_evidence(assessment_sources),
                "lessons" => lessons
              }
            end)

          if Enum.any?(units, &(Map.get(&1, "lessons", []) == [])) do
            {:error, :selected_chapter_has_no_sections}
          else
            {:ok,
             %{
               "book_slug" => book_slug,
               "title" => snapshot["title"] || format_book_title(book_slug),
               "license" => snapshot["license"] || %{},
               "units" => units
             }}
          end
      end
    else
      {:error, {:unsupported_openstax_plan_schema, Keyword.get(opts, :plan_schema_version)}}
    end
  end

  def build_outline(_, _), do: {:error, :invalid_source_snapshot}

  defp valid_section?(%{"url" => url}) when is_binary(url), do: url != ""
  defp valid_section?(_), do: false

  defp assessment_source?(section) do
    section["source_kind"] == "conceptual_questions" or
      get_in(section, ["source_metadata", "source_kind"]) == "conceptual_questions" or
      conceptual_questions_url?(section["url"])
  end

  defp conceptual_questions_url?(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/")
    |> List.last()
    |> String.ends_with?("-conceptual-questions")
  end

  defp conceptual_questions_url?(_), do: false

  defp assessment_evidence(sections) do
    sections
    |> Enum.flat_map(fn section ->
      section
      |> semantic_section_blocks()
      |> Enum.filter(&(block_kind(&1) == "assessment_question"))
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {block, index} ->
        prompt = block_text(block)

        if is_binary(prompt) and String.trim(prompt) != "" do
          semantic_payload = get_in(block, ["metadata", "semantic_payload"]) || %{}

          stable_id =
            semantic_payload["id"] ||
              block["source_key"] ||
              block["id"] ||
              assessment_question_id(section["url"], index, prompt)

          [
            %{
              "id" => stable_id,
              "prompt" => String.trim(prompt),
              "order" => index,
              "source_url" => section["url"],
              "source_title" => section["title"] || "Conceptual Questions",
              "source_block_ids" => [block["id"] || stable_id],
              "source_locator" =>
                semantic_payload["source_locator"] || block["source_locator"] || %{},
              "source_reference" =>
                semantic_payload["source_reference"] || block["source_reference"],
              "source_tags" => semantic_payload["source_tags"] || block["source_tags"] || [],
              "related_section_slugs" =>
                semantic_payload["related_section_slugs"] ||
                  block["related_section_slugs"] ||
                  [],
              "learning_objective_tags" =>
                semantic_payload["learning_objective_tags"] ||
                  block["learning_objective_tags"] ||
                  [],
              "content_hash" =>
                semantic_payload["content_hash"] ||
                  block["content_hash"] ||
                  assessment_content_hash(prompt)
            }
          ]
        else
          []
        end
      end)
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.with_index(1)
    |> Enum.map(fn {question, order} -> Map.put(question, "order", order) end)
  end

  defp assessment_question_id(url, index, prompt) do
    digest =
      :crypto.hash(:sha256, "#{url}|#{index}|#{prompt}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 24)

    "openstax-question-#{digest}"
  end

  defp assessment_content_hash(prompt) do
    :crypto.hash(:sha256, prompt)
    |> Base.encode16(case: :lower)
  end

  defp semantic_section_blocks(%{"content_blocks" => blocks})
       when is_list(blocks) and blocks != [],
       do: blocks

  defp semantic_section_blocks(%{"source_blocks" => blocks})
       when is_list(blocks) and blocks != [],
       do: blocks

  defp semantic_section_blocks(_), do: []

  defp block_kind(block),
    do:
      block["kind"] ||
        block["block_kind"] ||
        get_in(block, ["metadata", "semantic_payload", "kind"])

  defp block_text(block),
    do:
      block["text"] ||
        block["normalized_text"] ||
        get_in(block, ["metadata", "semantic_payload", "text"])

  defp section_groups(sections),
    do: sections |> Enum.flat_map(&split_exceptional_section/1) |> Enum.map(&[&1])

  defp split_exceptional_section(section) do
    blocks = section_content_blocks(section)
    {prelude, chunks} = pedagogical_chunks(section, blocks)
    source_words = section_word_count(section)

    if exceptional_section?(source_words, chunks) do
      fragment_count =
        max(
          ceil_div(source_words, @exceptional_word_threshold),
          ceil_div(length(chunks), @max_pedagogical_chunks_per_lesson)
        )
        |> min(length(chunks))

      objective_groups =
        section
        |> section_objectives()
        |> balanced_groups(fragment_count)

      chunks
      |> balanced_groups(fragment_count)
      |> Enum.with_index(1)
      |> Enum.map(fn {fragment_chunks, fragment_index} ->
        build_source_fragment(
          section,
          prelude,
          fragment_chunks,
          Enum.at(objective_groups, fragment_index - 1, []),
          fragment_index,
          fragment_count
        )
      end)
    else
      [section]
    end
  end

  defp exceptional_section?(_source_words, []), do: false

  defp exceptional_section?(source_words, chunks) do
    chunk_count = length(chunks)
    average_chunk_words = ceil_div(source_words, chunk_count)

    chunk_count > @exceptional_chunk_threshold or
      (source_words > @exceptional_word_threshold and
         (chunk_count > @max_pedagogical_chunks_per_lesson or
            average_chunk_words > @exceptional_average_chunk_word_threshold))
  end

  defp pedagogical_chunks(section, blocks) do
    document_heading_id =
      blocks
      |> Enum.find(fn block ->
        block_kind(block) == "heading" and heading_level(block) == 2 and
          not nested_semantic_block?(block)
      end)
      |> case do
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end

    {prelude, chunks, current} =
      Enum.reduce(blocks, {[], [], []}, fn block, {prelude, chunks, current} ->
        if pedagogical_boundary?(section, block, document_heading_id) do
          completed = if current == [], do: chunks, else: chunks ++ [current]
          {prelude, completed, [block]}
        else
          case current do
            [] -> {prelude ++ [block], chunks, current}
            _ -> {prelude, chunks, current ++ [block]}
          end
        end
      end)

    chunks = if current == [], do: chunks, else: chunks ++ [current]
    {prelude, chunks}
  end

  defp pedagogical_boundary?(section, block, document_heading_id) do
    kind = block_kind(block)
    level = heading_level(block)

    cond do
      kind == "objective" ->
        true

      kind != "heading" or level not in 2..3 ->
        false

      nested_semantic_block?(block) ->
        false

      is_binary(document_heading_id) and block["id"] == document_heading_id ->
        false

      section_title_heading?(section, block) ->
        false

      true ->
        true
    end
  end

  defp nested_semantic_block?(block) do
    block
    |> get_in(["source_locator", "semantic_path"])
    |> List.wrap()
    |> Enum.any?(&(&1 in ["blocks", "items"]))
  end

  defp section_title_heading?(section, block) do
    clean_title(block_text(block)) == clean_title(section["title"])
  end

  defp heading_level(%{"level" => level}) when is_integer(level), do: level

  defp heading_level(%{"level" => level}) when is_binary(level) do
    case Integer.parse(level) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp heading_level(_), do: nil

  defp build_source_fragment(
         section,
         prelude,
         fragment_chunks,
         objectives,
         fragment_index,
         fragment_count
       ) do
    fragment_blocks = prelude ++ Enum.flat_map(fragment_chunks, & &1)
    source_block_ids = recursive_source_block_ids(fragment_blocks)
    selected_ids = MapSet.new(source_block_ids)

    fragment_media =
      section
      |> section_media()
      |> Enum.with_index()
      |> Enum.filter(fn {media, _index} ->
        media_belongs_to_fragment?(media, selected_ids, fragment_index)
      end)
      |> Enum.map(&elem(&1, 0))

    source_media_ids = source_media_ids(fragment_media)

    fragment_metadata = %{
      "index" => fragment_index,
      "count" => fragment_count,
      "original_title" => section["title"],
      "source_block_ids" => source_block_ids,
      "source_media_ids" => source_media_ids
    }

    fragment_coverage =
      (section["coverage"] || section["source_coverage"] || %{})
      |> Map.put("complete", true)
      |> Map.put("source_fragment", fragment_metadata)
      |> Map.put("source_block_ids", source_block_ids)
      |> Map.put("source_media_ids", source_media_ids)

    section
    |> Map.put("title", fragment_title(section, fragment_chunks, fragment_index, fragment_count))
    |> Map.put("learning_objectives", objectives)
    |> Map.put("content_blocks", fragment_blocks)
    |> Map.put("source_blocks", fragment_blocks)
    |> Map.put("media", fragment_media)
    |> Map.put("source_media", fragment_media)
    |> Map.put("word_count", semantic_blocks_word_count(fragment_blocks))
    |> Map.put("source_word_count", semantic_blocks_word_count(fragment_blocks))
    |> Map.put("coverage", fragment_coverage)
    |> Map.put("source_coverage", fragment_coverage)
    |> Map.put("source_fragment", fragment_metadata)
  end

  defp media_belongs_to_fragment?(media, selected_block_ids, fragment_index) do
    evidence_ids =
      [media["source_block_id"] | List.wrap(media["evidence_block_ids"])]
      |> Enum.filter(&is_binary/1)

    case evidence_ids do
      [] -> fragment_index == 1
      ids -> Enum.any?(ids, &MapSet.member?(selected_block_ids, &1))
    end
  end

  defp fragment_title(section, fragment_chunks, fragment_index, fragment_count) do
    heading_titles =
      fragment_chunks
      |> Enum.flat_map(fn chunk ->
        chunk
        |> Enum.filter(&(block_kind(&1) == "heading"))
        |> Enum.map(&block_text/1)
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    scope =
      case {List.first(heading_titles), List.last(heading_titles)} do
        {nil, _} -> "Part #{fragment_index}"
        {first, first} -> first
        {first, last} -> "#{first} – #{last}"
      end

    "#{clean_title(section["title"]) || "OpenStax section"} — Part #{fragment_index} of #{fragment_count}: #{scope}"
  end

  defp balanced_groups([], _group_count), do: []

  defp balanced_groups(items, group_count) when group_count > 0 do
    group_count = min(group_count, length(items))
    base_size = div(length(items), group_count)
    larger_groups = rem(length(items), group_count)

    1..group_count
    |> Enum.map_reduce(items, fn index, remaining ->
      size = base_size + if(index <= larger_groups, do: 1, else: 0)
      Enum.split(remaining, size)
    end)
    |> elem(0)
  end

  defp ceil_div(value, divisor)
       when is_integer(value) and value >= 0 and is_integer(divisor) and divisor > 0,
       do: div(value + divisor - 1, divisor)

  defp section_objectives(section),
    do:
      section
      |> Map.get("learning_objectives", Map.get(section, "source_objectives", []))
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp build_lesson(sections, lesson_order) do
    source_blocks = lesson_source_blocks(sections)
    source_media = lesson_source_media(sections)
    source_block_ids = recursive_source_block_ids(source_blocks)

    {substantive_block_ids, deterministically_omittable_block_ids} =
      source_blocks
      |> recursive_source_blocks()
      |> Enum.split_with(&substantive_source_block?/1)

    substantive_block_ids = Enum.map(substantive_block_ids, & &1["id"]) |> Enum.uniq()

    deterministically_omittable_block_ids =
      Enum.map(deterministically_omittable_block_ids, & &1["id"]) |> Enum.uniq()

    source_media_ids = source_media_ids(source_media)
    source_word_count = Enum.reduce(sections, 0, &(&2 + section_word_count(&1)))
    {source_excerpt, excerpt_coverage} = lesson_excerpt(source_blocks)

    source_objectives =
      sections
      |> Enum.flat_map(&Map.get(&1, "learning_objectives", []))
      |> Enum.uniq()

    %{
      "title" => lesson_title(sections, lesson_order),
      "order" => lesson_order,
      "source_excerpt" => source_excerpt,
      "source_sections" => Enum.map(sections, & &1["url"]),
      "source_evidence_links" => Enum.map(sections, & &1["url"]),
      "source_objectives" => source_objectives,
      "source_blocks" => source_blocks,
      "source_media" => source_media,
      "source_word_count" => source_word_count,
      "source_coverage" =>
        %{
          "complete" => Enum.all?(sections, &complete_semantic_source?/1),
          "section_count" => length(sections),
          "section_urls" => Enum.map(sections, & &1["url"]),
          "source_block_ids" => source_block_ids,
          "source_media_ids" => source_media_ids,
          "source_fragments" =>
            sections
            |> Enum.map(& &1["source_fragment"])
            |> Enum.filter(&is_map/1),
          "block_count" => length(source_blocks),
          "semantic_block_count" => recursive_block_count(source_blocks),
          "block_kind_counts" => block_kind_counts(source_blocks),
          "objective_count" => length(source_objectives),
          "media_count" => length(source_media),
          "word_count" => source_word_count,
          "excerpt_block_count" => excerpt_coverage.block_count,
          "excerpt_block_ids" => excerpt_coverage.block_ids,
          "excerpt_truncated" => excerpt_coverage.truncated
        }
        |> add_current_source_coverage(
          substantive_block_ids,
          deterministically_omittable_block_ids
        )
    }
  end

  defp add_current_source_coverage(
         coverage,
         substantive_block_ids,
         deterministically_omittable_block_ids
       ) do
    coverage
    |> Map.put("policy", "exact_ast_source")
    |> Map.put("policy_schema_version", @current_plan_schema_version)
    |> Map.put("substantive_block_ids", substantive_block_ids)
    |> Map.put(
      "deterministically_omittable_block_ids",
      deterministically_omittable_block_ids
    )
    |> Map.put(
      "deterministically_omittable_kinds",
      @deterministically_omittable_block_kinds
    )
  end

  defp recursive_source_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        [block] ++
          recursive_source_blocks(block["blocks"]) ++
          recursive_list_source_blocks(block["items"])

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp recursive_list_source_blocks(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = item -> recursive_source_blocks(item["children"])
      _ -> []
    end)
  end

  defp substantive_source_block?(block) do
    block_kind(block) not in @deterministically_omittable_block_kinds
  end

  defp recursive_source_block_ids(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn block ->
      direct = if is_binary(block["id"]), do: [block["id"]], else: []

      direct ++
        recursive_source_block_ids(block["blocks"]) ++
        list_item_source_block_ids(block["items"])
    end)
    |> Enum.uniq()
  end

  defp list_item_source_block_ids(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = item -> recursive_source_block_ids(item["children"])
      _ -> []
    end)
  end

  defp source_media_ids(media) do
    media
    |> List.wrap()
    |> Enum.map(&(&1["id"] || &1["source_media_id"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp semantic_blocks_word_count(blocks) do
    blocks
    |> List.wrap()
    |> Enum.map(&block_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> count_words()
  end

  defp lesson_source_blocks(sections) do
    sections
    |> Enum.flat_map(fn section ->
      section
      |> section_content_blocks()
      |> Enum.map(fn block ->
        block
        |> Map.put("source_section_url", section["url"])
        |> Map.put("source_section_title", clean_title(section["title"]) || "OpenStax section")
        |> Map.put("source_section_order", Map.get(section, "order"))
      end)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {block, lesson_order} -> Map.put(block, "lesson_order", lesson_order) end)
  end

  defp section_content_blocks(%{"content_blocks" => blocks})
       when is_list(blocks) and blocks != [],
       do: blocks

  defp section_content_blocks(%{"source_blocks" => blocks})
       when is_list(blocks) and blocks != [] do
    Enum.map(blocks, fn block ->
      semantic_payload = get_in(block, ["metadata", "semantic_payload"]) || %{}

      semantic_payload
      |> Map.merge(block)
      |> Map.put("id", block["id"] || semantic_payload["id"])
      |> Map.put("kind", block_kind(block))
      |> Map.put("text", block_text(block))
    end)
  end

  defp section_content_blocks(_section), do: []

  defp lesson_source_media(sections) do
    sections
    |> Enum.flat_map(fn section ->
      section
      |> section_media()
      |> Enum.map(fn media ->
        media
        |> Map.put("source_section_url", section["url"])
        |> Map.put("source_section_title", clean_title(section["title"]) || "OpenStax section")
      end)
    end)
    |> Enum.uniq_by(fn media ->
      media["id"] || {media["src"], media["alt"], media["source_section_url"]}
    end)
  end

  defp section_media(%{"media" => media}) when is_list(media), do: media
  defp section_media(%{"source_media" => media}) when is_list(media), do: media
  defp section_media(%{"assets" => media}) when is_list(media), do: media
  defp section_media(_), do: []

  defp section_word_count(%{"source_word_count" => count})
       when is_integer(count) and count >= 0,
       do: count

  defp section_word_count(%{"word_count" => count}) when is_integer(count) and count >= 0,
    do: count

  defp section_word_count(section) do
    section
    |> Map.get("excerpt", "")
    |> count_words()
  end

  defp complete_semantic_source?(section),
    do:
      get_in(section, ["coverage", "complete"]) == true or
        get_in(section, ["source_coverage", "complete"]) == true

  defp lesson_title([section], lesson_order),
    do: clean_title(section["title"]) || "Lesson #{lesson_order}"

  defp lesson_title([first | rest], lesson_order) do
    first_title = clean_title(first["title"])
    last_title = rest |> List.last() |> Map.get("title") |> clean_title()

    cond do
      is_binary(first_title) and is_binary(last_title) and first_title != last_title ->
        "#{first_title} – #{last_title}"

      is_binary(first_title) ->
        first_title

      true ->
        "Lesson #{lesson_order}"
    end
  end

  defp lesson_title(_, lesson_order), do: "Lesson #{lesson_order}"

  defp lesson_excerpt(source_blocks) do
    preview_limit = 2_000
    block_ids = recursive_source_block_ids(source_blocks)

    text =
      source_blocks
      |> recursive_source_blocks()
      |> Enum.map(&block_text/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    preview = String.slice(text, 0, preview_limit)

    {preview,
     %{
       block_count: length(block_ids),
       block_ids: block_ids,
       truncated: String.length(text) > String.length(preview)
     }}
  end

  defp block_kind_counts(blocks) do
    blocks
    |> Enum.map(&Map.get(&1, "kind", "unknown"))
    |> Enum.frequencies()
  end

  defp recursive_block_count(blocks) do
    Enum.reduce(blocks, 0, fn block, count ->
      count + 1 +
        recursive_block_count(Map.get(block, "blocks", [])) +
        list_child_block_count(Map.get(block, "items", []))
    end)
  end

  defp list_child_block_count(items) do
    items
    |> List.wrap()
    |> Enum.reduce(0, fn
      %{} = item, count -> count + recursive_block_count(Map.get(item, "children", []))
      _item, count -> count
    end)
  end

  defp count_words(text) when is_binary(text) do
    ~r/[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/u
    |> Regex.scan(text)
    |> length()
  end

  defp count_words(_), do: 0

  defp clean_title(nil), do: nil

  defp clean_title(title) when is_binary(title) do
    title
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp clean_title(_), do: nil

  defp format_book_title(book_slug) do
    book_slug
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
