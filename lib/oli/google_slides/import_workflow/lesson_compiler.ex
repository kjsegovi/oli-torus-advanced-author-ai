defmodule Oli.GoogleSlides.ImportWorkflow.LessonCompiler do
  @moduledoc """
  Deterministically compiles a finalized semantic lesson plan into Torus
  Advanced Author page and `oli_adaptive` activity content.
  """

  alias Oli.GoogleSlides.Adaptive.{PartBuilders, TrapStateRulesBuilder}
  alias Oli.GoogleSlides.AI.{Catalog, CSSCompiler, ImportPlan, LessonPlan}

  @default_width 1200
  @default_height 540
  @scorable_part_types ~w(
    janus-mcq
    janus-dropdown
    janus-slider
    janus-text-slider
    janus-input-text
    janus-input-number
  )

  @spec compile(map(), map(), keyword()) :: {:ok, map()} | {:error, [map()]}
  def compile(plan, media_urls \\ %{}, opts \\ []) when is_map(plan) and is_map(media_urls) do
    allow_triggers = Keyword.get(opts, :allow_triggers, false)

    with :ok <- validate_catalog_version(plan),
         {:ok, finalized_plan} <- LessonPlan.finalize(plan),
         :ok <- validate_runtime_ai_gate(finalized_plan, allow_triggers),
         {:ok, stylesheets, custom_css} <- compile_appearance(finalized_plan),
         {:ok, activities} <-
           compile_screens(finalized_plan, media_urls, allow_triggers) do
      lesson = finalized_plan["lesson"]
      lesson_key = lesson["key"]

      {:ok,
       %{
         title: lesson["title"],
         runtime_ai_enabled: runtime_ai_enabled?(finalized_plan),
         activities: activities,
         page_content: %{
           "advancedDelivery" => true,
           "advancedAuthoring" => true,
           "displayApplicationChrome" => false,
           "custom" => page_custom(lesson["layout"], finalized_plan["variables"]),
           "additionalStylesheets" => stylesheets,
           "customCss" => custom_css,
           "model" => [
             %{
               "id" => stable_id("deck", lesson_key),
               "type" => "group",
               "layout" => "deck",
               "children" => []
             }
           ]
         },
         plan: finalized_plan
       }}
    end
  end

  @doc """
  Validates and compiles every lesson before the caller performs any mutation.
  """
  @spec compile_many(map(), map(), keyword()) :: {:ok, [map()]} | {:error, [map()]}
  def compile_many(import_plan, media_urls \\ %{}, opts \\ [])
      when is_map(import_plan) and is_map(media_urls) do
    with {:ok, validated} <- ImportPlan.validate(import_plan) do
      validated
      |> ImportPlan.lessons()
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {plan, index}, {:ok, compiled} ->
        case compile(plan, media_urls, opts) do
          {:ok, lesson} ->
            {:cont, {:ok, compiled ++ [lesson]}}

          {:error, errors} ->
            prefixed =
              Enum.map(errors, fn error ->
                Map.update(error, "path", "lessons[#{index}]", &"lessons[#{index}].#{&1}")
              end)

            {:halt, {:error, prefixed}}
        end
      end)
    end
  end

  defp validate_catalog_version(plan) do
    if plan["catalogVersion"] == Catalog.version() do
      :ok
    else
      {:error,
       [
         error(
           "catalogVersion",
           "stale_catalog",
           "plan catalog version #{inspect(plan["catalogVersion"])} does not match #{Catalog.version()}"
         )
       ]}
    end
  end

  defp compile_appearance(plan) do
    layout =
      (get_in(plan, ["lesson", "layout"]) || %{})
      |> Map.put("compilerScope", get_in(plan, ["lesson", "key"]) || "lesson")

    profile_key = layout["styleProfile"] || "torus-default"

    with {:ok, profile} <- Catalog.style_profile(profile_key),
         {:ok, css} <-
           CSSCompiler.compile(layout["styleRules"] || [],
             scope: get_in(plan, ["lesson", "key"]) || "lesson"
           ) do
      {:ok, profile["approvedStylesheets"], css}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, reason} -> {:error, [error("lesson.layout", "compile_failed", inspect(reason))]}
    end
  end

  defp compile_screens(plan, media_urls, allow_triggers) do
    layout =
      (get_in(plan, ["lesson", "layout"]) || %{})
      |> Map.put("compilerScope", get_in(plan, ["lesson", "key"]) || "lesson")

    objective_keys = objective_keys_by_screen(plan["objectives"] || %{})

    plan
    |> get_in(["lesson", "screens"])
    |> Enum.reduce_while({:ok, []}, fn screen, {:ok, activities} ->
      case compile_screen(screen, layout, media_urls, allow_triggers) do
        {:ok, content} ->
          activity = %{
            key: screen["key"],
            title: screen["title"],
            content: content,
            objective_keys: Map.get(objective_keys, screen["key"], [])
          }

          {:cont, {:ok, activities ++ [activity]}}

        {:error, errors} ->
          {:halt, {:error, errors}}
      end
    end)
  end

  defp compile_screen(screen, lesson_layout, media_urls, allow_triggers) do
    mode = lesson_layout["mode"] || "responsive"
    initial_y = 0
    title_key = "#{screen["key"]}_title"

    title_part =
      screen["title"]
      |> PartBuilders.text_flow(:h4, y: initial_y)
      |> put_stable_id(title_key)
      |> put_css_class("layout-section")
      |> apply_layout(%{}, mode, initial_y)

    with {:ok, content_parts, next_y} <-
           compile_content_parts(screen, media_urls, mode, [title_part], 40),
         {:ok, parts, interaction_parts, _next_y} <-
           compile_interactions(
             screen,
             mode,
             content_parts,
             [],
             next_y
           ),
         {:ok, rules} <-
           compile_rules(screen, interaction_parts, parts, allow_triggers) do
      primary_interaction = primary_scorable_interaction(screen)

      max_attempt =
        if is_nil(primary_interaction), do: 0, else: max_attempt(screen, primary_interaction)

      rules = stabilize_rules(rules, screen["key"])

      content = %{
        "custom" => screen_custom(screen, lesson_layout, max_attempt),
        "authoring" => %{
          "parts" => Enum.map(parts, &PartBuilders.authoring_part/1),
          "rules" => rules,
          "variablesRequiredForEvaluation" => required_variables(rules, screen),
          "activitiesRequiredForEvaluation" => []
        },
        "partsLayout" => parts
      }

      {:ok, content}
    end
  end

  defp compile_content_parts(screen, media_urls, mode, initial_parts, initial_y) do
    Enum.reduce_while(screen["parts"] || [], {:ok, initial_parts, initial_y}, fn semantic_part,
                                                                                 {:ok, parts, y} ->
      case compile_content_part(semantic_part, media_urls, mode, y) do
        {:ok, part, height} -> {:cont, {:ok, parts ++ [part], y + height + 12}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp compile_content_part(part, media_urls, mode, y) do
    kind = part["kind"]
    content = stringify_map(part["content"])
    layout = stringify_map(part["layout"])
    key = part["key"]

    result =
      case kind do
        "text" ->
          tag = heading_tag(content["tag"] || content["role"])
          text = content_text(content)
          {:ok, PartBuilders.text_flow(text, tag, y: y), text_height(tag)}

        "list" ->
          items = content["items"] || []

          {:ok, PartBuilders.list_flow(items, content["listType"] || "ul", y: y),
           list_height(items)}

        "table" ->
          text = table_text(content)
          {:ok, PartBuilders.text_flow(text, :p, y: y), 108}

        "image" ->
          compile_image_part(part, content, media_urls, y)

        "video" ->
          compile_video_part(part, content, media_urls, y)

        "audio" ->
          compile_audio_part(part, content, y)

        "iframe" ->
          src = content["src"]

          if safe_external_url?(src) do
            {:ok, PartBuilders.iframe_part(Map.put(content, "src", src), y: y), 340}
          else
            {:error,
             [
               error(
                 "part.#{key}.content.src",
                 "unsafe_url",
                 "iframe source must be an absolute HTTPS URL"
               )
             ]}
          end

        kind when kind in ["chart", "shape", "line", "word_art"] ->
          compile_graphic_or_text(part, content, media_urls, y)

        _ ->
          {:error,
           [
             error(
               "part.#{key}.kind",
               "unsupported",
               "cannot compile content kind #{inspect(kind)}"
             )
           ]}
      end

    case result do
      {:ok, built, height} ->
        built =
          built
          |> put_stable_id(key)
          |> put_css_class(part["styleTarget"])
          |> apply_layout(layout, mode, y)

        {:ok, built, layout_height(layout, height, mode)}

      error ->
        error
    end
  end

  defp compile_image_part(part, content, media_urls, y) do
    object_id = content["sourceObjectId"]
    src = Map.get(media_urls, object_id) || content["src"]
    alt_text = get_in(part, ["accessibility", "altText"])

    cond do
      not safe_media_url?(src) ->
        {:error,
         [
           error(
             "part.#{part["key"]}.content.sourceObjectId",
             "media_not_staged",
             "source image was not available during generation"
           )
         ]}

      not present?(alt_text) ->
        {:error,
         [
           error(
             "part.#{part["key"]}.accessibility.altText",
             "required",
             "image alt text is required"
           )
         ]}

      true ->
        height = positive_number(get_in(part, ["layout", "height"]), 200)
        {:ok, PartBuilders.image_part(src, y: y, height: height, alt: alt_text), height}
    end
  end

  defp compile_video_part(part, content, media_urls, y) do
    src = Map.get(media_urls, content["sourceObjectId"]) || content["src"]
    captions = get_in(part, ["accessibility", "captions"])
    alt_text = get_in(part, ["accessibility", "altText"]) || "Slide video"

    cond do
      not safe_media_url?(src) ->
        {:error,
         [
           error(
             "part.#{part["key"]}.content.src",
             "unsafe_url",
             "video source must be an HTTP(S) or project-media URL"
           )
         ]}

      not safe_media_url?(captions) ->
        {:error,
         [
           error(
             "part.#{part["key"]}.accessibility.captions",
             "invalid_media_reference",
             "captions must reference an HTTP(S) or project-media caption track"
           )
         ]}

      true ->
        height = positive_number(get_in(part, ["layout", "height"]), 280)

        subtitles = [
          %{
            "default" => true,
            "label" => "English",
            "language_code" => "en",
            "src" => captions
          }
        ]

        {:ok,
         PartBuilders.video_part(src,
           y: y,
           height: height,
           alt: alt_text,
           subtitles: subtitles
         ), height}
    end
  end

  defp compile_audio_part(part, content, y) do
    src = content["src"]

    if safe_media_url?(src) do
      transcript = get_in(part, ["accessibility", "transcript"]) || ""
      captions = get_in(part, ["accessibility", "captions"])

      with {:ok, subtitles} <- optional_audio_subtitles(captions, part["key"]) do
        transcript_opts =
          if safe_media_url?(transcript) do
            [transcript_file: transcript]
          else
            [transcript_text: transcript]
          end

        {:ok,
         PartBuilders.audio_part(
           src,
           [
             y: y,
             height: positive_number(get_in(part, ["layout", "height"]), 54),
             subtitles: subtitles
           ] ++ transcript_opts
         ), 54}
      end
    else
      {:error,
       [
         error(
           "part.#{part["key"]}.content.src",
           "unsafe_url",
           "audio source must be an HTTP(S) or project-media URL"
         )
       ]}
    end
  end

  defp optional_audio_subtitles(captions, _part_key) when captions in [nil, ""],
    do: {:ok, []}

  defp optional_audio_subtitles(captions, part_key) do
    if safe_media_url?(captions) do
      {:ok,
       [
         %{
           "default" => true,
           "language" => "en",
           "src" => captions
         }
       ]}
    else
      {:error,
       [
         error(
           "part.#{part_key}.accessibility.captions",
           "invalid_media_reference",
           "captions must reference an HTTP(S) or project-media caption track"
         )
       ]}
    end
  end

  defp compile_graphic_or_text(part, content, media_urls, y) do
    kind = part["kind"]
    object_id = content["sourceObjectId"]
    src = Map.get(media_urls, object_id) || content["src"]
    text = content_text(content)

    cond do
      kind in ["word_art", "shape"] and present?(text) ->
        {:ok, PartBuilders.text_flow(text, :p, y: y), 108}

      safe_media_url?(src) ->
        alt = get_in(part, ["accessibility", "altText"]) || content["altText"]

        if present?(alt) do
          height = positive_number(get_in(part, ["layout", "height"]), 200)
          {:ok, PartBuilders.image_part(src, y: y, height: height, alt: alt), height}
        else
          {:error,
           [
             error(
               "part.#{part["key"]}.accessibility.altText",
               "required",
               "reviewed alt text is required for rasterized slide graphics"
             )
           ]}
        end

      present?(object_id) ->
        {:error,
         [
           error(
             "part.#{part["key"]}.content.sourceObjectId",
             "media_not_staged",
             "source graphic was not available during generation"
           )
         ]}

      present?(text) ->
        {:ok, PartBuilders.text_flow(text, :p, y: y), 108}

      true ->
        {:error,
         [
           error(
             "part.#{part["key"]}.content",
             "required",
             "graphic content could not be compiled"
           )
         ]}
    end
  end

  defp compile_interactions(screen, mode, initial_parts, initial_interactions, initial_y) do
    Enum.reduce_while(
      screen["interactions"] || [],
      {:ok, initial_parts, initial_interactions, initial_y},
      fn interaction, {:ok, parts, interaction_parts, y} ->
        case compile_interaction(interaction, mode, y) do
          {:ok, part, height} ->
            {:cont, {:ok, parts ++ [part], interaction_parts ++ [part], y + height + 12}}

          {:error, errors} ->
            {:halt, {:error, errors}}
        end
      end
    )
  end

  defp compile_interaction(interaction, mode, y) do
    key = interaction["key"]
    component = interaction["componentKey"]
    config = interaction_spec(interaction)

    result =
      case component do
        "multiple_choice" -> {:ok, PartBuilders.mcq_part(config, y: y), 120}
        "dropdown" -> {:ok, PartBuilders.dropdown_part(config, y: y), 100}
        "slider" -> {:ok, PartBuilders.slider_part(config, y: y), 100}
        "text_slider" -> {:ok, PartBuilders.text_slider_part(config, y: y), 90}
        "text_input" -> {:ok, PartBuilders.input_text_part(config, y: y), 90}
        "number_input" -> {:ok, PartBuilders.input_number_part(config, y: y), 90}
        "iframe" -> compile_interaction_iframe(config, key, y)
        other -> {:error, [error("interaction.#{key}", "unsupported", "cannot compile #{other}")]}
      end

    case result do
      {:ok, part, height} ->
        part =
          part
          |> put_stable_id(key)
          |> put_css_class("prompt")
          |> apply_layout(stringify_map(interaction["layout"]), mode, y)
          |> maybe_mark_manual(interaction)

        {:ok, part, height}

      error ->
        error
    end
  end

  defp interaction_spec(interaction) do
    configuration =
      interaction["configuration"]
      |> stringify_map()
      |> canonicalize_configuration(interaction["componentKey"])

    feedback = stringify_map(interaction["feedback"])
    static = stringify_map(feedback["static"])
    response = interaction["correctResponse"]
    component = interaction["componentKey"]

    configuration
    |> Map.put_new("label", interaction["prompt"] || "Respond")
    |> Map.put_new("prompt", interaction["prompt"] || "Respond")
    |> Map.put("correctFeedback", feedback_text(static["correct"], "Correct!"))
    |> Map.put(
      "incorrectFeedback",
      feedback_text(static["incorrect"], "Incorrect, please try again.")
    )
    |> put_correct_response(component, response)
  end

  defp canonicalize_configuration(configuration, "dropdown") do
    options = configuration["optionLabels"] || configuration["choices"]

    configuration
    |> Map.delete("choices")
    |> Map.put("optionLabels", options)
  end

  defp canonicalize_configuration(configuration, "text_slider") do
    options = configuration["sliderOptionLabels"] || configuration["choices"]

    configuration
    |> Map.delete("choices")
    |> Map.put("sliderOptionLabels", options)
  end

  defp canonicalize_configuration(configuration, _component), do: configuration

  defp put_correct_response(spec, component, response)
       when component in ["multiple_choice", "dropdown", "text_slider"] do
    options = spec["choices"] || spec["optionLabels"] || spec["sliderOptionLabels"] || []
    Map.put(spec, "correct", response_index(response, options))
  end

  defp put_correct_response(spec, "slider", response),
    do: Map.put(spec, "correct", response_value(response))

  defp put_correct_response(spec, "number_input", response),
    do: Map.put(spec, "correct", response_value(response))

  defp put_correct_response(spec, "text_input", response) when is_map(response) do
    Map.put(spec, "correctAnswer", stringify_map(response))
  end

  defp put_correct_response(spec, "text_input", response) do
    Map.put(spec, "correctAnswer", %{
      "minimumLength" => 1,
      "mustContain" => to_string(response || ""),
      "mustNotContain" => ""
    })
  end

  defp put_correct_response(spec, _component, _response), do: spec

  defp compile_interaction_iframe(config, key, y) do
    if safe_external_url?(config["src"]) do
      {:ok, PartBuilders.iframe_part(config, y: y), 340}
    else
      {:error,
       [
         error(
           "interaction.#{key}.configuration.src",
           "unsafe_url",
           "iframe source must be an absolute HTTPS URL"
         )
       ]}
    end
  end

  defp compile_rules(_screen, [], _parts, _allow_triggers), do: {:ok, []}

  defp compile_rules(screen, interaction_parts, parts, allow_triggers) do
    interaction_pairs =
      (screen["interactions"] || [])
      |> Enum.zip(interaction_parts)
      |> Enum.filter(fn {_interaction, part} -> part["type"] in @scorable_part_types end)

    case interaction_pairs do
      [] ->
        {:ok, []}

      [{primary_interaction, primary_part}] ->
        scorable_parts = Enum.map(interaction_pairs, &elem(&1, 1))
        adaptivity = adaptivity_config(screen, primary_interaction)

        rules =
          adaptivity
          |> TrapStateRulesBuilder.build_rules(primary_part, parts, scorable_parts)
          |> apply_semantic_actions(screen["adaptivity"] || [])

        case runtime_ai(primary_interaction) do
          %{"enabled" => true} = config when allow_triggers ->
            prompt = config["prompt"]

            if present?(prompt) do
              {:ok, add_runtime_ai_action(rules, prompt)}
            else
              {:error,
               [
                 error(
                   "interaction.#{primary_interaction["key"]}.feedback.runtimeAi.prompt",
                   "required",
                   "enabled runtime AI feedback requires a prompt"
                 )
               ]}
            end

          _ ->
            {:ok, rules}
        end

      _multiple ->
        {:error,
         [
           error(
             "screen.#{screen["key"]}.interactions",
             "unsupported",
             "import v1 supports one automatically evaluated interaction per screen"
           )
         ]}
    end
  end

  defp adaptivity_config(screen, interaction) do
    static =
      interaction
      |> stringify_map()
      |> Map.get("feedback", %{})
      |> stringify_map()
      |> Map.get("static", %{})
      |> stringify_map()

    scoring = interaction |> stringify_map() |> Map.get("scoring", %{}) |> stringify_map()
    rules = screen["adaptivity"] || []
    policy = interaction |> stringify_map() |> Map.get("evaluationPolicy", %{}) |> stringify_map()

    %{
      "maxAttempt" => max_attempt(screen, interaction),
      "score" => scoring["points"] || 0,
      "correctFeedback" => feedback_text(static["correct"], "Correct!"),
      "incorrectFeedback" => feedback_text(static["incorrect"], "Incorrect, please try again."),
      "blankFeedback" => feedback_text(static["blank"], policy["blankFeedback"]),
      "exhaustedFeedback" => policy["exhaustedFeedback"],
      "onCorrect" => semantic_navigation(rules, "correct", "navigate next"),
      "onIncorrect" => semantic_navigation(rules, "incorrect", "show feedback"),
      "commonErrors" => semantic_common_errors(rules)
    }
  end

  defp semantic_navigation(rules, outcome, default) do
    Enum.find_value(rules, default, fn rule ->
      condition = stringify_map(rule["condition"])
      action = stringify_map(rule["action"])

      if condition["outcome"] == outcome do
        case {action["type"], action["target"]} do
          {"navigate", "next"} -> "navigate next"
          {"navigate", target} when is_binary(target) and target != "" -> "show feedback"
          {"feedback", _} -> "show feedback"
          _ -> nil
        end
      end
    end)
  end

  defp semantic_common_errors(rules) do
    Enum.flat_map(rules, fn rule ->
      condition = stringify_map(rule["condition"])
      action = stringify_map(rule["action"])

      if condition["outcome"] == "incorrect" and not is_nil(condition["option"]) do
        [
          %{
            "option" => condition["option"],
            "feedback" => action["message"] || "Incorrect."
          }
        ]
      else
        []
      end
    end)
  end

  defp apply_semantic_actions(rules, semantic_rules) do
    Enum.reduce(semantic_rules, rules, fn semantic_rule, compiled_rules ->
      condition = stringify_map(semantic_rule["condition"])
      action = stringify_map(semantic_rule["action"])
      outcome = condition["outcome"]

      case {action["type"], action["target"]} do
        {"navigate", target} when target != "next" ->
          append_action_for_outcome(
            compiled_rules,
            outcome,
            navigation_action(stable_sequence_id(target)),
            :navigation
          )

        {"set_variable", _target} ->
          append_action_for_outcome(
            compiled_rules,
            outcome,
            variable_action(action, "setting to"),
            :mutation
          )

        {"increment_variable", _target} ->
          append_action_for_outcome(
            compiled_rules,
            outcome,
            variable_action(action, "adding"),
            :mutation
          )

        _ ->
          compiled_rules
      end
    end)
  end

  defp append_action_for_outcome(rules, outcome, action, action_kind) do
    Enum.map(rules, fn rule ->
      if semantic_rule_target?(rule["name"], outcome, action_kind) do
        update_in(rule, ["event", "params", "actions"], &((&1 || []) ++ [action]))
      else
        rule
      end
    end)
  end

  defp semantic_rule_target?("correct", "correct", _action_kind), do: true
  defp semantic_rule_target?("incorrect-max-attempt", "incorrect", :navigation), do: true

  defp semantic_rule_target?(name, "incorrect", :mutation) when is_binary(name),
    do:
      name in ["incorrect-max-attempt", "default-incorrect"] or
        String.starts_with?(name, "common-error-")

  defp semantic_rule_target?(_name, _outcome, _action_kind), do: false

  defp navigation_action(target), do: %{"type" => "navigation", "params" => %{"target" => target}}

  defp variable_action(action, operator) do
    value = action["value"]

    %{
      "type" => "mutateState",
      "params" => %{
        "value" => mutation_expression(value),
        "target" => "variables.#{action["variableKey"]}",
        "operator" => operator,
        "targetType" => capi_type(value)
      }
    }
  end

  defp mutation_expression(value), do: Jason.encode!(value)
  defp capi_type(value) when is_number(value), do: 1
  defp capi_type(value) when is_binary(value), do: 2
  defp capi_type(value) when is_boolean(value), do: 4

  defp add_runtime_ai_action(rules, prompt) do
    index =
      Enum.find_index(rules, fn rule ->
        rule["name"] in ["default-incorrect", "incorrect-max-attempt"]
      end)

    case index do
      nil ->
        rules

      index ->
        update_in(
          rules,
          [Access.at(index), "event", "params", "actions"],
          &((&1 || []) ++
              [
                %{
                  "type" => "activationPoint",
                  "params" => %{"kind" => "feedback", "prompt" => prompt}
                }
              ])
        )
    end
  end

  defp validate_runtime_ai_gate(plan, allow_triggers) do
    enabled = runtime_ai_interactions(plan)

    if enabled != [] and not allow_triggers do
      {:error,
       [
         error(
           "lesson.interactions.feedback.runtimeAi",
           "triggers_disabled",
           "runtime AI feedback cannot be enabled because this project does not allow triggers"
         )
       ]}
    else
      :ok
    end
  end

  defp runtime_ai_enabled?(plan), do: runtime_ai_interactions(plan) != []

  defp runtime_ai_interactions(plan) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.flat_map(&(&1["interactions"] || []))
    |> Enum.filter(fn interaction ->
      runtime_ai = get_in(interaction, ["feedback", "runtimeAi"]) || %{}

      runtime_ai["enabled"] == true and
        runtime_ai["authorOptIn"] == true and
        runtime_ai["optInSource"] == "author_answer"
    end)
  end

  defp runtime_ai(nil), do: %{}
  defp runtime_ai(interaction), do: get_in(interaction, ["feedback", "runtimeAi"]) || %{}

  defp max_attempt(screen, interaction) do
    explicit =
      screen["adaptivity"]
      |> List.wrap()
      |> Enum.find_value(fn rule ->
        value =
          rule["maxAttempt"] ||
            get_in(rule, ["action", "maxAttempt"]) ||
            get_in(rule, ["condition", "maxAttempt"])

        if is_integer(value) and value > 0, do: value
      end)

    explicit || get_in(interaction, ["evaluationPolicy", "maxAttempts"]) || 3
  end

  defp primary_scorable_interaction(screen) do
    Enum.find(screen["interactions"] || [], fn interaction ->
      Catalog.automatically_evaluated?(interaction["componentKey"])
    end)
  end

  defp screen_custom(screen, layout, max_attempt) do
    canvas = stringify_map(layout["canvas"])
    lesson_key = layout_scope_key(layout, screen)

    %{
      "applyBtnFlag" => false,
      "applyBtnLabel" => "",
      "checkButtonLabel" => "Next",
      "combineFeedback" => false,
      "customCssClass" => "layout-section aa-import-#{lesson_key}",
      "facts" => [],
      "lockCanvasSize" => layout["mode"] == "pixel",
      "mainBtnLabel" => "",
      "maxAttempt" => max_attempt,
      "maxScore" => 0,
      "negativeScoreAllowed" => false,
      "palette" => %{
        "backgroundColor" => "rgba(255,255,255,0)",
        "borderColor" => "rgba(255,255,255,0)",
        "borderRadius" => "",
        "borderStyle" => "solid",
        "borderWidth" => "1px",
        "useHtmlProps" => true
      },
      "panelHeaderColor" => 0,
      "panelTitleColor" => 0,
      "showCheckBtn" => true,
      "trapStateScoreScheme" => false,
      "width" => positive_number(canvas["width"], @default_width),
      "height" => positive_number(canvas["height"], @default_height),
      "x" => 0,
      "y" => 0,
      "z" => 0
    }
  end

  defp layout_scope_key(layout, _screen),
    do: sanitize_key(layout["compilerScope"] || "lesson")

  defp page_custom(layout, variables) do
    canvas = stringify_map(layout["canvas"])

    %{
      "contentMode" => "expert",
      "defaultScreenHeight" => positive_number(canvas["height"], @default_height),
      "defaultScreenWidth" => positive_number(canvas["width"], @default_width),
      "enableHistory" => true,
      "maxScore" => 0,
      "responsiveLayout" => layout["mode"] != "pixel",
      "themeId" => "torus-default-light",
      "totalScore" => 0,
      "variables" => compile_lesson_variables(variables)
    }
  end

  defp compile_lesson_variables(variables) when is_list(variables) do
    Enum.map(variables, fn variable ->
      %{
        "name" => variable["key"],
        "expression" => initial_value_expression(variable["initialValue"], variable["type"])
      }
    end)
  end

  defp compile_lesson_variables(_variables), do: []

  # Advanced Author evaluates lesson-variable expressions in a constrained
  # expression engine. Import plans may only provide typed constant initial
  # values, so JSON encoding gives us a deterministic expression without
  # allowing the model to inject executable expressions.
  defp initial_value_expression(nil, "boolean"), do: "false"
  defp initial_value_expression(nil, type) when type in ["number", "integer"], do: "0"
  defp initial_value_expression(nil, "string"), do: ~s("")
  defp initial_value_expression(value, _type), do: Jason.encode!(value)

  defp apply_layout(part, layout, "pixel", default_y) do
    update_in(part, ["custom"], fn custom ->
      custom
      |> Map.put("x", number(layout["x"], 0))
      |> Map.put("y", number(layout["y"], default_y))
      |> Map.put("width", positive_number(layout["width"], custom["width"] || 100))
      |> Map.put("height", positive_number(layout["height"], custom["height"] || 80))
      |> Map.put("responsiveLayoutWidth", positive_number(layout["width"], 960))
    end)
  end

  defp apply_layout(part, _layout, _mode, default_y) do
    update_in(part, ["custom"], fn custom ->
      custom
      |> Map.put("x", 0)
      |> Map.put("y", default_y)
      |> Map.put("width", 100)
      |> Map.put("responsiveLayoutWidth", 960)
    end)
  end

  defp put_stable_id(part, key), do: Map.put(part, "id", stable_id(part["type"], key))

  defp stable_id(prefix, key) do
    digest =
      :crypto.hash(:sha256, "#{prefix}:#{key}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    "aa_#{sanitize_key(prefix)}_#{digest}"
  end

  defp stable_sequence_id(key) do
    digest =
      :crypto.hash(:sha256, "sequence:#{key}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    "aa_seq_#{digest}"
  end

  defp stabilize_rules(rules, screen_key) do
    rules
    |> Enum.with_index()
    |> Enum.map(fn {rule, index} ->
      id = stable_id("rule", "#{screen_key}_#{index}")

      rule
      |> Map.put("id", id)
      |> put_in(["event", "type"], id)
      |> stabilize_actions(screen_key, index)
    end)
  end

  defp stabilize_actions(rule, screen_key, rule_index) do
    update_in(rule, ["event", "params", "actions"], fn actions ->
      actions
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"type" => "feedback"} = action, action_index} ->
          action_id = stable_id("feedback", "#{screen_key}_#{rule_index}_#{action_index}")

          action
          |> put_in(["params", "id"], action_id)
          |> update_in(["params", "feedback", "partsLayout"], fn parts ->
            parts
            |> List.wrap()
            |> Enum.with_index()
            |> Enum.map(fn {part, part_index} ->
              Map.put(part, "id", "#{action_id}_part_#{part_index}")
            end)
          end)

        {action, _action_index} ->
          action
      end)
    end)
  end

  defp required_variables(rules, _screen) do
    rule_facts =
      rules
      |> collect_values("fact")
      |> Enum.filter(&is_binary/1)

    rule_facts |> Enum.uniq() |> Enum.sort()
  end

  defp collect_values(value, key) when is_map(value) do
    Enum.flat_map(value, fn
      {^key, found} -> [found]
      {_other, nested} -> collect_values(nested, key)
    end)
  end

  defp collect_values(value, key) when is_list(value),
    do: Enum.flat_map(value, &collect_values(&1, key))

  defp collect_values(_value, _key), do: []

  defp objective_keys_by_screen(objectives) do
    mapped =
      objectives
      |> Map.get("mapped", [])
      |> Enum.map(fn objective ->
        id = objective["objectiveId"] || objective["id"]
        {"objective_#{id}", objective["screenKeys"] || []}
      end)

    proposed =
      objectives
      |> Map.get("proposed", [])
      |> Enum.map(&{&1["key"], &1["screenKeys"] || []})

    Enum.reduce(mapped ++ proposed, %{}, fn {objective_key, screen_keys}, acc ->
      Enum.reduce(screen_keys, acc, fn screen_key, nested ->
        Map.update(nested, screen_key, [objective_key], &(&1 ++ [objective_key]))
      end)
    end)
  end

  defp put_css_class(part, class) when is_binary(class) and class != "" do
    update_in(part, ["custom", "customCssClass"], fn existing ->
      [existing, sanitize_key(class)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end)
  end

  defp put_css_class(part, _class), do: part

  defp maybe_mark_manual(part, %{"manualGrading" => true}) do
    put_in(part, ["custom", "requiresManualGrading"], true)
  end

  defp maybe_mark_manual(part, _interaction), do: part

  defp response_index(response, _options) when is_integer(response), do: response

  defp response_index(%{"index" => index}, _options) when is_integer(index), do: index

  defp response_index(response, options) when is_binary(response) do
    Enum.find_index(options, &(to_string(&1) == response)) || 0
  end

  defp response_index(_response, _options), do: 0

  defp response_value(%{"value" => value}), do: value
  defp response_value(value), do: value

  defp feedback_text(value, _default) when is_binary(value) and value != "", do: value
  defp feedback_text(%{"message" => message}, default), do: feedback_text(message, default)
  defp feedback_text(_value, default), do: default

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_map(content) do
    content["text"] || content["value"] || content["label"] || ""
  end

  defp content_text(_content), do: ""

  defp table_text(%{"rows" => rows}) when is_list(rows) do
    Enum.map_join(rows, "\n", fn
      row when is_list(row) -> Enum.map_join(row, " | ", &to_string/1)
      row -> to_string(row)
    end)
  end

  defp table_text(content), do: content_text(content)

  defp heading_tag(tag) when tag in ["h1", :h1], do: :h1
  defp heading_tag(tag) when tag in ["h2", :h2], do: :h2
  defp heading_tag(tag) when tag in ["h3", :h3], do: :h3
  defp heading_tag(tag) when tag in ["h4", :h4], do: :h4
  defp heading_tag(tag) when tag in ["h5", :h5], do: :h5
  defp heading_tag(tag) when tag in ["h6", :h6], do: :h6
  defp heading_tag(_tag), do: :p

  defp text_height(:h1), do: 48
  defp text_height(:h2), do: 44
  defp text_height(:h3), do: 40
  defp text_height(:h4), do: 36
  defp text_height(:h5), do: 32
  defp text_height(:h6), do: 28
  defp text_height(_), do: 108

  defp list_height(items), do: max(length(items) * 28, 48)

  defp layout_height(layout, fallback, "pixel"),
    do: positive_number(layout["height"], fallback)

  defp layout_height(_layout, fallback, _mode), do: fallback

  defp positive_number(value, _default) when is_number(value) and value > 0, do: value
  defp positive_number(_value, default), do: default

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_map(_map), do: %{}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp safe_media_url?("staged://" <> object_id), do: present?(object_id)
  defp safe_media_url?("/" <> path), do: present?(path)

  defp safe_media_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp safe_media_url?(_url), do: false

  defp safe_external_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp safe_external_url?(_url), do: false

  defp sanitize_key(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "lesson"
      sanitized -> sanitized
    end
  end

  defp error(path, code, message) do
    %{"path" => path, "code" => code, "message" => message}
  end
end
