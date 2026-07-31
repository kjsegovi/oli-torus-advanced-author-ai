defmodule Oli.OpenStax.CourseImport.ParserTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Parser

  describe "parse_openstax_url/1" do
    test "accepts only the canonical HTTPS details URL" do
      assert {:ok, "introduction-computer-science"} =
               Parser.parse_openstax_url(
                 "https://openstax.org/details/books/introduction-computer-science"
               )

      assert {:ok, "biology-2e"} =
               Parser.parse_openstax_url("https://openstax.org/details/books/biology-2e/")
    end

    test "rejects alternate hosts, schemes, paths, query strings, and malformed slugs" do
      invalid_urls = [
        "http://openstax.org/details/books/biology-2e",
        "https://www.openstax.org/details/books/biology-2e",
        "https://openstax.org/books/biology-2e",
        "https://openstax.org/details/books/biology-2e?utm_source=test",
        "https://openstax.org/details/books/../../admin",
        "https://example.com/details/books/biology-2e",
        "not a url"
      ]

      assert Enum.all?(
               invalid_urls,
               &(Parser.parse_openstax_url(&1) == {:error, :invalid_openstax_url})
             )
    end
  end

  describe "build_outline/1" do
    test "groups source sections into deterministic bundles of one to three" do
      snapshot = %{
        "book_slug" => "sample-book",
        "title" => "Sample Book",
        "chapters" => [
          %{
            "id" => "chapter-1",
            "title" => "Chapter 1",
            "order" => 1,
            "selected" => true,
            "url" => "https://openstax.org/books/sample-book/pages/1-introduction",
            "sections" =>
              Enum.map(1..5, fn index ->
                %{
                  "title" => "1.#{index} Topic #{index}",
                  "url" => "https://openstax.org/books/sample-book/pages/1-#{index}-topic",
                  "excerpt" => "Evidence for topic #{index}.",
                  "learning_objectives" => ["Explain topic #{index}"]
                }
              end)
          },
          %{
            "id" => "chapter-2",
            "title" => "Chapter 2",
            "order" => 2,
            "selected" => false,
            "sections" => []
          }
        ]
      }

      assert {:ok, %{"units" => [unit]}} = Parser.build_outline(snapshot)
      assert length(unit["lessons"]) == 3
      assert Enum.map(unit["lessons"], &length(&1["source_sections"])) == [2, 2, 1]
      assert Enum.all?(unit["lessons"], &(length(&1["source_evidence_links"]) in 1..3))

      [first_lesson | _] = unit["lessons"]
      assert first_lesson["source_excerpt"] =~ "## 1.1 Topic 1"
      assert first_lesson["source_excerpt"] =~ "## 1.2 Topic 2"
      assert length(first_lesson["source_blocks"]) == 2
      assert first_lesson["source_media"] == []
      assert first_lesson["source_word_count"] > 0
      assert first_lesson["source_coverage"]["section_count"] == 2
      assert first_lesson["source_coverage"]["block_count"] == 2
      refute first_lesson["source_coverage"]["complete"]
    end

    test "keeps a substantial semantic section standalone and exposes complete source coverage" do
      light_section = fn index ->
        url = "https://openstax.org/books/sample-book/pages/1-#{index}-topic"

        %{
          "title" => "1.#{index} Topic #{index}",
          "url" => url,
          "order" => index,
          "excerpt" => "A concise explanation for topic #{index}.",
          "learning_objectives" => ["Explain topic #{index}"],
          "content_blocks" => [
            %{
              "id" => "light-#{index}",
              "kind" => "paragraph",
              "order" => 1,
              "heading_path" => ["Topic #{index}"],
              "text" => "A concise explanation for topic #{index}."
            }
          ],
          "media" => [],
          "word_count" => 7,
          "coverage" => %{"complete" => true}
        }
      end

      substantive_blocks =
        [
          %{
            "id" => "substantial-opening",
            "kind" => "heading",
            "level" => 3,
            "order" => 1,
            "heading_path" => ["Data Science"],
            "text" => "Data Science"
          }
        ] ++
          Enum.map(1..28, fn index ->
            %{
              "id" => "substantial-paragraph-#{index}",
              "kind" => "paragraph",
              "order" => index + 1,
              "heading_path" => ["Data Science"],
              "text" =>
                "Evidence block #{index} explains a different relationship among computing disciplines."
            }
          end) ++
          [
            %{
              "id" => "substantial-final-heading",
              "kind" => "heading",
              "level" => 3,
              "order" => 30,
              "heading_path" => ["Final synthesis"],
              "text" => "Final synthesis"
            }
          ]

      substantial_section = %{
        "title" => "1.2 Computer Science across the Disciplines",
        "url" =>
          "https://openstax.org/books/sample-book/pages/1-2-computer-science-across-the-disciplines",
        "order" => 2,
        "excerpt" => "Legacy compatibility content.",
        "learning_objectives" => [
          "Differentiate discovery from invention.",
          "Describe the roles of science, mathematics, and engineering.",
          "Relate data, computational, and information science.",
          "Explain synergy across computer science."
        ],
        "content_blocks" => substantive_blocks,
        "media" => [
          %{
            "id" => "media-1",
            "kind" => "img",
            "src" => "https://openstax.org/apps/image-cdn/figure-1.png",
            "alt" => "A model visualization.",
            "source_block_id" => "substantial-paragraph-12"
          }
        ],
        "word_count" => 1_800,
        "coverage" => %{"complete" => true}
      }

      snapshot = %{
        "book_slug" => "sample-book",
        "title" => "Sample Book",
        "chapters" => [
          %{
            "id" => "chapter-1",
            "title" => "Chapter 1",
            "order" => 1,
            "selected" => true,
            "url" => "https://openstax.org/books/sample-book/pages/1-introduction",
            "sections" => [
              light_section.(1),
              substantial_section,
              light_section.(3),
              light_section.(4)
            ]
          }
        ]
      }

      assert {:ok, %{"units" => [%{"lessons" => lessons}]}} = Parser.build_outline(snapshot)
      assert Enum.map(lessons, &length(&1["source_sections"])) == [1, 1, 2]

      substantial_lesson = Enum.at(lessons, 1)

      assert substantial_lesson["title"] == "1.2 Computer Science across the Disciplines"
      assert length(substantial_lesson["source_blocks"]) == 30
      assert substantial_lesson["source_word_count"] == 1_800
      assert substantial_lesson["source_coverage"]["complete"]
      assert substantial_lesson["source_coverage"]["section_count"] == 1
      assert substantial_lesson["source_coverage"]["block_count"] == 30
      assert substantial_lesson["source_coverage"]["excerpt_truncated"]
      assert substantial_lesson["source_excerpt"] =~ "### Final synthesis"
      assert String.length(substantial_lesson["source_excerpt"]) <= 10_000

      assert [%{"id" => "media-1", "source_section_url" => source_url}] =
               substantial_lesson["source_media"]

      assert source_url == substantial_section["url"]
      expected_source_url = substantial_section["url"]

      assert Enum.all?(
               substantial_lesson["source_blocks"],
               &(&1["source_section_url"] == expected_source_url)
             )
    end

    test "splits only pedagogically overlarge sections and records exact fragment evidence" do
      url = "https://openstax.org/books/sample-book/pages/9-9-exceptional-systems"

      section =
        semantic_section(
          "9.9 Exceptional Systems",
          url,
          6,
          650,
          [
            %{
              "id" => "media-topic-2",
              "src" => "https://openstax.org/apps/image-cdn/topic-2.png",
              "alt" => "Topic two model",
              "source_block_id" => "topic-paragraph-2"
            },
            %{
              "id" => "media-topic-5",
              "src" => "https://openstax.org/apps/image-cdn/topic-5.png",
              "alt" => "Topic five model",
              "source_block_id" => "topic-paragraph-5"
            }
          ]
        )

      snapshot = outline_snapshot(section)

      assert {:ok, %{"units" => [%{"lessons" => [first, second]}]}} =
               Parser.build_outline(snapshot)

      assert first["source_sections"] == [url]
      assert second["source_sections"] == [url]
      assert first["source_objectives"] == Enum.take(section["learning_objectives"], 3)
      assert second["source_objectives"] == Enum.drop(section["learning_objectives"], 3)

      assert Enum.map(first["source_blocks"], & &1["id"]) == [
               "section-title",
               "section-objectives",
               "topic-heading-1",
               "topic-paragraph-1",
               "topic-heading-2",
               "topic-paragraph-2",
               "topic-heading-3",
               "topic-paragraph-3"
             ]

      assert Enum.map(second["source_blocks"], & &1["id"]) == [
               "section-title",
               "section-objectives",
               "topic-heading-4",
               "topic-paragraph-4",
               "topic-heading-5",
               "topic-paragraph-5",
               "topic-heading-6",
               "topic-paragraph-6"
             ]

      assert first["source_coverage"]["source_media_ids"] == ["media-topic-2"]
      assert second["source_coverage"]["source_media_ids"] == ["media-topic-5"]

      assert Enum.map(first["source_media"], & &1["id"]) == ["media-topic-2"]
      assert Enum.map(second["source_media"], & &1["id"]) == ["media-topic-5"]

      assert [
               %{"index" => 1, "count" => 2, "original_title" => "9.9 Exceptional Systems"}
             ] = first["source_coverage"]["source_fragments"]

      assert [
               %{"index" => 2, "count" => 2, "original_title" => "9.9 Exceptional Systems"}
             ] = second["source_coverage"]["source_fragments"]

      selected_ids =
        (first["source_coverage"]["source_block_ids"] ++
           second["source_coverage"]["source_block_ids"])
        |> MapSet.new()

      assert selected_ids ==
               section["content_blocks"]
               |> Enum.map(& &1["id"])
               |> MapSet.new()
    end

    test "keeps section 1.2 whole when four coherent major areas are just over 3000 words" do
      url =
        "https://openstax.org/books/introduction-computer-science/pages/1-2-computer-science-across-the-disciplines"

      section =
        semantic_section(
          "1.2 Computer Science across the Disciplines",
          url,
          4,
          800,
          []
        )

      assert {:ok, %{"units" => [%{"lessons" => [lesson]}]}} =
               section
               |> outline_snapshot()
               |> Parser.build_outline()

      assert lesson["title"] == "1.2 Computer Science across the Disciplines"
      assert lesson["source_word_count"] == 3_200
      assert lesson["source_coverage"]["source_fragments"] == []

      assert lesson["source_coverage"]["source_block_ids"] ==
               Enum.map(section["content_blocks"], & &1["id"])
    end

    test "uses objective and combined word caps for adaptive boundaries" do
      section = fn index, words, objectives ->
        %{
          "title" => "1.#{index} Topic #{index}",
          "url" => "https://openstax.org/books/sample-book/pages/1-#{index}-topic",
          "order" => index,
          "word_count" => words,
          "excerpt" => List.duplicate("evidence", words) |> Enum.join(" "),
          "learning_objectives" => objectives
        }
      end

      snapshot = %{
        "book_slug" => "sample-book",
        "chapters" => [
          %{
            "id" => "chapter-1",
            "selected" => true,
            "sections" => [
              section.(1, 650, ["Explain topic 1"]),
              section.(2, 650, ["Explain topic 2"]),
              section.(3, 200, ["Explain topic 3", "Apply topic 3"]),
              section.(4, 200, ["Explain topic 4"])
            ]
          }
        ]
      }

      assert {:ok, %{"units" => [%{"lessons" => lessons}]}} = Parser.build_outline(snapshot)

      assert Enum.map(lessons, & &1["source_sections"]) == [
               ["https://openstax.org/books/sample-book/pages/1-1-topic"],
               ["https://openstax.org/books/sample-book/pages/1-2-topic"],
               ["https://openstax.org/books/sample-book/pages/1-3-topic"],
               ["https://openstax.org/books/sample-book/pages/1-4-topic"]
             ]
    end

    test "merges a chapter introduction as an opening hook unless it has objectives" do
      introduction = %{
        "title" => "Chapter 1",
        "url" => "https://openstax.org/books/sample-book/pages/1-introduction",
        "order" => 0,
        "excerpt" => "A motivating chapter opening.",
        "learning_objectives" => []
      }

      numbered = %{
        "title" => "1.1 Foundations",
        "url" => "https://openstax.org/books/sample-book/pages/1-1-foundations",
        "order" => 1,
        "excerpt" => "The first numbered section.",
        "learning_objectives" => ["Explain the foundations"]
      }

      outline = fn intro ->
        Parser.build_outline(%{
          "book_slug" => "sample-book",
          "chapters" => [
            %{"id" => "chapter-1", "selected" => true, "sections" => [intro, numbered]}
          ]
        })
      end

      assert {:ok, %{"units" => [%{"lessons" => [merged]}]}} = outline.(introduction)
      assert merged["source_sections"] == [introduction["url"], numbered["url"]]

      independent_intro =
        Map.put(introduction, "learning_objectives", ["Evaluate the chapter's central problem"])

      assert {:ok, %{"units" => [%{"lessons" => [intro_lesson, numbered_lesson]}]}} =
               outline.(independent_intro)

      assert intro_lesson["source_sections"] == [introduction["url"]]
      assert numbered_lesson["source_sections"] == [numbered["url"]]
    end

    test "keeps conceptual questions out of lessons and exposes them as assessment evidence" do
      conceptual_url =
        "https://openstax.org/books/sample-book/pages/1-conceptual-questions"

      snapshot = %{
        "book_slug" => "sample-book",
        "title" => "Sample Book",
        "chapters" => [
          %{
            "id" => "chapter-1",
            "title" => "Chapter 1",
            "order" => 1,
            "selected" => true,
            "url" => "https://openstax.org/books/sample-book/pages/1-introduction",
            "sections" => [
              %{
                "title" => "1.1 Foundations",
                "url" => "https://openstax.org/books/sample-book/pages/1-1-foundations",
                "order" => 1,
                "excerpt" =>
                  "Computer science includes theoretical foundations, discovery, and invention.",
                "learning_objectives" => ["Differentiate discovery from invention"]
              },
              %{
                "title" => "Conceptual Questions",
                "url" => conceptual_url,
                "order" => 2,
                "source_kind" => "conceptual_questions",
                "source_blocks" => [
                  %{
                    "id" => "question-block-1",
                    "block_kind" => "assessment_question",
                    "normalized_text" => "How do discovery and invention differ?",
                    "content_hash" => String.duplicate("a", 64),
                    "metadata" => %{
                      "semantic_payload" => %{
                        "id" => "openstax-question-discovery",
                        "kind" => "assessment_question",
                        "text" => "How do discovery and invention differ?",
                        "source_locator" => %{"dom_id" => "question-1"}
                      }
                    }
                  },
                  %{
                    "id" => "question-block-2",
                    "block_kind" => "assessment_question",
                    "normalized_text" =>
                      "How does computer science shape data and information science?",
                    "content_hash" => String.duplicate("b", 64),
                    "metadata" => %{
                      "semantic_payload" => %{
                        "id" => "openstax-question-data",
                        "kind" => "assessment_question",
                        "text" => "How does computer science shape data and information science?"
                      }
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:ok, %{"units" => [unit]}} = Parser.build_outline(snapshot)

      assert [lesson] = unit["lessons"]

      assert lesson["source_sections"] == [
               "https://openstax.org/books/sample-book/pages/1-1-foundations"
             ]

      refute conceptual_url in lesson["source_sections"]
      refute Enum.any?(lesson["source_blocks"], &(&1["kind"] == "assessment_question"))

      assert Enum.map(unit["assessment_evidence"], & &1["id"]) == [
               "openstax-question-discovery",
               "openstax-question-data"
             ]

      assert Enum.all?(
               unit["assessment_evidence"],
               &(&1["source_url"] == conceptual_url)
             )

      assert unit["source_reference"]["assessment_source_urls"] == [conceptual_url]
    end

    test "requires at least one selected chapter with source sections" do
      assert {:error, :no_chapters_selected} =
               Parser.build_outline(%{"book_slug" => "book", "chapters" => []})

      assert {:error, :selected_chapter_has_no_sections} =
               Parser.build_outline(%{
                 "book_slug" => "book",
                 "chapters" => [%{"id" => "chapter-1", "selected" => true, "sections" => []}]
               })
    end
  end

  defp semantic_section(title, url, heading_count, words_per_heading, media) do
    objectives = Enum.map(1..heading_count, &"Explain major area #{&1}")

    content_blocks =
      [
        %{
          "id" => "section-title",
          "kind" => "heading",
          "level" => 2,
          "order" => 1,
          "heading_path" => [title],
          "text" => title
        },
        %{
          "id" => "section-objectives",
          "kind" => "objectives",
          "order" => 2,
          "heading_path" => [title],
          "items" => objectives,
          "text" => Enum.join(objectives, " ")
        }
      ] ++
        Enum.flat_map(1..heading_count, fn index ->
          heading = "Major area #{index}"

          [
            %{
              "id" => "topic-heading-#{index}",
              "kind" => "heading",
              "level" => 3,
              "order" => index * 2 + 1,
              "heading_path" => [title, heading],
              "text" => heading
            },
            %{
              "id" => "topic-paragraph-#{index}",
              "kind" => "paragraph",
              "order" => index * 2 + 2,
              "heading_path" => [title, heading],
              "text" =>
                List.duplicate("evidence#{index}", words_per_heading)
                |> Enum.join(" ")
            }
          ]
        end)

    %{
      "title" => title,
      "url" => url,
      "order" => 1,
      "learning_objectives" => objectives,
      "content_blocks" => content_blocks,
      "media" => media,
      "word_count" => heading_count * words_per_heading,
      "coverage" => %{"complete" => true}
    }
  end

  defp outline_snapshot(section) do
    %{
      "book_slug" => "sample-book",
      "title" => "Sample Book",
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "Chapter 1",
          "order" => 1,
          "selected" => true,
          "sections" => [section]
        }
      ]
    }
  end
end
