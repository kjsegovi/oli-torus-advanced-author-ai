defmodule Oli.GoogleSlides.ImportWorkflow.SourceCorpusTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.ImportWorkflow.SourceCorpus
  alias Oli.GoogleSlides.PresentationParser.Slide

  test "creates deterministic contiguous chunks without omitting an 80-slide deck" do
    {presentation, slides} = deck(80)

    assert {:ok, first} = SourceCorpus.build(presentation, slides, presentation_url())
    assert {:ok, second} = SourceCorpus.build(presentation, slides, presentation_url())

    assert first.manifest["schemaVersion"] == 3
    assert first.manifest["truncated"] == false
    assert first.manifest["slideAccounting"]["included"] == 80
    assert first.manifest["inventoryAccounting"]["omitted"] == 0
    assert length(first.chunks) == 7

    assert Enum.map(first.chunks, & &1.chunk_id) ==
             Enum.map(second.chunks, & &1.chunk_id)

    assert Enum.flat_map(first.chunks, & &1.slide_ids) == Enum.map(1..80, &"slide-#{&1}")

    Enum.each(first.chunks, fn chunk ->
      assert length(chunk.slide_ids) <= 12
      assert byte_size(Jason.encode!(chunk.source_fragment)) <= SourceCorpus.max_chunk_bytes()
    end)
  end

  test "subdivides an oversized slide by inventory-object ranges" do
    elements =
      Enum.map(1..600, fn index ->
        %{
          "objectId" => "shape-#{index}",
          "shape" => %{
            "text" => %{
              "textElements" => [
                %{"textRun" => %{"content" => "Meaningful source object #{index}"}}
              ]
            }
          }
        }
      end)

    slide = %Slide{
      index: 1,
      object_id: "slide-1",
      title: "Oversized inventory",
      title_from_placeholder: true,
      paragraphs: [],
      list_items: [],
      content_blocks: [],
      images: [],
      raw_elements: elements,
      notes_text: "Retain the source evidence."
    }

    presentation = %{
      "presentationId" => "large-slide",
      "revisionId" => "revision-1",
      "title" => "Large slide",
      "slides" => [%{"objectId" => "slide-1", "pageElements" => elements}]
    }

    assert {:ok, corpus} = SourceCorpus.build(presentation, [slide], presentation_url())
    assert length(corpus.chunks) > 1

    fragments = Enum.flat_map(corpus.chunks, & &1.source_fragment["slides"])

    assert Enum.all?(fragments, &(&1["title"] == "Oversized inventory"))
    assert Enum.all?(fragments, &(&1["notes"] == "Retain the source evidence."))

    assert fragments
           |> Enum.flat_map(& &1["sourceInventory"])
           |> Enum.map(& &1["objectId"])
           |> Enum.sort() == Enum.map(elements, & &1["objectId"]) |> Enum.sort()

    assert Enum.all?(
             corpus.chunks,
             &(byte_size(Jason.encode!(&1.source_fragment)) <= SourceCorpus.max_chunk_bytes())
           )
  end

  test "retains the 150-slide hard boundary" do
    {presentation_150, slides_150} = deck(150)
    assert {:ok, corpus} = SourceCorpus.build(presentation_150, slides_150, presentation_url())
    assert corpus.manifest["slideAccounting"]["included"] == 150

    {presentation_151, slides_151} = deck(151)

    assert {:error, {:slide_limit_exceeded, 151, 150}} =
             SourceCorpus.build(presentation_151, slides_151, presentation_url())
  end

  defp deck(count) do
    slides =
      Enum.map(1..count, fn index ->
        element = %{
          "objectId" => "text-#{index}",
          "shape" => %{
            "text" => %{
              "textElements" => [
                %{"textRun" => %{"content" => "Content for slide #{index}"}}
              ]
            }
          }
        }

        %Slide{
          index: index,
          object_id: "slide-#{index}",
          title: "Slide #{index}",
          title_from_placeholder: true,
          paragraphs: ["Content for slide #{index}"],
          list_items: [],
          content_blocks: [
            %{type: "paragraph", text: "Content for slide #{index}", object_id: "text-#{index}"}
          ],
          images: [],
          raw_elements: [element],
          notes_text: ""
        }
      end)

    presentation = %{
      "presentationId" => "deck-#{count}",
      "revisionId" => "revision-1",
      "title" => "Deck #{count}",
      "slides" =>
        Enum.map(slides, fn slide ->
          %{"objectId" => slide.object_id, "pageElements" => slide.raw_elements}
        end)
    }

    {presentation, slides}
  end

  defp presentation_url,
    do: "https://docs.google.com/presentation/d/presentation-1/edit"
end
