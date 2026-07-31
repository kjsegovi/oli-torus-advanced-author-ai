defmodule Oli.OpenStax.CourseImport.Section12GoldenTest do
  use ExUnit.Case, async: true

  alias Oli.Activities.Model
  alias Oli.OpenStax.CourseImport.{AuthoringCompiler, Checks, Parser, Planner, Source}
  alias Oli.Utils.SchemaResolver

  @section_url "https://openstax.org/books/introduction-computer-science/pages/1-2-computer-science-across-the-disciplines"

  @objectives [
    "Distinguish scientific discovery from technological invention.",
    "Explain how mathematics, science, and engineering support computing.",
    "Compare data science, information science, and computational science.",
    "Evaluate how computing disciplines cooperate on practical problems."
  ]

  @areas [
    %{
      id: "discovery",
      title: "Discovery, Invention, and Computing",
      seed:
        "Scientific discovery explains patterns that already exist, while technological invention creates a practical computing method or system. Researchers compare evidence, models, and observations before proposing an explanation. Engineers then test constraints, revise a design, and document how the invention addresses a practical problem. Computing connects discovery and invention by representing evidence, testing models, and communicating results."
    },
    %{
      id: "foundations",
      title: "Mathematics, Science, and Engineering",
      seed:
        "Mathematics provides precise structures for algorithms and models, science provides evidence and testable questions, and engineering turns a computing design into a dependable system. A team identifies assumptions, measures results, and compares tradeoffs. The disciplines cooperate when a practical problem needs both an explanation and an implementation that people can inspect, test, revise, and use."
    },
    %{
      id: "data",
      title: "Data, Information, and Computational Science",
      seed:
        "Data science studies data patterns with statistical and computing methods, information science organizes information for useful access, and computational science uses computing models to investigate a scientific question. The fields share data, evidence, algorithms, and models, yet each field emphasizes a different practical purpose. A careful team selects methods that fit the question and explains the limits of its results."
    },
    %{
      id: "synergy",
      title: "Interdisciplinary Computing in Practice",
      seed:
        "Interdisciplinary computing combines scientific evidence, mathematical models, engineering constraints, data analysis, and information organization. A practical team defines the problem, compares possible methods, tests a computing model, and communicates evidence to people affected by the decision. Cooperation creates useful results because each discipline contributes a distinct question, method, constraint, or way to evaluate the system."
    }
  ]

  test "section 1.2 remains complete, becomes one rich lesson, and compiles valid Basic and Advanced artifacts" do
    html = section_fixture()

    assert {:ok, source} =
             Source.parse_section_page(html, @section_url, strict_book_content: true)

    assert {:ok, reparsed} =
             Source.parse_section_page(html, @section_url, strict_book_content: true)

    assert source["learning_objectives"] == @objectives
    assert source["word_count"] >= 1_200
    assert source["coverage"]["complete"]

    assert Enum.map(source["content_blocks"], & &1["id"]) ==
             Enum.map(reparsed["content_blocks"], & &1["id"])

    callouts = Enum.filter(source["content_blocks"], &(&1["kind"] == "callout"))
    figures = Enum.filter(source["content_blocks"], &(&1["kind"] == "figure"))

    assert Enum.map(callouts, & &1["callout_type"]) == [
             "global_issue",
             "industry_spotlight",
             "concepts_in_practice"
           ]

    assert length(figures) == 2
    assert length(source["media"]) == 2

    assert Enum.all?(source["media"], fn media ->
             media["id"] =~ "openstax-media-" and
               media["source_block_id"] in Enum.map(figures, & &1["id"]) and
               present?(media["alt"]) and
               present?(media["caption"]) and
               present?(media["credit"]) and
               media["rights_status"] == "approved" and
               present?(media["width"]) and
               present?(media["height"]) and
               present?(media["srcset"])
           end)

    assert Enum.any?(
             source["content_blocks"],
             &(&1["kind"] == "paragraph" and
                 String.contains?(&1["text"], "fourth area cycle 6"))
           )

    snapshot = %{
      "book_slug" => "introduction-computer-science",
      "title" => "Introduction to Computer Science",
      "license" => %{"code" => "CC BY-NC-SA"},
      "chapters" => [
        %{
          "id" => "chapter-1",
          "title" => "Chapter 1: Introduction",
          "order" => 1,
          "selected" => true,
          "url" =>
            "https://openstax.org/books/introduction-computer-science/pages/1-introduction",
          "sections" => [Map.put(source, "order", 2)]
        }
      ]
    }

    assert {:ok, %{"units" => [%{"lessons" => [lesson]}]}} =
             Parser.build_outline(snapshot)

    assert lesson["title"] == "1.2 Computer Science across the Disciplines"
    assert lesson["source_sections"] == [@section_url]
    assert lesson["source_word_count"] >= 1_200
    assert lesson["source_coverage"]["complete"]
    assert lesson["source_coverage"]["section_count"] == 1
    assert lesson["source_coverage"]["media_count"] == 2
    assert lesson["source_coverage"]["semantic_block_count"] == source["coverage"]["block_count"]

    assert {"advanced", generated_plan} = Planner.build_lesson_plan(lesson, 1)

    basic_plan =
      generated_plan
      |> put_in(["content_payload", "authoring_mode"], "basic")
      |> put_in(["content_payload", "advanced_blueprint"], %{})

    section_ids_by_area =
      @areas
      |> Enum.zip(get_in(basic_plan, ["content_payload", "instructional_sections"]))
      |> Map.new(fn {area, section} -> {area.id, section["id"]} end)

    advanced_blueprint =
      lesson
      |> lesson_plan("advanced")
      |> get_in(["content_payload", "advanced_blueprint"])
      |> remap_advanced_sections(section_ids_by_area)

    advanced_plan =
      generated_plan
      |> put_in(["content_payload", "advanced_blueprint"], advanced_blueprint)

    assert instructional_word_count(basic_plan) >= 1_200
    assert length(get_in(basic_plan, ["content_payload", "instructional_sections"])) == 4
    assert length(get_in(basic_plan, ["content_payload", "worked_examples"])) == 3
    assert length(get_in(basic_plan, ["content_payload", "application_problems"])) == 4
    assert length(get_in(basic_plan, ["questions_payload", "items"])) == 4

    assert Enum.map(get_in(basic_plan, ["content_payload", "callouts"]), & &1["type"]) == [
             "global_issue",
             "industry_spotlight",
             "concepts_in_practice"
           ]

    assert Enum.all?(get_in(basic_plan, ["content_payload", "callouts"]), fn callout ->
             present?(callout["body"]) and callout["evidence_block_ids"] != []
           end)

    assert Checks.passed?(Checks.run(lesson, basic_plan))
    assert Checks.passed?(Checks.run(lesson, advanced_plan))

    media_urls =
      Map.new(source["media"], fn media ->
        {media["id"],
         %{
           "url" => "staged://#{media["id"]}",
           "alt" => media["alt"],
           "caption" => media["caption"],
           "credit" => media["credit"]
         }}
      end)

    attribution = %{
      "source_title" => "Introduction to Computer Science",
      "source_url" => "https://openstax.org/details/books/introduction-computer-science",
      "license" => "CC BY-NC-SA",
      "statement" => "Adapted from OpenStax with source-specific figure credits."
    }

    assert {:ok, basic} =
             AuthoringCompiler.compile(
               "basic",
               lesson["title"],
               basic_plan["content_payload"],
               basic_plan["questions_payload"],
               "openstax-section-1-2-basic",
               media_urls: media_urls,
               attribution: attribution
             )

    assert Enum.sort(basic["required_media_ids"]) ==
             source["media"] |> Enum.map(& &1["id"]) |> Enum.sort()

    assert Enum.all?(basic["activities"], &valid_activity?/1)

    assert Enum.count(basic["activities"], &(&1["activity_type_slug"] == "oli_multiple_choice")) ==
             2

    assert Enum.count(basic["activities"], &(&1["activity_type_slug"] == "oli_short_answer")) == 2

    assert {:ok, realized_basic} = realize(basic, 10_000)
    assert_valid_page_content(realized_basic)

    basic_images = collect_elements(realized_basic, "img")
    assert length(basic_images) == 2
    assert Enum.all?(basic_images, &String.starts_with?(&1["src"], "staged://"))
    assert Enum.all?(basic_images, &(present?(&1["alt"]) and present?(&1["caption"])))

    basic_groups = collect_elements(realized_basic, "group")
    assert Enum.any?(basic_groups, &(&1["purpose"] == "example"))
    assert Enum.any?(basic_groups, &(&1["purpose"] == "manystudentswonder"))
    assert Enum.any?(basic_groups, &(&1["purpose"] == "learnbydoing"))
    assert length(collect_elements(realized_basic, "activity-reference")) == 4
    assert collect_text(realized_basic) =~ "Adapted from OpenStax"

    assert {:ok, advanced} =
             AuthoringCompiler.compile(
               "advanced",
               lesson["title"],
               advanced_plan["content_payload"],
               advanced_plan["questions_payload"],
               "openstax-section-1-2-advanced",
               media_urls: media_urls,
               attribution: attribution
             )

    assert Enum.sort(advanced["required_media_ids"]) ==
             source["media"] |> Enum.map(& &1["id"]) |> Enum.sort()

    assert Enum.all?(advanced["activities"], &valid_activity?/1)
    assert {:ok, realized_advanced} = realize(advanced, 20_000)
    assert_valid_page_content(realized_advanced)

    advanced_parts =
      Enum.flat_map(advanced["activities"], &Map.get(&1["model"], "partsLayout", []))

    assert Enum.count(advanced_parts, &(&1["type"] == "janus-image")) == 2
    assert Enum.any?(advanced_parts, &(&1["type"] == "janus-dropdown"))
    assert Enum.any?(advanced_parts, &(&1["type"] == "janus-slider"))
    assert Enum.any?(advanced_parts, &(&1["type"] == "janus-mcq"))
    assert Enum.any?(advanced_parts, &(&1["type"] == "janus-input-text"))

    decision_screen =
      Enum.find(advanced["activities"], fn activity ->
        Enum.any?(activity["model"]["partsLayout"], &(&1["type"] == "janus-dropdown"))
      end)

    assert Enum.any?(
             decision_screen["model"]["authoring"]["rules"],
             &String.starts_with?(&1["name"], "common-error-")
           )

    remediation_rule =
      Enum.find(
        decision_screen["model"]["authoring"]["rules"],
        &(&1["name"] == "incorrect-max-attempt")
      )

    assert Enum.any?(
             get_in(remediation_rule, ["event", "params", "actions"]),
             fn action ->
               action["type"] == "navigation" and
                 get_in(action, ["params", "target"]) not in [nil, "next"]
             end
           )

    assert Enum.any?(advanced["activities"], &(&1["title"] == "Sources and attribution"))
  end

  defp section_fixture do
    content_areas =
      @areas
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {area, area_index} ->
        generated_section_html(area, area_index)
      end)

    """
    <html>
      <body>
        <nav>This navigation is outside the canonical book content.</nav>
        <main>
          <article data-book-content="true">
            <h2 data-type="document-title">1.2 Computer Science across the Disciplines</h2>
            <div data-type="learning-objectives" id="learning-objectives">
              <ul>
                #{Enum.map_join(@objectives, "\n", &"<li>#{&1}</li>")}
              </ul>
            </div>
            #{content_areas}
          </article>
        </main>
      </body>
    </html>
    """
  end

  defp generated_section_html(area, area_index) do
    paragraphs =
      Enum.map_join(1..6, "\n", fn cycle ->
        """
        <p id="#{area.id}-#{cycle}">
          #{instructional_paragraph(area, area_index, cycle)}
        </p>
        """
      end)

    extras =
      case area.id do
        "discovery" ->
          """
          <div data-type="note" class="global-tech" id="global-computing">
            <h4>Computing and shared evidence</h4>
            <p>
              A global science team uses computing models and shared evidence to compare
              observations before choosing a practical invention.
            </p>
          </div>
          <figure id="figure-discovery">
            <picture>
              <source
                srcset="/apps/image-cdn/discovery-model-640.png 640w, /apps/image-cdn/discovery-model-1280.png 1280w"
              />
              <img
                src="/apps/image-cdn/discovery-model.png"
                srcset="/apps/image-cdn/discovery-model-640.png 640w, /apps/image-cdn/discovery-model-1280.png 1280w"
                width="960"
                height="540"
                alt="A research team moves from observations to a tested computing model and then to an engineered invention."
              />
            </picture>
            <figcaption>
              Discovery and invention use evidence in different ways.
              <span data-type="credit">OpenStax representative figure, adapted for testing.</span>
            </figcaption>
          </figure>
          """

        "data" ->
          """
          <div data-type="note" class="industry-spotlight" id="information-work">
            <h4>Information work in public services</h4>
            <p>
              An information science team organizes data so a public service can inspect
              evidence, compare patterns, and explain a computing decision.
            </p>
          </div>
          <figure id="figure-disciplines">
            <img
              src="https://openstax.org/apps/image-cdn/interdisciplinary-data.png"
              srcset="https://openstax.org/apps/image-cdn/interdisciplinary-data-640.png 640w, https://openstax.org/apps/image-cdn/interdisciplinary-data-1200.png 1200w"
              width="1200"
              height="675"
              alt="Overlapping circles connect data science, information science, and computational science around a shared scientific question."
            />
            <figcaption>
              Related computing disciplines contribute different methods to one question.
              <span class="os-credit">OpenStax representative figure, adapted for testing.</span>
            </figcaption>
          </figure>
          """

        "synergy" ->
          """
          <div data-type="note" class="concepts-practice" id="team-decision">
            <h4>Concepts in practice: a team decision</h4>
            <p>
              A practical team compares scientific evidence, mathematical models,
              engineering constraints, and data analysis before selecting a computing method.
            </p>
          </div>
          """

        _ ->
          ""
      end

    """
    <section id="#{area.id}">
      <h3>#{area.title}</h3>
      #{paragraphs}
      #{extras}
    </section>
    """
  end

  defp instructional_paragraph(area, area_index, cycle) do
    marker =
      case {area_index, cycle} do
        {4, 6} -> "This fourth area cycle 6 confirms that the final source block is retained."
        _ -> "This is generated learning evidence for area #{area_index}, cycle #{cycle}."
      end

    "#{area.seed} #{marker}"
  end

  defp lesson_plan(lesson, mode) do
    blocks = lesson["source_blocks"]
    objective_block = Enum.find(blocks, &(&1["kind"] == "objectives"))
    document_heading = Enum.find(blocks, &(&1["kind"] == "heading" and &1["level"] == 2))

    instructional_sections =
      @areas
      |> Enum.with_index(1)
      |> Enum.map(fn {area, area_index} ->
        evidence_ids =
          blocks
          |> Enum.filter(&(List.last(&1["heading_path"] || []) == area.title))
          |> Enum.map(& &1["id"])
          |> then(fn ids ->
            if area_index == 1,
              do: [objective_block["id"], document_heading["id"] | ids],
              else: ids
          end)
          |> Enum.uniq()

        %{
          "id" => area.id,
          "title" => area.title,
          "explanation" =>
            Enum.map_join(1..6, " ", &instructional_paragraph(area, area_index, &1)),
          "evidence_block_ids" => evidence_ids
        }
      end)

    callouts =
      blocks
      |> Enum.filter(&(&1["kind"] == "callout"))
      |> Enum.map(fn block ->
        %{
          "id" => "plan-#{block["id"]}",
          "type" => block["callout_type"],
          "title" => block["subtitle"] || block["title"] || "Source connection",
          "body" => block["text"],
          "evidence_block_ids" => [block["id"]]
        }
      end)

    media =
      lesson["source_media"]
      |> Enum.with_index(1)
      |> Enum.map(fn {asset, index} ->
        %{
          "id" => asset["id"],
          "source_media_id" => asset["id"],
          "title" => "Source figure #{index}",
          "alt" => asset["alt"],
          "caption" => asset["caption"],
          "credit" => asset["credit"],
          "rights_status" => asset["rights_status"],
          "placement_after_section_id" => if(index == 1, do: "discovery", else: "data"),
          "evidence_block_ids" => [asset["source_block_id"]]
        }
      end)

    area_evidence = Map.new(instructional_sections, &{&1["id"], &1["evidence_block_ids"]})

    content = %{
      "schema_version" => 3,
      "title" => lesson["title"],
      "narrative" =>
        "Computing connects discovery, invention, mathematics, science, engineering, data, information, and computational models.",
      "opening_hook" =>
        "How can computing connect scientific discovery with a practical technological invention?",
      "why_this_matters" =>
        "Computing teams use evidence, models, data, and engineering constraints to address practical problems.",
      "learning_objectives" => @objectives,
      "authoring_mode" => mode,
      "source_evidence_links" => [@section_url],
      "instructional_sections" => instructional_sections,
      "callouts" => callouts,
      "media" => media,
      "worked_examples" => worked_examples(area_evidence),
      "curiosity_prompts" => curiosity_prompts(area_evidence),
      "application_problems" => application_problems(area_evidence),
      "key_takeaways" => [
        "Scientific discovery explains evidence while technological invention creates a practical system.",
        "Mathematics, science, and engineering contribute different methods to computing.",
        "Data science, information science, and computational science emphasize different practical purposes.",
        "Interdisciplinary computing combines evidence, models, constraints, analysis, and communication."
      ],
      "coverage_manifest" => %{"excluded_blocks" => []},
      "attribution" => %{
        "source_title" => "Introduction to Computer Science",
        "source_url" => "https://openstax.org/details/books/introduction-computer-science",
        "license" => "CC BY-NC-SA"
      }
    }

    content =
      if mode == "advanced",
        do: Map.put(content, "advanced_blueprint", advanced_blueprint(area_evidence)),
        else: content

    %{
      "content_payload" => content,
      "questions_payload" => %{"items" => formative_questions(area_evidence)}
    }
  end

  defp worked_examples(area_evidence) do
    [
      %{
        "id" => "case-discovery",
        "title" => "Worked case: discovery or invention",
        "scenario" => "A science team compares observations before proposing a computing model.",
        "steps" => [
          "Identify the scientific evidence and testable question.",
          "Separate an explanation of existing patterns from a practical invention.",
          "Document how the computing model supports the team decision."
        ],
        "conclusion" =>
          "Discovery explains evidence, while invention creates and tests a practical method.",
        "evidence_block_ids" => area_evidence["discovery"]
      },
      %{
        "id" => "case-data",
        "title" => "Worked case: choose a computing discipline",
        "scenario" =>
          "A team has data patterns, organized information, and a scientific question.",
        "steps" => [
          "Use data science to study data patterns.",
          "Use information science to organize useful access.",
          "Use computational science to test a computing model."
        ],
        "conclusion" =>
          "The team selects methods that fit the practical purpose and explains their limits.",
        "evidence_block_ids" => area_evidence["data"]
      },
      %{
        "id" => "case-synergy",
        "title" => "Worked case: interdisciplinary decision",
        "scenario" =>
          "A practical team must compare evidence, models, constraints, and data analysis.",
        "steps" => [
          "Define the practical problem and scientific question.",
          "Compare mathematical models and engineering constraints.",
          "Communicate evidence to people affected by the computing decision."
        ],
        "conclusion" =>
          "Cooperation creates useful results because each discipline contributes a distinct method.",
        "evidence_block_ids" => area_evidence["synergy"]
      }
    ]
  end

  defp curiosity_prompts(area_evidence) do
    [
      %{
        "id" => "curiosity-discovery",
        "prompt" =>
          "Predict when a computing result represents scientific discovery rather than technological invention.",
        "evidence_block_ids" => area_evidence["discovery"]
      },
      %{
        "id" => "curiosity-data",
        "prompt" =>
          "What changes when a team emphasizes data science instead of information science?",
        "evidence_block_ids" => area_evidence["data"]
      },
      %{
        "id" => "curiosity-synergy",
        "prompt" =>
          "Which engineering constraint could change an interdisciplinary computing decision?",
        "evidence_block_ids" => area_evidence["synergy"]
      }
    ]
  end

  defp application_problems(area_evidence) do
    [
      %{
        "id" => "application-discovery",
        "title" => "Classify discovery and invention",
        "prompt" =>
          "Explain whether a new computing model is a scientific discovery, a technological invention, or both.",
        "guidance" => "Use evidence, explanation, design, and testing in the comparison.",
        "evidence_block_ids" => area_evidence["discovery"]
      },
      %{
        "id" => "application-foundations",
        "title" => "Assign disciplinary roles",
        "prompt" =>
          "Describe how mathematics, science, and engineering would address one practical computing problem.",
        "guidance" => "Connect structures, evidence, constraints, testing, and implementation.",
        "evidence_block_ids" => area_evidence["foundations"]
      },
      %{
        "id" => "application-data",
        "title" => "Select a data discipline",
        "prompt" =>
          "Choose data science, information science, or computational science for a scientific question and justify the method.",
        "guidance" => "Compare data patterns, useful access, computing models, and limits.",
        "evidence_block_ids" => area_evidence["data"]
      },
      %{
        "id" => "application-synergy",
        "title" => "Design an interdisciplinary team",
        "prompt" =>
          "Design a computing team that combines evidence, models, constraints, analysis, and communication.",
        "guidance" => "Explain the distinct contribution of each discipline.",
        "evidence_block_ids" => area_evidence["synergy"]
      }
    ]
  end

  defp formative_questions(area_evidence) do
    [
      multiple_choice_question(
        "q-discovery",
        "Which statement best distinguishes scientific discovery from technological invention?",
        @objectives |> Enum.at(0),
        area_evidence["discovery"],
        [
          %{
            "id" => "explain",
            "text" =>
              "Discovery explains existing patterns; invention creates a practical method.",
            "correct" => true,
            "feedback" => "Correct. The distinction depends on explanation and creation."
          },
          %{
            "id" => "same",
            "text" => "Discovery and invention always describe the same activity.",
            "correct" => false,
            "feedback" => "Compare explaining evidence with creating and testing a design."
          },
          %{
            "id" => "reverse",
            "text" => "Discovery creates systems; invention only observes patterns.",
            "correct" => false,
            "feedback" => "Review the roles of evidence, explanation, design, and testing."
          }
        ],
        "explain"
      ),
      multiple_choice_question(
        "q-foundations",
        "Which discipline most directly turns a computing design into a dependable system?",
        @objectives |> Enum.at(1),
        area_evidence["foundations"],
        [
          %{
            "id" => "mathematics",
            "text" => "Mathematics",
            "correct" => false,
            "feedback" => "Mathematics provides precise structures and models."
          },
          %{
            "id" => "science",
            "text" => "Science",
            "correct" => false,
            "feedback" => "Science provides evidence and testable questions."
          },
          %{
            "id" => "engineering",
            "text" => "Engineering",
            "correct" => true,
            "feedback" => "Correct. Engineering tests constraints and implementation."
          }
        ],
        "engineering"
      ),
      multiple_choice_question(
        "q-data",
        "Which field uses computing models to investigate a scientific question?",
        @objectives |> Enum.at(2),
        area_evidence["data"],
        [
          %{
            "id" => "data-science",
            "text" => "Data science",
            "correct" => false,
            "feedback" => "Data science studies data patterns with statistical methods."
          },
          %{
            "id" => "information-science",
            "text" => "Information science",
            "correct" => false,
            "feedback" => "Information science organizes information for useful access."
          },
          %{
            "id" => "computational-science",
            "text" => "Computational science",
            "correct" => true,
            "feedback" => "Correct. Computational science investigates questions with models."
          }
        ],
        "computational-science"
      ),
      short_answer_question(
        "q-synergy",
        "How can computing disciplines cooperate on a practical problem?",
        @objectives |> Enum.at(3),
        area_evidence["synergy"],
        ["evidence", "models", "constraints", "analysis"]
      ),
      short_answer_question(
        "q-application",
        "Why should a computing team explain the limits of its data and models?",
        @objectives,
        area_evidence["data"] ++ area_evidence["synergy"],
        ["limits", "data", "models"]
      )
    ]
  end

  defp multiple_choice_question(id, prompt, objective, evidence_ids, choices, correct_id) do
    %{
      "id" => id,
      "type" => "multiple_choice",
      "prompt" => prompt,
      "choices" => choices,
      "correct_choice_id" => correct_id,
      "objective_ids" => List.wrap(objective),
      "placement_after_section_id" => id |> String.trim_leading("q-") |> placement_section_id(),
      "evidence_block_ids" => evidence_ids,
      "source_evidence_links" => [@section_url],
      "correct_feedback" => "The response is supported by the lesson evidence.",
      "incorrect_feedback" => "Review the related instructional section and try again.",
      "remediation" => "Return to the related instructional section."
    }
  end

  defp short_answer_question(id, prompt, objectives, evidence_ids, keywords) do
    %{
      "id" => id,
      "type" => "short_answer",
      "response_kind" => "application",
      "prompt" => prompt,
      "answer_keywords" => keywords,
      "objective_ids" => List.wrap(objectives),
      "placement_after_section_id" => id |> String.trim_leading("q-") |> placement_section_id(),
      "evidence_block_ids" => evidence_ids,
      "source_evidence_links" => [@section_url],
      "remediation" => "Review the evidence, model, constraint, and analysis in the lesson."
    }
  end

  defp placement_section_id("application"), do: "synergy"
  defp placement_section_id(section_id), do: section_id

  defp advanced_blueprint(area_evidence) do
    %{
      "screens" => [
        %{
          "id" => "disciplinary-foundations",
          "kind" => "content",
          "title" => "Source-grounded disciplinary context",
          "body" =>
            "Mathematics supplies precise structures, science supplies evidence and testable questions, and engineering turns a computing design into a dependable system.",
          "placement_after_section_id" => "foundations",
          "evidence_block_ids" => area_evidence["foundations"]
        },
        %{
          "id" => "choose-data-discipline",
          "kind" => "decision",
          "title" => "Choose a discipline",
          "prompt" =>
            "Which discipline uses computing models to investigate a scientific question?",
          "interaction_type" => "dropdown",
          "choices" => [
            %{
              "id" => "information",
              "text" => "Information science",
              "correct" => false,
              "feedback" => "Information science organizes information for useful access."
            },
            %{
              "id" => "computational",
              "text" => "Computational science",
              "correct" => true,
              "feedback" =>
                "Computational science investigates a scientific question with models."
            }
          ],
          "correct_choice_id" => "computational",
          "placement_after_section_id" => "data",
          "remediation_section_id" => "data",
          "evidence_block_ids" => area_evidence["data"]
        },
        %{
          "id" => "predict-team-contributions",
          "kind" => "exploration",
          "title" => "Predict team contributions",
          "prompt" => "How many distinct disciplinary contributions appear in this team model?",
          "interaction_type" => "slider",
          "configuration" => %{"min" => 1, "max" => 8, "step" => 1, "correct" => 5},
          "incorrect_feedback" =>
            "Compare evidence, mathematical models, engineering constraints, data analysis, and communication.",
          "remediation" =>
            "Review the interdisciplinary computing team and count each distinct contribution.",
          "placement_after_section_id" => "synergy",
          "remediation_section_id" => "synergy",
          "evidence_block_ids" => area_evidence["synergy"]
        }
      ],
      "remediation_paths" => [
        %{"from_question_id" => "choose-data-discipline", "to_section_id" => "data"}
      ]
    }
  end

  defp remap_advanced_sections(blueprint, section_ids_by_area) do
    screens =
      Enum.map(blueprint["screens"], fn screen ->
        screen
        |> remap_section_field("placement_after_section_id", section_ids_by_area)
        |> remap_section_field("remediation_section_id", section_ids_by_area)
      end)

    remediation_paths =
      Enum.map(blueprint["remediation_paths"], fn path ->
        remap_section_field(path, "to_section_id", section_ids_by_area)
      end)

    blueprint
    |> Map.put("screens", screens)
    |> Map.put("remediation_paths", remediation_paths)
  end

  defp remap_section_field(map, field, section_ids_by_area) do
    case map[field] do
      section_id when is_binary(section_id) ->
        Map.put(map, field, Map.get(section_ids_by_area, section_id, section_id))

      _ ->
        map
    end
  end

  defp instructional_word_count(plan) do
    plan
    |> get_in(["content_payload", "instructional_sections"])
    |> Enum.map_join(" ", & &1["explanation"])
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp valid_activity?(activity), do: match?({:ok, _}, Model.parse(activity["model"]))

  defp realize(artifact, starting_id) do
    activity_ids =
      artifact["activities"]
      |> Enum.with_index(starting_id)
      |> Map.new(fn {activity, id} -> {activity["key"], id} end)

    AuthoringCompiler.realize_page(artifact["page_content_template"], activity_ids)
  end

  defp assert_valid_page_content(content) do
    assert :ok =
             "page-content.schema.json"
             |> SchemaResolver.resolve()
             |> ExJsonSchema.Validator.validate(content)
  end

  defp collect_text(value) when is_map(value) do
    [value["text"] | Enum.map(Map.values(value), &collect_text/1)]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp collect_text(value) when is_list(value) do
    value
    |> Enum.map(&collect_text/1)
    |> Enum.join(" ")
  end

  defp collect_text(_value), do: ""

  defp collect_elements(value, type) when is_map(value) do
    current = if value["type"] == type, do: [value], else: []
    current ++ Enum.flat_map(Map.values(value), &collect_elements(&1, type))
  end

  defp collect_elements(value, type) when is_list(value),
    do: Enum.flat_map(value, &collect_elements(&1, type))

  defp collect_elements(_value, _type), do: []

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
