defmodule Oli.GoogleSlides.AI.DraftTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.AI.LessonPlan

  test "assembles and finalizes one semantic lesson without Torus resource data" do
    assert {:ok, plan} =
             Draft.create_lesson(%{
               "presentationId" => "deck-123",
               "fingerprint" => "sha256:abc",
               "title" => "Habitability"
             })

    assert plan["schemaVersion"] == 1
    assert plan["lesson"]["layout"]["mode"] == "responsive"
    assert plan["lesson"]["layout"]["styleProfile"] == "torus-default"
    refute Map.has_key?(plan, "resourceId")

    assert {:ok, plan} =
             Draft.add_screen(plan, %{
               "key" => "habitable-zone",
               "title" => "The habitable zone",
               "sourceRefs" => [%{"slideId" => "slide-1"}]
             })

    assert {:ok, plan} =
             Draft.add_content_part(plan, "habitable-zone", %{
               "key" => "intro",
               "kind" => "text",
               "content" => %{"text" => "Distance from a star affects surface temperature."},
               "sourceRefs" => [%{"slideId" => "slide-1", "objectId" => "shape-1"}]
             })

    assert {:ok, plan} =
             Draft.add_interaction(plan, "habitable-zone", %{
               "key" => "planet-choice",
               "componentKey" => "mcq",
               "explicit" => true,
               "sourceEvidence" => [
                 %{"slideId" => "slide-2", "evidence" => "Select the habitable planet"}
               ],
               "prompt" => "Which planet is most likely habitable?",
               "configuration" => %{"choices" => ["A", "B", "C"]},
               "correctResponse" => 1,
               "correctResponseEvidence" => [
                 %{"slideId" => "slide-2", "evidence" => "Planet B is in the habitable zone"}
               ]
             })

    assert {:ok, plan} =
             Draft.set_feedback(plan, "habitable-zone", "planet-choice", %{
               "static" => %{
                 "correct" => "Correct. Planet B is in the habitable zone.",
                 "incorrect" => "Compare each planet's distance from its star."
               }
             })

    assert {:ok, finalized} = Draft.finalize_lesson_plan(plan)
    assert finalized["status"] == "finalized"
    assert finalized["lesson"]["screens"] |> length() == 1

    interaction =
      finalized["lesson"]["screens"]
      |> hd()
      |> Map.fetch!("interactions")
      |> hd()

    assert interaction["componentKey"] == "multiple_choice"
    assert interaction["scoring"] == %{"mode" => "formative", "points" => 0}
  end

  test "rejects interactions that are not explicit in the source" do
    plan = plan_with_screen()

    assert {:error, errors} =
             Draft.add_interaction(plan, "screen-one", %{
               "key" => "invented-practice",
               "componentKey" => "multiple_choice",
               "explicit" => false,
               "sourceEvidence" => [%{"slideId" => "slide-1"}]
             })

    assert Enum.any?(errors, &(&1["path"] == "interaction.explicit"))
    assert plan["lesson"]["screens"] |> hd() |> Map.fetch!("interactions") == []
  end

  test "records an unsupported explicit component as a blocker without adding it" do
    plan = plan_with_screen()

    assert {:ok, blocked} =
             Draft.add_interaction(plan, "screen-one", %{
               "key" => "molecule-builder",
               "componentKey" => "immersive-molecule-builder",
               "explicit" => true,
               "sourceEvidence" => [%{"slideId" => "slide-1", "objectId" => "embed-1"}]
             })

    assert blocked["lesson"]["screens"] |> hd() |> Map.fetch!("interactions") == []

    assert [
             %{
               "code" => "unsupported_component",
               "details" => %{"requestedComponent" => "immersive-molecule-builder"}
             }
           ] = blocked["blockers"]

    assert {:error, errors} = LessonPlan.finalize(blocked)
    assert Enum.any?(errors, &(&1["code"] == "unresolved_blocker"))
  end

  test "missing correct responses block finalization and can be resolved" do
    plan = plan_with_screen()

    assert {:ok, blocked} =
             Draft.add_interaction(plan, "screen-one", %{
               "key" => "choice",
               "componentKey" => "dropdown",
               "explicit" => true,
               "sourceEvidence" => [%{"slideId" => "slide-1"}],
               "prompt" => "Choose the third option.",
               "configuration" => %{"optionLabels" => ["First", "Second", "Third"]}
             })

    assert Enum.any?(blocked["blockers"], &(&1["code"] == "missing_correct_response"))

    assert {:ok, resolved} =
             Draft.set_interaction_response(blocked, "screen-one", "choice", 2, [
               %{"slideId" => "slide-1", "evidence" => "The third option is correct"}
             ])

    assert {:ok, resolved} =
             Draft.set_feedback(resolved, "screen-one", "choice", %{
               "static" => %{
                 "correct" => "Correct.",
                 "incorrect" => "Choose another option."
               }
             })

    refute Enum.any?(resolved["blockers"], &(&1["code"] == "missing_correct_response"))
    assert {:ok, _finalized} = Draft.finalize_lesson_plan(resolved)
  end

  test "does not trust a model-authored correct response without dedicated source evidence" do
    plan = plan_with_screen()

    assert {:ok, blocked} =
             Draft.add_interaction(plan, "screen-one", %{
               "key" => "choice",
               "componentKey" => "multiple_choice",
               "explicit" => true,
               "sourceEvidence" => [
                 %{"slideId" => "slide-1", "evidence" => "Choose the best answer"}
               ],
               "prompt" => "Choose the best answer.",
               "configuration" => %{"choices" => ["First", "Second"]},
               "correctResponse" => 1
             })

    interaction =
      get_in(blocked, ["lesson", "screens", Access.at(0), "interactions", Access.at(0)])

    assert interaction["correctResponse"] == nil
    assert interaction["correctResponseSource"] == nil
    assert Enum.any?(blocked["blockers"], &(&1["code"] == "missing_correct_response"))
  end

  test "runtime AI feedback remains recommendation metadata until explicitly opted in" do
    plan = plan_with_interaction()

    assert {:ok, blocked} =
             Draft.set_feedback(plan, "screen-one", "choice", %{
               "static" => %{
                 "correct" => "Correct.",
                 "incorrect" => "Review the evidence on the slide."
               },
               "runtimeAi" => %{
                 "recommended" => true,
                 "enabled" => true,
                 "authorOptIn" => false
               }
             })

    assert Enum.any?(blocked["blockers"], &(&1["code"] == "runtime_ai_opt_in"))
    assert Enum.any?(blocked["blockers"], &(&1["code"] == "runtime_ai_static_fallback"))
    assert Enum.any?(blocked["blockers"], &(&1["code"] == "runtime_ai_prompt"))

    assert {:ok, still_blocked} =
             Draft.set_feedback(blocked, "screen-one", "choice", %{
               "static" => %{
                 "correct" => "Correct.",
                 "incorrect" => "Review the evidence on the slide."
               },
               "runtimeAi" => %{
                 "recommended" => true,
                 "enabled" => true,
                 "authorOptIn" => true,
                 "staticFallbackKey" => "incorrect",
                 "prompt" => "Explain the misconception using only the lesson evidence."
               }
             })

    assert Enum.any?(still_blocked["blockers"], &(&1["code"] == "runtime_ai_opt_in"))

    assert {:ok, approved} =
             Draft.record_runtime_ai_opt_in(still_blocked, "screen-one", "choice", true)

    assert approved["blockers"] == []
    assert {:ok, _finalized} = Draft.finalize_lesson_plan(approved)
  end

  test "new objectives require confirmation" do
    plan = plan_with_screen()

    assert {:ok, blocked} =
             Draft.propose_objective(plan, %{
               "key" => "explain-habitability",
               "title" => "Explain the factors that influence planetary habitability",
               "screenKeys" => ["screen-one"],
               "sourceRefs" => [%{"slideId" => "slide-1"}]
             })

    assert [%{"code" => "objective_confirmation"}] = blocked["blockers"]

    assert {:ok, confirmed} = Draft.confirm_objective(blocked, "explain-habitability")
    assert confirmed["blockers"] == []
    assert confirmed["objectives"]["proposed"] |> hd() |> Map.fetch!("confirmed")

    assert confirmed["objectives"]["proposed"] |> hd() |> Map.fetch!("confirmationSource") ==
             "author_answer"
  end

  test "media accessibility decisions remain visible blockers and warnings" do
    plan = plan_with_screen()

    assert {:ok, image_plan} =
             Draft.add_media_part(plan, "screen-one", %{
               "key" => "planet-photo",
               "kind" => "image",
               "sourceObjectId" => "image-1",
               "sourceRefs" => [%{"slideId" => "slide-1"}]
             })

    assert [%{"code" => "missing_alt_text"}] = image_plan["blockers"]

    assert {:ok, video_plan} =
             Draft.add_media_part(plan, "screen-one", %{
               "key" => "orbit-video",
               "kind" => "video",
               "sourceObjectId" => "video-1",
               "sourceRefs" => [%{"slideId" => "slide-1"}],
               "captionTrackUrl" => "https://example.edu/captions/orbit.vtt"
             })

    assert video_plan["blockers"] == []
    assert [%{"code" => "missing_transcript"}] = video_plan["warnings"]
  end

  test "pixel layout requires source canvas dimensions" do
    plan = plan_with_screen()

    assert {:error, errors} =
             Draft.set_layout(plan, %{
               "mode" => "pixel",
               "styleProfile" => "torus-default"
             })

    assert Enum.any?(errors, &(&1["path"] == "lesson.layout.canvas"))

    assert {:ok, pixel_plan} =
             Draft.set_layout(plan, %{
               "mode" => "pixel",
               "styleProfile" => "torus-default",
               "canvas" => %{"width" => 1200, "height" => 675}
             })

    assert pixel_plan["lesson"]["layout"]["canvas"] == %{"width" => 1200, "height" => 675}
  end

  test "structured style rules are stored only after sandbox validation" do
    plan = plan_with_screen()

    assert {:ok, styled} =
             Draft.set_style_rules(plan, [
               %{
                 "target" => "prompt",
                 "declarations" => %{"padding" => "1rem", "background-color" => "#f5f5f5"}
               }
             ])

    assert [%{"target" => "prompt"}] = styled["lesson"]["layout"]["styleRules"]

    assert {:error, errors} =
             Draft.set_style_rules(plan, [
               %{
                 "target" => "prompt",
                 "declarations" => %{"background-color" => "url(https://example.com/a.png)"}
               }
             ])

    assert Enum.any?(errors, &(&1["code"] == "unsafe_value"))
  end

  defp plan_with_screen do
    {:ok, plan} =
      Draft.create_lesson(%{
        "presentationId" => "deck-123",
        "fingerprint" => "sha256:abc",
        "title" => "Test lesson"
      })

    {:ok, plan} =
      Draft.add_screen(plan, %{
        "key" => "screen-one",
        "title" => "Screen one",
        "sourceRefs" => [%{"slideId" => "slide-1"}]
      })

    plan
  end

  defp plan_with_interaction do
    {:ok, plan} =
      plan_with_screen()
      |> Draft.add_interaction("screen-one", %{
        "key" => "choice",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [%{"slideId" => "slide-1"}],
        "prompt" => "Choose an option.",
        "configuration" => %{"choices" => ["One", "Two"]},
        "correctResponse" => 0,
        "correctResponseEvidence" => [
          %{"slideId" => "slide-1", "evidence" => "One is the correct option"}
        ]
      })

    plan
  end
end
