defmodule Oli.GoogleSlides.ImportWorkflow.SourceInventoryTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.ImportWorkflow.SourceInventory

  test "inventories groups, nested children, and unknown elements without hiding them" do
    elements = [
      %{
        "objectId" => "group-1",
        "elementGroup" => %{
          "children" => [
            %{
              "objectId" => "text-1",
              "shape" => %{
                "shapeProperties" => %{
                  "shapeBackgroundFill" => %{
                    "solidFill" => %{"color" => %{"rgbColor" => %{"red" => 0.8}}}
                  }
                },
                "text" => %{
                  "textElements" => [
                    %{"textRun" => %{"content" => "Explain diffusion"}}
                  ]
                }
              }
            },
            %{
              "mysteryWidget" => %{
                "contentUrl" => "https://temporary.example/secret",
                "rawBytes" => "not-for-the-planner"
              }
            }
          ]
        }
      }
    ]

    first = SourceInventory.build("slide-1", elements)
    second = SourceInventory.build("slide-1", elements)

    assert first == second

    assert [
             %{
               "objectId" => "group-1",
               "sourceType" => "group",
               "container" => true,
               "meaningful" => false,
               "reviewRequired" => true,
               "suggestedDisposition" => "decomposed_children",
               "fidelity" => "decomposed"
             },
             %{
               "objectId" => "text-1",
               "parentObjectId" => "group-1",
               "depth" => 1,
               "sourceType" => "shape",
               "suggestedDisposition" => "native_semantic",
               "fidelity" => "semantic"
             },
             %{
               "objectId" => synthetic_id,
               "objectIdSource" => "synthetic",
               "parentObjectId" => "group-1",
               "sourceType" => "unknown",
               "suggestedDisposition" => "unsupported",
               "fidelity" => "unsupported",
               "reviewRequired" => true
             }
           ] = first

    assert synthetic_id == "slide-1:element:0.1:unknown"

    encoded = Jason.encode!(first)
    refute encoded =~ "temporary.example"
    refute encoded =~ "not-for-the-planner"
    refute encoded =~ "solidFill"
    refute encoded =~ "rgbColor"
  end

  test "assigns conservative fidelity to native and linked media" do
    entries =
      SourceInventory.build("slide-1", [
        %{
          "objectId" => "image-1",
          "description" => "A cell",
          "image" => %{"contentUrl" => "https://temporary.example/cell.png"}
        },
        %{
          "objectId" => "video-1",
          "video" => %{
            "source" => "YOUTUBE",
            "id" => "abc123",
            "url" => "https://temporary.example/video"
          }
        },
        %{
          "objectId" => "chart-1",
          "sheetsChart" => %{
            "chartId" => 42,
            "spreadsheetId" => "sheet-1",
            "contentUrl" => "https://temporary.example/chart.png"
          }
        }
      ])

    assert [
             %{
               "sourceType" => "image",
               "suggestedDisposition" => "native_media",
               "fidelity" => "content",
               "reviewRequired" => true
             },
             %{
               "sourceType" => "video",
               "suggestedDisposition" => "linked_media",
               "fidelity" => "linked",
               "summary" => %{
                 "provider" => "YOUTUBE",
                 "providerMediaId" => "abc123"
               }
             },
             %{
               "sourceType" => "sheets_chart",
               "suggestedDisposition" => "visual_fallback",
               "fidelity" => "rasterized",
               "summary" => %{
                 "chartId" => 42,
                 "spreadsheetId" => "sheet-1"
               }
             }
           ] = entries

    refute Jason.encode!(entries) =~ "temporary.example"
  end

  test "only advertises dispositions backed by a deterministic import path" do
    entries =
      SourceInventory.build("slide-1", [
        %{"objectId" => "word-art-1", "wordArt" => %{"renderedText" => "Key idea"}},
        %{
          "objectId" => "line-1",
          "line" => %{"lineProperties" => %{}}
        },
        %{
          "objectId" => "shape-1",
          "shape" => %{
            "shapeType" => "RECTANGLE",
            "shapeProperties" => %{
              "shapeBackgroundFill" => %{"solidFill" => %{}}
            }
          }
        },
        %{
          "objectId" => "speaker-1",
          "description" => "The current speaker",
          "speakerSpotlight" => %{}
        },
        %{
          "objectId" => "unknown-1",
          "description" => "Future element",
          "futureElement" => %{}
        }
      ])

    assert [
             %{
               "sourceType" => "word_art",
               "suggestedDisposition" => "native_semantic",
               "fidelity" => "semantic"
             },
             %{
               "sourceType" => "line",
               "suggestedDisposition" => "visual_fallback",
               "fidelity" => "rasterized"
             },
             %{
               "sourceType" => "shape",
               "suggestedDisposition" => "visual_fallback",
               "fidelity" => "rasterized"
             },
             %{
               "sourceType" => "speaker_spotlight",
               "suggestedDisposition" => "unsupported",
               "fidelity" => "unsupported"
             },
             %{
               "sourceType" => "unknown",
               "suggestedDisposition" => "unsupported",
               "fidelity" => "unsupported"
             }
           ] = entries
  end

  test "does not promise image, chart, or video import when source media is unavailable" do
    entries =
      SourceInventory.build("slide-1", [
        %{"objectId" => "image-1", "image" => %{}},
        %{"objectId" => "chart-1", "sheetsChart" => %{"chartId" => 1}},
        %{"objectId" => "video-1", "video" => %{"source" => "YOUTUBE"}},
        %{
          "objectId" => "described-image",
          "description" => "A described but unavailable source image",
          "image" => %{}
        }
      ])

    assert Enum.take(entries, 3)
           |> Enum.all?(
             &(&1["suggestedDisposition"] == "unsupported" and
                 &1["fidelity"] == "unsupported")
           )

    assert List.last(entries)["suggestedDisposition"] == "native_semantic"
    assert List.last(entries)["fidelity"] == "semantic"
  end
end
