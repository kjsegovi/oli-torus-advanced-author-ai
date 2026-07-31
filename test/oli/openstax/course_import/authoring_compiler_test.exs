defmodule Oli.OpenStax.CourseImport.AuthoringCompilerTest do
  use ExUnit.Case, async: true

  alias Oli.Activities.Model
  alias Oli.OpenStax.CourseImport.AuthoringCompiler
  alias Oli.Utils.SchemaResolver

  test "compiles deterministic Basic Author pages with canonical short-answer models" do
    assert {:ok, first} =
             AuthoringCompiler.compile(
               "basic",
               "Lesson one",
               content(),
               questions(),
               "lesson-one"
             )

    assert {:ok, second} =
             AuthoringCompiler.compile(
               "basic",
               "Lesson one",
               content(),
               questions(),
               "lesson-one"
             )

    assert first == second
    assert first["mode"] == "basic"
    assert length(first["activities"]) == 2

    assert Enum.all?(first["activities"], fn spec ->
             spec["activity_type_slug"] == "oli_short_answer" and
               match?({:ok, _}, Model.parse(spec["model"]))
           end)

    ids =
      first["activities"]
      |> Enum.with_index(101)
      |> Map.new(fn {spec, id} -> {spec["key"], id} end)

    assert {:ok, realized} =
             AuthoringCompiler.realize_page(first["page_content_template"], ids)

    assert [content_block | _] = realized["model"]
    assert content_block["type"] == "content"
    assert realized["version"] == "0.1.0"

    references =
      Enum.filter(realized["model"], &(&1["type"] == "activity-reference"))

    assert Enum.map(references, & &1["activity_id"]) == [101, 102]
    refute Jason.encode!(realized) =~ "activity_key"

    assert :ok =
             "page-content-basic.schema.json"
             |> SchemaResolver.resolve()
             |> ExJsonSchema.Validator.validate(realized)
  end

  test "places structured instructional material and source links before Basic formative questions" do
    content =
      advanced_content()
      |> put_in(
        ["instructional_sections", Access.at(0), "examples"],
        [
          %{
            "title" => "Compare two searches",
            "scenario" => "A learner must find one item in a sorted collection.",
            "steps" => [
              "Inspect each candidate for a linear search.",
              "Discard half of the candidates after each comparison for binary search."
            ],
            "conclusion" =>
              "Binary search examines far fewer candidates as the collection grows.",
            "source_evidence_links" => [
              "https://openstax.org/books/sample/pages/1-1-topic"
            ]
          }
        ]
      )

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "basic",
               "Lesson one",
               content,
               questions(),
               "rich-basic-lesson"
             )

    ids =
      compiled["activities"]
      |> Enum.with_index(201)
      |> Map.new(fn {spec, id} -> {spec["key"], id} end)

    assert {:ok, realized} =
             AuthoringCompiler.realize_page(compiled["page_content_template"], ids)

    model = realized["model"]
    first_question_index = Enum.find_index(model, &(&1["type"] == "activity-reference"))
    instructional_model = Enum.take(model, first_question_index)
    instructional_text = collect_text(instructional_model)

    assert instructional_text =~ "Learning Objectives"
    assert instructional_text =~ "Models of computation"
    assert instructional_text =~ "Algorithm limits"
    assert instructional_text =~ "Compare two searches"
    assert instructional_text =~ "Binary search examines far fewer candidates"
    assert instructional_text =~ "Key Takeaways"
    assert instructional_text =~ "Sources"
    assert instructional_text =~ "Check Your Understanding"

    assert Enum.any?(instructional_model, fn block ->
             block["type"] == "group" and block["purpose"] == "example"
           end)

    assert [
             %{
               "href" => "https://openstax.org/books/sample/pages/1-1-topic",
               "linkType" => "url"
             }
           ] =
             model
             |> collect_elements("a")
             |> Enum.uniq_by(& &1["href"])

    assert Enum.map(Enum.drop(model, first_question_index), & &1["activity_id"]) == [201, 202]

    assert :ok =
             "page-content-basic.schema.json"
             |> SchemaResolver.resolve()
             |> ExJsonSchema.Validator.validate(realized)
  end

  test "compiles deterministic Advanced Author pages as a staged adaptive sequence" do
    assert {:ok, first} =
             AuthoringCompiler.compile(
               "advanced",
               "Lesson two",
               advanced_content(),
               advanced_questions(),
               "lesson-two"
             )

    assert {:ok, second} =
             AuthoringCompiler.compile(
               "advanced",
               "Lesson two",
               advanced_content(),
               advanced_questions(),
               "lesson-two"
             )

    assert first == second
    assert first["mode"] == "advanced"
    assert length(first["activities"]) == 9

    assert Enum.all?(first["activities"], fn screen ->
             screen["activity_type_slug"] == "oli_adaptive" and
               match?({:ok, _}, Model.parse(screen["model"]))
           end)

    {content_screens, question_screens} =
      Enum.split_with(first["activities"], fn screen ->
        Enum.all?(
          screen["model"]["partsLayout"],
          &(&1["type"] != "janus-input-text")
        )
      end)

    assert Enum.all?(content_screens, fn screen ->
             content_screen_navigates_next?(screen)
           end)

    assert Enum.map(content_screens, & &1["title"]) == [
             "Lesson two — Explore",
             "Computing and public decisions",
             "Models of computation",
             "Algorithm limits",
             "Worked example: search growth",
             "Lesson two — Key takeaways",
             "Sources and attribution"
           ]

    assert Enum.all?(question_screens, fn screen ->
             Enum.count(
               screen["model"]["partsLayout"],
               &(&1["type"] == "janus-input-text")
             ) == 1
           end)

    [first_check, second_check] = question_screens

    first_input =
      Enum.find(first_check["model"]["partsLayout"], &(&1["type"] == "janus-input-text"))

    assert get_in(first_input, ["custom", "correctAnswer", "mustContain"]) ==
             "algorithm,complexity"

    assert first_check["model"]["authoring"]["rules"]
           |> Enum.map(& &1["name"])
           |> Enum.sort() ==
             Enum.sort(["correct", "blank", "incorrect-max-attempt", "default-incorrect"])

    correct_rule =
      Enum.find(first_check["model"]["authoring"]["rules"], &(&1["name"] == "correct"))

    assert correct_rule
           |> get_in(["event", "params", "actions"])
           |> Enum.any?(fn action ->
             action["type"] == "navigation" and get_in(action, ["params", "target"]) == "next"
           end)

    remediation_rule =
      Enum.find(
        first_check["model"]["authoring"]["rules"],
        &(&1["name"] == "incorrect-max-attempt")
      )

    assert Jason.encode!(remediation_rule) =~
             "Review how algorithm growth changes as inputs increase."

    first_check_index = Enum.find_index(first["activities"], &(&1["key"] == first_check["key"]))
    first_check_anchor = Enum.at(first["activities"], first_check_index - 1)

    first_check_anchor_sequence =
      first["page_content_template"]["model"]
      |> List.first()
      |> Map.fetch!("children")
      |> Enum.at(first_check_index - 1)
      |> get_in(["custom", "sequenceId"])

    assert first_check_anchor["title"] == "Algorithm limits"

    assert remediation_rule
           |> get_in(["event", "params", "actions"])
           |> Enum.any?(fn action ->
             action["type"] == "navigation" and
               get_in(action, ["params", "target"]) == first_check_anchor_sequence
           end)

    assert Jason.encode!(second_check["model"]) =~
             "Connect the model assumptions to the problem."

    ids =
      first["activities"]
      |> Enum.with_index(501)
      |> Map.new(fn {screen, id} -> {screen["key"], id} end)

    assert {:ok, realized} =
             AuthoringCompiler.realize_page(
               first["page_content_template"],
               ids
             )

    assert realized["advancedAuthoring"]
    assert realized["advancedDelivery"]

    assert [
             %{
               "type" => "group",
               "layout" => "deck",
               "children" => children
             }
           ] = realized["model"]

    assert Enum.map(children, & &1["activity_id"]) == Enum.to_list(501..509)
    assert Enum.all?(children, &is_binary(get_in(&1, ["custom", "sequenceName"])))
    refute Jason.encode!(realized) =~ "activity_key"
  end

  test "legacy Advanced plans still separate content from each formative check" do
    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               "Legacy lesson",
               content(),
               questions(),
               "legacy-lesson"
             )

    assert length(compiled["activities"]) == 5

    {content_screens, question_screens} =
      Enum.split_with(compiled["activities"], fn screen ->
        Enum.all?(
          screen["model"]["partsLayout"],
          &(&1["type"] != "janus-input-text")
        )
      end)

    assert length(content_screens) == 3
    assert Enum.all?(content_screens, &content_screen_navigates_next?/1)

    assert question_screens
           |> Enum.all?(fn screen ->
             Enum.count(
               screen["model"]["partsLayout"],
               &(&1["type"] == "janus-input-text")
             ) == 1
           end)
  end

  test "compiles V3 Basic material with callouts, staged media, and section practice" do
    attribution = %{
      "source_title" => "Introduction to Computer Science",
      "source_url" => "https://openstax.org/details/books/introduction-computer-science",
      "license" => "CC BY-NC-SA"
    }

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "basic",
               "Models and limits",
               v3_content(),
               v3_questions(),
               "v3-basic",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               },
               attribution: attribution
             )

    assert compiled["required_media_ids"] == ["search-growth"]
    assert compiled["attribution"] == attribution

    assert Enum.map(compiled["activities"], & &1["activity_type_slug"]) == [
             "oli_multiple_choice",
             "oli_short_answer"
           ]

    ids =
      compiled["activities"]
      |> Enum.with_index(801)
      |> Map.new(fn {spec, id} -> {spec["key"], id} end)

    assert {:ok, realized} =
             AuthoringCompiler.realize_page(compiled["page_content_template"], ids)

    assert :ok =
             "page-content-basic.schema.json"
             |> SchemaResolver.resolve()
             |> ExJsonSchema.Validator.validate(realized)

    model = realized["model"]
    text = collect_text(model)

    assert text =~ "Why does a faster algorithm matter"
    assert text =~ "Why this matters"
    assert text =~ "Computing and public decisions"
    assert text =~ "Trace binary search"
    assert text =~ "Attribution"
    assert text =~ "CC BY-NC-SA"

    assert [%{"src" => "staged://search-growth"} = image] = collect_elements(model, "img")
    assert image["alt"] =~ "linear and logarithmic"
    assert image["caption"] =~ "Growth comparison"

    assert Enum.any?(model, &(&1["type"] == "group" and &1["purpose"] == "manystudentswonder"))

    practice_groups =
      Enum.filter(model, &(&1["type"] == "group" and &1["purpose"] == "learnbydoing"))

    assert length(practice_groups) >= 3

    assert practice_groups
           |> collect_elements("activity-reference")
           |> Enum.map(& &1["activity_id"]) == [802, 801]

    refute Enum.any?(model, &(&1["type"] == "activity-reference"))
  end

  test "compiles V3 Advanced material into media and adaptive MCQ screens" do
    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               "Models and limits",
               v3_content(),
               v3_questions(),
               "v3-advanced",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               },
               attribution: "Adapted from OpenStax under CC BY-NC-SA."
             )

    image_screen =
      Enum.find(compiled["activities"], fn screen ->
        Enum.any?(screen["model"]["partsLayout"], &(&1["type"] == "janus-image"))
      end)

    assert image_screen

    image = Enum.find(image_screen["model"]["partsLayout"], &(&1["type"] == "janus-image"))
    assert image["custom"]["src"] == "staged://search-growth"
    assert image["custom"]["alt"] =~ "linear and logarithmic"
    assert image_screen["model"]["custom"]["height"] >= 540

    mcq_screen =
      Enum.find(compiled["activities"], fn screen ->
        Enum.any?(screen["model"]["partsLayout"], &(&1["type"] == "janus-mcq"))
      end)

    assert mcq_screen

    mcq = Enum.find(mcq_screen["model"]["partsLayout"], &(&1["type"] == "janus-mcq"))
    assert mcq["custom"]["correctAnswer"] == 1
    assert length(mcq["custom"]["mcqItems"]) == 3

    assert mcq_screen["model"]["authoring"]["rules"]
           |> Enum.map(& &1["name"])
           |> Enum.sort() ==
             Enum.sort(["correct", "blank", "incorrect-max-attempt", "default-incorrect"])

    assert Enum.any?(
             compiled["activities"],
             &(&1["title"] == "Sources and attribution")
           )

    assert Enum.all?(compiled["activities"], fn screen ->
             match?({:ok, _}, Model.parse(screen["model"]))
           end)
  end

  test "Advanced knowledge checks preserve misconception feedback and branch to remediation" do
    questions = %{
      "items" =>
        Enum.map(1..4, fn index ->
          %{
            "type" => "multiple_choice",
            "prompt" => "Which explanation is supported by the lesson? #{index}",
            "choices" => [
              %{
                "id" => "misconception-#{index}",
                "text" => "The tempting misconception",
                "feedback" => "Reconsider assumption #{index} before trying again."
              },
              %{
                "id" => "supported-#{index}",
                "text" => "The source-supported explanation",
                "correct" => true
              },
              %{"id" => "unrelated-#{index}", "text" => "An unrelated explanation"}
            ],
            "correct_choice_id" => "supported-#{index}",
            "remediation" => "Review the source-grounded explanation for check #{index}."
          }
        end)
    }

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               "Adaptive lesson",
               content(),
               questions,
               "adaptive-knowledge-checks"
             )

    knowledge_checks =
      Enum.filter(compiled["activities"], fn screen ->
        Enum.any?(screen["model"]["partsLayout"], &(&1["type"] == "janus-mcq"))
      end)

    assert length(knowledge_checks) == 4

    first_check = List.first(knowledge_checks)

    misconception_rule =
      Enum.find(
        first_check["model"]["authoring"]["rules"],
        &String.starts_with?(&1["name"], "common-error-")
      )

    assert get_in(misconception_rule, ["conditions", "all", Access.at(1), "value"]) == "1"
    assert Jason.encode!(misconception_rule) =~ "Reconsider assumption 1 before trying again."

    sequence_ids =
      compiled["page_content_template"]["model"]
      |> List.first()
      |> Map.fetch!("children")
      |> Enum.map(&get_in(&1, ["custom", "sequenceId"]))
      |> MapSet.new()

    assert Enum.all?(knowledge_checks, fn check ->
             remediation_rule =
               Enum.find(
                 check["model"]["authoring"]["rules"],
                 &(&1["name"] == "incorrect-max-attempt")
               )

             remediation_rule
             |> get_in(["event", "params", "actions"])
             |> Enum.any?(fn action ->
               target = get_in(action, ["params", "target"])

               action["type"] == "navigation" and target != "next" and
                 MapSet.member?(sequence_ids, target)
             end)
           end)

    assert Enum.all?(compiled["activities"], fn screen ->
             match?({:ok, _}, Model.parse(screen["model"]))
           end)
  end

  test "honors top-level figure placement in Basic and Advanced output" do
    [models, growth] = v3_content()["instructional_sections"]
    [figure] = growth["media"]

    content =
      v3_content()
      |> Map.put("instructional_sections", [models, Map.delete(growth, "media")])
      |> Map.put("media", [Map.put(figure, "placement_after_section_id", "models")])

    media_urls = %{
      "search-growth" => %{
        "url" => "staged://search-growth",
        "alt" => "A graph comparing linear and logarithmic search growth"
      }
    }

    assert {:ok, basic} =
             AuthoringCompiler.compile(
               "basic",
               "Models and limits",
               content,
               v3_questions(),
               "placed-basic",
               media_urls: media_urls
             )

    activity_ids =
      basic["activities"]
      |> Enum.with_index(901)
      |> Map.new(fn {spec, id} -> {spec["key"], id} end)

    assert {:ok, realized} =
             AuthoringCompiler.realize_page(basic["page_content_template"], activity_ids)

    model = realized["model"]
    models_index = Enum.find_index(model, &(collect_text(&1) =~ "Computation models"))
    image_index = Enum.find_index(model, &(collect_elements(&1, "img") != []))

    assert image_index > models_index

    assert {:ok, advanced} =
             AuthoringCompiler.compile(
               "advanced",
               "Models and limits",
               meaningful_v3_advanced_content(content),
               v3_questions(),
               "placed-advanced",
               media_urls: media_urls
             )

    models_screen_index =
      Enum.find_index(advanced["activities"], &(&1["title"] == "Computation models"))

    image_screen_index =
      Enum.find_index(advanced["activities"], fn screen ->
        Enum.any?(screen["model"]["partsLayout"], &(&1["type"] == "janus-image"))
      end)

    assert image_screen_index > models_screen_index
  end

  test "compiles the V3 Advanced blueprint into decision, slider, and numeric interactions" do
    content =
      v3_content()
      |> Map.put("schema_version", 3)
      |> Map.put("advanced_blueprint", %{
        "screens" => [
          %{
            "id" => "search-context",
            "kind" => "content",
            "title" => "Source-grounded search context",
            "body" =>
              "Binary search uses sorted order to discard half of the remaining candidates after each comparison.",
            "placement_after_section_id" => "models",
            "evidence_block_ids" => ["models-explanation"]
          },
          %{
            "id" => "choose-search",
            "kind" => "decision",
            "title" => "Choose a search strategy",
            "prompt" => "Which strategy best fits a large sorted collection?",
            "interaction_type" => "dropdown",
            "choices" => [
              %{
                "id" => "linear",
                "text" => "Linear search",
                "correct" => false,
                "feedback" => "Linear search ignores the sorted order."
              },
              %{
                "id" => "binary",
                "text" => "Binary search",
                "correct" => true,
                "feedback" => "Binary search uses the sorted order to halve the candidates."
              }
            ],
            "placement_after_section_id" => "models",
            "remediation_section_id" => "models"
          },
          %{
            "id" => "predict-comparisons",
            "kind" => "exploration",
            "title" => "Predict the search effort",
            "prompt" => "How many halvings are needed for sixteen candidates?",
            "interaction_type" => "slider",
            "configuration" => %{"min" => 0, "max" => 8, "step" => 1, "correct" => 4},
            "incorrect_feedback" => "Trace each halving in the worked example.",
            "placement_after_section_id" => "growth",
            "remediation_section_id" => "growth"
          },
          %{
            "id" => "calculate-halvings",
            "kind" => "check",
            "title" => "Calculate the effort",
            "prompt" => "Enter the number of halvings.",
            "interaction_type" => "number_input",
            "correct_response" => 4,
            "incorrect_feedback" => "Count each time the candidate set is halved.",
            "remediation_section_id" => "growth"
          }
        ],
        "remediation_paths" => [
          %{"from_question_id" => "choose-search", "to_section_id" => "models"}
        ]
      })

    assert {:ok, compiled} =
             AuthoringCompiler.compile(
               "advanced",
               "Models and limits",
               content,
               v3_questions(),
               "v3-blueprint",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               }
             )

    interaction_types =
      compiled["activities"]
      |> Enum.flat_map(&Enum.map(&1["model"]["partsLayout"], fn part -> part["type"] end))

    assert "janus-dropdown" in interaction_types
    assert "janus-slider" in interaction_types
    assert "janus-input-number" in interaction_types

    content_screen =
      Enum.find(compiled["activities"], &(&1["title"] == "Source-grounded search context"))

    assert content_screen

    assert collect_text(content_screen["model"]["partsLayout"]) =~
             "Binary search uses sorted order"

    refute Enum.any?(
             content_screen["model"]["partsLayout"],
             &(&1["type"] in ["janus-dropdown", "janus-slider", "janus-input-number"])
           )

    decision_screen =
      Enum.find(compiled["activities"], fn screen ->
        Enum.any?(screen["model"]["partsLayout"], &(&1["type"] == "janus-dropdown"))
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

    assert remediation_rule
           |> get_in(["event", "params", "actions"])
           |> Enum.any?(fn action ->
             action["type"] == "navigation" and
               get_in(action, ["params", "target"]) not in [nil, "next"]
           end)

    assert Enum.all?(compiled["activities"], fn screen ->
             match?({:ok, _}, Model.parse(screen["model"]))
           end)
  end

  test "fails closed for structurally invalid V3 Advanced pathways and duplicate screens" do
    content = meaningful_v3_advanced_content(v3_content())

    missing_target =
      content
      |> update_in(
        ["advanced_blueprint", "screens", Access.at(0)],
        &Map.delete(&1, "remediation_section_id")
      )
      |> put_in(["advanced_blueprint", "remediation_paths"], [])

    assert {:error, {:missing_advanced_remediation_target, 1}} =
             AuthoringCompiler.compile(
               "advanced",
               "Broken pathway",
               missing_target,
               v3_questions(),
               "missing-remediation-target",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               }
             )

    invalid_path =
      put_in(
        content,
        ["advanced_blueprint", "remediation_paths", Access.at(0), "to_section_id"],
        "missing-section"
      )

    assert {:error, {:invalid_advanced_remediation_path, 1, :missing_section}} =
             AuthoringCompiler.compile(
               "advanced",
               "Broken pathway",
               invalid_path,
               v3_questions(),
               "invalid-remediation-target",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               }
             )

    duplicate_screen =
      update_in(content, ["advanced_blueprint", "screens"], fn [screen] ->
        [screen, Map.put(screen, "title", "Duplicate")]
      end)

    assert {:error, {:duplicate_advanced_screen_id, "choose-model"}} =
             AuthoringCompiler.compile(
               "advanced",
               "Duplicate pathway",
               duplicate_screen,
               v3_questions(),
               "duplicate-blueprint-screen",
               media_urls: %{
                 "search-growth" => %{
                   "url" => "staged://search-growth",
                   "alt" => "A graph comparing linear and logarithmic search growth"
                 }
               }
             )
  end

  test "fails closed when planned media is not accessible" do
    assert {:error, {:missing_media_alt, "search-growth"}} =
             AuthoringCompiler.compile(
               "basic",
               "Lesson",
               Map.put(content(), "media", [%{"id" => "search-growth"}]),
               questions(),
               "missing-media-alt",
               media_urls: %{"search-growth" => "staged://search-growth"}
             )
  end

  test "fails closed for unsupported question shapes" do
    assert {:error, :invalid_question_count} =
             AuthoringCompiler.compile("basic", "Lesson", content(), %{"items" => []}, "lesson")

    assert {:error, :invalid_question_payload} =
             AuthoringCompiler.compile(
               "advanced",
               "Lesson",
               content(),
               %{
                 "items" => [
                   %{"prompt" => "One", "type" => "short_answer"},
                   %{"prompt" => "Two", "type" => "drag_drop"}
                 ]
               },
               "lesson"
             )
  end

  defp content do
    %{
      "objective" => "Apply the source concept",
      "learning_objectives" => ["Apply the source concept"],
      "narrative" => "A source-grounded narrative.",
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-topic"
      ]
    }
  end

  defp questions do
    %{
      "items" => [
        %{"prompt" => "Explain the concept.", "type" => "short_answer"},
        %{"prompt" => "Apply the concept.", "type" => "short_answer"}
      ]
    }
  end

  defp advanced_content do
    %{
      "objective" => "Apply models of computation to algorithmic limits",
      "learning_objectives" => [
        "Compare models of computation",
        "Explain how algorithm growth constrains problem solving"
      ],
      "narrative" =>
        "Computer science uses models to describe which operations a machine can perform and how an algorithm consumes resources.",
      "instructional_sections" => [
        %{
          "title" => "Models of computation",
          "explanation" =>
            "A model of computation makes processing assumptions explicit so two algorithms can be compared using the same operations."
        },
        %{
          "title" => "Algorithm limits",
          "explanation" =>
            "As input size grows, time and memory requirements may grow fast enough to make an otherwise valid algorithm impractical."
        }
      ],
      "callouts" => [
        %{
          "type" => "global_issue",
          "title" => "Computing and public decisions",
          "body" =>
            "Algorithm choices can change who receives information and how those choices are explained."
        }
      ],
      "worked_examples" => [
        %{
          "title" => "Worked example: search growth",
          "scenario" =>
            "Compare a linear search with a search that repeatedly halves the search space.",
          "steps" => [
            "Count the candidates inspected by linear search.",
            "Count how often the second search can halve the candidates."
          ],
          "solution" =>
            "The halving strategy grows much more slowly when the input becomes large."
        }
      ],
      "key_takeaways" => [
        "A computation model defines the operations available to an algorithm.",
        "Growth rates help distinguish feasible and infeasible approaches."
      ],
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-topic"
      ]
    }
  end

  defp advanced_questions do
    %{
      "items" => [
        %{
          "prompt" => "How does algorithm growth affect practical problem solving?",
          "type" => "short_answer",
          "answer_keywords" => ["algorithm", "complexity"],
          "correct_feedback" => "You connected growth to practical limits.",
          "incorrect_feedback" => "Name both the algorithm and its complexity.",
          "remediation" => "Review how algorithm growth changes as inputs increase."
        },
        %{
          "prompt" => "Why must algorithms be compared within a model of computation?",
          "type" => "short_answer",
          "answer_keywords" => ["model"],
          "remediation" => "Connect the model assumptions to the problem."
        }
      ]
    }
  end

  defp v3_content do
    %{
      "objective" => "Compare algorithm growth",
      "learning_objectives" => [
        "Explain why a computation model matters",
        "Compare linear and logarithmic growth"
      ],
      "opening_hook" => "Why does a faster algorithm matter when both answers are correct?",
      "why_this_matters" =>
        "Growth determines whether a correct algorithm remains useful as its input grows.",
      "callouts" => [
        %{
          "type" => "global_issue",
          "title" => "Computing and public decisions",
          "body" =>
            "Algorithm choices can change who receives information and how those choices are explained."
        }
      ],
      "instructional_sections" => [
        %{
          "id" => "models",
          "title" => "Computation models",
          "explanation" =>
            "A computation model defines which operations an algorithm may use and how their cost is measured.",
          "callouts" => [
            %{
              "title" => "Keep the comparison fair",
              "body" => "Compare algorithms under the same model and cost assumptions."
            }
          ],
          "curiosity_prompts" => [
            "What changes when one operation becomes much more expensive than another?"
          ]
        },
        %{
          "id" => "growth",
          "title" => "Growth and feasibility",
          "explanation" =>
            "Linear search inspects candidates one at a time, while binary search repeatedly removes half of the remaining candidates.",
          "media" => [
            %{
              "id" => "search-growth",
              "title" => "Search growth",
              "caption" => "Growth comparison for two search strategies",
              "credit" => "OpenStax source figure"
            }
          ]
        }
      ],
      "worked_examples" => [
        %{
          "title" => "Trace binary search",
          "scenario" => "Find a value in a sorted list of sixteen values.",
          "steps" => [
            "Compare the target with the middle value.",
            "Keep only the half that can contain the target.",
            "Repeat until the target is found."
          ],
          "solution" => "At most four halvings are needed."
        }
      ],
      "curiosity_prompts" => [
        "How large must an input become before the growth difference is visible?"
      ],
      "application_problems" => [
        %{
          "title" => "Choose a search strategy",
          "prompt" =>
            "Explain which strategy you would use for a large sorted collection and why."
        }
      ],
      "key_takeaways" => [
        "Models make algorithm comparisons meaningful.",
        "Growth rates connect theoretical algorithms to practical limits."
      ],
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-topic"
      ]
    }
  end

  defp v3_questions do
    %{
      "items" => [
        %{
          "type" => "multiple_choice",
          "prompt" => "Which search repeatedly removes half of the candidates?",
          "choices" => [
            %{"id" => "linear", "text" => "Linear search"},
            %{"id" => "binary", "text" => "Binary search"},
            %{"id" => "random", "text" => "Random search"}
          ],
          "correct_choice_id" => "binary",
          "correct_feedback" => "Correct. Binary search halves the remaining candidates.",
          "incorrect_feedback" => "Review the growth and feasibility explanation.",
          "placement_after_section_id" => "growth",
          "objective_ids" => ["compare-growth"],
          "evidence_block_ids" => ["growth-explanation"]
        },
        %{
          "type" => "short_answer",
          "prompt" => "Why must algorithms be compared under the same model?",
          "answer_keywords" => ["model"],
          "placement_after_section_id" => "models",
          "objective_ids" => ["compare-models"],
          "evidence_block_ids" => ["models-explanation"]
        }
      ]
    }
  end

  defp meaningful_v3_advanced_content(content) do
    content
    |> Map.put("schema_version", 3)
    |> Map.put("advanced_blueprint", %{
      "screens" => [
        %{
          "id" => "choose-model",
          "kind" => "decision",
          "title" => "Choose a comparison model",
          "prompt" => "Which comparison keeps the algorithm assumptions consistent?",
          "interaction_type" => "dropdown",
          "choices" => [
            %{
              "id" => "mixed",
              "text" => "Use different cost assumptions",
              "correct" => false,
              "feedback" => "Different assumptions make the comparison inconsistent."
            },
            %{
              "id" => "shared",
              "text" => "Use the same computation model",
              "correct" => true,
              "feedback" => "A shared model makes the comparison meaningful."
            }
          ],
          "correct_choice_id" => "shared",
          "placement_after_section_id" => "models",
          "remediation_section_id" => "models"
        }
      ],
      "remediation_paths" => [
        %{"from_question_id" => "choose-model", "to_section_id" => "models"}
      ]
    })
  end

  defp content_screen_navigates_next?(screen) do
    case screen["model"]["authoring"]["rules"] do
      [%{"name" => "correct"} = rule] ->
        rule
        |> get_in(["event", "params", "actions"])
        |> Enum.any?(fn action ->
          action["type"] == "navigation" and get_in(action, ["params", "target"]) == "next"
        end)

      _ ->
        false
    end
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

  defp collect_text(_), do: ""

  defp collect_elements(value, type) when is_map(value) do
    current = if value["type"] == type, do: [value], else: []
    current ++ Enum.flat_map(Map.values(value), &collect_elements(&1, type))
  end

  defp collect_elements(value, type) when is_list(value),
    do: Enum.flat_map(value, &collect_elements(&1, type))

  defp collect_elements(_, _), do: []
end
