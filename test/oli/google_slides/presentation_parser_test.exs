defmodule Oli.GoogleSlides.PresentationParserTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.PresentationParser

  @fixture Path.expand("../../support/google_slides_import/sample_presentation.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "parse/2 extracts slide titles and paragraphs" do
    {:ok, slides, _warnings} = PresentationParser.parse(@fixture)

    assert length(slides) == 2
    assert hd(slides).title == "Welcome Slide"
    assert hd(slides).title_from_placeholder == true
    assert hd(slides).paragraphs == ["Intro paragraph text."]
    assert hd(slides).list_items == []

    assert hd(slides).content_blocks == [
             %{type: "paragraph", text: "Intro paragraph text.", object_id: "body1"}
           ]
  end

  test "parse/2 extracts native bullet lists from Slides paragraph markers" do
    presentation = %{
      "presentationId" => "list123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "body1",
              "shape" => %{
                "text" => %{
                  "lists" => %{
                    "list-1" => %{
                      "listId" => "list-1",
                      "nestingLevel" => %{
                        "0" => %{
                          "glyphFormat" => %{"type" => "BULLET"}
                        }
                      }
                    }
                  },
                  "textElements" => [
                    %{
                      "paragraphMarker" => %{
                        "style" => %{},
                        "bullet" => %{"listId" => "list-1", "nestingLevel" => 0}
                      }
                    },
                    %{"textRun" => %{"content" => "First item\n"}},
                    %{
                      "paragraphMarker" => %{
                        "style" => %{},
                        "bullet" => %{"listId" => "list-1", "nestingLevel" => 0}
                      }
                    },
                    %{"textRun" => %{"content" => "Second item\n"}}
                  ]
                }
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)

    assert slide.list_items == ["First item", "Second item"]

    assert slide.content_blocks == [
             %{
               type: "list",
               list_type: "ul",
               list_id: "list-1",
               items: ["First item", "Second item"],
               object_id: "body1"
             }
           ]
  end

  test "parse/2 preserves page element order for text and images" do
    presentation = %{
      "presentationId" => "ordered123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "body1",
              "shape" => %{
                "text" => %{
                  "textElements" => [
                    %{"paragraphMarker" => %{"style" => %{}}},
                    %{"textRun" => %{"content" => "Before image\n"}}
                  ]
                }
              }
            },
            %{
              "objectId" => "img1",
              "image" => %{"contentUrl" => "https://example.com/image.png"},
              "size" => %{"height" => %{"magnitude" => 180.0}}
            },
            %{
              "objectId" => "body2",
              "shape" => %{
                "text" => %{
                  "textElements" => [
                    %{"paragraphMarker" => %{"style" => %{}}},
                    %{"textRun" => %{"content" => "After image\n"}}
                  ]
                }
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)

    assert Enum.map(slide.content_blocks, & &1.type) == ["paragraph", "image", "paragraph"]
    assert hd(slide.images).object_id == "img1"
    assert hd(slide.images).height == 180.0
  end

  test "parse/2 flattens grouped page elements" do
    presentation = %{
      "presentationId" => "group123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "elementGroup" => %{
                "children" => [
                  %{
                    "objectId" => "body1",
                    "shape" => %{
                      "text" => %{
                        "textElements" => [
                          %{"paragraphMarker" => %{"style" => %{}}},
                          %{"textRun" => %{"content" => "Grouped text\n"}}
                        ]
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)
    assert slide.paragraphs == ["Grouped text"]
  end

  test "parse/2 extracts video, chart, word art, line, and decorative shape blocks" do
    presentation = %{
      "presentationId" => "rich123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "video1",
              "size" => %{"height" => %{"magnitude" => 1_905_000.0}},
              "video" => %{"source" => "YOUTUBE", "id" => "abc123xyz"}
            },
            %{
              "objectId" => "chart1",
              "size" => %{"height" => %{"magnitude" => 2_000_000.0}},
              "sheetsChart" => %{"contentUrl" => "https://example.com/chart.png", "chartId" => 1}
            },
            %{"wordArt" => %{"renderedText" => "Big Title"}},
            %{
              "objectId" => "line1",
              "size" => %{
                "width" => %{"magnitude" => 3_000_000.0},
                "height" => %{"magnitude" => 50_000.0}
              },
              "line" => %{"lineProperties" => %{"weight" => %{"magnitude" => 2}}}
            },
            %{
              "objectId" => "shape1",
              "size" => %{
                "width" => %{"magnitude" => 1_000_000.0},
                "height" => %{"magnitude" => 500_000.0}
              },
              "shape" => %{
                "shapeType" => "ELLIPSE",
                "shapeProperties" => %{
                  "shapeBackgroundFill" => %{
                    "solidFill" => %{
                      "color" => %{"rgbColor" => %{"red" => 0.2, "green" => 0.4, "blue" => 0.9}}
                    }
                  }
                },
                "text" => %{"textElements" => []}
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)

    assert Enum.map(slide.content_blocks, & &1.type) == [
             "video",
             "image",
             "word_art",
             "image",
             "image"
           ]

    [video | _] = slide.content_blocks
    assert video.src == "https://www.youtube.com/watch?v=abc123xyz"
    assert length(slide.images) == 3

    assert Enum.all?(slide.images, fn ref ->
             is_binary(ref.inline_bytes) or is_binary(ref.content_url)
           end)
  end

  test "uses accessibility text as a semantic fallback when known media is unavailable" do
    presentation = %{
      "presentationId" => "fallback123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "image1",
              "description" => "Unavailable image description",
              "image" => %{}
            },
            %{
              "objectId" => "video1",
              "description" => "Unavailable video description",
              "video" => %{"source" => "YOUTUBE"}
            },
            %{
              "objectId" => "chart1",
              "description" => "Unavailable chart description",
              "sheetsChart" => %{"chartId" => 1}
            },
            %{
              "objectId" => "table1",
              "description" => "Empty table description",
              "table" => %{"tableRows" => []}
            }
          ]
        }
      ]
    }

    {:ok, [slide], _warnings} = PresentationParser.parse(presentation)

    assert Enum.map(slide.content_blocks, &{&1.type, &1.object_id}) == [
             {"paragraph", "image1"},
             {"paragraph", "video1"},
             {"paragraph", "chart1"},
             {"paragraph", "table1"}
           ]

    assert slide.images == []
  end

  test "parse/2 skips empty layout placeholder shapes without exporting graphics" do
    presentation = %{
      "presentationId" => "placeholder123",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "body1",
              "shape" => %{
                "placeholder" => %{"type" => "BODY"},
                "text" => %{"textElements" => []}
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)

    assert slide.content_blocks == []
    assert slide.images == []
  end

  test "parse/2 keeps owning object ids on semantic text and table blocks" do
    presentation = %{
      "presentationId" => "owned-content",
      "slides" => [
        %{
          "objectId" => "slide1",
          "pageElements" => [
            %{
              "objectId" => "text1",
              "shape" => %{
                "text" => %{
                  "textElements" => [
                    %{"textRun" => %{"content" => "An explanation"}}
                  ]
                }
              }
            },
            %{
              "objectId" => "table1",
              "table" => %{
                "tableRows" => [
                  %{
                    "tableCells" => [
                      %{
                        "text" => %{
                          "textElements" => [
                            %{"textRun" => %{"content" => "Cell value"}}
                          ]
                        }
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    {:ok, [slide], _} = PresentationParser.parse(presentation)

    assert [
             %{type: "paragraph", object_id: "text1"},
             %{type: "table", object_id: "table1"}
           ] = slide.content_blocks
  end

  test "parse/2 supplies a deterministic slide id when the source omits one" do
    presentation = %{
      "presentationId" => "deck-id",
      "slides" => [%{"pageElements" => []}]
    }

    assert {:ok, [%{object_id: "deck-id:slide:1"}], []} =
             PresentationParser.parse(presentation)
  end
end
