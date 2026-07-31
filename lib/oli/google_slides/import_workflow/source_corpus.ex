defmodule Oli.GoogleSlides.ImportWorkflow.SourceCorpus do
  @moduledoc """
  Builds the complete schema-v3 source corpus for resumable Slides planning.

  The persisted run keeps a compact manifest. Bounded planner fragments are
  stored separately as analysis chunks, so a large deck is never truncated to
  fit a single prompt or JSON field.
  """

  alias Oli.GoogleSlides.ImportWorkflow.{SourceInventory, SourceSnapshot}

  @schema_version 3
  @max_slides 150
  @max_chunk_slides 12
  @max_chunk_bytes 64 * 1024

  @type chunk :: %{
          required(:ordinal) => non_neg_integer(),
          required(:chunk_id) => String.t(),
          required(:slide_ids) => [String.t()],
          required(:object_ids) => [String.t()],
          required(:source_fragment) => map()
        }

  @spec build(map(), list(), String.t()) ::
          {:ok, %{manifest: map(), chunks: [chunk()], validation_snapshot: map()}}
          | {:error, term()}
  def build(presentation_json, slides, presentation_url)
      when is_map(presentation_json) and is_list(slides) and is_binary(presentation_url) do
    with :ok <- validate_slide_count(slides),
         presentation <-
           SourceSnapshot.corpus_presentation(presentation_json, slides, presentation_url),
         records <- SourceSnapshot.corpus_records(presentation_json, slides),
         {:ok, segments} <- subdivide_records(records, presentation),
         {:ok, chunks} <- pack_segments(segments, presentation) do
      manifest = build_manifest(presentation, records, chunks)

      {:ok,
       %{
         manifest: manifest,
         chunks: chunks,
         validation_snapshot: build_validation_snapshot(presentation, records)
       }}
    end
  end

  @spec max_slides() :: pos_integer()
  def max_slides, do: @max_slides

  @spec max_chunk_slides() :: pos_integer()
  def max_chunk_slides, do: @max_chunk_slides

  @spec max_chunk_bytes() :: pos_integer()
  def max_chunk_bytes, do: @max_chunk_bytes

  defp validate_slide_count(slides) when length(slides) <= @max_slides, do: :ok

  defp validate_slide_count(slides),
    do: {:error, {:slide_limit_exceeded, length(slides), @max_slides}}

  defp subdivide_records(records, presentation) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, segments} ->
      case subdivide_record(record, presentation) do
        {:ok, record_segments} -> {:cont, {:ok, segments ++ record_segments}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp subdivide_record(record, presentation) do
    fragment = fragment(presentation, [record])

    if encoded_bytes(fragment) <= @max_chunk_bytes do
      {:ok, [Map.put(record, "objectRange", object_range(record["sourceInventory"]))]}
    else
      split_oversized_record(record, presentation)
    end
  end

  defp split_oversized_record(record, presentation) do
    inventory = record["sourceInventory"] || []
    blocks = record["contentBlocks"] || []

    items =
      case inventory do
        [] -> Enum.map(blocks, &{:block, &1})
        entries -> Enum.map(entries, &{:inventory, &1})
      end

    base =
      record
      |> Map.put("sourceInventory", [])
      |> Map.put("contentBlocks", [])
      |> Map.put("paragraphs", [])
      |> Map.put("listItems", [])

    with {:ok, item_groups} <- pack_slide_items(items, base, blocks, presentation) do
      segments =
        item_groups
        |> Enum.with_index()
        |> Enum.map(fn {group, segment_index} ->
          inventory_group = for {:inventory, entry} <- group, do: entry
          block_group = blocks_for_group(group, blocks, segment_index)

          base
          |> Map.put("sourceInventory", inventory_group)
          |> Map.put("contentBlocks", block_group)
          |> Map.put("segmentIndex", segment_index)
          |> Map.put("segmentCount", length(item_groups))
          |> Map.put("objectRange", object_range(inventory_group, block_group))
        end)

      {:ok, segments}
    end
  end

  defp pack_slide_items(items, base, blocks, presentation) do
    items
    |> Enum.reduce_while({:ok, [], []}, fn item, {:ok, groups, current} ->
      candidate = current ++ [item]

      if segment_fits?(candidate, base, blocks, presentation, length(groups)) do
        {:cont, {:ok, groups, candidate}}
      else
        cond do
          current == [] ->
            {:halt, {:error, {:source_object_too_large, record_object_id(item)}}}

          segment_fits?([item], base, blocks, presentation, length(groups) + 1) ->
            {:cont, {:ok, groups ++ [current], [item]}}

          true ->
            {:halt, {:error, {:source_object_too_large, record_object_id(item)}}}
        end
      end
    end)
    |> case do
      {:ok, groups, []} -> {:ok, groups}
      {:ok, groups, current} -> {:ok, groups ++ [current]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp segment_fits?(group, base, blocks, presentation, segment_index) do
    inventory_group = for {:inventory, entry} <- group, do: entry
    block_group = blocks_for_group(group, blocks, segment_index)

    record =
      base
      |> Map.put("sourceInventory", inventory_group)
      |> Map.put("contentBlocks", block_group)

    # Reserve room for segment metadata and the enclosing chunk wrapper added
    # after the item groups are known.
    encoded_bytes(fragment(presentation, [record])) <= @max_chunk_bytes - 2_048
  end

  defp blocks_for_group(group, blocks, segment_index) do
    inventory_ids =
      group
      |> Enum.flat_map(fn
        {:inventory, entry} -> [entry["objectId"]]
        _ -> []
      end)
      |> MapSet.new()

    explicit_blocks = for {:block, block} <- group, do: block

    matched_blocks =
      Enum.filter(blocks, fn block ->
        object_id = block["objectId"] || block["object_id"]
        is_binary(object_id) and MapSet.member?(inventory_ids, object_id)
      end)

    unscoped_blocks =
      if segment_index == 0 and MapSet.size(inventory_ids) > 0 do
        Enum.filter(blocks, fn block ->
          object_id = block["objectId"] || block["object_id"]
          not is_binary(object_id) or object_id == ""
        end)
      else
        []
      end

    (explicit_blocks ++ matched_blocks ++ unscoped_blocks)
    |> Enum.uniq()
  end

  defp pack_segments(segments, presentation) do
    segments
    |> Enum.reduce_while({:ok, [], []}, fn segment, {:ok, groups, current} ->
      candidate = current ++ [segment]

      if chunk_fits?(candidate, presentation) do
        {:cont, {:ok, groups, candidate}}
      else
        cond do
          current == [] ->
            {:halt, {:error, {:source_fragment_too_large, segment["objectId"]}}}

          chunk_fits?([segment], presentation) ->
            {:cont, {:ok, groups ++ [current], [segment]}}

          true ->
            {:halt, {:error, {:source_fragment_too_large, segment["objectId"]}}}
        end
      end
    end)
    |> case do
      {:ok, groups, []} -> {:ok, materialize_chunks(groups, presentation)}
      {:ok, groups, current} -> {:ok, materialize_chunks(groups ++ [current], presentation)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunk_fits?(segments, presentation) do
    slide_count =
      segments
      |> Enum.map(& &1["objectId"])
      |> Enum.uniq()
      |> length()

    slide_count <= @max_chunk_slides and
      encoded_bytes(fragment(presentation, segments)) <= @max_chunk_bytes
  end

  defp materialize_chunks(groups, presentation) do
    groups
    |> Enum.with_index()
    |> Enum.map(fn {records, ordinal} ->
      source_fragment = fragment(presentation, records)
      slide_ids = records |> Enum.map(& &1["objectId"]) |> Enum.uniq()

      object_ids =
        records
        |> Enum.flat_map(fn record ->
          record
          |> Map.get("sourceInventory", [])
          |> Enum.map(& &1["objectId"])
        end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      %{
        ordinal: ordinal,
        chunk_id: stable_chunk_id(ordinal, source_fragment),
        slide_ids: slide_ids,
        object_ids: object_ids,
        source_fragment: source_fragment
      }
    end)
  end

  defp build_manifest(presentation, records, chunks) do
    inventory = Enum.flat_map(records, &Map.get(&1, "sourceInventory", []))

    %{
      "schemaVersion" => @schema_version,
      "truncated" => false,
      "presentation" => presentation,
      "limits" => %{
        "maxSlides" => @max_slides,
        "maxChunkSlides" => @max_chunk_slides,
        "maxChunkBytes" => @max_chunk_bytes
      },
      "slideAccounting" => %{
        "discovered" => length(records),
        "included" => length(records),
        "omitted" => 0
      },
      "inventoryAccounting" => %{
        "discovered" => length(inventory),
        "included" => length(inventory),
        "omitted" => 0,
        "bySourceType" => SourceInventory.source_type_counts(inventory)
      },
      "slides" =>
        Enum.map(records, fn record ->
          %{
            "index" => record["index"],
            "objectId" => record["objectId"],
            "title" => record["title"],
            "inventoryCount" => length(record["sourceInventory"] || [])
          }
        end),
      "chunks" =>
        Enum.map(chunks, fn chunk ->
          %{
            "id" => chunk.chunk_id,
            "ordinal" => chunk.ordinal,
            "slideIds" => chunk.slide_ids,
            "objectCount" => length(chunk.object_ids),
            "encodedBytes" => encoded_bytes(chunk.source_fragment)
          }
        end)
    }
  end

  defp build_validation_snapshot(presentation, records) do
    inventory = Enum.flat_map(records, &Map.get(&1, "sourceInventory", []))

    %{
      "schemaVersion" => @schema_version,
      "truncated" => false,
      "presentation" => presentation,
      "slideAccounting" => %{
        "discovered" => length(records),
        "included" => length(records),
        "omitted" => 0
      },
      "inventoryAccounting" => %{
        "discovered" => length(inventory),
        "included" => length(inventory),
        "omitted" => 0,
        "bySourceType" => SourceInventory.source_type_counts(inventory)
      },
      "slides" => records
    }
  end

  defp fragment(presentation, records) do
    %{
      "schemaVersion" => @schema_version,
      "presentation" =>
        Map.take(presentation, ["id", "revisionId", "title", "fingerprint", "slideCount"]),
      "slides" => records
    }
  end

  defp object_range(inventory, blocks \\ []) do
    ids =
      (Enum.map(inventory || [], & &1["objectId"]) ++
         Enum.map(blocks || [], &(&1["objectId"] || &1["object_id"])))
      |> Enum.filter(&is_binary/1)

    case ids do
      [] -> %{"first" => nil, "last" => nil, "count" => 0}
      _ -> %{"first" => hd(ids), "last" => List.last(ids), "count" => length(ids)}
    end
  end

  defp stable_chunk_id(ordinal, fragment) do
    digest =
      fragment
      |> SourceSnapshot.fingerprint()
      |> String.slice(0, 16)

    "chunk-#{ordinal}-#{digest}"
  end

  defp encoded_bytes(value), do: value |> Jason.encode!() |> byte_size()

  defp record_object_id({:inventory, entry}), do: entry["objectId"] || entry["inventoryId"]
  defp record_object_id({:block, block}), do: block["objectId"] || block["type"] || "unknown"
end
