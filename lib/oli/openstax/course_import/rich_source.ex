defmodule Oli.OpenStax.CourseImport.RichSource do
  @moduledoc """
  Persists and reconstructs the semantic OpenStax source corpus for a run.

  Run checkpoints retain only table-of-contents metadata. Full instructional
  text, semantic blocks, and media references live in normalized rows and can
  be loaded for one lesson without reading the entire book.
  """

  import Ecto.Query

  alias Oli.OpenStax.CourseImport.{
    Lesson,
    LessonSource,
    Run,
    SourceAsset,
    SourceBlock,
    SourceSection,
    Telemetry
  }

  alias Oli.Repo
  alias Oli.Utils.Database

  @rich_section_keys ~w(
    body content excerpt full_body html content_blocks blocks source_blocks media source_media
    word_count coverage source_metadata
  )

  @spec persist_snapshot(Ecto.UUID.t(), map()) ::
          {:ok,
           %{sections: non_neg_integer(), blocks: non_neg_integer(), assets: non_neg_integer()}}
          | {:error, term()}
  def persist_snapshot(run_id, snapshot) when is_binary(run_id) and is_map(snapshot) do
    section_specs = snapshot_sections(snapshot)

    Repo.transaction(fn ->
      Repo.get(Run, run_id) || Repo.rollback(:not_found)
      Repo.delete_all(from(section in SourceSection, where: section.run_id == ^run_id))

      section_specs
      |> Enum.with_index(1)
      |> Enum.reduce(%{sections: 0, blocks: 0, assets: 0}, fn {spec, global_order}, acc ->
        {block_count, asset_count} =
          persist_section!(run_id, snapshot, spec, global_order)

        %{
          sections: acc.sections + 1,
          blocks: acc.blocks + block_count,
          assets: acc.assets + asset_count
        }
      end)
    end)
    |> tap(fn
      {:ok, counts} -> Telemetry.source_persisted(run_id, counts)
      _ -> :ok
    end)
  rescue
    exception -> {:error, {:source_corpus_persistence_failed, Exception.message(exception)}}
  end

  def persist_snapshot(_, _), do: {:error, :invalid_source_snapshot}

  @spec compact_snapshot(map()) :: map()
  def compact_snapshot(snapshot) when is_map(snapshot) do
    Map.update(snapshot, "chapters", [], fn chapters ->
      Enum.map(List.wrap(chapters), fn chapter ->
        chapter
        |> drop_rich_fields()
        |> Map.update("sections", [], fn sections ->
          Enum.map(List.wrap(sections), &drop_rich_fields/1)
        end)
      end)
    end)
  end

  def compact_snapshot(_), do: %{}

  @spec load_snapshot(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def load_snapshot(run_id, base_snapshot \\ %{})

  def load_snapshot(run_id, base_snapshot) when is_binary(run_id) and is_map(base_snapshot) do
    with {:ok, corpus} <- load_run_corpus(run_id) do
      sections_by_url = Map.new(corpus.sections, &{&1["url"], &1})
      chapters = hydrate_chapters(base_snapshot["chapters"], corpus.sections, sections_by_url)

      {:ok, Map.put(base_snapshot, "chapters", chapters)}
    end
  end

  def load_snapshot(_, _), do: {:error, :invalid_input}

  @spec load_run_corpus(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def load_run_corpus(run_id) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, :not_found}

      %Run{} = run ->
        sections =
          SourceSection
          |> where([section], section.run_id == ^run_id)
          |> order_by([section], asc: section.order)
          |> Repo.all()
          |> preload_corpus()
          |> Enum.map(&section_payload/1)

        {:ok,
         %{
           run_id: run_id,
           sections: sections,
           source_word_count: Enum.reduce(sections, 0, &(&2 + &1["source_word_count"])),
           attribution: attribution_payload(run, sections)
         }}
    end
  end

  def load_run_corpus(_), do: {:error, :not_found}

  @spec link_lessons(Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def link_lessons(run_id) when is_binary(run_id) do
    Repo.transaction(fn ->
      Repo.get(Run, run_id) || Repo.rollback(:not_found)

      sections =
        SourceSection
        |> where([section], section.run_id == ^run_id)
        |> order_by([section], asc: section.order)
        |> preload(
          blocks: ^from(block in SourceBlock, order_by: [asc: block.order]),
          assets: ^from(asset in SourceAsset, order_by: [asc: asset.order])
        )
        |> Repo.all()

      sections_by_url = Map.new(sections, &{&1.canonical_url, &1})

      lessons =
        Lesson
        |> where([lesson], lesson.run_id == ^run_id)
        |> order_by([lesson], asc: lesson.unit_id, asc: lesson.order)
        |> Repo.all()

      Repo.delete_all(from(join in LessonSource, where: join.run_id == ^run_id))

      now = DateTime.utc_now()

      {linked_count, lesson_source_rows} =
        Enum.reduce(lessons, {0, []}, fn lesson, {total, rows} ->
          linked_sections =
            lesson
            |> lesson_urls()
            |> Enum.map(&Map.get(sections_by_url, &1))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq_by(& &1.id)

          available_blocks =
            linked_sections
            |> Enum.flat_map(& &1.blocks)
            |> Enum.uniq_by(& &1.id)

          block_selection = source_id_selection(lesson.source_coverage, "source_block_ids")
          blocks = select_source_blocks(available_blocks, block_selection)
          validate_source_block_selection!(lesson, available_blocks, block_selection)

          available_assets =
            linked_sections
            |> Enum.flat_map(& &1.assets)
            |> Enum.uniq_by(& &1.id)

          media_selection = source_id_selection(lesson.source_coverage, "source_media_ids")
          assets = select_source_assets(available_assets, media_selection)
          validate_source_asset_selection!(lesson, available_assets, media_selection)

          lesson_rows =
            blocks
            |> Enum.with_index(1)
            |> Enum.map(fn {block, order} ->
              %{
                id: Ecto.UUID.generate(),
                run_id: run_id,
                lesson_id: lesson.id,
                source_block_id: block.id,
                order: order,
                purpose: "instruction",
                metadata: %{"source_section_id" => block.source_section_id},
                inserted_at: now,
                updated_at: now
              }
            end)

          source_word_count =
            if is_integer(lesson.source_word_count) and lesson.source_word_count > 0 do
              lesson.source_word_count
            else
              Enum.reduce(
                linked_sections,
                0,
                &(&2 + (&1.normalized_word_count || 0))
              )
            end

          coverage =
            (lesson.source_coverage || %{})
            |> Map.put("linked_block_count", length(blocks))
            |> Map.put("linked_source_block_ids", Enum.map(blocks, & &1.source_key))
            |> Map.put("linked_source_media_ids", Enum.map(assets, & &1.source_key))
            |> Map.put("linked_source_urls", lesson_urls(lesson))

          lesson
          |> Lesson.changeset(%{
            source_word_count: source_word_count,
            source_coverage: coverage
          })
          |> Repo.update!()

          {total + length(blocks), [lesson_rows | rows]}
        end)

      lesson_source_rows
      |> Enum.reverse()
      |> List.flatten()
      |> then(&Database.batch_insert_all(LessonSource, &1))

      linked_count
    end)
  rescue
    exception -> {:error, {:lesson_source_link_failed, Exception.message(exception)}}
  end

  def link_lessons(_), do: {:error, :invalid_input}

  @spec load_lesson_corpus(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def load_lesson_corpus(lesson_id) when is_binary(lesson_id) do
    case Repo.get(Lesson, lesson_id) do
      nil ->
        {:error, :not_found}

      %Lesson{} = lesson ->
        joins =
          LessonSource
          |> where([join], join.lesson_id == ^lesson.id and join.run_id == ^lesson.run_id)
          |> order_by([join], asc: join.order)
          |> preload(
            source_block: [
              source_section:
                ^from(section in SourceSection,
                  preload: [
                    assets:
                      ^from(asset in SourceAsset,
                        order_by: [asc: asset.order],
                        preload: [:media]
                      )
                  ]
                )
            ]
          )
          |> Repo.all()

        blocks = Enum.map(joins, &block_payload(&1.source_block))
        media_selection = source_id_selection(lesson.source_coverage, "source_media_ids")

        sections =
          joins
          |> Enum.map(& &1.source_block.source_section)
          |> Enum.uniq_by(& &1.id)
          |> Enum.map(&section_payload_from_loaded(&1, media_selection))

        run = Repo.get!(Run, lesson.run_id)

        {:ok,
         %{
           "lesson_id" => lesson.id,
           "run_id" => lesson.run_id,
           "source_blocks" => blocks,
           "source_sections" => sections,
           "source_media" => Enum.flat_map(sections, & &1["source_media"]),
           "source_word_count" => lesson.source_word_count,
           "source_coverage" => lesson.source_coverage || %{},
           "attribution" => attribution_payload(run, sections)
         }}
    end
  end

  def load_lesson_corpus(_), do: {:error, :not_found}

  defp persist_section!(run_id, snapshot, spec, global_order) do
    section = spec.section
    blocks = normalized_blocks(section)
    canonical_url = value(section, "url") || value(section, "canonical_url") || ""
    text = Enum.map_join(blocks, "\n\n", & &1.normalized_text)

    persisted_section =
      %SourceSection{}
      |> SourceSection.changeset(%{
        run_id: run_id,
        canonical_url: canonical_url,
        section_slug: section_slug(canonical_url),
        title: value(section, "title") || section_slug(canonical_url) || "OpenStax section",
        order: global_order,
        chapter_id: value(spec.chapter, "id"),
        chapter_order: positive_integer(value(spec.chapter, "order"), spec.chapter_order),
        section_order: positive_integer(value(section, "order"), spec.section_order),
        learning_objectives:
          normalize_strings(
            value(section, "learning_objectives") || value(section, "source_objectives")
          ),
        normalized_word_count:
          nonnegative_integer(
            value(section, "source_word_count") || value(section, "word_count"),
            word_count(text)
          ),
        content_hash: value(section, "content_hash") || sha256(text),
        retrieved_at: parsed_datetime(value(section, "retrieved_at") || snapshot["ingested_at"]),
        attribution_payload: snapshot["license"] || %{},
        source_coverage:
          normalize_map(value(section, "source_coverage") || value(section, "coverage")),
        source_metadata:
          normalize_map(value(section, "source_metadata"))
          |> Map.put_new("source_schema_version", 2)
      })
      |> Repo.insert!()

    now = DateTime.utc_now()

    persisted_blocks =
      Enum.map(blocks, fn block ->
        %{
          id: Ecto.UUID.generate(),
          run_id: run_id,
          source_section_id: persisted_section.id,
          source_key: block.source_key,
          order: block.order,
          heading_path: block.heading_path,
          block_kind: block.block_kind,
          normalized_text: block.normalized_text,
          source_locator: block.source_locator,
          token_estimate: block.token_estimate,
          content_hash: block.content_hash,
          metadata: block.metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    Database.batch_insert_all(SourceBlock, persisted_blocks)

    blocks_by_order = Map.new(persisted_blocks, &{&1.order, &1.id})
    blocks_by_source_key = Map.new(persisted_blocks, &{&1.source_key, &1.id})

    assets =
      section
      |> normalized_assets(blocks)
      |> Enum.map(fn asset ->
        %{
          id: Ecto.UUID.generate(),
          run_id: run_id,
          source_section_id: persisted_section.id,
          source_block_id:
            Map.get(blocks_by_source_key, asset.source_block_key) ||
              Map.get(blocks_by_order, asset.source_block_order),
          source_key: asset.source_key,
          order: asset.order,
          asset_type: asset.asset_type,
          source_url: resolve_asset_url(canonical_url, asset.source_url),
          alt_text: asset.alt_text,
          caption: asset.caption,
          declared_mime_type: asset.declared_mime_type,
          source_locator: asset.source_locator,
          status: "discovered",
          required: false,
          metadata: asset.metadata,
          inserted_at: now,
          updated_at: now
        }
      end)

    Database.batch_insert_all(SourceAsset, assets)

    {length(persisted_blocks), length(assets)}
  end

  defp snapshot_sections(snapshot) do
    snapshot
    |> Map.get("chapters", [])
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {chapter, chapter_order} ->
      chapter
      |> value("sections")
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {section, section_order} ->
        %{
          chapter: chapter,
          chapter_order: chapter_order,
          section: section,
          section_order: section_order
        }
      end)
    end)
  end

  defp normalized_blocks(section) do
    source_blocks =
      value(section, "source_blocks") || value(section, "content_blocks") ||
        value(section, "blocks") || []

    source_blocks
    |> List.wrap()
    |> flatten_semantic_blocks()
    |> Enum.with_index(1)
    |> Enum.map(fn {%{block: block, semantic_path: semantic_path}, order} ->
      text = semantic_block_text(block)

      %{
        source_key:
          normalized_source_key(
            value(block, "id"),
            "block",
            "#{value(section, "url")}|#{Enum.join(semantic_path, ".")}|#{text}"
          ),
        order: order,
        heading_path: normalize_strings(value(block, "heading_path")),
        block_kind: value(block, "block_kind") || value(block, "kind") || "paragraph",
        normalized_text: text,
        source_locator:
          normalize_map(value(block, "source_locator"))
          |> Map.put_new("semantic_path", semantic_path),
        token_estimate: nonnegative_integer(value(block, "token_estimate"), token_estimate(text)),
        content_hash: value(block, "content_hash") || sha256(text),
        metadata:
          normalize_map(value(block, "metadata"))
          |> Map.put("semantic_payload", semantic_payload_for_block(block)),
        source_media: value(block, "source_media") || value(block, "media") || []
      }
    end)
    |> case do
      [] ->
        case value(section, "excerpt") do
          excerpt when is_binary(excerpt) and excerpt != "" ->
            text = String.trim(excerpt)

            [
              %{
                source_key:
                  normalized_source_key(
                    nil,
                    "block",
                    "#{value(section, "url")}|legacy-excerpt"
                  ),
                order: 1,
                heading_path: normalize_strings([value(section, "title")]),
                block_kind: "legacy_excerpt",
                normalized_text: text,
                source_locator: %{"legacy_excerpt" => true},
                token_estimate: token_estimate(text),
                content_hash: sha256(text),
                metadata: %{},
                source_media: []
              }
            ]

          _ ->
            []
        end

      blocks ->
        blocks
    end
  end

  defp flatten_semantic_blocks(blocks, parent_path \\ []) do
    blocks
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {block, index} ->
      path = parent_path ++ [index]

      [%{block: block, semantic_path: path}] ++
        flatten_semantic_blocks(value(block, "blocks"), path ++ ["blocks"]) ++
        flatten_list_item_blocks(value(block, "items"), path)
    end)
  end

  defp flatten_list_item_blocks(items, parent_path) do
    items
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {item, index} ->
      flatten_semantic_blocks(value(item, "children"), parent_path ++ ["items", index])
    end)
  end

  defp semantic_block_text(block) do
    direct = value(block, "normalized_text") || value(block, "text")
    kind = value(block, "kind") || value(block, "block_kind")

    cond do
      kind in ["callout", "footnotes"] and List.wrap(value(block, "blocks")) != [] ->
        [value(block, "title"), value(block, "subtitle"), kind]
        |> normalize_strings()
        |> Enum.join(" ")
        |> nonempty_or(kind)

      kind == "objectives" ->
        block |> value("items") |> normalize_strings() |> Enum.join(" ")

      kind == "list" ->
        block
        |> value("items")
        |> List.wrap()
        |> Enum.map_join(" ", fn item -> value(item, "text") || "" end)
        |> String.trim()
        |> nonempty_or("list")

      is_binary(direct) and String.trim(direct) != "" ->
        String.trim(direct)

      true ->
        [
          value(block, "title"),
          value(block, "caption"),
          value(block, "credit"),
          kind
        ]
        |> normalize_strings()
        |> Enum.join(" ")
        |> nonempty_or("semantic block")
    end
  end

  defp semantic_payload_for_block(block) do
    block
    |> normalize_map()
    |> Map.delete("blocks")
    |> Map.update("items", [], fn items ->
      Enum.map(List.wrap(items), fn
        item when is_map(item) -> Map.delete(item, "children")
        item -> item
      end)
    end)
  end

  defp nonempty_or(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp nonempty_or(_value, fallback), do: fallback

  defp normalized_assets(section, blocks) do
    section_assets =
      value(section, "source_media") || value(section, "media") ||
        value(section, "assets") || []

    block_assets =
      Enum.flat_map(blocks, fn block ->
        block.source_media
        |> List.wrap()
        |> Enum.map(fn asset ->
          asset
          |> put_value("source_block_order", block.order)
          |> put_value("source_block_id", block.source_key)
        end)
      end)

    (List.wrap(section_assets) ++ block_assets)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {asset, index} ->
      url = value(asset, "source_url") || value(asset, "url") || value(asset, "src")

      if is_binary(url) and String.trim(url) != "" do
        [
          %{
            source_key:
              normalized_source_key(
                value(asset, "id") || value(asset, "source_media_id"),
                "media",
                "#{value(section, "url")}|#{index}|#{url}"
              ),
            order: index,
            source_block_key: value(asset, "source_block_id"),
            source_block_order:
              positive_integer(
                value(asset, "source_block_order") || value(asset, "block_order"),
                nil
              ),
            asset_type:
              value(asset, "asset_type") || value(asset, "type") ||
                value(asset, "kind") || "image",
            source_url: String.trim(url),
            alt_text: value(asset, "alt_text") || value(asset, "alt"),
            caption: value(asset, "caption"),
            declared_mime_type: value(asset, "mime_type") || value(asset, "content_type"),
            source_locator: normalize_map(value(asset, "source_locator")),
            metadata:
              normalize_map(value(asset, "metadata"))
              |> Map.put("semantic_payload", normalize_map(asset))
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.source_key)
    |> Enum.with_index(1)
    |> Enum.map(fn {asset, order} -> %{asset | order: order} end)
  end

  defp preload_corpus(sections) do
    Repo.preload(
      sections,
      [
        blocks: from(block in SourceBlock, order_by: [asc: block.order]),
        assets:
          from(asset in SourceAsset,
            order_by: [asc: asset.order],
            preload: [:media]
          )
      ],
      force: true
    )
  end

  defp section_payload(section) do
    %{
      "source_section_id" => section.id,
      "url" => section.canonical_url,
      "title" => section.title,
      "order" => section.section_order || section.order,
      "chapter_id" => section.chapter_id,
      "chapter_order" => section.chapter_order,
      "learning_objectives" => section.learning_objectives || [],
      "source_word_count" => section.normalized_word_count,
      "source_coverage" => section.source_coverage || %{},
      "content_hash" => section.content_hash,
      "attribution" => section.attribution_payload || %{},
      "excerpt" => Enum.map_join(section.blocks, "\n\n", & &1.normalized_text),
      "source_blocks" => Enum.map(section.blocks, &block_payload/1),
      "source_media" => Enum.map(section.assets, &asset_payload/1)
    }
  end

  defp section_payload_from_loaded(section, media_selection) do
    %{
      "source_section_id" => section.id,
      "url" => section.canonical_url,
      "title" => section.title,
      "order" => section.section_order || section.order,
      "learning_objectives" => section.learning_objectives || [],
      "source_word_count" => section.normalized_word_count,
      "source_coverage" => section.source_coverage || %{},
      "attribution" => section.attribution_payload || %{},
      "source_media" =>
        section.assets
        |> select_source_assets(media_selection)
        |> Enum.map(&asset_payload/1)
    }
  end

  defp block_payload(block) do
    semantic_payload =
      block.metadata
      |> normalize_map()
      |> Map.get("semantic_payload", %{})
      |> normalize_map()

    section_fields =
      case block.source_section do
        %SourceSection{} = section ->
          %{
            "source_section_url" => section.canonical_url,
            "source_section_title" => section.title
          }

        _ ->
          %{}
      end

    semantic_payload
    |> preserve_semantic_callout_body(block.block_kind)
    |> Map.merge(%{
      "id" => block.source_key,
      "source_block_record_id" => block.id,
      "source_section_id" => block.source_section_id,
      "order" => block.order,
      "heading_path" => block.heading_path || [],
      "kind" => block.block_kind,
      "block_kind" => block.block_kind,
      "text" => block.normalized_text,
      "normalized_text" => block.normalized_text,
      "source_locator" => block.source_locator || %{},
      "token_estimate" => block.token_estimate,
      "content_hash" => block.content_hash,
      "metadata" => block.metadata || %{}
    })
    |> Map.merge(section_fields)
  end

  defp preserve_semantic_callout_body(payload, "callout") do
    case payload["text"] do
      body when is_binary(body) and body != "" -> Map.put(payload, "callout_body", body)
      _ -> payload
    end
  end

  defp preserve_semantic_callout_body(payload, _block_kind), do: payload

  defp asset_payload(asset) do
    media = Ecto.assoc_loaded?(asset.media) && asset.media

    semantic_payload =
      asset.metadata
      |> normalize_map()
      |> Map.get("semantic_payload", %{})
      |> normalize_map()

    Map.merge(semantic_payload, %{
      "id" => asset.source_key,
      "source_media_id" => asset.source_key,
      "source_asset_record_id" => asset.id,
      "source_block_record_id" => asset.source_block_id,
      "order" => asset.order,
      "kind" => asset.asset_type,
      "asset_type" => asset.asset_type,
      "src" => if(media, do: media.media_url || asset.source_url, else: asset.source_url),
      "source_url" => asset.source_url,
      "url" => if(media, do: media.media_url || asset.source_url, else: asset.source_url),
      "alt" => asset.alt_text,
      "alt_text" => asset.alt_text,
      "caption" => asset.caption,
      "mime_type" => asset.declared_mime_type,
      "status" => if(media, do: media.status, else: asset.status),
      "required" => asset.required,
      "source_locator" => asset.source_locator || %{},
      "metadata" => asset.metadata || %{}
    })
  end

  defp hydrate_chapters(chapters, _corpus_sections, sections_by_url)
       when is_list(chapters) and chapters != [] do
    Enum.map(chapters, fn chapter ->
      Map.update(chapter, "sections", [], fn sections ->
        Enum.map(List.wrap(sections), fn section ->
          case Map.get(sections_by_url, value(section, "url")) do
            nil -> section
            stored -> Map.merge(section, stored)
          end
        end)
      end)
    end)
  end

  defp hydrate_chapters(_chapters, corpus_sections, _sections_by_url) do
    corpus_sections
    |> Enum.group_by(&{&1["chapter_order"] || 1, &1["chapter_id"] || "chapter-1"})
    |> Enum.sort_by(fn {{chapter_order, _chapter_id}, _sections} -> chapter_order end)
    |> Enum.map(fn {{chapter_order, chapter_id}, sections} ->
      %{
        "id" => chapter_id,
        "order" => chapter_order,
        "title" => chapter_id,
        "selected" => true,
        "sections" => sections
      }
    end)
  end

  defp lesson_urls(lesson) do
    ((lesson.source_evidence_links || []) ++ (lesson.source_sections || []))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp source_id_selection(coverage, key) when is_map(coverage) do
    atom_key =
      case key do
        "source_block_ids" -> :source_block_ids
        "source_media_ids" -> :source_media_ids
      end

    cond do
      Map.has_key?(coverage, key) ->
        {:exact, normalize_source_ids(Map.get(coverage, key))}

      Map.has_key?(coverage, atom_key) ->
        {:exact, normalize_source_ids(Map.get(coverage, atom_key))}

      true ->
        :all
    end
  end

  defp source_id_selection(_coverage, _key), do: :all

  defp normalize_source_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp select_source_blocks(blocks, :all), do: blocks

  defp select_source_blocks(blocks, {:exact, source_ids}) do
    selected = MapSet.new(source_ids)
    Enum.filter(blocks, &MapSet.member?(selected, &1.source_key))
  end

  defp validate_source_block_selection!(_lesson, _available_blocks, :all), do: :ok

  defp validate_source_block_selection!(lesson, available_blocks, {:exact, source_ids}) do
    available_ids = MapSet.new(available_blocks, & &1.source_key)

    missing =
      source_ids
      |> Enum.reject(&MapSet.member?(available_ids, &1))
      |> Enum.sort()

    if missing != [] do
      Repo.rollback({:missing_lesson_source_blocks, lesson.id, missing})
    end
  end

  defp select_source_assets(assets, :all), do: assets

  defp select_source_assets(assets, {:exact, source_ids}) do
    selected = MapSet.new(source_ids)
    Enum.filter(assets, &MapSet.member?(selected, &1.source_key))
  end

  defp validate_source_asset_selection!(_lesson, _available_assets, :all), do: :ok

  defp validate_source_asset_selection!(lesson, available_assets, {:exact, source_ids}) do
    available_ids = MapSet.new(available_assets, & &1.source_key)

    missing =
      source_ids
      |> Enum.reject(&MapSet.member?(available_ids, &1))
      |> Enum.sort()

    if missing != [] do
      Repo.rollback({:missing_lesson_source_media, lesson.id, missing})
    end
  end

  defp drop_rich_fields(map) when is_map(map), do: Map.drop(map, @rich_section_keys)
  defp drop_rich_fields(value), do: value

  defp section_slug(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/", trim: true)
    |> List.last()
  end

  defp section_slug(_), do: nil

  defp resolve_asset_url(base_url, asset_url) do
    case URI.parse(asset_url) do
      %URI{scheme: nil} -> base_url |> URI.parse() |> URI.merge(asset_url) |> URI.to_string()
      _ -> asset_url
    end
  rescue
    _ -> asset_url
  end

  defp parsed_datetime(%DateTime{} = value), do: value

  defp parsed_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp parsed_datetime(_), do: DateTime.utc_now()

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default

  defp normalized_source_key(value, _prefix, _identity)
       when is_binary(value) and value != "",
       do: value

  defp normalized_source_key(_value, prefix, identity),
    do: "openstax-#{prefix}-#{String.slice(sha256(identity), 0, 24)}"

  defp token_estimate(text), do: div(word_count(text) * 4 + 2, 3)

  defp word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp word_count(_), do: 0

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp normalize_strings(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_map(value) when is_map(value), do: stringify_keys(value)
  defp normalize_map(_), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, map_value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: map_value

        _ ->
          nil
      end)
  end

  defp value(_, _), do: nil

  defp attribution_payload(run, sections) do
    source =
      sections
      |> List.first()
      |> case do
        %{"attribution" => attribution} when is_map(attribution) -> attribution
        _ -> %{}
      end

    source
    |> normalize_map()
    |> Map.put_new("source_provider", "OpenStax")
    |> Map.put_new("source_title", run.book_slug)
    |> Map.put_new("book_title", run.book_slug)
    |> Map.put_new("source_url", run.source_url)
    |> Map.put_new("license", "CC BY 4.0")
    |> Map.put_new("license_type", "cc_by")
    |> Map.put_new("license_url", "https://creativecommons.org/licenses/by/4.0/")
  end

  defp put_value(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp put_value(_, key, value), do: %{key => value}
end
