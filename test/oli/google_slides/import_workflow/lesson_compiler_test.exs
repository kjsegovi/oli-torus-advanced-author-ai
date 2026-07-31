defmodule Oli.GoogleSlides.ImportWorkflow.LessonCompilerTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.ImportWorkflow.LessonCompiler

  test "compiles the same semantic plan into stable Advanced Author content" do
    plan = lesson_plan()

    assert {:ok, first} = LessonCompiler.compile(plan)
    assert {:ok, second} = LessonCompiler.compile(plan)
    assert first == second

    assert first.title == "Cell transport"
    refute first.runtime_ai_enabled
    assert [%{content: activity}] = first.activities
    assert activity["authoring"]["rules"] != []

    types = Enum.map(activity["partsLayout"], & &1["type"])
    assert "janus-text-flow" in types
    assert "janus-mcq" in types

    assert get_in(first.page_content, ["custom", "responsiveLayout"])

    assert get_in(first.page_content, ["custom", "variables"]) == [
             %{"name" => "reviewed_transport", "expression" => "false"}
           ]

    assert get_in(activity, ["custom", "customCssClass"]) =~ "aa-import-lesson"
    assert [%{"layout" => "deck", "children" => []}] = first.page_content["model"]
  end

  test "runtime AI feedback remains gated by the project trigger setting" do
    plan =
      lesson_plan(%{
        "recommended" => true,
        "enabled" => true,
        "authorOptIn" => true,
        "staticFallbackKey" => "fallback",
        "prompt" => "Ask one guiding question without revealing the answer."
      })

    assert {:error, [error]} = LessonCompiler.compile(plan, %{}, allow_triggers: false)
    assert error["code"] == "triggers_disabled"

    assert {:ok, compiled} = LessonCompiler.compile(plan, %{}, allow_triggers: true)
    assert compiled.runtime_ai_enabled
    [%{content: activity}] = compiled.activities

    assert activity["authoring"]["rules"]
           |> Enum.flat_map(&get_in(&1, ["event", "params", "actions"]))
           |> Enum.any?(fn action ->
             action["type"] == "activationPoint" and
               get_in(action, ["params", "kind"]) == "feedback"
           end)
  end

  test "named navigation replaces the default next action" do
    plan =
      lesson_plan()
      |> put_in(
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [
          %{
            "key" => "continue_to_follow_up",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "correct"
            },
            "action" => %{"type" => "navigate", "target" => "follow_up"},
            "sourceRefs" => [source_ref()]
          }
        ]
      )
      |> update_in(["lesson", "screens"], fn screens ->
        screens ++
          [
            %{
              "key" => "follow_up",
              "title" => "Apply the idea",
              "sourceRefs" => [source_ref()],
              "parts" => [],
              "interactions" => [],
              "adaptivity" => []
            }
          ]
      end)

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}, _follow_up] = compiled.activities
    correct_rule = Enum.find(activity["authoring"]["rules"], &(&1["name"] == "correct"))

    navigation_actions =
      correct_rule
      |> get_in(["event", "params", "actions"])
      |> Enum.filter(&(&1["type"] == "navigation"))

    assert [%{"params" => %{"target" => target}}] = navigation_actions
    assert String.starts_with?(target, "aa_seq_")
    refute target == "next"
  end

  test "compiles reviewed variable mutations with typed constant expressions" do
    plan =
      lesson_plan()
      |> update_in(["variables"], fn variables ->
        variables ++
          [
            %{
              "key" => "incorrect_attempts",
              "type" => "integer",
              "initialValue" => 0,
              "purpose" => "Count the explicit retry path",
              "sourceRefs" => [source_ref()]
            }
          ]
      end)
      |> put_in(
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [
          %{
            "key" => "mark_reviewed",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "correct"
            },
            "action" => %{
              "type" => "set_variable",
              "variableKey" => "reviewed_transport",
              "value" => true
            },
            "sourceRefs" => [source_ref()]
          },
          %{
            "key" => "count_retry",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "incorrect"
            },
            "action" => %{
              "type" => "increment_variable",
              "variableKey" => "incorrect_attempts",
              "value" => 1
            },
            "sourceRefs" => [source_ref()]
          }
        ]
      )

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}] = compiled.activities

    correct_rule = Enum.find(activity["authoring"]["rules"], &(&1["name"] == "correct"))

    assert Enum.any?(actions(correct_rule), fn action ->
             action == %{
               "type" => "mutateState",
               "params" => %{
                 "value" => "true",
                 "target" => "variables.reviewed_transport",
                 "operator" => "setting to",
                 "targetType" => 4
               }
             }
           end)

    incorrect_rule =
      Enum.find(activity["authoring"]["rules"], &(&1["name"] == "default-incorrect"))

    assert Enum.any?(actions(incorrect_rule), fn action ->
             action == %{
               "type" => "mutateState",
               "params" => %{
                 "value" => "1",
                 "target" => "variables.incorrect_attempts",
                 "operator" => "adding",
                 "targetType" => 1
               }
             }
           end)
  end

  test "compiles option-specific feedback into a common-error rule" do
    plan =
      put_in(
        lesson_plan(),
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [
          %{
            "key" => "diffusion_misconception",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "incorrect",
              "option" => 0
            },
            "action" => %{
              "type" => "feedback",
              "message" => "Diffusion is broader than the water-specific process."
            },
            "sourceRefs" => [source_ref()]
          }
        ]
      )

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}] = compiled.activities

    common_error_rule =
      Enum.find(
        activity["authoring"]["rules"],
        &String.starts_with?(&1["name"], "common-error-")
      )

    assert common_error_rule

    assert Jason.encode!(common_error_rule) =~
             "Diffusion is broader than the water-specific process."
  end

  test "compiles an iframe-only screen without scoring rules" do
    plan =
      lesson_plan()
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "componentKey"
        ],
        "iframe"
      )
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "configuration"
        ],
        %{"src" => "https://example.edu/embedded-simulation"}
      )
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "correctResponse"
        ],
        nil
      )

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}] = compiled.activities

    assert Enum.any?(activity["partsLayout"], &(&1["type"] == "janus-capi-iframe"))
    assert activity["authoring"]["rules"] == []
  end

  test "canonicalizes dropdown choices before compiling the Advanced Author part" do
    plan =
      lesson_plan()
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "componentKey"
        ],
        "dropdown"
      )
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "configuration"
        ],
        %{"choices" => ["Diffusion", "Osmosis"]}
      )
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "correctResponse"
        ],
        "Osmosis"
      )

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}] = compiled.activities
    dropdown = Enum.find(activity["partsLayout"], &(&1["type"] == "janus-dropdown"))

    assert dropdown["custom"]["optionLabels"] == ["Diffusion", "Osmosis"]
    assert dropdown["custom"]["correctAnswer"] == 1
  end

  test "requires reviewed alt text for every rasterized source graphic" do
    for kind <- ["chart", "shape", "line"] do
      object_id = "#{kind}-1"

      graphic = %{
        "key" => "#{kind}_graphic",
        "kind" => kind,
        "content" => %{"sourceObjectId" => object_id},
        "sourceRefs" => [source_ref()],
        "accessibility" => %{},
        "layout" => %{}
      }

      missing_alt_plan =
        update_in(
          lesson_plan(),
          ["lesson", "screens", Access.at(0), "parts"],
          &(&1 ++ [graphic])
        )

      assert {:error, errors} =
               LessonCompiler.compile(missing_alt_plan, %{
                 object_id => "https://media.example.edu/#{object_id}.png"
               })

      assert Enum.any?(
               errors,
               &(&1["path"] ==
                   "lesson.screens[0].parts[1].accessibility.altText")
             )

      reviewed_plan =
        put_in(
          missing_alt_plan,
          [
            "lesson",
            "screens",
            Access.at(0),
            "parts",
            Access.at(1),
            "accessibility",
            "altText"
          ],
          "Reviewed #{kind} description"
        )

      assert {:ok, compiled} =
               LessonCompiler.compile(reviewed_plan, %{
                 object_id => "https://media.example.edu/#{object_id}.png"
               })

      [%{content: activity}] = compiled.activities
      image = Enum.find(activity["partsLayout"], &(&1["type"] == "janus-image"))
      assert get_in(image, ["custom", "alt"]) == "Reviewed #{kind} description"
    end
  end

  test "compiles word art as semantic text instead of promising a raster fallback" do
    word_art = %{
      "key" => "key_idea",
      "kind" => "word_art",
      "content" => %{"sourceObjectId" => "word-art-1", "text" => "Key idea"},
      "sourceRefs" => [source_ref()],
      "accessibility" => %{},
      "layout" => %{}
    }

    plan =
      update_in(
        lesson_plan(),
        ["lesson", "screens", Access.at(0), "parts"],
        &(&1 ++ [word_art])
      )

    assert {:ok, compiled} = LessonCompiler.compile(plan)
    [%{content: activity}] = compiled.activities

    refute Enum.any?(activity["partsLayout"], fn part ->
             part["type"] == "janus-image" and Jason.encode!(part) =~ "word-art-1"
           end)

    assert Jason.encode!(activity["partsLayout"]) =~ "Key idea"

    source_only =
      put_in(
        plan,
        ["lesson", "screens", Access.at(0), "parts", Access.at(-1), "content"],
        %{"sourceObjectId" => "word-art-1"}
      )

    assert {:error, errors} = LessonCompiler.compile(source_only)
    assert Enum.any?(errors, &(&1["path"] =~ ".content.text"))
  end

  test "fails closed when object-backed images and graphics were not staged" do
    parts = [
      %{
        "key" => "image",
        "kind" => "image",
        "content" => %{"sourceObjectId" => "image-1"},
        "sourceRefs" => [source_ref()],
        "accessibility" => %{"altText" => "Cell membrane"},
        "layout" => %{}
      },
      %{
        "key" => "chart",
        "kind" => "chart",
        "content" => %{"sourceObjectId" => "chart-1"},
        "sourceRefs" => [source_ref()],
        "accessibility" => %{"altText" => "Transport chart"},
        "layout" => %{}
      }
    ]

    for part <- parts do
      plan =
        update_in(
          lesson_plan(),
          ["lesson", "screens", Access.at(0), "parts"],
          &(&1 ++ [part])
        )

      assert {:error, errors} = LessonCompiler.compile(plan)

      assert Enum.any?(errors, fn error ->
               error["code"] == "media_not_staged" and
                 error["path"] =~ part["key"]
             end)
    end
  end

  defp lesson_plan(runtime_ai \\ %{}) do
    source_ref = source_ref()

    {:ok, plan} =
      Draft.create_lesson(%{
        "title" => "Cell transport",
        "presentationId" => "presentation-1",
        "fingerprint" => String.duplicate("a", 64),
        "url" => "https://docs.google.com/presentation/d/presentation-1/edit"
      })

    {:ok, plan} =
      Draft.add_screen(plan, %{
        "key" => "transport",
        "title" => "Check your understanding",
        "sourceRefs" => [source_ref]
      })

    {:ok, plan} =
      Draft.add_content_part(plan, "transport", %{
        "key" => "intro",
        "kind" => "text",
        "content" => %{"tag" => "p", "text" => "Water moves across a membrane."},
        "sourceRefs" => [source_ref]
      })

    {:ok, plan} =
      Draft.add_interaction(plan, "transport", %{
        "key" => "transport_check",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [source_ref],
        "prompt" => "Which process moves water?",
        "configuration" => %{"choices" => ["Diffusion", "Osmosis"]},
        "correctResponse" => 1,
        "correctResponseEvidence" => [source_ref],
        "scoring" => %{"mode" => "formative", "points" => 0}
      })

    {:ok, plan} =
      Draft.set_feedback(plan, "transport", "transport_check", %{
        "static" => %{
          "correct" => "Correct.",
          "incorrect" => "Review how water crosses a membrane.",
          "fallback" => "Review the membrane diagram and try again."
        },
        "runtimeAi" => runtime_ai
      })

    plan =
      if runtime_ai["enabled"] == true and runtime_ai["authorOptIn"] == true do
        {:ok, opted_in_plan} =
          Draft.record_runtime_ai_opt_in(plan, "transport", "transport_check", true)

        opted_in_plan
      else
        plan
      end

    {:ok, plan} =
      Draft.declare_variable(plan, %{
        "key" => "reviewed_transport",
        "type" => "boolean",
        "initialValue" => false,
        "purpose" => "Track the explicit review instruction",
        "sourceRefs" => [source_ref]
      })

    {:ok, plan} = Draft.set_layout(plan, %{"mode" => "responsive"})
    {:ok, plan} = Draft.finalize_lesson_plan(plan)
    plan
  end

  defp source_ref do
    %{"slideId" => "slide-1", "slideIndex" => 1, "evidence" => "visible prompt"}
  end

  defp actions(rule), do: get_in(rule, ["event", "params", "actions"]) || []
end
