defmodule Oli.GoogleSlides.ImportWorkflow.SourceSnapshotTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.ImportWorkflow.SourceSnapshot
  alias Oli.GoogleSlides.PresentationParser.{ImageRef, Slide}

  test "fingerprints ignore expiring media URLs but include parsed speaker notes" do
    first_json = presentation("https://temporary.example/first")
    second_json = presentation("https://temporary.example/second")

    first_slide = slide("Explain osmosis")
    same_slide = slide("Explain osmosis")
    changed_notes = slide("Explain diffusion")

    first = SourceSnapshot.build(first_json, [first_slide], presentation_url())
    second = SourceSnapshot.build(second_json, [same_slide], presentation_url())
    changed = SourceSnapshot.build(second_json, [changed_notes], presentation_url())

    assert first["presentation"]["fingerprint"] == second["presentation"]["fingerprint"]
    refute first["presentation"]["fingerprint"] == changed["presentation"]["fingerprint"]

    [image] = get_in(first, ["slides", Access.at(0), "contentBlocks"])
    refute Map.has_key?(image, "contentUrl")
    assert image["objectId"] == "image-1"

    assert get_in(first, ["slides", Access.at(0), "links"]) == [
             "https://example.edu/explicit-practice"
           ]

    assert SourceSnapshot.complete?(first)
  end

  test "marks a deck that exceeds the bounded planning snapshot as incomplete" do
    slides =
      Enum.map(1..151, fn index ->
        %{slide("Notes") | index: index, object_id: "slide-#{index}"}
      end)

    snapshot =
      SourceSnapshot.build(
        presentation("https://temporary.example/first"),
        slides,
        presentation_url()
      )

    refute SourceSnapshot.complete?(snapshot)
    assert length(snapshot["slides"]) <= 150
  end

  test "preserves stable video identifiers needed for deterministic generation" do
    slide =
      slide("Watch the demonstration")
      |> Map.put(:content_blocks, [
        %{
          type: "video",
          object_id: "video-1",
          src: "https://www.youtube.com/watch?v=demo",
          provider: "YOUTUBE",
          provider_media_id: "demo",
          alt: "Membrane transport demonstration",
          height: 240
        }
      ])

    snapshot =
      SourceSnapshot.build(
        presentation("https://temporary.example/first"),
        [slide],
        presentation_url()
      )

    assert [
             %{
               "type" => "video",
               "objectId" => "video-1",
               "provider" => "YOUTUBE",
               "providerMediaId" => "demo",
               "alt" => "Membrane transport demonstration",
               "height" => 240
             }
           ] = get_in(snapshot, ["slides", Access.at(0), "contentBlocks"])
  end

  test "includes a safe source inventory and owning ids on semantic blocks" do
    presentation = %{
      "presentationId" => "presentation-1",
      "revisionId" => "revision-1",
      "title" => "Transport",
      "masters" => [
        %{
          "pageProperties" => %{
            "pageBackgroundFill" => %{
              "solidFill" => %{"color" => %{"rgbColor" => %{"red" => 0.5}}}
            }
          }
        }
      ],
      "slides" => [
        %{
          "objectId" => "slide-1",
          "pageProperties" => %{
            "pageBackgroundFill" => %{
              "solidFill" => %{"color" => %{"rgbColor" => %{"blue" => 0.5}}}
            }
          },
          "pageElements" => [
            %{
              "objectId" => "text-1",
              "shape" => %{
                "text" => %{
                  "textElements" => [
                    %{"textRun" => %{"content" => "Water crosses a membrane."}}
                  ]
                }
              }
            },
            %{
              "objectId" => "image-1",
              "image" => %{
                "contentUrl" => "https://temporary.example/image.png"
              }
            },
            %{
              "objectId" => "unknown-1",
              "newSlidesElement" => %{"rawBlob" => "never expose"}
            }
          ]
        }
      ]
    }

    {:ok, slides, []} = Oli.GoogleSlides.PresentationParser.parse(presentation)
    snapshot = SourceSnapshot.build(presentation, slides, presentation_url())

    assert [
             %{"type" => "paragraph", "objectId" => "text-1"} | _
           ] = get_in(snapshot, ["slides", Access.at(0), "contentBlocks"])

    inventory = get_in(snapshot, ["slides", Access.at(0), "sourceInventory"])
    assert Enum.map(inventory, & &1["sourceType"]) == ["shape", "image", "unknown"]

    assert snapshot["inventoryAccounting"] == %{
             "discovered" => 3,
             "included" => 3,
             "omitted" => 0,
             "omittedScope" => "snapshot_limits_only",
             "omissionReasonCounts" => %{
               "slideLimit" => 0,
               "perSlideInventoryLimit" => 0,
               "payloadBudget" => 0
             },
             "bySourceType" => %{"image" => 1, "shape" => 1, "unknown" => 1}
           }

    encoded = Jason.encode!(snapshot)
    refute encoded =~ "temporary.example/image.png"
    refute encoded =~ "rawBlob"
    refute encoded =~ "pageBackgroundFill"
    refute encoded =~ "rgbColor"
  end

  test "accounts explicitly for inventory omitted by the per-slide limit" do
    raw_elements =
      Enum.map(1..301, fn index ->
        %{"objectId" => "unknown-#{index}", "futureElement" => %{"value" => index}}
      end)

    raw_presentation =
      presentation("https://temporary.example/first")
      |> put_in(["slides", Access.at(0), "pageElements"], raw_elements)

    source_slide = %{slide("Notes") | raw_elements: raw_elements}
    snapshot = SourceSnapshot.build(raw_presentation, [source_slide], presentation_url())

    assert snapshot["truncated"]
    refute SourceSnapshot.complete?(snapshot)

    assert %{
             "discovered" => 301,
             "included" => 300,
             "omitted" => 1,
             "omittedScope" => "snapshot_limits_only",
             "omissionReasonCounts" => %{
               "perSlideInventoryLimit" => 1,
               "payloadBudget" => 0,
               "slideLimit" => 0
             }
           } = snapshot["inventoryAccounting"]
  end

  test "keeps the complete encoded snapshot within its payload budget and accounts for omissions" do
    content = String.duplicate("x", 4_000)

    slides =
      Enum.map(1..80, fn index ->
        %Slide{
          index: index,
          object_id: "slide-#{index}",
          title: "Slide #{index}",
          title_from_placeholder: true,
          paragraphs: [content],
          list_items: [],
          content_blocks: [
            %{type: "paragraph", text: content, object_id: "text-#{index}"}
          ],
          images: [],
          raw_elements: [
            %{
              "objectId" => "text-#{index}",
              "shape" => %{
                "text" => %{
                  "textElements" => [%{"textRun" => %{"content" => content}}]
                }
              }
            }
          ],
          notes_text: ""
        }
      end)

    raw_presentation = %{
      "presentationId" => "large-deck",
      "revisionId" => "revision-1",
      "title" => "Large deck",
      "slides" =>
        Enum.map(slides, fn slide ->
          %{"objectId" => slide.object_id, "pageElements" => slide.raw_elements}
        end)
    }

    snapshot = SourceSnapshot.build(raw_presentation, slides, presentation_url())
    encoded_bytes = byte_size(Jason.encode!(snapshot))

    assert encoded_bytes <= snapshot["payloadAccounting"]["maxBytes"]
    assert encoded_bytes == snapshot["payloadAccounting"]["encodedBytes"]
    assert snapshot["payloadAccounting"]["slidesOmittedForBudget"] > 0
    assert snapshot["inventoryAccounting"]["omissionReasonCounts"]["payloadBudget"] > 0

    assert snapshot["inventoryAccounting"]["omitted"] ==
             snapshot["inventoryAccounting"]["discovered"] -
               snapshot["inventoryAccounting"]["included"]
  end

  defp presentation(content_url) do
    %{
      "presentationId" => "presentation-1",
      "revisionId" => "revision-1",
      "title" => "Transport",
      "slides" => [
        %{
          "objectId" => "slide-1",
          "pageElements" => [
            %{
              "objectId" => "image-1",
              "image" => %{"contentUrl" => content_url}
            },
            %{
              "shape" => %{
                "text" => %{
                  "textElements" => [
                    %{
                      "textRun" => %{
                        "content" => "Practice",
                        "style" => %{
                          "link" => %{"url" => "https://example.edu/explicit-practice"}
                        }
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
      ]
    }
  end

  defp slide(notes) do
    image = %ImageRef{
      object_id: "image-1",
      content_url: "https://temporary.example/image",
      width: 400,
      height: 200
    }

    %Slide{
      index: 1,
      object_id: "slide-1",
      title: "Osmosis",
      title_from_placeholder: true,
      paragraphs: ["Water crosses a membrane."],
      list_items: [],
      content_blocks: [%{type: "image", ref: image, alt: "Cell membrane"}],
      images: [image],
      raw_elements: [],
      notes_text: notes
    }
  end

  defp presentation_url,
    do: "https://docs.google.com/presentation/d/presentation-1/edit"
end
