defmodule Oli.OpenStax.CourseImport.Parser do
  @moduledoc """
  Validates OpenStax entry URLs and converts an ingested source snapshot into
  the provider-neutral course outline consumed by the planner.
  """

  @details_path ~r{\A/details/books/(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)/?\z}
  @default_bundle_size 2
  @standalone_word_threshold 1_200
  @standalone_block_threshold 24
  @standalone_major_feature_threshold 4
  @merge_objective_limit 3
  @exceptional_word_threshold 3_000
  @exceptional_average_chunk_word_threshold 900
  @exceptional_chunk_threshold 10
  @max_pedagogical_chunks_per_lesson 4
  @compatibility_excerpt_block_limit 24
  @compatibility_excerpt_char_limit 10_000
  @full_source_plan_schema_version 4
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
  Builds the legacy adaptive outline used by plan schemas v1-v3.

  Use `build_outline/2` with `plan_schema_version: 4` for the refined import
  contract, where source sections are never merged and only an exceptional
  section may be split at an existing pedagogical boundary.
  """
  @spec build_outline(map()) :: {:ok, outline()} | {:error, term()}
  def build_outline(snapshot), do: build_outline(snapshot, [])

  @spec build_outline(map(), keyword()) :: {:ok, outline()} | {:error, term()}
  def build_outline(%{"book_slug" => book_slug, "chapters" => chapters} = snapshot, opts)
      when is_list(opts) and is_binary(book_slug) and is_list(chapters) do
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
              |> section_groups(opts)
              |> Enum.with_index(1)
              |> Enum.map(fn {lesson_sections, lesson_order} ->
                build_lesson(lesson_sections, lesson_order, opts)
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

  defp section_groups(sections, opts) do
    if plan_schema_version(opts) >= @full_source_plan_schema_version do
      sections
      |> Enum.flat_map(&split_exceptional_section/1)
      |> Enum.map(&[&1])
    else
      adaptive_section_groups(sections)
    end
  end

  defp adaptive_section_groups(sections) do
    {opening_hook, numbered_sections} = chapter_opening(sections)

    {groups, pending} =
      numbered_sections
      |> Enum.flat_map(&split_exceptional_section/1)
      |> Enum.reduce({[], []}, fn section, {groups, pending} ->
        if standalone_section?(section) do
          {groups ++ light_section_groups(pending) ++ [[section]], []}
        else
          {groups, pending ++ [section]}
        end
      end)

    groups
    |> Kernel.++(light_section_groups(pending))
    |> merge_chapter_opening(opening_hook)
  end

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

  defp light_section_groups([]), do: []

  defp light_section_groups(sections) do
    {groups, pending} =
      Enum.reduce(sections, {[], []}, fn section, {groups, pending} ->
        candidate = pending ++ [section]

        cond do
          pending == [] ->
            {groups, candidate}

          length(candidate) <= @default_bundle_size and mergeable_group?(candidate) ->
            {groups, candidate}

          true ->
            {groups ++ [pending], [section]}
        end
      end)

    if pending == [], do: groups, else: groups ++ [pending]
  end

  defp mergeable_group?(sections) do
    Enum.reduce(sections, 0, &(&2 + section_word_count(&1))) < @standalone_word_threshold and
      sections
      |> Enum.flat_map(&section_objectives/1)
      |> Enum.uniq()
      |> length() < @merge_objective_limit
  end

  defp chapter_opening([section | rest]) do
    if chapter_intro?(section) and section_objectives(section) == [],
      do: {section, rest},
      else: {nil, [section | rest]}
  end

  defp chapter_opening([]), do: {nil, []}

  defp merge_chapter_opening([], nil), do: []
  defp merge_chapter_opening([], opening), do: [[opening]]
  defp merge_chapter_opening(groups, nil), do: groups

  defp merge_chapter_opening([first | rest], opening),
    do: [[opening | first] | rest]

  defp standalone_section?(section) do
    blocks = section_content_blocks(section)

    major_features =
      recursive_kind_count(blocks, "heading", &major_heading?/1) +
        recursive_kind_count(blocks, "callout")

    is_map(section["source_fragment"]) or
      (chapter_intro?(section) and section_objectives(section) != []) or
      section_word_count(section) >= @standalone_word_threshold or
      length(section_objectives(section)) >= 2 or
      recursive_block_count(blocks) >= @standalone_block_threshold or
      major_features >= @standalone_major_feature_threshold or
      Enum.any?(section_media(section), &meaningful_figure?/1)
  end

  defp major_heading?(%{"level" => level}) when is_integer(level), do: level in 2..4
  defp major_heading?(_), do: false

  defp meaningful_figure?(media) when is_map(media) do
    is_binary(media["src"] || media["source_url"] || media["url"]) and
      is_binary(media["alt"] || media["alt_text"])
  end

  defp meaningful_figure?(_), do: false

  defp section_objectives(section),
    do:
      section
      |> Map.get("learning_objectives", Map.get(section, "source_objectives", []))
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp chapter_intro?(section) do
    section["order"] == 0 or
      case section["url"] do
        url when is_binary(url) ->
          url
          |> URI.parse()
          |> Map.get(:path)
          |> to_string()
          |> String.ends_with?("-introduction")

        _ ->
          false
      end
  end

  defp build_lesson(sections, lesson_order, opts) do
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
        |> maybe_add_full_source_coverage(
          opts,
          substantive_block_ids,
          deterministically_omittable_block_ids
        )
    }
  end

  defp maybe_add_full_source_coverage(
         coverage,
         opts,
         substantive_block_ids,
         deterministically_omittable_block_ids
       ) do
    if plan_schema_version(opts) >= @full_source_plan_schema_version do
      coverage
      |> Map.put("policy", "full_substantive_source")
      |> Map.put("policy_schema_version", @full_source_plan_schema_version)
      |> Map.put("substantive_block_ids", substantive_block_ids)
      |> Map.put(
        "deterministically_omittable_block_ids",
        deterministically_omittable_block_ids
      )
      |> Map.put(
        "deterministically_omittable_kinds",
        @deterministically_omittable_block_kinds
      )
    else
      coverage
    end
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

  defp plan_schema_version(opts) do
    case Keyword.get(opts, :plan_schema_version, 3) do
      version when is_integer(version) -> version
      _ -> 3
    end
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

  defp section_content_blocks(section) do
    case Map.get(section, "excerpt") do
      excerpt when is_binary(excerpt) and excerpt != "" ->
        url = Map.get(section, "url", "")

        [
          %{
            "id" => legacy_block_id(url),
            "kind" => "paragraph",
            "order" => 1,
            "heading_path" => [],
            "text" => excerpt,
            "source_locator" => %{"legacy_excerpt" => true}
          }
        ]

      _ ->
        []
    end
  end

  defp legacy_block_id(url) do
    digest =
      :crypto.hash(:sha256, "#{url}|legacy-excerpt")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 24)

    "openstax-block-#{digest}"
  end

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
    selected_blocks = select_excerpt_blocks(source_blocks)

    header_budget =
      selected_blocks
      |> Enum.uniq_by(& &1["source_section_url"])
      |> Enum.reduce(0, fn block, size ->
        size + String.length(block["source_section_title"] || "OpenStax section") + 5
      end)

    block_budget =
      case length(selected_blocks) do
        0 ->
          @compatibility_excerpt_char_limit

        count ->
          max(div(@compatibility_excerpt_char_limit - header_budget, count), 120)
      end

    {parts, _current_section, clipped?} =
      Enum.reduce(selected_blocks, {[], nil, false}, fn block,
                                                        {parts, current_section, clipped?} ->
        section_url = block["source_section_url"]
        section_title = block["source_section_title"] || "OpenStax section"
        {snippet, snippet_clipped?} = compatibility_block_text(block, block_budget)

        section_parts =
          if section_url == current_section,
            do: [snippet],
            else: ["## #{section_title}", snippet]

        {parts ++ section_parts, section_url, clipped? or snippet_clipped?}
      end)

    excerpt =
      parts
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    coverage = %{
      block_count: length(selected_blocks),
      block_ids: Enum.map(selected_blocks, & &1["id"]),
      truncated: length(selected_blocks) < length(source_blocks) or clipped?
    }

    {excerpt, coverage}
  end

  defp select_excerpt_blocks(blocks)
       when length(blocks) <= @compatibility_excerpt_block_limit,
       do: blocks

  defp select_excerpt_blocks(blocks) do
    first_per_section = Enum.uniq_by(blocks, & &1["source_section_url"])

    structural =
      Enum.filter(blocks, fn block ->
        block["kind"] in ~w(heading objectives callout figure table code footnotes)
      end)

    required =
      (first_per_section ++ structural)
      |> Enum.uniq_by(& &1["id"])

    cond do
      length(required) >= @compatibility_excerpt_block_limit ->
        evenly_spaced(required, @compatibility_excerpt_block_limit)
        |> restore_source_order(blocks)

      true ->
        remaining_slots = @compatibility_excerpt_block_limit - length(required)
        required_ids = MapSet.new(required, & &1["id"])
        remaining = Enum.reject(blocks, &MapSet.member?(required_ids, &1["id"]))

        (required ++ evenly_spaced(remaining, remaining_slots))
        |> Enum.uniq_by(& &1["id"])
        |> restore_source_order(blocks)
    end
  end

  defp evenly_spaced(_items, count) when count <= 0, do: []

  defp evenly_spaced(items, count) when count >= length(items), do: items

  defp evenly_spaced(items, 1), do: [List.first(items)]

  defp evenly_spaced(items, count) do
    last_index = length(items) - 1

    0..(count - 1)
    |> Enum.map(fn index ->
      source_index = round(index * last_index / (count - 1))
      Enum.at(items, source_index)
    end)
    |> Enum.uniq()
  end

  defp restore_source_order(selected, source_blocks) do
    selected_ids = MapSet.new(selected, & &1["id"])
    Enum.filter(source_blocks, &MapSet.member?(selected_ids, &1["id"]))
  end

  defp compatibility_block_text(block, budget) do
    text =
      case block do
        %{"kind" => "heading", "text" => text} ->
          "### #{text}"

        %{"kind" => "objectives", "items" => items} ->
          "Learning Objectives:\n" <> Enum.map_join(items, "\n", &"- #{&1}")

        %{"kind" => "callout"} ->
          callout_label =
            [block["title"], block["subtitle"]]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join(": ")

          "Callout (#{block["callout_type"]}): #{callout_label}\n#{block["text"]}"

        %{"kind" => "figure"} ->
          "Figure: #{block["caption"] || block["text"]}"

        %{"kind" => "table"} ->
          "Table: #{block["text"]}"

        %{"kind" => "code"} ->
          "Code example:\n#{block["text"]}"

        %{"kind" => "footnotes"} ->
          "Footnotes: #{block["text"]}"

        %{"kind" => "list"} ->
          block
          |> Map.get("items", [])
          |> Enum.map_join("\n", fn item -> "- #{item["text"]}" end)

        %{"text" => text} ->
          text

        _ ->
          ""
      end
      |> String.trim()

    if String.length(text) > budget do
      {String.slice(text, 0, max(budget - 1, 0)) <> "…", true}
    else
      {text, false}
    end
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

  defp recursive_kind_count(blocks, kind, predicate \\ fn _ -> true end) do
    Enum.reduce(blocks, 0, fn block, count ->
      matching = if block["kind"] == kind and predicate.(block), do: 1, else: 0

      count + matching +
        recursive_kind_count(Map.get(block, "blocks", []), kind, predicate) +
        list_child_kind_count(Map.get(block, "items", []), kind, predicate)
    end)
  end

  defp list_child_kind_count(items, kind, predicate) do
    items
    |> List.wrap()
    |> Enum.reduce(0, fn
      %{} = item, count ->
        count + recursive_kind_count(Map.get(item, "children", []), kind, predicate)

      _item, count ->
        count
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
