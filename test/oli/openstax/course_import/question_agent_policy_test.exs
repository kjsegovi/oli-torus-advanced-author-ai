defmodule Oli.OpenStax.CourseImport.QuestionAgentPolicyTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Agent.Decision
  alias Oli.GenAI.Agent.Server.Step

  alias Oli.OpenStax.CourseImport.{
    QuestionAgentPolicy,
    QuestionAgentToolBroker,
    QuestionAgentValidator
  }

  test "exposes only whole-set review and submission tools" do
    assert QuestionAgentToolBroker.describe() |> Enum.map(& &1.name) == [
             "review_openstax_questions",
             "submit_openstax_questions"
           ]

    refute Enum.any?(QuestionAgentToolBroker.describe(), &(&1.name == "create_activity"))
  end

  test "requires a successful review of the exact candidate before submission" do
    candidate = %{
      "count_rationale" => "One focused objective needs one high-value transfer question.",
      "questions_payload" => %{"items" => []}
    }

    submit = %Decision{
      next_action: "tool",
      tool_name: "submit_openstax_questions",
      arguments: candidate
    }

    assert {false, reason} = QuestionAgentPolicy.allowed_action?(submit, %{steps: []})
    assert reason =~ "Review this exact candidate"

    reviewed = %Step{
      num: 1,
      action: %{type: "tool", name: "review_openstax_questions", args: candidate},
      observation: %{
        valid: true,
        candidate_hash: QuestionAgentValidator.candidate_hash(candidate)
      }
    }

    assert true = QuestionAgentPolicy.allowed_action?(submit, %{steps: [reviewed]})

    changed = put_in(submit.arguments["count_rationale"], "A different rationale and candidate.")
    assert {false, _reason} = QuestionAgentPolicy.allowed_action?(changed, %{steps: [reviewed]})
  end

  test "terminates successfully only after an accepted submission" do
    accepted = %Step{
      num: 2,
      action: %{type: "tool", name: "submit_openstax_questions", args: %{}},
      observation: %{accepted: true}
    }

    assert {:done, _reason} = QuestionAgentPolicy.stop_reason?(%{steps: [accepted]})
    assert nil == QuestionAgentPolicy.stop_reason?(%{steps: []})
  end
end
