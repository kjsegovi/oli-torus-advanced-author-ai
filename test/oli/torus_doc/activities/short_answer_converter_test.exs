defmodule Oli.TorusDoc.Activities.ShortAnswerConverterTest do
  use ExUnit.Case, async: true

  alias Oli.TorusDoc.ActivityConverter

  test "text responses include the authoring catch-all response contract" do
    yaml = """
    type: oli_short_answer
    stem_md: "Explain how evidence can change a model."
    input_type: text
    explanation_md: "Good explanation of how the evidence changes the model."
    incorrect_feedback_md: "Revisit the evidence and explain what the model must change."
    """

    assert {:ok, json} = ActivityConverter.from_yaml(yaml)

    responses = json["authoring"]["parts"] |> hd() |> Map.fetch!("responses")

    assert Enum.any?(responses, &(&1["score"] == 1 and &1["rule"] == ".*"))

    assert Enum.any?(
             responses,
             &(&1["score"] == 0 and &1["rule"] == "input like {.*}")
           )

    correct = Enum.find(responses, &(&1["score"] == 1))
    incorrect = Enum.find(responses, &(&1["score"] == 0))

    assert Jason.encode!(correct["feedback"]) =~
             "Good explanation of how the evidence changes the model."

    assert Jason.encode!(incorrect["feedback"]) =~
             "Revisit the evidence and explain what the model must change."
  end
end
