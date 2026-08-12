defmodule Oli.OpenStax.CourseImport.QuestionAgentPolicy do
  @moduledoc false

  @behaviour Oli.GenAI.Agent.Policy

  alias Oli.OpenStax.CourseImport.QuestionAgentValidator

  @review_tool "review_openstax_questions"
  @submit_tool "submit_openstax_questions"
  @max_candidates 3

  @impl true
  def allowed_action?(%{next_action: "tool", tool_name: @review_tool}, state) do
    if tool_count(state, @review_tool) < @max_candidates,
      do: true,
      else: {false, "The three-candidate review budget is exhausted."}
  end

  def allowed_action?(%{next_action: "tool", tool_name: @submit_tool} = decision, state) do
    cond do
      tool_count(state, @submit_tool) >= @max_candidates ->
        {false, "The three-candidate submission budget is exhausted."}

      not successfully_reviewed?(state, decision.arguments) ->
        {false, "Review this exact candidate successfully before submitting it."}

      true ->
        true
    end
  end

  def allowed_action?(%{next_action: "tool", tool_name: tool_name}, _state) do
    {false, "Tool '#{tool_name}' is outside the OpenStax question-agent scope."}
  end

  def allowed_action?(%{next_action: "done"}, state) do
    if accepted?(state),
      do: true,
      else: {false, "A validated question set must be submitted before completion."}
  end

  def allowed_action?(%{next_action: action}, _state) when action in ["message", "replan"],
    do: true

  def allowed_action?(_decision, _state), do: {false, "Unsupported agent action."}

  @impl true
  def stop_reason?(state) do
    if accepted?(state),
      do: {:done, "Validated OpenStax question set accepted."},
      else: nil
  end

  @impl true
  def redact(payload) do
    Map.drop(payload, [
      :api_key,
      :credentials,
      :raw_source,
      :source_blocks,
      "api_key",
      "credentials",
      "raw_source",
      "source_blocks"
    ])
  end

  defp successfully_reviewed?(state, candidate) do
    candidate_hash = QuestionAgentValidator.candidate_hash(candidate)

    Enum.any?(state.steps, fn step ->
      step.action[:type] == "tool" and step.action[:name] == @review_tool and
        truthy?(step.observation[:valid] || step.observation["valid"]) and
        (step.observation[:candidate_hash] || step.observation["candidate_hash"]) ==
          candidate_hash
    end)
  end

  defp accepted?(state) do
    Enum.any?(state.steps, fn step ->
      step.action[:type] == "tool" and step.action[:name] == @submit_tool and
        truthy?(step.observation[:accepted] || step.observation["accepted"])
    end)
  end

  defp tool_count(state, tool_name) do
    Enum.count(state.steps, fn step ->
      step.action[:type] == "tool" and step.action[:name] == tool_name
    end)
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
