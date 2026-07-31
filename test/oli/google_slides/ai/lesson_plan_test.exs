defmodule Oli.GoogleSlides.AI.LessonPlanTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.{Draft, LessonPlan}

  test "enforces bounded screen, part, and interaction collections" do
    plan = valid_plan()
    [screen] = get_in(plan, ["lesson", "screens"])

    too_many_screens =
      put_in(
        plan,
        ["lesson", "screens"],
        for index <- 1..151 do
          Map.put(screen, "key", "screen_#{index}")
        end
      )

    assert_error(too_many_screens, "lesson.screens", "limit_exceeded", :draft)

    part = %{
      "key" => "part",
      "kind" => "text",
      "content" => %{"text" => "A bounded content part"},
      "sourceRefs" => [source_ref()],
      "accessibility" => %{},
      "layout" => %{}
    }

    too_many_parts =
      put_in(
        plan,
        ["lesson", "screens", Access.at(0), "parts"],
        for index <- 1..41 do
          Map.put(part, "key", "part_#{index}")
        end
      )

    assert_error(
      too_many_parts,
      "lesson.screens[0].parts",
      "limit_exceeded",
      :draft
    )

    [interaction] = screen["interactions"]

    too_many_interactions =
      put_in(
        plan,
        ["lesson", "screens", Access.at(0), "interactions"],
        for index <- 1..9 do
          Map.put(interaction, "key", "interaction_#{index}")
        end
      )

    assert_error(
      too_many_interactions,
      "lesson.screens[0].interactions",
      "limit_exceeded",
      :draft
    )
  end

  test "enforces aggregate and top-level semantic plan limits" do
    plan = valid_plan()
    [screen] = get_in(plan, ["lesson", "screens"])
    [interaction] = screen["interactions"]

    part = %{
      "key" => "part",
      "kind" => "text",
      "content" => %{"text" => "A bounded content part"},
      "sourceRefs" => [source_ref()],
      "accessibility" => %{},
      "layout" => %{}
    }

    too_many_total_parts =
      put_in(
        plan,
        ["lesson", "screens"],
        for screen_index <- 1..16 do
          screen
          |> Map.put("key", "screen_#{screen_index}")
          |> Map.put(
            "parts",
            for part_index <- 1..40 do
              Map.put(part, "key", "part_#{part_index}")
            end
          )
        end
      )

    assert_error(
      too_many_total_parts,
      "lesson.screens.parts",
      "limit_exceeded",
      :draft
    )

    too_many_total_interactions =
      put_in(
        plan,
        ["lesson", "screens"],
        for screen_index <- 1..19 do
          screen
          |> Map.put("key", "screen_#{screen_index}")
          |> Map.put(
            "interactions",
            for interaction_index <- 1..8 do
              Map.put(interaction, "key", "interaction_#{interaction_index}")
            end
          )
        end
      )

    assert_error(
      too_many_total_interactions,
      "lesson.screens.interactions",
      "limit_exceeded",
      :draft
    )

    too_many_variables =
      Map.put(
        plan,
        "variables",
        for index <- 1..101 do
          %{
            "key" => "variable_#{index}",
            "type" => "boolean",
            "initialValue" => false,
            "purpose" => "Bounded variable",
            "sourceRefs" => [source_ref()]
          }
        end
      )

    assert_error(too_many_variables, "variables", "limit_exceeded", :draft)

    too_many_objectives =
      put_in(
        plan,
        ["objectives", "mapped"],
        for index <- 1..201 do
          %{
            "objectiveId" => index,
            "title" => "Objective #{index}",
            "screenKeys" => ["transport"],
            "sourceRefs" => [source_ref()]
          }
        end
      )

    assert_error(
      too_many_objectives,
      "objectives.mapped",
      "limit_exceeded",
      :draft
    )

    oversized_plan =
      put_in(
        plan,
        ["lesson", "title"],
        String.duplicate("x", 1_500_001)
      )

    assert_error(oversized_plan, "$", "limit_exceeded", :draft)
  end

  test "rejects incomplete reviewed component configurations" do
    plan = valid_plan()

    invalid_components = [
      {
        "dropdown",
        %{"choices" => ["Only one option"]},
        0,
        "lesson.screens[0].interactions[0].configuration.optionLabels"
      },
      {
        "slider",
        %{"min" => 10, "max" => 5, "step" => 0},
        11,
        "lesson.screens[0].interactions[0].configuration.max"
      },
      {
        "text_input",
        %{},
        %{"minimumLength" => 2},
        "lesson.screens[0].interactions[0].correctResponse.mustContain"
      },
      {
        "iframe",
        %{"src" => "http://example.edu/embed"},
        nil,
        "lesson.screens[0].interactions[0].configuration.src"
      }
    ]

    for {component, configuration, response, expected_path} <- invalid_components do
      invalid =
        plan
        |> put_in(
          ["lesson", "screens", Access.at(0), "interactions", Access.at(0), "componentKey"],
          component
        )
        |> put_in(
          ["lesson", "screens", Access.at(0), "interactions", Access.at(0), "configuration"],
          configuration
        )
        |> put_in(
          ["lesson", "screens", Access.at(0), "interactions", Access.at(0), "correctResponse"],
          response
        )

      assert_error(invalid, expected_path)
    end
  end

  test "rejects dangling objective, navigation, and variable references" do
    plan =
      valid_plan()
      |> put_in(
        ["objectives", "mapped"],
        [
          %{
            "objectiveId" => 42,
            "title" => "Explain transport",
            "screenKeys" => ["missing_screen"],
            "sourceRefs" => [source_ref()]
          }
        ]
      )
      |> put_in(
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [
          %{
            "key" => "go_missing",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "correct"
            },
            "action" => %{"type" => "navigate", "target" => "missing_screen"},
            "sourceRefs" => [source_ref()]
          },
          %{
            "key" => "increment_missing",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "incorrect"
            },
            "action" => %{
              "type" => "increment_variable",
              "variableKey" => "missing_variable",
              "value" => 1
            },
            "sourceRefs" => [source_ref()]
          }
        ]
      )

    assert {:error, errors} = LessonPlan.finalize(plan)

    assert has_error?(
             errors,
             "objectives.mapped[0].screenKeys[0]",
             "unknown_reference"
           )

    assert has_error?(
             errors,
             "lesson.screens[0].adaptivity[0].action.target",
             "unknown_reference"
           )

    assert has_error?(
             errors,
             "lesson.screens[0].adaptivity[1].action.variableKey",
             "unknown_reference"
           )
  end

  test "rejects fields outside the reviewed adaptivity DSL" do
    plan =
      put_in(
        valid_plan(),
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [
          %{
            "key" => "invented_rule",
            "condition" => %{
              "interactionKey" => "transport_check",
              "outcome" => "incorrect",
              "option" => 0,
              "expression" => "window.authorApproved"
            },
            "action" => %{
              "type" => "feedback",
              "message" => "Review the process.",
              "javascript" => "alert('surprise')"
            },
            "sourceRefs" => [source_ref()]
          }
        ]
      )

    assert {:error, errors} = LessonPlan.finalize(plan)

    assert has_error?(
             errors,
             "lesson.screens[0].adaptivity[0].condition.expression",
             "unsupported"
           )

    assert has_error?(
             errors,
             "lesson.screens[0].adaptivity[0].action.javascript",
             "unsupported"
           )
  end

  test "rejects multiple automatically evaluated interactions on one screen" do
    plan = valid_plan()
    [interaction] = get_in(plan, ["lesson", "screens", Access.at(0), "interactions"])

    plan =
      put_in(
        plan,
        ["lesson", "screens", Access.at(0), "interactions"],
        [interaction, Map.put(interaction, "key", "second_check")]
      )

    assert_error(
      plan,
      "lesson.screens[0].interactions",
      "unsupported"
    )
  end

  test "v1 rejects scored interactions because generated lessons are formative" do
    scored_plan =
      valid_plan()
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "scoring"
        ],
        %{"mode" => "scored", "points" => 5}
      )

    assert_error(
      scored_plan,
      "lesson.screens[0].interactions[0].scoring.mode",
      "invalid_value"
    )
  end

  test "rejects malformed non-media content before deterministic generation" do
    invalid_parts = [
      {%{
         "key" => "bad_text",
         "kind" => "text",
         "content" => %{"text" => %{"invented" => true}},
         "sourceRefs" => [source_ref()],
         "accessibility" => %{},
         "layout" => %{}
       }, "lesson.screens[0].parts[0].content.text"},
      {%{
         "key" => "bad_list",
         "kind" => "list",
         "content" => %{"items" => "not-a-list"},
         "sourceRefs" => [source_ref()],
         "accessibility" => %{},
         "layout" => %{}
       }, "lesson.screens[0].parts[0].content.items"},
      {%{
         "key" => "bad_table",
         "kind" => "table",
         "content" => %{"rows" => [[%{"unsafe" => "cell"}]]},
         "sourceRefs" => [source_ref()],
         "accessibility" => %{},
         "layout" => %{}
       }, "lesson.screens[0].parts[0].content.rows"},
      {%{
         "key" => "bad_chart",
         "kind" => "chart",
         "content" => %{"src" => "https://invented.example/chart.png"},
         "sourceRefs" => [source_ref()],
         "accessibility" => %{"altText" => "Chart"},
         "layout" => %{}
       }, "lesson.screens[0].parts[0].content.src"}
    ]

    for {part, expected_path} <- invalid_parts do
      invalid =
        put_in(
          valid_plan(),
          ["lesson", "screens", Access.at(0), "parts"],
          [part]
        )

      assert_error(invalid, expected_path)
    end
  end

  defp valid_plan do
    {:ok, plan} =
      Draft.create_lesson(%{
        "title" => "Cell transport",
        "presentationId" => "presentation-1",
        "fingerprint" => String.duplicate("a", 64)
      })

    {:ok, plan} =
      Draft.add_screen(plan, %{
        "key" => "transport",
        "title" => "Check your understanding",
        "sourceRefs" => [source_ref()]
      })

    {:ok, plan} =
      Draft.add_interaction(plan, "transport", %{
        "key" => "transport_check",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [source_ref()],
        "prompt" => "Which process moves water?",
        "configuration" => %{"choices" => ["Diffusion", "Osmosis"]},
        "correctResponse" => 1,
        "correctResponseEvidence" => [source_ref()],
        "scoring" => %{"mode" => "formative", "points" => 0}
      })

    {:ok, plan} =
      Draft.set_feedback(plan, "transport", "transport_check", %{
        "static" => %{
          "correct" => "Correct.",
          "incorrect" => "Review how water crosses a membrane."
        }
      })

    {:ok, plan} = Draft.finalize_lesson_plan(plan)
    plan
  end

  defp source_ref do
    %{
      "slideId" => "slide-1",
      "slideIndex" => 1,
      "evidence" => "Choose the best answer"
    }
  end

  defp assert_error(plan, path, code \\ nil, mode \\ :final) do
    result =
      case mode do
        :draft -> LessonPlan.validate(plan, mode: :draft)
        :final -> LessonPlan.finalize(plan)
      end

    assert {:error, errors} = result
    assert Enum.any?(errors, &(&1["path"] == path and (is_nil(code) or &1["code"] == code)))
  end

  defp has_error?(errors, path, code) do
    Enum.any?(errors, &(&1["path"] == path and &1["code"] == code))
  end
end
