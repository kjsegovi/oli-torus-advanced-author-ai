defmodule Oli.OpenStax.CourseImport.QuestionAgentValidatorTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.QuestionAgentValidator

  test "accepts deliberate question counts of one and ten" do
    one = candidate([short_answer(1, objective_ids())])
    assert %{valid: true, questions_payload: %{"items" => [_]}} = validate(one)

    ten =
      candidate(
        Enum.map(1..10, fn index ->
          short_answer(
            index,
            objective_ids(),
            "topic#{index} setting#{index} evidence#{index} decision#{index}"
          )
        end)
      )

    assert %{valid: true, questions_payload: %{"items" => items}} = validate(ten)
    assert length(items) == 10
  end

  test "rejects counts of zero and eleven" do
    refute validate(candidate([])).valid

    eleven =
      candidate(
        Enum.map(1..11, fn index ->
          short_answer(
            index,
            objective_ids(),
            "transfer#{index} setting#{index} model#{index} outcome#{index}"
          )
        end)
      )

    result = validate(eleven)
    refute result.valid
    assert finding?(result, "invalid_question_count")
  end

  test "rejects invalid evidence and material duplication" do
    invalid_evidence =
      candidate([
        short_answer(1, objective_ids())
        |> Map.put("evidence_block_ids", ["invented-block"])
      ])

    result = validate(invalid_evidence)
    assert finding?(result, "invalid_evidence")

    duplicate =
      candidate([short_answer(1, objective_ids()), short_answer(1, objective_ids())])

    result = validate(duplicate)
    assert finding?(result, "duplicate_questions")
  end

  test "preserves stable catalog IDs and separately resolves objective text" do
    result = validate(candidate([short_answer(1, objective_ids())]))

    assert result.valid
    assert [question] = result.questions_payload["items"]
    assert question["objective_ids"] == objective_ids()
    assert question["mapped_objectives"] == objectives()

    invalid = validate(candidate([short_answer(1, ["openstax-block-models"])]))
    refute invalid.valid

    assert %{
             "allowed_objective_ids" => ["objective-1", "objective-2"]
           } = finding(invalid, "invalid_objective_mapping")
  end

  test "rejects ambiguous multiple-choice answers and generic distractor feedback" do
    ambiguous =
      multiple_choice()
      |> update_in(["choices", Access.at(1)], &Map.put(&1, "correct", true))

    result = validate(candidate([ambiguous]))
    assert finding?(result, "ambiguous_answer")

    generic =
      multiple_choice()
      |> update_in(["choices", Access.at(1)], &Map.put(&1, "feedback", "Try again"))

    result = validate(candidate([generic]))
    assert finding?(result, "untargeted_feedback")
  end

  test "v5 accepts one consolidated question without forcing every objective into the slot" do
    context =
      context()
      |> put_in(
        [:content_payload, "question_slots"],
        [%{"placement_after_section_id" => "section-models"}]
      )

    question = short_answer(1, ["objective-1"])
    result = QuestionAgentValidator.validate(candidate([question]), context)

    assert result.valid
    refute finding?(result, "unassessed_objectives")
  end

  test "v5 rejects multiple questions at one approved checkpoint" do
    context =
      context()
      |> put_in(
        [:content_payload, "question_slots"],
        [%{"placement_after_section_id" => "section-models"}]
      )

    result =
      QuestionAgentValidator.validate(
        candidate([
          short_answer(1, ["objective-1"]),
          short_answer(3, ["objective-1"], "a second transfer setting")
        ]),
        context
      )

    refute result.valid
    assert finding?(result, "invalid_question_count")
    assert finding?(result, "duplicate_question_boundary")
  end

  defp validate(candidate), do: QuestionAgentValidator.validate(candidate, context())

  defp context do
    %{
      content_payload: %{
        "schema_version" => 5,
        "authoring_mode" => "basic",
        "learning_objectives" => objectives(),
        "content_groups" => [
          %{"id" => "section-models"},
          %{"id" => "section-growth"}
        ]
      },
      lesson: %{
        "source_evidence_links" => ["https://openstax.org/books/test/pages/lesson"],
        "source_blocks" => [
          %{"id" => "block-models", "text" => "Models define comparison assumptions."},
          %{"id" => "block-growth", "text" => "Growth affects practical feasibility."}
        ]
      }
    }
  end

  defp objectives, do: ["Compare computation models", "Explain algorithm growth"]
  defp objective_ids, do: ["objective-1", "objective-2"]

  defp candidate(items) do
    %{
      "count_rationale" =>
        "This count matches the two objectives, concept density, and expected transfer value.",
      "questions_payload" => %{"items" => items}
    }
  end

  defp short_answer(index, mapped_objectives, suffix \\ "a practical transfer setting") do
    %{
      "prompt" =>
        "Explain how the lesson's comparison evidence applies in #{suffix} without changing its assumptions.",
      "type" => "short_answer",
      "response_kind" => "application",
      "answer_guidance" =>
        "A strong answer identifies the shared model and explains the growth tradeoff.",
      "answer_keywords" => ["model", "growth"],
      "placement_after_section_id" =>
        if(rem(index, 2) == 0, do: "section-growth", else: "section-models"),
      "objective_ids" => mapped_objectives,
      "evidence_block_ids" => [if(rem(index, 2) == 0, do: "block-growth", else: "block-models")]
    }
  end

  defp multiple_choice do
    %{
      "prompt" =>
        "Which comparison most fairly uses the lesson evidence to evaluate two algorithms?",
      "type" => "multiple_choice",
      "placement_after_section_id" => "section-models",
      "objective_ids" => objective_ids(),
      "evidence_block_ids" => ["block-models"],
      "choices" => [
        %{
          "text" => "Use the same computation model for both algorithms",
          "correct" => true,
          "feedback" => "Correct because shared assumptions make the costs comparable."
        },
        %{
          "text" => "Change the cost assumptions for the preferred algorithm",
          "correct" => false,
          "feedback" =>
            "Changing assumptions hides the model difference instead of comparing the algorithms."
        }
      ]
    }
  end

  defp finding?(result, code),
    do: Enum.any?(result.findings, &(&1["code"] == code))

  defp finding(result, code), do: Enum.find(result.findings, &(&1["code"] == code))
end
