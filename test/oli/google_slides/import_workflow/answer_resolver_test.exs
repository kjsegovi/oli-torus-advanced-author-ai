defmodule Oli.GoogleSlides.ImportWorkflow.AnswerResolverTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.ImportWorkflow.AnswerResolver

  test "only the trusted answer resolver confirms a proposed objective" do
    {:ok, plan} = base_plan()

    {:ok, blocked} =
      Draft.propose_objective(plan, %{
        "key" => "explain_transport",
        "title" => "Explain membrane transport",
        "screenKeys" => ["screen_one"],
        "sourceRefs" => [source_ref()],
        "confirmed" => true
      })

    objective = get_in(blocked, ["objectives", "proposed", Access.at(0)])
    refute objective["confirmed"]
    assert objective["confirmationSource"] == nil

    blocker_key = "objective_confirmation:objective:explain_transport"
    assert {:ok, resolved} = AnswerResolver.apply(blocked, %{blocker_key => "yes"})

    objective = get_in(resolved, ["objectives", "proposed", Access.at(0)])
    assert objective["confirmed"]
    assert objective["confirmationSource"] == "author_answer"
    refute Enum.any?(resolved["blockers"], &(&1["key"] == blocker_key))
  end

  test "model-authored runtime AI opt-in is ignored until the author answers" do
    {:ok, plan} = base_plan()

    {:ok, plan} =
      Draft.add_interaction(plan, "screen_one", %{
        "key" => "check_one",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [source_ref()],
        "prompt" => "Choose one",
        "configuration" => %{"choices" => ["A", "B"]},
        "correctResponse" => 0
      })

    {:ok, blocked} =
      Draft.set_feedback(plan, "screen_one", "check_one", %{
        "static" => %{"correct" => "Correct", "incorrect" => "Try again"},
        "runtimeAi" => %{
          "enabled" => true,
          "authorOptIn" => true,
          "staticFallbackKey" => "incorrect",
          "prompt" => "Give one hint."
        }
      })

    runtime_ai =
      get_in(
        blocked,
        ["lesson", "screens", Access.at(0), "interactions", Access.at(0), "feedback", "runtimeAi"]
      )

    refute runtime_ai["authorOptIn"]

    blocker_key = "runtime_ai_opt_in:screen:screen_one:interaction:check_one"
    assert {:ok, resolved} = AnswerResolver.apply(blocked, %{blocker_key => "yes"})

    runtime_ai =
      get_in(
        resolved,
        ["lesson", "screens", Access.at(0), "interactions", Access.at(0), "feedback", "runtimeAi"]
      )

    assert runtime_ai["authorOptIn"]
    assert runtime_ai["optInSource"] == "author_answer"
  end

  test "author correct responses are marked as trusted answers" do
    {:ok, plan} = base_plan()

    {:ok, blocked} =
      Draft.add_interaction(plan, "screen_one", %{
        "key" => "check_one",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [source_ref()],
        "prompt" => "Choose one",
        "configuration" => %{"choices" => ["A", "B"]}
      })

    blocker_key = "missing_correct_response:screen:screen_one:interaction:check_one"
    assert {:ok, resolved} = AnswerResolver.apply(blocked, %{blocker_key => "B"})

    interaction =
      get_in(resolved, [
        "lesson",
        "screens",
        Access.at(0),
        "interactions",
        Access.at(0)
      ])

    assert interaction["correctResponse"] == "B"
    assert interaction["correctResponseSource"] == "author_answer"
    assert interaction["correctResponseEvidence"] == []
    refute Enum.any?(resolved["blockers"], &(&1["key"] == blocker_key))
  end

  test "invalid caption answers return actionable validation feedback" do
    {:ok, plan} = base_plan()

    {:ok, blocked} =
      Draft.add_media_part(plan, "screen_one", %{
        "key" => "demo_video",
        "kind" => "video",
        "sourceObjectId" => "video-1",
        "sourceRefs" => [source_ref()]
      })

    blocker_key = "missing_captions:screen:screen_one:part:demo_video"

    assert {:error, {:invalid_answer, ^blocker_key, message}} =
             AnswerResolver.apply(blocked, %{blocker_key => "WEBVTT pasted inline"})

    assert message =~ "absolute HTTPS URL"
  end

  defp base_plan do
    with {:ok, plan} <-
           Draft.create_lesson(%{
             "title" => "Transport",
             "presentationId" => "presentation-1",
             "fingerprint" => String.duplicate("a", 64)
           }),
         {:ok, plan} <-
           Draft.add_screen(plan, %{
             "key" => "screen_one",
             "title" => "Transport",
             "sourceRefs" => [source_ref()]
           }) do
      {:ok, plan}
    end
  end

  defp source_ref do
    %{"slideId" => "slide-1", "slideIndex" => 1, "evidence" => "Choose one"}
  end
end
