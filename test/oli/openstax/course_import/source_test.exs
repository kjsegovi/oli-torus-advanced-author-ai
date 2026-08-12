defmodule Oli.OpenStax.CourseImport.SourceTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Source

  defmodule HTTPClient do
    def get("https://openstax.org/details/books/sample-book", _headers, _opts) do
      {:ok,
       %{
         status_code: 200,
         body: """
         <html><main><h1>Sample Book</h1>
           <a href="/books/sample-book/pages/1-introduction">Ch. 1 Introduction</a>
           <a href="/books/sample-book/pages/1-1-first-topic">1.1 First Topic</a>
           <a href="/books/sample-book/pages/1-2-second-topic?ignored=true">1.2 Second Topic</a>
           <a href="https://openstax.org/books/another-book/pages/1-1-nope">Wrong book</a>
           <a href="https://example.com/books/sample-book/pages/1-3-nope">Wrong host</a>
         </main></html>
         """
       }}
    end

    def get(url, _headers, _opts) do
      title =
        if String.ends_with?(url, "1-introduction"),
          do: "Chapter 1 Introduction",
          else: "1.1 First Topic"

      {:ok,
       %{
         status_code: 200,
         body: """
         <html><main>
           <h1>#{title}</h1>
           <div class="learning-objectives"><ul><li>Explain the topic</li></ul></div>
           <p>This paragraph contains enough source material to serve as a useful lesson excerpt for planning.</p>
         </main></html>
         """
       }}
    end
  end

  defmodule PreloadedStateClient do
    def get("https://openstax.org/details/books/sample-book", _headers, _opts) do
      {:ok,
       %{
         status_code: 200,
         body: "<html><head><title>OpenStax</title></head><body><main></main></body></html>"
       }}
    end

    def get("https://openstax.org/books/sample-book/pages/1-introduction", _headers, _opts) do
      state = %{
        "content" => %{
          "book" => %{
            "slug" => "sample-book",
            "title" => "Structured Sample Book",
            "tree" => %{
              "slug" => "sample-book",
              "contents" => [
                %{
                  "toc_type" => "unit",
                  "slug" => "part-1",
                  "contents" => [
                    %{
                      "toc_type" => "chapter",
                      "slug" => "1-foundations",
                      "title" => "<span class=\"os-number\">1</span> Foundations",
                      "contents" => [
                        %{
                          "toc_type" => "book-content",
                          "toc_target_type" => "intro",
                          "slug" => "1-introduction",
                          "title" => "Introduction"
                        },
                        %{
                          "toc_type" => "book-content",
                          "toc_target_type" => "numbered-section",
                          "slug" => "1-1-first-topic",
                          "title" => "<span class=\"os-number\">1.1</span> First Topic"
                        },
                        %{
                          "toc_type" => "sub-book-tree",
                          "slug" => "1-chapter-review",
                          "title" => "Chapter Review",
                          "contents" => [
                            %{
                              "toc_type" => "book-content",
                              "toc_target_type" => "conceptual-questions",
                              "slug" => "1-conceptual-questions",
                              "title" => "Conceptual Questions"
                            },
                            %{
                              "toc_type" => "book-content",
                              "toc_target_type" => "review-questions",
                              "slug" => "1-review-questions",
                              "title" => "Review Questions"
                            }
                          ]
                        }
                      ]
                    }
                  ]
                },
                %{
                  "toc_type" => "book-content",
                  "toc_target_type" => "appendix",
                  "slug" => "a-appendix",
                  "title" => "Appendix"
                }
              ]
            }
          }
        }
      }

      {:ok,
       %{
         status_code: 200,
         body:
           "<html><body><script>window.__PRELOADED_STATE__ = #{Jason.encode!(state)};</script></body></html>"
       }}
    end
  end

  test "discovers and ingests only canonical same-book pages" do
    assert {:ok, snapshot} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: HTTPClient
             )

    assert snapshot["license"] == %{
             "book_slug" => "sample-book",
             "license" => "CC BY 4.0",
             "license_type" => "cc_by",
             "license_url" => "https://creativecommons.org/licenses/by/4.0/",
             "provider" => "OpenStax",
             "source_url" => "https://openstax.org/details/books/sample-book"
           }

    assert snapshot["title"] == "Sample Book"
    assert [%{"id" => "chapter-1"} = chapter] = snapshot["chapters"]
    assert length(chapter["sections"]) == 3

    assert Enum.all?(
             chapter["sections"],
             &String.starts_with?(
               &1["url"],
               "https://openstax.org/books/sample-book/pages/"
             )
           )

    assert {:ok, ingested} =
             Source.ingest(snapshot, ["chapter-1"], http_client: HTTPClient)

    assert [ingested_chapter] = ingested["chapters"]
    assert Enum.all?(ingested_chapter["sections"], &(&1["excerpt"] != ""))

    assert Enum.all?(
             ingested_chapter["sections"],
             &(&1["learning_objectives"] == ["Explain the topic"])
           )
  end

  test "discovers chapters from OpenStax preloaded state and excludes review material" do
    assert {:ok, snapshot} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: PreloadedStateClient
             )

    assert snapshot["title"] == "Structured Sample Book"

    assert [
             %{
               "id" => "chapter-1",
               "title" => "Chapter 1: Foundations",
               "sections" => sections
             }
           ] = snapshot["chapters"]

    assert Enum.map(sections, & &1["url"]) == [
             "https://openstax.org/books/sample-book/pages/1-introduction",
             "https://openstax.org/books/sample-book/pages/1-1-first-topic"
           ]

    assert chapter_assessment_urls(snapshot) == [
             "https://openstax.org/books/sample-book/pages/1-conceptual-questions"
           ]

    refute Enum.any?(sections, &String.contains?(&1["url"], "review"))
  end

  test "extracts conceptual questions as stable assessment blocks" do
    url = "https://openstax.org/books/sample-book/pages/1-conceptual-questions"

    body = """
    <html><main>
      <div data-book-content="true">
        <h2 data-type="document-title">Conceptual Questions</h2>
        <div data-type="exercise" id="question-1">
          <div data-type="problem"><p>How do discovery and invention differ?</p></div>
        </div>
        <div data-type="exercise" id="question-2">
          <div data-type="problem">
            <p>How does computer science shape data science and information science?</p>
          </div>
        </div>
        <div
          data-type="injected-exercise"
          data-injected-from-nickname="01-02-CS-CQ03"
          data-tags="type:practice lo:stax-cs:1.2.2 module-slug:introduction-computer-science:1-2-computer-science-across-the-disciplines"
        >
          <div data-type="exercise-question" id="495881">
            <span class="os-number">3</span>
            <div data-type="question-stem">
              How are data science and information science related?
            </div>
          </div>
        </div>
      </div>
    </main></html>
    """

    assert {:ok, first} = Source.parse_section_page(body, url)
    assert {:ok, second} = Source.parse_section_page(body, url)

    assert first["source_kind"] == "conceptual_questions"
    assert first["coverage"]["assessment_question_count"] == 3

    questions =
      Enum.filter(first["content_blocks"], &(&1["kind"] == "assessment_question"))

    assert Enum.map(questions, & &1["text"]) == [
             "How do discovery and invention differ?",
             "How does computer science shape data science and information science?",
             "How are data science and information science related?"
           ]

    assert Enum.map(questions, & &1["id"]) ==
             second["content_blocks"]
             |> Enum.filter(&(&1["kind"] == "assessment_question"))
             |> Enum.map(& &1["id"])

    assert Enum.all?(questions, &String.starts_with?(&1["id"], "openstax-question-"))

    assert List.last(questions)["related_section_slugs"] == [
             "1-2-computer-science-across-the-disciplines"
           ]

    assert List.last(questions)["learning_objective_tags"] == ["lo:stax-cs:1.2.2"]
  end

  test "rich ingestion requires the canonical book-content region" do
    body = """
    <html><body><main><article><p>Page chrome that must not be ingested.</p></article></main></body></html>
    """

    assert {:error, :missing_canonical_book_content} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample/pages/1-1-test",
               strict_book_content: true
             )

    assert {:ok, legacy} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample/pages/1-1-test"
             )

    assert legacy["excerpt"] =~ "Page chrome"
  end

  test "preserves instructional exercises as typed source blocks" do
    body = """
    <html><body>
      <article data-book-content="true">
        <h2>Practice</h2>
        <div data-type="exercise" id="exercise-1">
          <div data-type="problem"><p>Compare discovery with invention.</p></div>
          <div data-type="solution"><p>Discovery finds; invention creates.</p></div>
        </div>
      </article>
    </body></html>
    """

    assert {:ok, parsed} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample/pages/1-1-test",
               strict_book_content: true
             )

    assert exercise = Enum.find(parsed["content_blocks"], &(&1["kind"] == "exercise"))
    assert exercise["exercise_type"] == "exercise"
    assert exercise["problem"] == "Compare discovery with invention."
    assert exercise["solution"] == "Discovery finds; invention creates."
  end

  test "ingests conceptual questions through the assessment-only source path" do
    lesson_url = "https://openstax.org/books/sample-book/pages/1-1-foundations"
    conceptual_url = "https://openstax.org/books/sample-book/pages/1-conceptual-questions"

    snapshot = %{
      "book_slug" => "sample-book",
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "Chapter 1",
          "order" => 1,
          "sections" => [
            %{"title" => "1.1 Foundations", "url" => lesson_url, "order" => 1}
          ],
          "assessment_sources" => [
            %{
              "title" => "Conceptual Questions",
              "url" => conceptual_url,
              "order" => 10_000,
              "source_kind" => "conceptual_questions"
            }
          ]
        }
      ]
    }

    client = fn
      ^lesson_url, _headers, _opts ->
        {:ok,
         %{
           status_code: 200,
           body:
             "<main data-book-content=\"true\"><h2>Foundations</h2><p>Instructional material remains in the lesson source.</p></main>"
         }}

      ^conceptual_url, _headers, _opts ->
        {:ok,
         %{
           status_code: 200,
           body: """
           <main data-book-content="true">
             <h2>Conceptual Questions</h2>
             <div data-type="exercise" id="concept-1">
               <div data-type="problem"><p>How do discovery and invention differ?</p></div>
             </div>
           </main>
           """
         }}
    end

    assert {:ok, ingested} =
             Source.ingest(snapshot, ["chapter-1"], http_client: client)

    assert [%{"sections" => [lesson, assessment], "assessment_sources" => [metadata]}] =
             ingested["chapters"]

    assert lesson["url"] == lesson_url
    assert lesson["source_kind"] == "instructional"
    assert assessment["url"] == conceptual_url
    assert assessment["source_kind"] == "conceptual_questions"
    assert Enum.any?(assessment["content_blocks"], &(&1["kind"] == "assessment_question"))

    assert metadata == %{
             "order" => 2,
             "question_count" => 1,
             "source_kind" => "conceptual_questions",
             "title" => "Conceptual Questions",
             "url" => conceptual_url
           }

    refute Map.has_key?(metadata, "content_blocks")
  end

  test "enforces the response size ceiling" do
    assert {:error, {:response_too_large, _, 10}} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: HTTPClient,
               max_response_bytes: 10
             )
  end

  test "retains complete instructional material instead of silently truncating a prefix" do
    paragraphs =
      Enum.map_join(1..12, "\n", fn index ->
        """
        <p>Paragraph #{index} explains a substantive OpenStax concept with enough detail
        for the lesson planner to teach it accurately to learners.
        #{String.duplicate("Supporting evidence remains available for grounding. ", 16)}</p>
        """
      end)

    assert {:ok, section} =
             Source.parse_section_page(
               """
               <html><main><h1>Deep topic</h1>#{paragraphs}
                 <h3 id="late-synthesis">Late synthesis</h3>
                 <p>The final synthesis must remain available even after a long source section.</p>
               </main></html>
               """,
               "https://openstax.org/books/sample-book/pages/1-1-deep-topic"
             )

    assert String.length(section["excerpt"]) > 6_000
    assert section["excerpt"] =~ "Paragraph 1 explains"
    assert section["excerpt"] =~ "Paragraph 12 explains"
    assert section["excerpt"] =~ "Late synthesis"
    assert section["excerpt"] =~ "The final synthesis must remain available"
    assert section["coverage"]["complete"]
  end

  test "retains headings, lists, code, figures, and tables as source evidence" do
    body = """
    <html><main><article>
      <h1>Structured topic</h1>
      <h2>Compare the approaches</h2>
      <p>This paragraph explains why the two approaches behave differently as the input grows.</p>
      <ul><li>Use the first approach when the input remains small and predictable.</li></ul>
      <pre>for item in values: inspect(item)</pre>
      <figure><figcaption>The curve grows more quickly for the exhaustive approach.</figcaption></figure>
      <table><tr><th>Approach</th><th>Growth</th></tr><tr><td>Linear</td><td>n</td></tr></table>
    </article></main></html>
    """

    assert {:ok, section} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample-book/pages/1-2-structured-topic"
             )

    assert section["excerpt"] =~ "### Compare the approaches"
    assert section["excerpt"] =~ "- Use the first approach"
    assert section["excerpt"] =~ "Code example:"
    assert section["excerpt"] =~ "Figure context:"
    assert section["excerpt"] =~ "Table:"
  end

  test "extracts a Torus-safe AST for formatting, links, lists, tables, equations, footnotes, callouts, and figures" do
    body = """
    <html><main><article data-book-content="true">
      <h2 id="nature">The Nature of Science</h2>
      <p id="formatted">
        Scientific knowledge uses <strong>evidence</strong>, <em>reasoning</em>, and
        <a href="/books/sample-book/pages/1-1-evidence">shared review</a>.
        Water is H<sub>2</sub>O and a result can be revised<sup>1</sup>.
      </p>
      <ol id="process"><li>Observe carefully<ul><li>Record uncertainty</li></ul></li></ol>
      <table id="evidence-table">
        <tr><th>Evidence</th><th>Interpretation</th></tr>
        <tr><td>Observation</td><td>Model</td></tr>
      </table>
      <div data-type="equation" data-latex="E = mc^2"></div>
      <div data-type="note" id="science-note"><p>Explanations are tested against evidence.</p></div>
      <figure id="scientific-model">
        <img src="/apps/image-cdn/model.png" alt="A scientific model changing with evidence." />
        <figcaption>Figure 1 A model is revised.</figcaption>
      </figure>
      <div data-type="footnote-refs" id="notes"><ol><li>Supporting source.</li></ol></div>
    </article></main></html>
    """

    assert {:ok, section} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample-book/pages/1-2-nature-of-science",
               strict_book_content: true
             )

    blocks = section["content_blocks"]

    paragraph = Enum.find(blocks, &(&1["source_locator"]["dom_id"] == "formatted"))
    encoded_paragraph = Jason.encode!(paragraph["ast"])
    assert encoded_paragraph =~ ~s("bold":true)
    assert encoded_paragraph =~ ~s("italic":true)
    assert encoded_paragraph =~ ~s("subscript":true)
    assert encoded_paragraph =~ ~s("superscript":true)
    assert encoded_paragraph =~ "https://openstax.org/books/sample-book/pages/1-1-evidence"

    assert [%{"type" => "ol", "children" => list_children}] =
             Enum.find(blocks, &(&1["kind"] == "list"))["ast"]

    assert Enum.any?(list_children, &(&1["type"] == "ul"))

    assert [%{"type" => "table", "children" => [%{"type" => "tr"} | _]}] =
             Enum.find(blocks, &(&1["kind"] == "table"))["ast"]

    assert %{"kind" => "equation", "latex" => "E = mc^2", "ast" => [equation]} =
             Enum.find(blocks, &(&1["kind"] == "equation"))

    assert equation["type"] == "formula"
    assert Enum.any?(blocks, &(&1["kind"] == "callout" and &1["ast"] != []))
    assert Enum.any?(blocks, &(&1["kind"] == "figure" and &1["ast"] != []))
    assert Enum.any?(blocks, &(&1["kind"] == "footnotes" and &1["ast"] != []))
  end

  test "preserves MathML without duplicate semantic text and keeps worked examples intact" do
    body = """
    <html><main><article data-book-content="true">
      <h2>Numbers in Astronomy</h2>
      <p id="notation">Write the value as
        <math display="inline"><semantics>
          <mrow><mn>5</mn><mo>×</mo><msup><mn>10</mn><mn>8</mn></msup></mrow>
          <annotation-xml encoding="MathML-Content">
            <mrow><mn>5</mn><mo>×</mo><msup><mn>10</mn><mn>8</mn></msup></mrow>
          </annotation-xml>
        </semantics></math>.
      </p>
      <div data-type="example" id="example-1">
        <header><h3>Example 1.1</h3></header>
        <section><div class="body">
          <h4 data-type="title">Scientific Notation</h4>
          Express 79.2 billion in scientific notation.
          <h4 data-type="title">Solution</h4>
          The value is
          <math display="inline"><semantics>
            <mrow><mn>7.92</mn><mo>×</mo><msup><mn>10</mn><mn>10</mn></msup></mrow>
            <annotation-xml encoding="MathML-Content">
              <mrow><mn>7.92</mn><mo>×</mo><msup><mn>10</mn><mn>10</mn></msup></mrow>
            </annotation-xml>
          </semantics></math>.
        </div></section>
      </div>
    </article></main></html>
    """

    assert {:ok, section} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/astronomy-2e/pages/1-4-numbers-in-astronomy",
               strict_book_content: true
             )

    paragraph = Enum.find(section["content_blocks"], &(&1["kind"] == "paragraph"))

    assert [%{"type" => "p", "children" => children}] = paragraph["ast"]

    assert %{"type" => "formula_inline", "subtype" => "mathml", "src" => mathml} =
             Enum.find(children, &(&1["type"] == "formula_inline"))

    assert mathml =~ "<msup>"
    refute mathml == "5×1085×108"

    assert [example] = Enum.filter(section["content_blocks"], &(&1["kind"] == "exercise"))
    assert example["exercise_type"] == "example"
    assert example["text"] =~ "Express 79.2 billion"
    assert example["text"] =~ "Solution"
    assert Jason.encode!(example["ast"]) =~ ~s("subtype":"mathml")

    refute Enum.any?(section["content_blocks"], fn block ->
             block["kind"] == "heading" and block["text"] == "Solution"
           end)
  end

  test "extracts canonical semantic blocks with stable ids and media metadata" do
    body = """
    <html><main>
      <aside><p>This navigation copy must not enter the source snapshot.</p></aside>
      <div data-book-content="true" data-type="page" id="page-1-2">
        <h2 data-type="document-title" id="section-title">1.2 Across Disciplines</h2>
        <div class="learning-objectives" id="objectives">
          <h3>Learning Objectives</h3>
          <ul>
            <li>Explain how data science relates to computer science.</li>
            <li>Compare scientific discovery with engineering invention.</li>
          </ul>
        </div>
        <h3 id="data-science">Data Science</h3>
        <p id="data-science-intro">Data science combines computation and domain knowledge to interpret evidence.</p>
        <div data-type="note" class="global-tech ui-has-child-title" id="note-1">
          <h3 data-type="title">Global Issues in Technology</h3>
          <h4 data-type="title">Targeted Advertising</h4>
          <p>Targeting decisions create questions about transparency, accountability, and consent.</p>
        </div>
        <h3 id="taxonomy-heading">Interdisciplinary Areas</h3>
        <ul id="taxonomy">
          <li>Computer systems
            <ul><li>Networks and distributed computing</li></ul>
          </li>
        </ul>
        <figure id="figure-1-7">
          <img src="/apps/image-cdn/example.png" alt="A weather map showing atmospheric water." />
          <figcaption>
            Figure 1.7 Weather prediction combines observations with computational models.
            <span class="os-figure-source">Credit: Sample source.</span>
          </figcaption>
        </figure>
        <table id="comparison-table">
          <tr><th>Area</th><th>Example</th></tr>
          <tr><td>Data science</td><td>Fraud detection</td></tr>
        </table>
        <pre id="sample-code"><code class="language-python">for value in data: analyze(value)</code></pre>
        <div data-type="footnote-refs" id="footnotes">
          <h3 data-type="footnote-refs-title">Footnotes</h3>
          <ol><li>Supporting publication metadata.</li></ol>
        </div>
      </div>
    </main></html>
    """

    url = "https://openstax.org/books/sample-book/pages/1-2-across-disciplines"

    assert {:ok, first} = Source.parse_section_page(body, url)
    assert {:ok, second} = Source.parse_section_page(body, url)

    assert first["title"] == "1.2 Across Disciplines"

    assert first["learning_objectives"] == [
             "Explain how data science relates to computer science.",
             "Compare scientific discovery with engineering invention."
           ]

    refute first["excerpt"] =~ "navigation copy"
    assert first["excerpt"] =~ "Targeted Advertising"

    assert Enum.map(first["content_blocks"], & &1["id"]) ==
             Enum.map(second["content_blocks"], & &1["id"])

    assert first["content_hash"] == second["content_hash"]
    assert Enum.all?(first["content_blocks"], &String.starts_with?(&1["id"], "openstax-block-"))

    assert %{"kind" => "heading", "level" => 2} =
             Enum.find(first["content_blocks"], &(&1["text"] == "1.2 Across Disciplines"))

    assert %{
             "kind" => "objectives",
             "items" => [_, _],
             "blocks" => objective_blocks
           } = Enum.find(first["content_blocks"], &(&1["kind"] == "objectives"))

    assert Enum.any?(objective_blocks, &(&1["kind"] == "heading" and &1["level"] == 3))

    assert %{
             "kind" => "callout",
             "callout_type" => "global_issue",
             "title" => "Global Issues in Technology",
             "subtitle" => "Targeted Advertising",
             "blocks" => callout_blocks
           } = Enum.find(first["content_blocks"], &(&1["kind"] == "callout"))

    assert Enum.any?(
             callout_blocks,
             &(&1["kind"] == "heading" and &1["level"] == 4 and
                 &1["text"] == "Targeted Advertising")
           )

    assert %{"kind" => "list", "items" => [%{"children" => [nested_list]}]} =
             Enum.find(first["content_blocks"], &(&1["source_locator"]["dom_id"] == "taxonomy"))

    assert nested_list["kind"] == "list"
    assert hd(nested_list["items"])["text"] == "Networks and distributed computing"

    assert %{
             "kind" => "table",
             "rows" => [["Area", "Example"], ["Data science", "Fraud detection"]]
           } =
             Enum.find(first["content_blocks"], &(&1["kind"] == "table"))

    assert %{"kind" => "code", "language" => "python"} =
             Enum.find(first["content_blocks"], &(&1["kind"] == "code"))

    assert Enum.any?(first["content_blocks"], &(&1["kind"] == "footnotes"))

    assert [
             %{
               "kind" => "img",
               "src" => "https://openstax.org/apps/image-cdn/example.png",
               "alt" => "A weather map showing atmospheric water.",
               "caption" => caption,
               "credit" => "Credit: Sample source.",
               "rights_status" => "approved",
               "content_hash" => media_content_hash,
               "source_block_id" => source_block_id
             }
           ] = first["media"]

    assert caption =~ "Weather prediction combines observations"
    assert byte_size(media_content_hash) == 64
    assert String.starts_with?(source_block_id, "openstax-block-")
    assert Enum.all?(first["content_blocks"], &(byte_size(&1["content_hash"]) == 64))
    assert first["coverage"]["media_count"] == 1
    assert first["coverage"]["block_count"] > first["coverage"]["top_level_block_count"]
    assert first["word_count"] > 25
  end

  test "extracts figure credit embedded in an OpenStax caption" do
    body = """
    <html><main>
      <div data-book-content="true">
        <h2 data-type="document-title">1.2 Caption credit</h2>
        <figure id="figure-caption-credit">
          <img
            src="https://openstax.org/apps/image-cdn/caption-credit.png"
            alt="A chart comparing two evidence sources."
            width="640"
            height="480"
          />
          <figcaption>
            Figure 1.2 A chart grounded in two sources.
            (data source: Example survey; attribution: Copyright Rice University,
            OpenStax, under CC BY NC-SA 4.0 license)
          </figcaption>
        </figure>
      </div>
    </main></html>
    """

    assert {:ok, section} =
             Source.parse_section_page(
               body,
               "https://openstax.org/books/sample-book/pages/1-2-caption-credit",
               strict_book_content: true
             )

    assert [%{"credit" => credit, "rights_status" => "approved"}] = section["media"]
    assert credit =~ "attribution: Copyright Rice University"
    assert credit =~ "CC BY NC-SA 4.0 license"
  end

  test "rejects an oversized declared content length before accepting the body" do
    client = fn _url, _headers, _opts ->
      {:ok,
       %{
         status_code: 200,
         headers: [{"Content-Length", "250"}],
         body: "small buffered body"
       }}
    end

    assert {:error, {:response_too_large, 250, 100}} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: client,
               max_response_bytes: 100
             )
  end

  test "fetches sections with bounded global concurrency and preserves chapter order" do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, max_active: 0} end)

    client = fn url, _headers, _opts ->
      Agent.update(tracker, fn state ->
        active = state.active + 1
        %{state | active: active, max_active: max(state.max_active, active)}
      end)

      chapter_number =
        url
        |> URI.parse()
        |> Map.fetch!(:path)
        |> String.split("/")
        |> List.last()
        |> String.split("-")
        |> List.first()

      # Make completions occur out of order so the assertion also verifies that
      # task scheduling does not reorder the persisted course scope.
      Process.sleep((7 - String.to_integer(chapter_number)) * 10)

      Agent.update(tracker, &%{&1 | active: &1.active - 1})

      {:ok,
       %{
         status_code: 200,
         body: """
         <html><main>
           <h1>Chapter #{chapter_number} topic</h1>
           <p>This OpenStax paragraph is long enough to become a source excerpt for the planned lesson.</p>
         </main></html>
         """
       }}
    end

    chapters =
      Enum.map(1..6, fn chapter_number ->
        %{
          "id" => "chapter-#{chapter_number}",
          "title" => "Chapter #{chapter_number}",
          "order" => chapter_number,
          "selected" => true,
          "sections" => [
            %{
              "title" => "Topic #{chapter_number}",
              "url" => "https://openstax.org/books/sample-book/pages/#{chapter_number}-1-topic",
              "order" => 1
            }
          ]
        }
      end)

    snapshot = %{
      "book_slug" => "sample-book",
      "source_url" => "https://openstax.org/details/books/sample-book",
      "chapters" => chapters
    }

    selected_ids = Enum.map(1..6, &"chapter-#{&1}")

    assert {:ok, ingested} =
             Source.ingest(snapshot, selected_ids,
               http_client: client,
               fetch_concurrency: 3,
               fetch_task_timeout: 1_000
             )

    assert Enum.map(ingested["chapters"], & &1["id"]) == selected_ids
    assert Agent.get(tracker, & &1.max_active) == 3
  end

  test "bounds optional discovery probes instead of walking every section URL" do
    {:ok, tracker} = Agent.start_link(fn -> [] end)

    source_url = "https://openstax.org/details/books/sample-book"

    client = fn
      ^source_url, _headers, _opts ->
        links =
          Enum.map_join(1..20, "", fn chapter ->
            ~s(<a href="/books/sample-book/pages/#{chapter}-introduction">Chapter #{chapter}</a>)
          end)

        {:ok, %{status_code: 200, body: "<html><main>#{links}</main></html>"}}

      url, _headers, _opts ->
        Agent.update(tracker, &[url | &1])
        {:error, :unavailable}
    end

    assert {:ok, snapshot} =
             Source.discover(source_url,
               http_client: client,
               discovery_candidate_limit: 4,
               discovery_fetch_concurrency: 2,
               discovery_fetch_task_timeout: 100
             )

    assert length(snapshot["chapters"]) == 20

    assert Enum.map(snapshot["chapters"], & &1["id"]) ==
             Enum.map(1..20, &"chapter-#{&1}")

    assert Agent.get(tracker, &length/1) == 4
  end

  test "discovers a merged canonical source with more than 120 sections without truncation" do
    source_url = "https://openstax.org/details/books/sample-book"

    client = fn
      ^source_url, _headers, _opts ->
        anchors =
          Enum.map_join(1..120, "", fn chapter ->
            ~s(<a href="/books/sample-book/pages/#{chapter}-introduction">Chapter #{chapter}</a>)
          end)

        {:ok, %{status_code: 200, body: "<html><main>#{anchors}</main></html>"}}

      _url, _headers, _opts ->
        chapters =
          Enum.map(121..240, fn chapter ->
            %{
              "toc_type" => "chapter",
              "title" => "Chapter #{chapter}",
              "contents" => [
                %{
                  "toc_target_type" => "intro",
                  "slug" => "#{chapter}-introduction",
                  "title" => "Chapter #{chapter}"
                }
              ]
            }
          end)

        state = %{
          "content" => %{
            "book" => %{
              "slug" => "sample-book",
              "title" => "Large Sample Book",
              "tree" => %{"contents" => chapters}
            }
          }
        }

        {:ok,
         %{
           status_code: 200,
           body:
             "<html><script>window.__PRELOADED_STATE__ = #{Jason.encode!(state)};</script></html>"
         }}
    end

    assert {:ok, snapshot} =
             Source.discover(source_url,
               http_client: client,
               discovery_candidate_limit: 1
             )

    assert snapshot["title"] == "Large Sample Book"
    assert length(snapshot["chapters"]) == 240
    assert snapshot["chapters"] |> List.last() |> Map.fetch!("id") == "chapter-240"
  end

  test "ingests more than 120 selected sections without truncation" do
    client = fn url, _headers, _opts ->
      section_number = url |> String.split("/") |> List.last() |> String.split("-") |> hd()

      {:ok,
       %{
         status_code: 200,
         body: """
         <html><main>
           <h1>Section #{section_number}</h1>
           <p>This source paragraph is long enough to be retained for lesson planning.</p>
         </main></html>
         """
       }}
    end

    sections =
      Enum.map(1..121, fn section_number ->
        %{
          "title" => "Section #{section_number}",
          "url" => "https://openstax.org/books/sample-book/pages/#{section_number}-section",
          "order" => section_number
        }
      end)

    snapshot = %{
      "book_slug" => "sample-book",
      "source_url" => "https://openstax.org/details/books/sample-book",
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "Large chapter",
          "order" => 1,
          "selected" => true,
          "sections" => sections
        }
      ]
    }

    assert {:ok, ingested} =
             Source.ingest(snapshot, ["chapter-1"],
               http_client: client,
               fetch_concurrency: 12,
               fetch_task_timeout: 1_000
             )

    assert [%{"sections" => ingested_sections}] = ingested["chapters"]
    assert length(ingested_sections) == 121
    assert List.last(ingested_sections)["order"] == 121
  end

  test "returns a controlled error when the initial discovery page times out" do
    client = fn _url, _headers, _opts ->
      Process.sleep(100)
      {:ok, %{status_code: 200, body: "<html><main></main></html>"}}
    end

    assert {:error, :discovery_fetch_timeout} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: client,
               discovery_fetch_task_timeout: 10
             )
  end

  test "does not follow redirects outside the canonical allowlist" do
    parent = self()

    client = fn _url, _headers, opts ->
      send(parent, {:request_options, opts})
      {:ok, %{status_code: 302, body: ""}}
    end

    assert {:error, {:unexpected_status, 302}} =
             Source.discover("https://openstax.org/details/books/sample-book",
               http_client: client
             )

    assert_receive {:request_options, opts}
    assert get_in(opts, [:hackney, :follow_redirect]) == false
  end

  test "rejects userinfo, non-default ports, and non-page path shapes during ingestion" do
    invalid_urls = [
      "https://user@openstax.org/books/sample-book/pages/1-1-topic",
      "https://openstax.org:444/books/sample-book/pages/1-1-topic",
      "https://openstax.org/books/sample-book/pages/1-1-topic/extra",
      "https://openstax.org/books/sample-book/pages/../1-1-topic",
      "https://openstax.org/books/sample-book/pages/1-1-topic.json"
    ]

    Enum.each(invalid_urls, fn url ->
      snapshot = %{
        "book_slug" => "sample-book",
        "chapters" => [
          %{
            "id" => "chapter-1",
            "order" => 1,
            "sections" => [%{"title" => "Topic", "url" => url, "order" => 1}]
          }
        ]
      }

      assert {:error, {:section_fetch_failed, ^url, :noncanonical_source_url}} =
               Source.ingest(snapshot, ["chapter-1"],
                 http_client: fn _, _, _ -> flunk("invalid URL must not be fetched") end
               )
    end)
  end

  defp chapter_assessment_urls(snapshot) do
    snapshot
    |> get_in(["chapters", Access.at(0), "assessment_sources"])
    |> Enum.map(& &1["url"])
  end
end
