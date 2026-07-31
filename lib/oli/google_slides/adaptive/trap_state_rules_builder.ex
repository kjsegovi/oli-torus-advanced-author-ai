defmodule Oli.GoogleSlides.Adaptive.TrapStateRulesBuilder do
  @moduledoc """
  Builds rich trap-state adaptive rules (3-try workflow) for imported screens.
  """

  alias Oli.GoogleSlides.Adaptive.PartBuilders
  alias Oli.GoogleSlides.AdaptiveRulesBuilder
  alias Oli.GoogleSlides.Util

  @default_max_attempt 3
  @default_three_times_feedback "You've reached the maximum number of attempts. The correct answer is shown."

  @scorable_types [
    "janus-mcq",
    "janus-slider",
    "janus-text-slider",
    "janus-dropdown",
    "janus-input-text",
    "janus-input-number"
  ]

  @spec build_rules(map() | nil, map() | nil, [map()], [map()]) :: [map()]
  def build_rules(adaptivity, component_part, parts_layout, component_parts \\ []) do
    scorable_parts = find_scorable_parts(component_part, parts_layout, component_parts)

    case {adaptivity, scorable_parts} do
      {_, []} ->
        AdaptiveRulesBuilder.build_rules(adaptivity, component_part, parts_layout)

      {adaptivity, [part]} ->
        max_attempt = max_attempt(adaptivity, part)

        if max_attempt > 0 do
          build_trap_workflow(adaptivity, [part], max_attempt)
        else
          AdaptiveRulesBuilder.build_rules(adaptivity, component_part, parts_layout)
        end

      {adaptivity, parts} ->
        max_attempt = max_attempt(adaptivity, hd(parts))

        if max_attempt > 0 do
          build_trap_workflow(adaptivity, parts, max_attempt)
        else
          AdaptiveRulesBuilder.build_rules(adaptivity, component_part, parts_layout)
        end
    end
  end

  defp build_trap_workflow(adaptivity, parts, max_attempt) do
    adaptivity = adaptivity || %{}
    rule_id = Util.new_rule_id()
    score = Map.get(adaptivity, "score", 0)
    correct_feedback = Map.get(adaptivity, "correctFeedback", "Correct!")
    incorrect_feedback = Map.get(adaptivity, "incorrectFeedback", "Incorrect, please try again.")
    on_correct = Map.get(adaptivity, "onCorrect", "navigate next")
    on_incorrect = Map.get(adaptivity, "onIncorrect", "show feedback")
    common_errors = Map.get(adaptivity, "commonErrors", [])

    correct_actions = correct_actions(on_correct, correct_feedback)
    incorrect_nav_actions = incorrect_nav_actions(on_incorrect, incorrect_feedback)

    rules = [
      correct_rule(rule_id, parts, correct_actions, score),
      blank_rule(rule_id, parts, adaptivity),
      max_attempt_incorrect_rule(
        rule_id,
        parts,
        max_attempt,
        incorrect_nav_actions,
        Map.get(adaptivity, "exhaustedFeedback", @default_three_times_feedback)
      )
    ]

    rules =
      rules ++
        (common_errors
         |> Enum.with_index(1)
         |> Enum.flat_map(fn {error_spec, idx} ->
           case common_error_rules(rule_id, parts, error_spec, idx, max_attempt) do
             nil -> []
             rule -> [rule]
           end
         end))

    rules ++ [default_incorrect_rule(rule_id, incorrect_feedback)]
  end

  defp correct_rule(rule_id, parts, actions, score) do
    %{
      "id" => "#{rule_id}.correct",
      "name" => "correct",
      "disabled" => false,
      "additionalScore" => score * 1.0,
      "forceProgress" => false,
      "default" => true,
      "correct" => true,
      "conditions" => %{"all" => Enum.flat_map(parts, &correct_conditions/1)},
      "event" => %{
        "type" => "#{rule_id}.correct",
        "params" => %{
          "actions" => actions
        }
      }
    }
  end

  defp blank_rule(rule_id, parts, adaptivity) do
    message =
      case adaptivity do
        %{"blankFeedback" => feedback} when is_binary(feedback) and feedback != "" ->
          feedback

        _ ->
          "Please provide an answer before continuing."
      end

    blank_conditions =
      if Map.get(adaptivity, "requireAllModified", false) and length(parts) > 1 do
        %{"any" => Enum.map(parts, &blank_condition/1)}
      else
        %{"all" => [blank_condition(hd(parts))]}
      end

    %{
      "id" => "#{rule_id}.blank",
      "name" => "blank",
      "disabled" => false,
      "additionalScore" => 0.0,
      "forceProgress" => false,
      "default" => false,
      "correct" => false,
      "conditions" => blank_conditions,
      "event" => %{
        "type" => "#{rule_id}.blank",
        "params" => %{
          "actions" => [
            feedback_action(message),
            reset_attempts_action()
          ]
        }
      }
    }
  end

  defp max_attempt_incorrect_rule(rule_id, parts, max_attempt, actions, exhausted_feedback) do
    %{
      "id" => "#{rule_id}.incorrect-max-attempt",
      "name" => "incorrect-max-attempt",
      "disabled" => false,
      "additionalScore" => 0.0,
      "forceProgress" => false,
      "default" => false,
      "correct" => false,
      "conditions" => max_attempt_conditions(parts, max_attempt),
      "event" => %{
        "type" => "#{rule_id}.incorrect-max-attempt",
        "params" => %{
          "actions" =>
            actions ++
              Enum.flat_map(parts, &set_correct_value_actions/1) ++
              [feedback_action(exhausted_feedback)]
        }
      }
    }
  end

  defp max_attempt_conditions(parts, max_attempt) do
    base = [max_attempt_condition(max_attempt)]

    if text_input_screen?(parts) do
      %{"all" => base}
    else
      build_max_attempt_part_conditions(parts, base)
    end
  end

  defp build_max_attempt_part_conditions(parts, base) do
    part_incorrect =
      parts
      |> Enum.flat_map(&max_attempt_incorrect_conditions/1)

    case part_incorrect do
      [] ->
        %{"all" => base}

      [single] ->
        %{"all" => base ++ [single]}

      many ->
        if length(parts) > 1 do
          %{"all" => base ++ [%{"any" => many}]}
        else
          %{"all" => base ++ many}
        end
    end
  end

  defp text_input_screen?(parts) do
    Enum.any?(parts, &(&1["type"] == "janus-input-text"))
  end

  defp max_attempt_incorrect_conditions(%{"type" => "janus-input-text"}), do: []

  defp max_attempt_incorrect_conditions(part) do
    case incorrect_condition(part) do
      nil -> []
      condition -> [condition]
    end
  end

  defp common_error_rules(rule_id, parts, error_spec, idx, max_attempt) do
    case find_part_for_error(parts, error_spec) do
      nil ->
        nil

      part ->
        option = Map.get(error_spec, "option") || Map.get(error_spec, :option)

        feedback =
          Map.get(error_spec, "feedback") || Map.get(error_spec, :feedback) || "Incorrect."

        %{
          "id" => "#{rule_id}.common-error-#{idx}",
          "name" => "common-error-#{idx}",
          "disabled" => false,
          "additionalScore" => 0.0,
          "forceProgress" => false,
          "default" => false,
          "correct" => false,
          "conditions" => %{
            "all" => [
              max_attempt_less_than_condition(max_attempt),
              common_error_condition(part, option)
            ]
          },
          "event" => %{
            "type" => "#{rule_id}.common-error-#{idx}",
            "params" => %{"actions" => [feedback_action(feedback)]}
          }
        }
    end
  end

  defp default_incorrect_rule(rule_id, feedback) do
    %{
      "id" => "#{rule_id}.default-incorrect",
      "name" => "default-incorrect",
      "disabled" => false,
      "additionalScore" => 0.0,
      "forceProgress" => false,
      "default" => true,
      "correct" => false,
      "conditions" => %{"all" => []},
      "event" => %{
        "type" => "#{rule_id}.default-incorrect",
        "params" => %{"actions" => [feedback_action(feedback)]}
      }
    }
  end

  defp correct_actions("navigate next", feedback) do
    [navigation_action("next"), feedback_action(feedback)]
  end

  defp correct_actions(_, feedback), do: [feedback_action(feedback)]

  defp incorrect_nav_actions("navigate next", feedback) do
    [navigation_action("next"), feedback_action(feedback)]
  end

  defp incorrect_nav_actions(_, feedback), do: [feedback_action(feedback)]

  defp correct_conditions(%{"id" => part_id, "type" => "janus-mcq", "custom" => custom}) do
    [
      %{
        "fact" => "stage.#{part_id}.selectedChoice",
        "operator" => "equal",
        "value" => to_string(mcq_correct_choice(custom))
      }
    ]
  end

  defp correct_conditions(%{"id" => part_id, "type" => "janus-dropdown", "custom" => custom}) do
    [
      %{
        "fact" => "stage.#{part_id}.selectedIndex",
        "operator" => "equal",
        "value" => to_string(dropdown_correct_index(custom)),
        "type" => 1
      }
    ]
  end

  defp correct_conditions(%{"id" => part_id, "type" => "janus-text-slider", "custom" => custom}) do
    numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), false)
  end

  defp correct_conditions(%{"id" => part_id, "type" => "janus-slider", "custom" => custom}) do
    numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), false)
  end

  defp correct_conditions(%{"id" => part_id, "type" => "janus-input-number", "custom" => custom}) do
    numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), false)
  end

  defp correct_conditions(%{"id" => part_id, "type" => "janus-input-text", "custom" => custom}) do
    text_input_correct_conditions(part_id, custom)
  end

  defp correct_conditions(%{"id" => part_id, "type" => type}) when type in @scorable_types do
    [
      %{
        "fact" => "stage.#{part_id}.userModified",
        "operator" => "equal",
        "value" => "true",
        "type" => 4
      }
    ]
  end

  defp incorrect_condition(%{"id" => part_id, "type" => "janus-mcq", "custom" => custom}) do
    %{
      "fact" => "stage.#{part_id}.selectedChoice",
      "operator" => "notEqual",
      "value" => to_string(mcq_correct_choice(custom))
    }
  end

  defp incorrect_condition(%{"id" => part_id, "type" => "janus-dropdown", "custom" => custom}) do
    %{
      "fact" => "stage.#{part_id}.selectedIndex",
      "operator" => "notEqual",
      "value" => to_string(dropdown_correct_index(custom)),
      "type" => 1
    }
  end

  defp incorrect_condition(%{"id" => part_id, "type" => "janus-text-slider", "custom" => custom}) do
    case numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), true) do
      [condition] -> condition
      _ -> nil
    end
  end

  defp incorrect_condition(%{"id" => part_id, "type" => "janus-slider", "custom" => custom}) do
    case numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), true) do
      [condition] -> condition
      _ -> nil
    end
  end

  defp incorrect_condition(%{"id" => part_id, "type" => "janus-input-number", "custom" => custom}) do
    case numeric_value_conditions(part_id, Map.get(custom, "answer", %{}), true) do
      [condition] -> condition
      _ -> nil
    end
  end

  defp incorrect_condition(%{"type" => "janus-input-text"}), do: nil

  defp incorrect_condition(%{"id" => part_id, "type" => type}) when type in @scorable_types do
    %{
      "fact" => "stage.#{part_id}.userModified",
      "operator" => "equal",
      "value" => "true",
      "type" => 4
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-dropdown"}) do
    %{
      "fact" => "stage.#{part_id}.selectedItem",
      "operator" => "equal",
      "value" => "",
      "type" => 2
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-mcq"}) do
    %{
      "fact" => "stage.#{part_id}.numberOfSelectedChoices",
      "operator" => "equal",
      "value" => "0"
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-slider"}) do
    %{
      "fact" => "stage.#{part_id}.userModified",
      "operator" => "equal",
      "value" => "false",
      "type" => 4
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-text-slider"}) do
    %{
      "fact" => "stage.#{part_id}.userModified",
      "operator" => "equal",
      "value" => "false",
      "type" => 4
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-input-text", "custom" => custom}) do
    min_length = get_in(custom, ["correctAnswer", "minimumLength"]) || 1

    %{
      "fact" => "stage.#{part_id}.textLength",
      "operator" => "lessThan",
      "value" => to_string(min_length)
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => "janus-input-number"}) do
    %{
      "fact" => "stage.#{part_id}.value",
      "operator" => "isNaN",
      "value" => "true",
      "type" => 1
    }
  end

  defp blank_condition(%{"id" => part_id, "type" => type}) when type in @scorable_types do
    %{
      "fact" => "stage.#{part_id}.userModified",
      "operator" => "equal",
      "value" => "false",
      "type" => 4
    }
  end

  defp common_error_condition(%{"id" => part_id, "type" => "janus-text-slider"}, option)
       when is_integer(option) do
    %{
      "fact" => "stage.#{part_id}.value",
      "operator" => "equal",
      "value" => to_string(option)
    }
  end

  defp common_error_condition(%{"id" => part_id, "type" => "janus-dropdown"}, option)
       when is_integer(option) do
    %{
      "fact" => "stage.#{part_id}.selectedIndex",
      "operator" => "equal",
      "value" => to_string(option),
      "type" => 1
    }
  end

  defp common_error_condition(%{"id" => part_id, "type" => "janus-mcq"}, option)
       when is_integer(option) do
    %{
      "fact" => "stage.#{part_id}.selectedChoice",
      "operator" => "equal",
      "value" => to_string(option)
    }
  end

  defp common_error_condition(part, nil), do: incorrect_condition(part)

  defp common_error_condition(_part, _option) do
    %{"fact" => "session.attemptNumber", "operator" => "equal", "value" => "-1"}
  end

  defp mcq_correct_choice(custom) do
    Map.get(custom, "correctAnswer", 0) + 1
  end

  defp dropdown_correct_index(custom) do
    Map.get(custom, "correctAnswer", 0) + 1
  end

  defp numeric_correct_value(custom) do
    answer = Map.get(custom, "answer", %{})

    cond do
      answer["range"] == true -> answer["correctMin"] || 0
      Map.has_key?(answer, "correctAnswer") -> answer["correctAnswer"] || 0
      Map.has_key?(answer, "correct") -> answer["correct"] || 0
      true -> 0
    end
  end

  defp numeric_value_conditions(part_id, answer, invert?) when is_map(answer) do
    fact = "stage.#{part_id}.value"

    cond do
      answer["range"] == true ->
        min = answer["correctMin"] || 0
        max = answer["correctMax"] || min
        operator = if invert?, do: "notInRange", else: "inRange"

        [
          %{
            "fact" => fact,
            "operator" => operator,
            "value" => "[#{min},#{max}]"
          }
        ]

      Map.has_key?(answer, "correctAnswer") ->
        [
          %{
            "fact" => fact,
            "operator" => if(invert?, do: "notEqual", else: "equal"),
            "value" => to_string(answer["correctAnswer"])
          }
        ]

      Map.has_key?(answer, "correct") ->
        [
          %{
            "fact" => fact,
            "operator" => if(invert?, do: "notEqual", else: "equal"),
            "value" => to_string(answer["correct"])
          }
        ]

      true ->
        []
    end
  end

  defp numeric_value_conditions(_part_id, _answer, _invert?), do: []

  defp text_input_correct_conditions(part_id, custom) do
    must_contain = get_in(custom, ["correctAnswer", "mustContain"]) || ""
    must_not_contain = get_in(custom, ["correctAnswer", "mustNotContain"]) || ""
    min_length = get_in(custom, ["correctAnswer", "minimumLength"]) || 1

    required_terms = split_csv_terms(must_contain)
    forbidden_terms = split_csv_terms(must_not_contain)

    required_conditions =
      Enum.map(required_terms, fn term ->
        %{
          "fact" => "stage.#{part_id}.text",
          "operator" => "contains",
          "value" => term,
          "type" => 2
        }
      end)

    forbidden_conditions =
      Enum.map(forbidden_terms, fn term ->
        %{
          "fact" => "stage.#{part_id}.text",
          "operator" => "notContains",
          "value" => term,
          "type" => 2
        }
      end)

    length_condition = %{
      "fact" => "stage.#{part_id}.textLength",
      "operator" => "greaterThanInclusive",
      "value" => to_string(min_length)
    }

    required_conditions ++ forbidden_conditions ++ [length_condition]
  end

  defp split_csv_terms(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_csv_terms(_), do: []

  defp max_attempt_condition(max_attempt) do
    %{
      "fact" => "session.attemptNumber",
      "operator" => "equal",
      "value" => to_string(max_attempt),
      "type" => 1
    }
  end

  defp max_attempt_less_than_condition(max_attempt) do
    %{
      "fact" => "session.attemptNumber",
      "operator" => "lessThan",
      "value" => to_string(max_attempt),
      "type" => 1
    }
  end

  defp set_correct_value_actions(%{"id" => part_id, "type" => "janus-mcq", "custom" => custom}) do
    correct_index = Map.get(custom, "correctAnswer", 0)

    [
      %{
        "type" => "mutateState",
        "params" => %{
          "value" => to_string(correct_index + 1),
          "target" => "stage.#{part_id}.selectedChoice",
          "operator" => "=",
          "targetType" => 1
        }
      }
    ]
  end

  defp set_correct_value_actions(%{
         "id" => part_id,
         "type" => "janus-text-slider",
         "custom" => custom
       }) do
    numeric_set_correct_value_action(part_id, Map.get(custom, "answer", %{}))
  end

  defp set_correct_value_actions(%{
         "id" => part_id,
         "type" => "janus-input-text",
         "custom" => custom
       }) do
    must_contain = get_in(custom, ["correctAnswer", "mustContain"]) || ""

    if must_contain != "" do
      [
        %{
          "type" => "mutateState",
          "params" => %{
            "value" => must_contain,
            "target" => "stage.#{part_id}.text",
            "operator" => "=",
            "targetType" => 2
          }
        }
      ]
    else
      []
    end
  end

  defp set_correct_value_actions(%{
         "id" => part_id,
         "type" => "janus-input-number",
         "custom" => custom
       }) do
    numeric_set_correct_value_action(part_id, Map.get(custom, "answer", %{}))
  end

  defp set_correct_value_actions(%{"id" => part_id, "type" => "janus-slider", "custom" => custom}) do
    numeric_set_correct_value_action(part_id, Map.get(custom, "answer", %{}))
  end

  defp set_correct_value_actions(%{
         "id" => part_id,
         "type" => "janus-dropdown",
         "custom" => custom
       }) do
    [
      %{
        "type" => "mutateState",
        "params" => %{
          "value" => to_string(dropdown_correct_index(custom)),
          "target" => "stage.#{part_id}.selectedIndex",
          "operator" => "=",
          "targetType" => 1
        }
      }
    ]
  end

  defp set_correct_value_actions(_), do: []

  defp numeric_set_correct_value_action(part_id, answer) do
    value =
      cond do
        answer["range"] == true -> answer["correctMin"] || 0
        Map.has_key?(answer, "correctAnswer") -> answer["correctAnswer"] || 0
        Map.has_key?(answer, "correct") -> answer["correct"] || 0
        true -> nil
      end

    case value do
      nil ->
        []

      resolved ->
        [
          %{
            "type" => "mutateState",
            "params" => %{
              "value" => to_string(resolved),
              "target" => "stage.#{part_id}.value",
              "operator" => "=",
              "targetType" => 1
            }
          }
        ]
    end
  end

  defp reset_attempts_action do
    %{
      "type" => "mutateState",
      "params" => %{
        "value" => "1",
        "target" => "session.attemptNumber",
        "operator" => "setting to",
        "targetType" => 1
      }
    }
  end

  defp navigation_action(target) do
    %{"type" => "navigation", "params" => %{"target" => target}}
  end

  defp feedback_action(message) do
    feedback_part = PartBuilders.feedback_text_part(message)

    %{
      "type" => "feedback",
      "params" => %{
        "id" => "a_f_#{Util.new_id("fb")}",
        "feedback" => %{
          "custom" => %{
            "applyBtnFlag" => false,
            "applyBtnLabel" => "Show Solution",
            "mainBtnLabel" => "Next",
            "panelTitleColor" => 16_777_215,
            "panelHeaderColor" => 10_027_008,
            "lockCanvasSize" => true,
            "width" => 350.0,
            "height" => 100.0,
            "palette" => %{
              "fillColor" => 1.6777215e7,
              "fillAlpha" => 0.0,
              "lineColor" => 1.6777215e7,
              "lineAlpha" => 0.0,
              "lineThickness" => 0.1,
              "lineStyle" => 0.0
            },
            "rules" => [],
            "facts" => []
          },
          "partsLayout" => [feedback_part]
        }
      }
    }
  end

  defp find_scorable_parts(component_part, parts_layout, component_parts) do
    from_layout =
      parts_layout
      |> Enum.filter(&(&1["type"] in @scorable_types))

    cond do
      from_layout != [] ->
        from_layout

      component_parts != [] ->
        component_parts

      not is_nil(component_part) ->
        [component_part]

      true ->
        case find_scorable_part(component_part, parts_layout) do
          nil -> []
          part -> [part]
        end
    end
  end

  defp find_part_for_error(parts, error_spec) do
    part_key = Map.get(error_spec, "partKey") || Map.get(error_spec, :partKey)

    cond do
      is_binary(part_key) and part_key != "" ->
        normalized_key = normalize_label(part_key)

        Enum.find(parts, fn part ->
          label = get_in(part, ["custom", "label"]) || ""
          normalized_label = normalize_label(label)

          normalized_label == normalized_key or
            label_abbreviation(label) == normalized_key or
            String.contains?(normalized_label, normalized_key)
        end)

      Map.has_key?(error_spec, "option") or Map.has_key?(error_spec, :option) ->
        case Enum.filter(parts, &(&1["type"] in ["janus-mcq", "janus-dropdown"])) do
          [part] ->
            part

          matching_parts ->
            Enum.find(matching_parts, &(&1["type"] == "janus-mcq")) || List.first(matching_parts)
        end

      true ->
        name = Map.get(error_spec, "name") || Map.get(error_spec, :name) || ""

        case Regex.run(~r/^incorrect (.+?) feedback$/, name) do
          [_, part_name] ->
            normalized_key = normalize_label(part_name)

            Enum.find(parts, fn part ->
              label = get_in(part, ["custom", "label"]) || ""
              normalize_label(label) == normalized_key
            end)

          _ ->
            List.first(parts)
        end
    end
  end

  defp normalize_label(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp label_abbreviation(label) do
    label
    |> normalize_label()
    |> String.split(" ", trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.join()
  end

  defp find_scorable_part(%{"id" => id}, parts_layout) do
    Enum.find(parts_layout, &(&1["id"] == id))
  end

  defp find_scorable_part(nil, parts_layout) do
    Enum.find(parts_layout, &(&1["type"] in @scorable_types))
  end

  defp max_attempt(adaptivity, _part) when is_map(adaptivity) do
    case Map.get(adaptivity, "maxAttempt") do
      attempt when is_integer(attempt) and attempt >= 0 -> attempt
      attempt when is_binary(attempt) -> String.to_integer(attempt)
      _ -> @default_max_attempt
    end
  end

  defp max_attempt(nil, part) when not is_nil(part), do: @default_max_attempt
  defp max_attempt(_, _), do: 0
end
