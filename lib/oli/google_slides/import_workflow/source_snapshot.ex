defmodule Oli.GoogleSlides.ImportWorkflow.SourceSnapshot do
  @moduledoc """
  Builds the bounded, JSON-compatible source snapshot supplied to the planner.

  Expiring Google image URLs, inline binary data, and raw page elements are
  deliberately excluded. Generation re-fetches the presentation after approval.
  """

  alias Oli.GoogleSlides.ImportWorkflow.SourceInventory
  alias Oli.GoogleSlides.PresentationParser.{ImageRef, Slide}

  @schema_version 2
  @max_slides 150
  @max_blocks_per_slide 80
  @max_inventory_elements_per_slide 300
  @max_values_per_list 100
  @max_string_length 4_000
  @max_links_per_slide 50
  @max_snapshot_bytes 240_000

  @spec build(map(), [Slide.t()], String.t()) :: map()
  def build(presentation_json, slides, presentation_url)
      when is_map(presentation_json) and is_list(slides) and is_binary(presentation_url) do
    fingerprint = fingerprint(presentation_json, slides)

    raw_slides = Map.get(presentation_json, "slides", [])

    candidate_records =
      slides
      |> Enum.take(@max_slides)
      |> Enum.with_index()
      |> Enum.map(fn {slide, index} ->
        normalize_slide(slide, Enum.at(raw_slides, index, %{}))
      end)

    slide_limit_records =
      slides
      |> Enum.drop(@max_slides)
      |> Enum.with_index(@max_slides)
      |> Enum.map(fn {slide, index} ->
        inventory_stats(slide, Enum.at(raw_slides, index, %{}))
      end)

    context = %{
      candidate_records: candidate_records,
      slide_limit_records: slide_limit_records,
      presentation: %{
        "id" => bounded_value(presentation_json["presentationId"]),
        "revisionId" => bounded_value(presentation_json["revisionId"]),
        "title" => bounded_value(presentation_json["title"] || "Imported Slides Lesson"),
        "url" => bounded_value(presentation_url),
        "fingerprint" => fingerprint,
        "pageSize" => presentation_json["pageSize"] |> normalize_value() |> bounded_value(),
        "slideCount" => length(slides)
      }
    }

    fit_snapshot_budget(candidate_records, context)
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(presentation_json) when is_map(presentation_json) do
    presentation_json
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec fingerprint(map(), [Slide.t()]) :: String.t()
  def fingerprint(presentation_json, slides)
      when is_map(presentation_json) and is_list(slides) do
    %{
      "presentation" => presentation_json,
      "slides" => Enum.map(slides, &normalize_slide_full/1)
    }
    |> fingerprint()
  end

  @spec complete?(map()) :: boolean()
  def complete?(%{"truncated" => truncated}), do: truncated != true
  def complete?(_snapshot), do: false

  @spec metadata(map()) :: map()
  def metadata(%{"presentation" => presentation}) when is_map(presentation) do
    Map.take(presentation, ["id", "revisionId", "title", "pageSize", "slideCount"])
  end

  def metadata(_snapshot), do: %{}

  @doc """
  Returns complete, bounded-value slide records for the v3 chunked corpus.

  Unlike `build/3`, this function does not impose a whole-deck byte budget or
  per-slide collection count. The corpus chunker applies its own byte and slide
  boundaries without dropping inventory objects.
  """
  @spec corpus_records(map(), [Slide.t()]) :: [map()]
  def corpus_records(presentation_json, slides)
      when is_map(presentation_json) and is_list(slides) do
    raw_slides = Map.get(presentation_json, "slides", [])

    slides
    |> Enum.with_index()
    |> Enum.map(fn {slide, index} ->
      normalize_corpus_slide(slide, Enum.at(raw_slides, index, %{}))
    end)
  end

  @doc """
  Builds the compact presentation metadata shared by v3 manifests and chunks.
  """
  @spec corpus_presentation(map(), [Slide.t()], String.t()) :: map()
  def corpus_presentation(presentation_json, slides, presentation_url)
      when is_map(presentation_json) and is_list(slides) and is_binary(presentation_url) do
    %{
      "id" => bounded_value(presentation_json["presentationId"]),
      "revisionId" => bounded_value(presentation_json["revisionId"]),
      "title" => bounded_value(presentation_json["title"] || "Imported Slides Lesson"),
      "url" => bounded_value(presentation_url),
      "fingerprint" => fingerprint(presentation_json, slides),
      "pageSize" => presentation_json["pageSize"] |> normalize_value() |> bounded_value(),
      "slideCount" => length(slides)
    }
  end

  defp normalize_corpus_slide(%Slide{} = slide, raw_slide) do
    %{
      "index" => slide.index,
      "objectId" => slide.object_id,
      "objectIdSource" => if(valid_id?(raw_slide["objectId"]), do: "google", else: "synthetic"),
      "title" => bounded_corpus_value(slide.title || ""),
      "titleFromPlaceholder" => slide.title_from_placeholder == true,
      "paragraphs" => bounded_corpus_value(normalize_value(slide.paragraphs || [])),
      "listItems" => bounded_corpus_value(normalize_value(slide.list_items || [])),
      "contentBlocks" =>
        slide.content_blocks
        |> Kernel.||([])
        |> Enum.map(&normalize_block/1)
        |> bounded_corpus_value(),
      "notes" => bounded_corpus_value(slide.notes_text || ""),
      "links" => raw_slide |> extract_links() |> bounded_corpus_value(),
      "sourceInventory" =>
        slide
        |> source_inventory(raw_slide)
        |> bounded_corpus_value()
    }
  end

  defp normalize_slide(%Slide{} = slide, raw_slide) do
    inventory = source_inventory(slide, raw_slide)
    links = extract_links(raw_slide)
    paragraphs = normalize_value(slide.paragraphs || [])
    list_items = normalize_value(slide.list_items || [])
    content_blocks = Enum.map(slide.content_blocks || [], &normalize_block/1)

    bounded_paragraphs = paragraphs |> Enum.take(@max_values_per_list) |> bounded_value()
    bounded_list_items = list_items |> Enum.take(@max_values_per_list) |> bounded_value()

    bounded_content_blocks =
      content_blocks
      |> Enum.take(@max_blocks_per_slide)
      |> bounded_value()

    bounded_inventory =
      inventory
      |> Enum.take(@max_inventory_elements_per_slide)
      |> Enum.map(&bounded_value/1)

    bounded_links =
      links
      |> Enum.take(@max_links_per_slide)
      |> bounded_value()

    field_accounting = %{
      "paragraphs" => field_accounting(paragraphs, bounded_paragraphs),
      "listItems" => field_accounting(list_items, bounded_list_items),
      "contentBlocks" => field_accounting(content_blocks, bounded_content_blocks),
      "sourceInventory" => field_accounting(inventory, bounded_inventory),
      "links" => field_accounting(links, bounded_links)
    }

    string_source = [
      slide.title || "",
      slide.notes_text || "",
      paragraphs,
      list_items,
      content_blocks,
      inventory,
      links
    ]

    strings_truncated = count_truncated_strings(string_source)

    nested_values_omitted =
      [
        Enum.take(paragraphs, @max_values_per_list),
        Enum.take(list_items, @max_values_per_list),
        Enum.take(content_blocks, @max_blocks_per_slide),
        Enum.take(inventory, @max_inventory_elements_per_slide)
      ]
      |> Enum.map(fn values ->
        Enum.reduce(values, 0, fn value, count ->
          count + count_nested_list_omissions(value)
        end)
      end)
      |> Enum.sum()

    truncated? =
      Enum.any?(field_accounting, fn {_field, accounting} ->
        accounting["omitted"] > 0
      end) or strings_truncated > 0 or nested_values_omitted > 0

    value = %{
      "index" => slide.index,
      "objectId" => slide.object_id,
      "objectIdSource" => if(valid_id?(raw_slide["objectId"]), do: "google", else: "synthetic"),
      "title" => bounded_value(slide.title || ""),
      "titleFromPlaceholder" => slide.title_from_placeholder == true,
      "paragraphs" => bounded_paragraphs,
      "listItems" => bounded_list_items,
      "contentBlocks" => bounded_content_blocks,
      "notes" => bounded_value(slide.notes_text || ""),
      "links" => bounded_links,
      "sourceInventory" => bounded_inventory,
      "truncated" => truncated?,
      "truncationAccounting" => %{
        "fields" => field_accounting,
        "stringsTruncated" => strings_truncated,
        "nestedValuesOmitted" => nested_values_omitted
      }
    }

    %{
      value: value,
      inventory_discovered: length(inventory),
      inventory_included: length(bounded_inventory),
      inventory_type_counts: SourceInventory.source_type_counts(inventory)
    }
  end

  defp normalize_slide_full(%Slide{} = slide) do
    %{
      "index" => slide.index,
      "objectId" => slide.object_id,
      "title" => slide.title,
      "titleFromPlaceholder" => slide.title_from_placeholder == true,
      "paragraphs" => normalize_value(slide.paragraphs || []),
      "listItems" => normalize_value(slide.list_items || []),
      "contentBlocks" => Enum.map(slide.content_blocks || [], &normalize_block/1),
      "notes" => slide.notes_text || ""
    }
  end

  defp normalize_block(%{type: "image", ref: %ImageRef{} = image} = block) do
    %{
      "type" => "image",
      "objectId" => image.object_id,
      "width" => image.width,
      "height" => image.height,
      "transform" => normalize_value(Map.get(image, :transform)),
      "altText" => Map.get(block, :alt),
      "inlineGraphic" => is_binary(image.inline_bytes)
    }
    |> reject_nil_values()
  end

  defp normalize_block(%{type: "video"} = block) do
    %{
      "type" => "video",
      "objectId" => Map.get(block, :object_id),
      "provider" => Map.get(block, :provider),
      "providerMediaId" => Map.get(block, :provider_media_id),
      "alt" => Map.get(block, :alt),
      "height" => Map.get(block, :height)
    }
    |> reject_nil_values()
  end

  defp normalize_block(block) do
    normalized = normalize_value(block)

    case Map.pop(normalized, "object_id") do
      {nil, normalized} -> normalized
      {object_id, normalized} -> Map.put(normalized, "objectId", object_id)
    end
  end

  defp normalize_value(%ImageRef{} = image) do
    %{
      "objectId" => image.object_id,
      "width" => image.width,
      "height" => image.height,
      "inlineGraphic" => is_binary(image.inline_bytes)
    }
    |> reject_nil_values()
  end

  defp normalize_value(%_{} = struct), do: struct |> Map.from_struct() |> normalize_value()

  defp normalize_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)

  defp normalize_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> normalize_value()

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_value(value), do: value

  defp bounded_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, bounded_value(nested)} end)
  end

  defp bounded_value(value) when is_list(value) do
    value
    |> Enum.take(@max_values_per_list)
    |> Enum.map(&bounded_value/1)
  end

  defp bounded_value(value) when is_binary(value) do
    if String.length(value) > @max_string_length do
      String.slice(value, 0, @max_string_length)
    else
      value
    end
  end

  defp bounded_value(value), do: value

  defp bounded_corpus_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, bounded_corpus_value(nested)} end)
  end

  defp bounded_corpus_value(value) when is_list(value),
    do: Enum.map(value, &bounded_corpus_value/1)

  defp bounded_corpus_value(value) when is_binary(value) do
    if String.length(value) > @max_string_length do
      String.slice(value, 0, @max_string_length)
    else
      value
    end
  end

  defp bounded_corpus_value(value), do: value

  defp fit_snapshot_budget(candidate_records, context) do
    empty_snapshot =
      assemble_snapshot([], context)
      |> stabilize_encoded_bytes()

    find_largest_fitting_prefix(
      candidate_records,
      context,
      0,
      length(candidate_records),
      empty_snapshot
    )
  end

  defp find_largest_fitting_prefix(_records, _context, lower, upper, best)
       when lower > upper,
       do: best

  defp find_largest_fitting_prefix(records, context, lower, upper, best) do
    count = div(lower + upper, 2)

    candidate =
      records
      |> Enum.take(count)
      |> assemble_snapshot(context)
      |> stabilize_encoded_bytes()

    if byte_size(Jason.encode!(candidate)) <= @max_snapshot_bytes do
      find_largest_fitting_prefix(records, context, count + 1, upper, candidate)
    else
      find_largest_fitting_prefix(records, context, lower, count - 1, best)
    end
  end

  defp assemble_snapshot(kept_records, context) do
    payload_omitted_records =
      Enum.drop(context.candidate_records, length(kept_records))

    slide_limit_count = length(context.slide_limit_records)
    payload_slide_count = length(payload_omitted_records)

    inventory_discovered =
      sum_inventory(context.candidate_records, :inventory_discovered) +
        sum_inventory(context.slide_limit_records, :inventory_discovered)

    inventory_included = sum_inventory(kept_records, :inventory_included)

    per_slide_inventory_omitted =
      Enum.reduce(context.candidate_records, 0, fn record, count ->
        count + record.inventory_discovered - record.inventory_included
      end)

    payload_inventory_omitted =
      sum_inventory(payload_omitted_records, :inventory_included)

    slide_limit_inventory_omitted =
      sum_inventory(context.slide_limit_records, :inventory_discovered)

    inventory_omitted = inventory_discovered - inventory_included

    truncated? =
      slide_limit_count > 0 or payload_slide_count > 0 or inventory_omitted > 0 or
        Enum.any?(kept_records, &(&1.value["truncated"] == true))

    %{
      "schemaVersion" => @schema_version,
      "truncated" => truncated?,
      "limits" => %{
        "maxSlides" => @max_slides,
        "maxBlocksPerSlide" => @max_blocks_per_slide,
        "maxInventoryElementsPerSlide" => @max_inventory_elements_per_slide,
        "maxValuesPerList" => @max_values_per_list,
        "maxStringLength" => @max_string_length,
        "maxLinksPerSlide" => @max_links_per_slide,
        "maxSnapshotBytes" => @max_snapshot_bytes
      },
      "presentation" => context.presentation,
      "slideAccounting" => %{
        "discovered" => length(context.candidate_records) + slide_limit_count,
        "included" => length(kept_records),
        "omitted" => slide_limit_count + payload_slide_count,
        "omittedScope" => "snapshot_limits_only",
        "omissionReasonCounts" => %{
          "slideLimit" => slide_limit_count,
          "payloadBudget" => payload_slide_count
        }
      },
      "inventoryAccounting" => %{
        "discovered" => inventory_discovered,
        "included" => inventory_included,
        "omitted" => inventory_omitted,
        "omittedScope" => "snapshot_limits_only",
        "omissionReasonCounts" => %{
          "slideLimit" => slide_limit_inventory_omitted,
          "perSlideInventoryLimit" => per_slide_inventory_omitted,
          "payloadBudget" => payload_inventory_omitted
        },
        "bySourceType" =>
          merge_type_counts(
            Enum.map(
              context.candidate_records ++ context.slide_limit_records,
              & &1.inventory_type_counts
            )
          )
      },
      "payloadAccounting" => %{
        "maxBytes" => @max_snapshot_bytes,
        "encodedBytes" => 0,
        "slidesOmittedForBudget" => payload_slide_count
      },
      "slides" => Enum.map(kept_records, & &1.value)
    }
  end

  defp stabilize_encoded_bytes(snapshot) do
    Enum.reduce(1..3, snapshot, fn _iteration, candidate ->
      encoded_bytes = byte_size(Jason.encode!(candidate))
      put_in(candidate, ["payloadAccounting", "encodedBytes"], encoded_bytes)
    end)
  end

  defp inventory_stats(%Slide{} = slide, raw_slide) do
    inventory = source_inventory(slide, raw_slide)

    %{
      inventory_discovered: length(inventory),
      inventory_included: 0,
      inventory_type_counts: SourceInventory.source_type_counts(inventory)
    }
  end

  defp source_inventory(%Slide{} = slide, raw_slide) do
    elements =
      case raw_slide do
        %{"pageElements" => elements} when is_list(elements) -> elements
        _ -> slide.raw_elements || []
      end

    SourceInventory.build(slide.object_id, elements)
  end

  defp field_accounting(discovered, included) do
    discovered_count = length(discovered)
    included_count = length(included)

    %{
      "discovered" => discovered_count,
      "included" => included_count,
      "omitted" => max(discovered_count - included_count, 0)
    }
  end

  defp sum_inventory(records, field) do
    Enum.reduce(records, 0, fn record, count -> count + Map.fetch!(record, field) end)
  end

  defp merge_type_counts(counts) do
    Enum.reduce(counts, %{}, fn count_map, merged ->
      Map.merge(merged, count_map, fn _type, first, second -> first + second end)
    end)
  end

  defp count_truncated_strings(value) when is_binary(value) do
    if String.length(value) > @max_string_length, do: 1, else: 0
  end

  defp count_truncated_strings(value) when is_map(value) do
    Enum.reduce(value, 0, fn {_key, nested}, count ->
      count + count_truncated_strings(nested)
    end)
  end

  defp count_truncated_strings(value) when is_list(value) do
    Enum.reduce(value, 0, fn nested, count ->
      count + count_truncated_strings(nested)
    end)
  end

  defp count_truncated_strings(_value), do: 0

  defp count_nested_list_omissions(value) when is_map(value) do
    Enum.reduce(value, 0, fn {_key, nested}, count ->
      count + count_nested_list_omissions(nested)
    end)
  end

  defp count_nested_list_omissions(value) when is_list(value) do
    max(length(value) - @max_values_per_list, 0) +
      Enum.reduce(value, 0, fn nested, count ->
        count + count_nested_list_omissions(nested)
      end)
  end

  defp count_nested_list_omissions(_value), do: 0

  defp extract_links(value) do
    value
    |> collect_links()
    |> Enum.uniq()
  end

  defp collect_links(value) when is_map(value) do
    direct_links =
      case value do
        %{"link" => %{"url" => url}} when is_binary(url) ->
          if safe_link?(url), do: [url], else: []

        _ ->
          []
      end

    nested_links =
      Enum.flat_map(value, fn
        {"link", _nested} -> []
        {key, _nested} when key in ["contentUrl", "thumbnailUrl"] -> []
        {_key, nested} -> collect_links(nested)
      end)

    direct_links ++ nested_links
  end

  defp collect_links(value) when is_list(value), do: Enum.flat_map(value, &collect_links/1)
  defp collect_links(_value), do: []

  defp safe_link?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_id?(value), do: is_binary(value) and value != ""

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} ->
      to_string(key) in ["contentUrl", "thumbnailUrl"]
    end)
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)

  defp canonical_term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> canonical_term()

  defp canonical_term(value), do: value
end
