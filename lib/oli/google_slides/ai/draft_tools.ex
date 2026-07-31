defmodule Oli.GoogleSlides.AI.DraftTools do
  @moduledoc """
  Tool definitions and a pure dispatcher for semantic lesson-draft operations.

  The workflow owns loading and persisting a draft around `call/3`. The
  dispatcher deliberately has no repository, editor, media, or network access.
  """

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.AI.LessonPlan

  @batch_operations ~w(
    create_lesson_draft
    add_screen
    add_content_part
    add_media_part
    add_interaction
    set_interaction_response
    set_feedback
    set_adaptivity
    declare_variable
    map_objective
    propose_objective
    set_layout
    set_style_rules
    add_assumption
  )
  @max_batch_operations 120

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "create_lesson_draft",
        desc: "Create the one-lesson semantic draft before adding screens",
        schema:
          object_schema(
            %{
              "title" => string_property("Lesson title"),
              "presentationId" => string_property("Google Slides presentation identifier"),
              "fingerprint" => string_property("Immutable source snapshot fingerprint"),
              "url" => string_property("Original Google Slides URL")
            },
            ["presentationId", "fingerprint"]
          )
      },
      %{
        name: "add_screen",
        desc: "Add a semantic adaptive screen with Google Slides provenance",
        schema:
          object_schema(
            %{
              "key" => key_property("Stable screen key"),
              "title" => string_property("Screen title"),
              "sourceRefs" => source_refs_property()
            },
            ["key", "title", "sourceRefs"]
          )
      },
      %{
        name: "add_content_part",
        desc:
          "Add source-grounded text, list, table, chart, shape, line, word art, or iframe content",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "key" => key_property("Stable part key"),
              "kind" =>
                enum_property(
                  "Semantic content kind",
                  ~w(text list table chart word_art shape line iframe)
                ),
              "content" => object_property("Structured content payload"),
              "sourceRefs" => source_refs_property(),
              "altText" =>
                string_property(
                  "Reviewed alt text when chart, shape, line, or word art is rendered as an image"
                ),
              "layout" => object_property("Semantic or source geometry"),
              "styleTarget" => key_property("Optional semantic style class")
            },
            ["screenKey", "key", "kind", "content", "sourceRefs"]
          )
      },
      %{
        name: "add_media_part",
        desc: "Add source-grounded image, audio, or video metadata without ingesting the media",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "key" => key_property("Stable media part key"),
              "kind" => enum_property("Media kind", ~w(image audio video)),
              "sourceObjectId" => string_property("Object identifier in the source deck"),
              "sourceUrl" =>
                string_property(
                  "Absolute source URL explicitly present in the deck; required for linked audio"
                ),
              "sourceRefs" => source_refs_property(),
              "altText" => string_property("Reviewed image alternative text"),
              "captionTrackUrl" =>
                string_property("Absolute HTTPS URL for a reviewed WebVTT caption track"),
              "transcript" => string_property("Transcript reference or content"),
              "layout" => object_property("Semantic or source geometry")
            },
            ["screenKey", "key", "kind", "sourceRefs"]
          )
      },
      %{
        name: "add_interaction",
        desc: "Add an interaction explicitly established by the source deck",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "key" => key_property("Stable interaction key"),
              "componentKey" => string_property("Reviewed semantic component key"),
              "explicit" => %{
                "type" => "boolean",
                "description" => "Must be true only when the deck establishes the interaction"
              },
              "sourceEvidence" => source_refs_property(),
              "prompt" => string_property("Interaction prompt"),
              "configuration" => interaction_configuration_property(),
              "correctResponse" => %{
                "description" =>
                  "Correct response only when explicitly established by the source evidence"
              },
              "correctResponseEvidence" =>
                source_refs_property(
                  "Exact source excerpt that states or marks the correct response"
                ),
              "manualGrading" => %{"type" => "boolean"},
              "scoring" =>
                object_schema(
                  %{
                    "mode" =>
                      enum_property(
                        "Scoring mode; v1 imports create ungraded lessons",
                        ["formative"]
                      ),
                    "points" => %{"type" => "number", "minimum" => 0}
                  },
                  ["mode", "points"]
                )
            },
            ["screenKey", "key", "componentKey", "explicit", "sourceEvidence"]
          )
      },
      %{
        name: "set_interaction_response",
        desc:
          "Set a source-grounded correct response; author-entered answers are handled outside model tools",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "interactionKey" => key_property("Existing interaction key"),
              "correctResponse" => %{"description" => "Source-grounded correct response"},
              "correctResponseEvidence" =>
                source_refs_property(
                  "Exact source excerpt that states or marks the correct response"
                )
            },
            [
              "screenKey",
              "interactionKey",
              "correctResponse",
              "correctResponseEvidence"
            ]
          )
      },
      %{
        name: "set_feedback",
        desc: "Set static feedback and optional author-gated runtime AI feedback metadata",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "interactionKey" => key_property("Existing interaction key"),
              "static" =>
                object_schema(
                  %{
                    "correct" => string_property("Feedback for a correct response"),
                    "incorrect" => string_property("Feedback for an incorrect response"),
                    "blank" => string_property("Optional feedback for an empty response"),
                    "fallback" => string_property("Optional static runtime-AI fallback")
                  },
                  ["correct", "incorrect"]
                ),
              "runtimeAi" =>
                object_schema(
                  %{
                    "recommended" => %{"type" => "boolean"},
                    "enabled" => %{"type" => "boolean"},
                    "staticFallbackKey" => string_property("Key in static feedback"),
                    "prompt" => string_property("Focused learner-feedback prompt")
                  },
                  []
                )
            },
            ["screenKey", "interactionKey", "static"]
          )
      },
      %{
        name: "set_adaptivity",
        desc: "Replace a screen's semantic adaptivity rules",
        schema:
          object_schema(
            %{
              "screenKey" => key_property("Existing screen key"),
              "rules" => %{
                "type" => "array",
                "maxItems" => 40,
                "items" => adaptivity_rule_property()
              }
            },
            ["screenKey", "rules"]
          )
      },
      %{
        name: "declare_variable",
        desc: "Declare a semantic lesson variable without generating runtime fact paths",
        schema:
          object_schema(
            %{
              "key" => key_property("Stable variable key"),
              "type" => enum_property("Variable type", ~w(boolean string number integer)),
              "initialValue" => %{"description" => "Initial value"},
              "purpose" => string_property("Instructional purpose"),
              "sourceRefs" => source_refs_property()
            },
            ["key", "type", "initialValue", "purpose", "sourceRefs"]
          )
      },
      %{
        name: "map_objective",
        desc: "Map lesson screens to an existing project objective",
        schema:
          object_schema(
            %{
              "objectiveId" => string_property("Existing objective resource identifier"),
              "title" => string_property("Existing objective title"),
              "screenKeys" => array_of_strings("Mapped screen keys"),
              "sourceRefs" => source_refs_property()
            },
            ["objectiveId", "screenKeys"]
          )
      },
      %{
        name: "propose_objective",
        desc: "Propose a new objective; unconfirmed proposals create an author blocker",
        schema:
          object_schema(
            %{
              "key" => key_property("Stable proposed objective key"),
              "title" => string_property("Proposed objective title"),
              "description" => string_property("Proposed objective description"),
              "screenKeys" => array_of_strings("Mapped screen keys"),
              "sourceRefs" => source_refs_property(),
              "confirmed" => %{"type" => "boolean"}
            },
            ["key", "title", "screenKeys", "sourceRefs"]
          )
      },
      %{
        name: "set_layout",
        desc: "Choose responsive or pixel layout and a reviewed style profile",
        schema:
          object_schema(
            %{
              "mode" => enum_property("Layout mode", ~w(responsive pixel)),
              "styleProfile" => string_property("Reviewed catalog style profile"),
              "canvas" =>
                object_property("Required source canvas width and height for pixel mode")
            },
            ["mode", "styleProfile"]
          )
      },
      %{
        name: "set_style_rules",
        desc: "Replace lesson-scoped structured style declarations; raw CSS is not accepted",
        schema:
          object_schema(
            %{
              "rules" => %{
                "type" => "array",
                "items" =>
                  object_schema(
                    %{
                      "target" => key_property("Semantic class target, never a selector"),
                      "declarations" => object_property("Allowlisted CSS property values")
                    },
                    ["target", "declarations"]
                  )
              }
            },
            ["rules"]
          )
      },
      %{
        name: "add_assumption",
        desc: "Record a safe, reviewable import assumption with provenance",
        schema:
          object_schema(
            %{
              "key" => key_property("Stable assumption key"),
              "message" => string_property("Assumption shown during plan review"),
              "sourceRefs" => source_refs_property()
            },
            ["key", "message"]
          )
      },
      %{
        name: "apply_draft_operations",
        desc:
          "Apply an ordered batch of semantic draft operations in one tool call to reduce planning round trips",
        schema:
          object_schema(
            %{
              "operations" => %{
                "type" => "array",
                "minItems" => 1,
                "maxItems" => @max_batch_operations,
                "items" =>
                  object_schema(
                    %{
                      "name" => enum_property("Semantic draft operation", @batch_operations),
                      "arguments" => object_property("Arguments for the named operation")
                    },
                    ["name", "arguments"]
                  )
              }
            },
            ["operations"]
          )
      },
      %{
        name: "validate_lesson_draft",
        desc: "Validate the current semantic draft without changing it",
        schema: object_schema(%{}, [])
      },
      %{
        name: "finalize_lesson_plan",
        desc: "Strictly validate and mark the approved semantic plan finalized",
        schema: object_schema(%{}, [])
      }
    ]
  end

  @spec definition(String.t()) :: map() | nil
  def definition(name) when is_binary(name), do: Enum.find(definitions(), &(&1.name == name))
  def definition(_name), do: nil

  @spec call(String.t(), LessonPlan.t() | nil, map()) ::
          {:ok, LessonPlan.t()} | {:error, [LessonPlan.validation_error()]}
  def call("create_lesson_draft", _plan, args), do: Draft.create_lesson(args)

  def call("add_screen", plan, args), do: Draft.add_screen(plan, args)

  def call("add_content_part", plan, args),
    do: Draft.add_content_part(plan, required(args, "screenKey"), args)

  def call("add_media_part", plan, args),
    do: Draft.add_media_part(plan, required(args, "screenKey"), args)

  def call("add_interaction", plan, args),
    do: Draft.add_interaction(plan, required(args, "screenKey"), args)

  def call("set_interaction_response", plan, args) do
    Draft.set_interaction_response(
      plan,
      required(args, "screenKey"),
      required(args, "interactionKey"),
      required(args, "correctResponse"),
      required(args, "correctResponseEvidence", [])
    )
  end

  def call("set_feedback", plan, args) do
    Draft.set_feedback(
      plan,
      required(args, "screenKey"),
      required(args, "interactionKey"),
      args
    )
  end

  def call("set_adaptivity", plan, args),
    do: Draft.set_adaptivity(plan, required(args, "screenKey"), required(args, "rules"))

  def call("declare_variable", plan, args), do: Draft.declare_variable(plan, args)
  def call("map_objective", plan, args), do: Draft.map_objective(plan, args)
  def call("propose_objective", plan, args), do: Draft.propose_objective(plan, args)

  def call("set_layout", plan, args), do: Draft.set_layout(plan, args)

  def call("set_style_rules", plan, args),
    do: Draft.set_style_rules(plan, required(args, "rules"))

  def call("add_assumption", plan, args), do: Draft.add_assumption(plan, args)

  def call("apply_draft_operations", plan, args) do
    case required(args, "operations") do
      operations
      when is_list(operations) and operations != [] and
             length(operations) <= @max_batch_operations ->
        operations
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, plan}, fn {operation, index}, {:ok, current_plan} ->
          operation = stringify_keys(operation)
          name = operation["name"]
          operation_args = operation["arguments"]

          cond do
            name not in @batch_operations ->
              {:halt,
               invalid_batch_operation(index, "operation is not available in a draft batch")}

            name == "create_lesson_draft" and not is_nil(current_plan) ->
              {:halt,
               invalid_batch_operation(
                 index,
                 "create_lesson_draft can only be the first operation for a new draft"
               )}

            not is_map(operation_args) ->
              {:halt, invalid_batch_operation(index, "operation arguments must be an object")}

            true ->
              case call(name, current_plan, operation_args) do
                {:ok, updated_plan} -> {:cont, {:ok, updated_plan}}
                {:error, errors} -> {:halt, {:error, prefix_batch_errors(errors, index)}}
              end
          end
        end)

      _ ->
        invalid_arguments(
          "operations",
          "operations must contain between 1 and #{@max_batch_operations} entries"
        )
    end
  end

  def call("validate_lesson_draft", plan, _args), do: LessonPlan.validate(plan)
  def call("finalize_lesson_plan", plan, _args), do: Draft.finalize_lesson_plan(plan)

  def call(name, _plan, _args) do
    {:error,
     [
       %{
         "path" => "tool",
         "code" => "unknown_tool",
         "message" => "semantic draft tool #{inspect(name)} is not registered"
       }
     ]}
  end

  defp required(args, key, default \\ nil)

  defp required(args, key, default) when is_map(args) do
    Map.get(args, key, Map.get(args, known_atom_key(key), default))
  end

  defp required(_args, _key, default), do: default

  defp known_atom_key("screenKey"), do: :screenKey
  defp known_atom_key("interactionKey"), do: :interactionKey
  defp known_atom_key("correctResponse"), do: :correctResponse
  defp known_atom_key("correctResponseEvidence"), do: :correctResponseEvidence
  defp known_atom_key("rules"), do: :rules
  defp known_atom_key("operations"), do: :operations

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp string_property(description),
    do: %{"type" => "string", "description" => description}

  defp key_property(description) do
    %{
      "type" => "string",
      "pattern" => "^[a-z][a-z0-9_-]{0,63}$",
      "description" => description
    }
  end

  defp enum_property(description, values) do
    %{"type" => "string", "enum" => values, "description" => description}
  end

  defp object_property(description),
    do: %{"type" => "object", "description" => description}

  defp interaction_configuration_property do
    %{
      "type" => "object",
      "description" =>
        "Use choices for multiple_choice; optionLabels for dropdown; sliderOptionLabels for text_slider; min/max/step for slider; src for iframe",
      "properties" => %{
        "choices" => array_of_strings("Multiple-choice labels"),
        "optionLabels" => array_of_strings("Dropdown labels"),
        "sliderOptionLabels" => array_of_strings("Text-slider labels"),
        "min" => %{"type" => "number"},
        "max" => %{"type" => "number"},
        "step" => %{"type" => "number", "exclusiveMinimum" => 0},
        "src" => string_property("Absolute HTTPS iframe URL"),
        "label" => string_property("Visible input label"),
        "unitsLabel" => string_property("Optional numeric units")
      },
      "additionalProperties" => false
    }
  end

  defp adaptivity_rule_property do
    object_schema(
      %{
        "key" => key_property("Stable rule key"),
        "condition" =>
          object_schema(
            %{
              "outcome" => enum_property("Evaluated outcome", ~w(correct incorrect)),
              "interactionKey" => key_property("Interaction on this screen"),
              "option" => %{"description" => "Explicit incorrect option for specific feedback"}
            },
            ["outcome"]
          ),
        "action" =>
          object_schema(
            %{
              "type" =>
                enum_property(
                  "Semantic action",
                  ~w(navigate feedback set_variable increment_variable)
                ),
              "target" => string_property("next or another lesson screen key"),
              "message" => string_property("Specific feedback message"),
              "variableKey" => key_property("Declared lesson variable"),
              "value" => %{"description" => "Typed variable value or increment amount"}
            },
            ["type"]
          ),
        "maxAttempt" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 10
        },
        "sourceRefs" => source_refs_property()
      },
      ["key", "condition", "action", "sourceRefs"]
    )
  end

  defp array_of_strings(description) do
    %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => description
    }
  end

  defp prefix_batch_errors(errors, index) when is_list(errors) do
    Enum.map(errors, fn error ->
      Map.update(error, "path", "operations[#{index}]", fn path ->
        "operations[#{index}].#{path}"
      end)
    end)
  end

  defp prefix_batch_errors(reason, index) do
    [
      %{
        "path" => "operations[#{index}]",
        "code" => "operation_failed",
        "message" => inspect(reason)
      }
    ]
  end

  defp invalid_batch_operation(index, message) do
    {:error,
     [
       %{
         "path" => "operations[#{index}]",
         "code" => "invalid_batch_operation",
         "message" => message
       }
     ]}
  end

  defp invalid_arguments(path, message) do
    {:error, [%{"path" => path, "code" => "invalid_arguments", "message" => message}]}
  end

  defp source_refs_property(description \\ "Source slide/object provenance") do
    %{
      "type" => "array",
      "minItems" => 1,
      "description" => description,
      "items" => %{
        "type" => "object",
        "properties" => %{
          "slideId" => %{"type" => "string"},
          "slideIndex" => %{"type" => "integer"},
          "objectId" => %{"type" => "string"},
          "evidence" => %{"type" => "string"}
        },
        "additionalProperties" => false
      }
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
