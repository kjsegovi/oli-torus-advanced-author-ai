defmodule Oli.OpenStax.CourseImport.QuestionAgentPolicyTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Agent.Decision
  alias Oli.GenAI.Agent.Server.Step

  alias Oli.OpenStax.CourseImport.{QuestionAgentPolicy, QuestionAgentToolBroker}

  test "exposes only the atomic whole-set validation and submission tool" do
    assert QuestionAgentToolBroker.describe() |> Enum.map(& &1.name) == [
             "validate_and_submit_openstax_questions"
           ]

    refute Enum.any?(QuestionAgentToolBroker.describe(), &(&1.name == "create_activity"))
  end

  test "allows at most two bounded candidate validations" do
    validate = %Decision{
      next_action: "tool",
      tool_name: "validate_and_submit_openstax_questions",
      arguments: %{}
    }

    assert true = QuestionAgentPolicy.allowed_action?(validate, %{steps: []})

    attempts =
      Enum.map(1..2, fn num ->
        %Step{
          num: num,
          action: %{type: "tool", name: "validate_and_submit_openstax_questions", args: %{}},
          observation: %{valid: false, accepted: false}
        }
      end)

    assert {false, reason} = QuestionAgentPolicy.allowed_action?(validate, %{steps: attempts})
    assert reason =~ "two-candidate"
  end

  test "terminates successfully only after an accepted submission" do
    accepted = %Step{
      num: 2,
      action: %{type: "tool", name: "validate_and_submit_openstax_questions", args: %{}},
      observation: %{accepted: true}
    }

    assert {:done, _reason} = QuestionAgentPolicy.stop_reason?(%{steps: [accepted]})
    assert nil == QuestionAgentPolicy.stop_reason?(%{steps: []})
  end
end
