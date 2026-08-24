defmodule Oli.OpenStax.CourseImport.QuestionAgentPolicy do
  @moduledoc false

  @behaviour Oli.GenAI.Agent.Policy

  @validate_and_submit_tool "validate_and_submit_openstax_questions"
  @max_candidates 2

  @impl true
  def allowed_action?(%{next_action: "tool", tool_name: @validate_and_submit_tool}, state) do
    if tool_count(state, @validate_and_submit_tool) < @max_candidates,
      do: true,
      else: {false, "The two-candidate validation budget is exhausted."}
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

  defp accepted?(state) do
    Enum.any?(state.steps, fn step ->
      step.action[:type] == "tool" and step.action[:name] == @validate_and_submit_tool and
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
