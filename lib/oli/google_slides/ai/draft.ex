defmodule Oli.GoogleSlides.AI.Draft do
  @moduledoc """
  Pure semantic operations used to assemble a Google Slides lesson draft.

  Every operation returns a new `LessonPlan` map. These functions never call
  authoring editors, create resources, upload media, or otherwise mutate a
  project.
  """

  alias Oli.GoogleSlides.AI.Catalog
  alias Oli.GoogleSlides.AI.CSSCompiler
  alias Oli.GoogleSlides.AI.LessonPlan

  @media_kinds ~w(image audio video)
  @variable_types ~w(boolean string number integer)

  @type result :: {:ok, LessonPlan.t()} | {:error, [LessonPlan.validation_error()]}

  @spec create_lesson(map()) :: result()
  def create_lesson(attrs \\ %{}), do: LessonPlan.new(attrs)

  @spec add_screen(LessonPlan.t(), map()) :: result()
  def add_screen(plan, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    screen = %{
      "key" => attrs["key"],
      "title" => attrs["title"],
      "sourceRefs" => source_refs(attrs["sourceRefs"]),
      "parts" => [],
      "interactions" => [],
      "adaptivity" => []
    }

    update_draft(plan, fn normalized ->
      update_in(normalized, ["lesson", "screens"], &(&1 ++ [screen]))
    end)
  end

  def add_screen(_plan, _attrs),
    do: invalid_arguments("screen", "screen attributes must be an object")

  @spec add_content_part(LessonPlan.t(), String.t(), map()) :: result()
  def add_content_part(plan, screen_key, attrs)
      when is_binary(screen_key) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = normalize_kind(attrs["kind"] || "text")

    cond do
      not Catalog.supported_content_part?(kind) ->
        invalid_arguments("part.kind", "content part kind is not in the reviewed catalog")

      kind in @media_kinds ->
        add_media_part(plan, screen_key, Map.put(attrs, "kind", kind))

      true ->
        part =
          %{
            "key" => attrs["key"],
            "kind" => kind,
            "content" => attrs["content"] || %{},
            "sourceRefs" => source_refs(attrs["sourceRefs"]),
            "accessibility" =>
              attrs
              |> Map.get("accessibility", %{})
              |> stringify_keys()
              |> put_present("altText", attrs["altText"]),
            "layout" => attrs["layout"] || %{}
          }
          |> put_present("styleTarget", attrs["styleTarget"])

        with {:ok, updated} <- append_to_screen(plan, screen_key, "parts", part) do
          {:ok, maybe_add_graphic_blocker(updated, screen_key, part)}
        end
    end
  end

  def add_content_part(_plan, _screen_key, _attrs),
    do: invalid_arguments("part", "screen key and part attributes are required")

  @spec add_media_part(LessonPlan.t(), String.t(), map()) :: result()
  def add_media_part(plan, screen_key, attrs)
      when is_binary(screen_key) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = normalize_kind(attrs["kind"] || attrs["mediaType"])

    cond do
      kind not in @media_kinds ->
        invalid_arguments("part.kind", "media kind must be image, audio, or video")

      source_refs(attrs["sourceRefs"]) == [] ->
        invalid_arguments("part.sourceRefs", "media must include source provenance")

      kind in ["image", "video"] and not present?(attrs["sourceObjectId"]) ->
        invalid_arguments(
          "part.sourceObjectId",
          "#{kind} media must identify an object in the source deck"
        )

      kind == "audio" and not safe_https_url?(attrs["sourceUrl"]) ->
        invalid_arguments(
          "part.sourceUrl",
          "linked audio must use an absolute HTTPS URL present in the source deck"
        )

      present?(attrs["captionTrackUrl"]) and not safe_https_url?(attrs["captionTrackUrl"]) ->
        invalid_arguments(
          "part.captionTrackUrl",
          "caption tracks must use an absolute HTTPS URL"
        )

      true ->
        accessibility =
          attrs
          |> Map.get("accessibility", %{})
          |> stringify_keys()
          |> put_present("altText", attrs["altText"])
          |> put_present("captions", attrs["captionTrackUrl"])
          |> put_present("transcript", attrs["transcript"])

        content =
          attrs
          |> Map.get("content", %{})
          |> stringify_keys()
          |> put_present("sourceObjectId", attrs["sourceObjectId"])
          |> put_present("src", attrs["sourceUrl"])
          |> put_present("mimeType", attrs["mimeType"])

        part =
          %{
            "key" => attrs["key"],
            "kind" => kind,
            "content" => content,
            "sourceRefs" => source_refs(attrs["sourceRefs"]),
            "accessibility" => accessibility,
            "layout" => attrs["layout"] || %{}
          }
          |> put_present("styleTarget", attrs["styleTarget"])

        with {:ok, updated} <- append_to_screen(plan, screen_key, "parts", part) do
          updated =
            updated
            |> maybe_add_media_blocker(screen_key, part)
            |> maybe_add_transcript_warning(screen_key, part)

          {:ok, updated}
        end
    end
  end

  def add_media_part(_plan, _screen_key, _attrs),
    do: invalid_arguments("part", "screen key and media attributes are required")

  @spec add_interaction(LessonPlan.t(), String.t(), map()) :: result()
  def add_interaction(plan, screen_key, attrs)
      when is_binary(screen_key) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    component_key = attrs["componentKey"] || attrs["component"]
    target = interaction_target(screen_key, attrs["key"])

    cond do
      attrs["explicit"] != true ->
        invalid_arguments(
          "interaction.explicit",
          "the source deck must explicitly establish every interaction"
        )

      source_refs(attrs["sourceEvidence"]) == [] ->
        invalid_arguments(
          "interaction.sourceEvidence",
          "an explicit interaction must include source evidence"
        )

      true ->
        case Catalog.normalize_component_key(component_key) do
          {:error, :unsupported_component} ->
            with {:ok, normalized} <- ensure_draft(plan),
                 :ok <- ensure_screen(normalized, screen_key) do
              blocker = %{
                "code" => "unsupported_component",
                "target" => target,
                "message" =>
                  "The source requests unsupported component #{inspect(component_key)}",
                "sourceRefs" => source_refs(attrs["sourceEvidence"]),
                "details" => %{
                  "requestedComponent" => component_key,
                  "interaction" => attrs
                }
              }

              {:ok, LessonPlan.put_blocker(normalized, blocker)}
            end

          {:ok, canonical_component} ->
            {correct_response, correct_response_source, correct_response_evidence} =
              source_grounded_correct_response(attrs, canonical_component)

            interaction =
              %{
                "key" => attrs["key"],
                "componentKey" => canonical_component,
                "explicit" => true,
                "sourceEvidence" => source_refs(attrs["sourceEvidence"]),
                "prompt" => attrs["prompt"],
                "configuration" => attrs["configuration"] || %{},
                "correctResponse" => correct_response,
                "correctResponseSource" => correct_response_source,
                "correctResponseEvidence" => correct_response_evidence,
                "manualGrading" => attrs["manualGrading"] == true,
                "scoring" => normalize_scoring(attrs["scoring"]),
                "feedback" => empty_feedback(),
                "status" => "ready"
              }

            with {:ok, updated} <-
                   append_to_screen(plan, screen_key, "interactions", interaction) do
              updated =
                if Catalog.automatically_evaluated?(canonical_component) and
                     interaction["manualGrading"] != true and
                     is_nil(interaction["correctResponse"]) do
                  LessonPlan.put_blocker(updated, %{
                    "code" => "missing_correct_response",
                    "target" => target,
                    "message" => "Confirm the correct response for this interaction",
                    "sourceRefs" => interaction["sourceEvidence"]
                  })
                else
                  updated
                end

              {:ok, updated}
            end
        end
    end
  end

  def add_interaction(_plan, _screen_key, _attrs),
    do: invalid_arguments("interaction", "screen key and interaction attributes are required")

  @spec set_interaction_response(
          LessonPlan.t(),
          String.t(),
          String.t(),
          term(),
          [map()]
        ) :: result()
  def set_interaction_response(plan, screen_key, interaction_key, response, evidence)
      when is_binary(screen_key) and is_binary(interaction_key) and is_list(evidence) do
    update_interaction(plan, screen_key, interaction_key, fn interaction ->
      interaction
      |> Map.put("correctResponse", response)
      |> Map.put("correctResponseSource", "source_evidence")
      |> Map.put("correctResponseEvidence", source_refs(evidence))
    end)
    |> resolve_on_success(
      "missing_correct_response:#{interaction_target(screen_key, interaction_key)}"
    )
  end

  @spec record_author_correct_response(
          LessonPlan.t(),
          String.t(),
          String.t(),
          term()
        ) :: result()
  def record_author_correct_response(plan, screen_key, interaction_key, response)
      when is_binary(screen_key) and is_binary(interaction_key) do
    update_interaction(plan, screen_key, interaction_key, fn interaction ->
      interaction
      |> Map.put("correctResponse", response)
      |> Map.put("correctResponseSource", "author_answer")
      |> Map.put("correctResponseEvidence", [])
    end)
    |> resolve_on_success(
      "missing_correct_response:#{interaction_target(screen_key, interaction_key)}"
    )
  end

  @spec set_feedback(LessonPlan.t(), String.t(), String.t(), map()) :: result()
  def set_feedback(plan, screen_key, interaction_key, attrs)
      when is_binary(screen_key) and is_binary(interaction_key) and is_map(attrs) do
    attrs = stringify_keys(attrs)
    static = attrs |> Map.get("static", %{}) |> stringify_keys()

    target = interaction_target(screen_key, interaction_key)

    with {:ok, normalized} <- ensure_draft(plan),
         {:ok, _screen_index, screen} <- find_screen(normalized, screen_key),
         {:ok, interaction_index} <- find_interaction(screen, interaction_key) do
      existing_runtime_ai =
        screen
        |> get_in(["interactions", Access.at(interaction_index), "feedback", "runtimeAi"])
        |> stringify_keys()

      # `authorOptIn` is a trusted workflow decision, not model-authored plan
      # content. Preserve an existing trusted answer and ignore any value the
      # semantic tool call tries to assert.
      runtime_ai =
        empty_feedback()["runtimeAi"]
        |> Map.merge(attrs |> Map.get("runtimeAi", %{}) |> stringify_keys())
        |> Map.put("authorOptIn", existing_runtime_ai["authorOptIn"] == true)
        |> Map.put("optInSource", existing_runtime_ai["optInSource"])

      feedback = %{"static" => static, "runtimeAi" => runtime_ai}

      with {:ok, updated} <-
             update_interaction(normalized, screen_key, interaction_key, fn interaction ->
               Map.put(interaction, "feedback", feedback)
             end) do
        updated =
          updated
          |> LessonPlan.resolve_blocker("runtime_ai_opt_in:#{target}")
          |> LessonPlan.resolve_blocker("runtime_ai_static_fallback:#{target}")
          |> LessonPlan.resolve_blocker("runtime_ai_prompt:#{target}")
          |> maybe_add_runtime_ai_blockers(target, feedback)

        {:ok, updated}
      end
    end
  end

  def set_feedback(_plan, _screen_key, _interaction_key, _attrs),
    do: invalid_arguments("feedback", "screen key, interaction key, and feedback are required")

  @spec set_adaptivity(LessonPlan.t(), String.t(), map() | [map()]) :: result()
  def set_adaptivity(plan, screen_key, rule_or_rules) when is_binary(screen_key) do
    rules =
      case rule_or_rules do
        rules when is_list(rules) -> Enum.map(rules, &stringify_keys/1)
        rule when is_map(rule) -> [stringify_keys(rule)]
        _ -> :invalid
      end

    case rules do
      :invalid ->
        invalid_arguments("adaptivity", "adaptivity must be a rule object or list of rules")

      rules ->
        update_screen(plan, screen_key, &Map.put(&1, "adaptivity", rules))
    end
  end

  @spec declare_variable(LessonPlan.t(), map()) :: result()
  def declare_variable(plan, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    type = attrs["type"] || infer_variable_type(attrs["initialValue"])

    if type in @variable_types do
      variable =
        %{
          "key" => attrs["key"],
          "type" => type,
          "initialValue" => attrs["initialValue"],
          "purpose" => attrs["purpose"],
          "sourceRefs" => source_refs(attrs["sourceRefs"])
        }

      update_draft(plan, fn normalized ->
        Map.update!(normalized, "variables", &(&1 ++ [variable]))
      end)
    else
      invalid_arguments(
        "variable.type",
        "variable type must be boolean, string, number, or integer"
      )
    end
  end

  def declare_variable(_plan, _attrs),
    do: invalid_arguments("variable", "variable attributes must be an object")

  @spec map_objective(LessonPlan.t(), map()) :: result()
  def map_objective(plan, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    objective = %{
      "objectiveId" => attrs["objectiveId"] || attrs["id"],
      "title" => attrs["title"],
      "screenKeys" => attrs["screenKeys"] || [],
      "sourceRefs" => source_refs(attrs["sourceRefs"])
    }

    update_draft(plan, fn normalized ->
      update_in(normalized, ["objectives", "mapped"], &(&1 ++ [objective]))
    end)
  end

  def map_objective(_plan, _attrs),
    do: invalid_arguments("objective", "objective attributes must be an object")

  @spec propose_objective(LessonPlan.t(), map()) :: result()
  def propose_objective(plan, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    objective = %{
      "key" => attrs["key"],
      "title" => attrs["title"],
      "description" => attrs["description"],
      "screenKeys" => attrs["screenKeys"] || [],
      "sourceRefs" => source_refs(attrs["sourceRefs"]),
      "confirmed" => false,
      "confirmationSource" => nil
    }

    with {:ok, updated} <-
           update_draft(plan, fn normalized ->
             update_in(normalized, ["objectives", "proposed"], &(&1 ++ [objective]))
           end) do
      {:ok,
       LessonPlan.put_blocker(updated, %{
         "code" => "objective_confirmation",
         "target" => "objective:#{objective["key"]}",
         "message" => "Confirm creation of the proposed objective #{inspect(objective["title"])}",
         "sourceRefs" => objective["sourceRefs"]
       })}
    end
  end

  def propose_objective(_plan, _attrs),
    do: invalid_arguments("objective", "objective attributes must be an object")

  @spec confirm_objective(LessonPlan.t(), String.t()) :: result()
  def confirm_objective(plan, objective_key) when is_binary(objective_key) do
    with {:ok, normalized} <- ensure_draft(plan) do
      proposed = normalized["objectives"]["proposed"]

      case Enum.find_index(proposed, &(&1["key"] == objective_key)) do
        nil ->
          not_found("objective", objective_key)

        index ->
          updated =
            normalized
            |> put_in(
              ["objectives", "proposed", Access.at(index), "confirmed"],
              true
            )
            |> put_in(
              ["objectives", "proposed", Access.at(index), "confirmationSource"],
              "author_answer"
            )
            |> LessonPlan.resolve_blocker("objective_confirmation:objective:#{objective_key}")

          LessonPlan.validate(updated)
      end
    end
  end

  @doc """
  Records the author's explicit runtime-AI feedback decision.

  This operation is intentionally not exposed in `DraftTools`; only the trusted
  workflow answer resolver may call it.
  """
  @spec record_runtime_ai_opt_in(
          LessonPlan.t(),
          String.t(),
          String.t(),
          boolean()
        ) :: result()
  def record_runtime_ai_opt_in(plan, screen_key, interaction_key, enabled)
      when is_binary(screen_key) and is_binary(interaction_key) and is_boolean(enabled) do
    target = interaction_target(screen_key, interaction_key)

    with {:ok, updated} <-
           update_interaction(plan, screen_key, interaction_key, fn interaction ->
             update_in(interaction, ["feedback", "runtimeAi"], fn runtime_ai ->
               runtime_ai
               |> stringify_keys()
               |> Map.put("authorOptIn", enabled)
               |> Map.put("optInSource", if(enabled, do: "author_answer", else: nil))
               |> then(fn runtime_ai ->
                 if enabled, do: runtime_ai, else: Map.put(runtime_ai, "enabled", false)
               end)
             end)
           end) do
      updated =
        updated
        |> LessonPlan.resolve_blocker("runtime_ai_opt_in:#{target}")
        |> then(fn updated ->
          if enabled do
            maybe_add_runtime_ai_blockers(
              updated,
              target,
              interaction_feedback(updated, screen_key, interaction_key)
            )
          else
            updated
            |> LessonPlan.resolve_blocker("runtime_ai_static_fallback:#{target}")
            |> LessonPlan.resolve_blocker("runtime_ai_prompt:#{target}")
          end
        end)

      LessonPlan.validate(updated)
    end
  end

  @spec set_layout(LessonPlan.t(), map()) :: result()
  def set_layout(plan, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    mode = attrs["mode"] || "responsive"
    profile_key = attrs["styleProfile"] || "torus-default"

    with true <- mode in ~w(responsive pixel),
         {:ok, profile} <- Catalog.style_profile(profile_key),
         {:ok, updated} <-
           update_draft(plan, fn normalized ->
             canvas = if mode == "pixel", do: attrs["canvas"], else: nil

             layout =
               normalized["lesson"]["layout"]
               |> Map.put("mode", mode)
               |> Map.put("styleProfile", profile["key"])
               |> Map.put("canvas", canvas)

             put_in(normalized, ["lesson", "layout"], layout)
           end) do
      target = "layout.styleProfile"

      updated =
        updated
        |> LessonPlan.resolve_blocker("style_profile_confirmation:#{target}")
        |> maybe_add_profile_blocker(profile)

      {:ok, updated}
    else
      false ->
        invalid_arguments("layout.mode", "layout mode must be responsive or pixel")

      {:error, :unsupported_style_profile} ->
        invalid_arguments(
          "layout.styleProfile",
          "style profile is not in the reviewed catalog"
        )

      {:error, errors} when is_list(errors) ->
        {:error, errors}
    end
  end

  def set_layout(_plan, _attrs),
    do: invalid_arguments("layout", "layout attributes must be an object")

  @spec set_style_rules(LessonPlan.t(), [map()]) :: result()
  def set_style_rules(plan, rules) do
    with {:ok, normalized_rules} <- CSSCompiler.normalize(rules) do
      update_draft(plan, fn normalized ->
        put_in(normalized, ["lesson", "layout", "styleRules"], normalized_rules)
      end)
    end
  end

  @spec add_assumption(LessonPlan.t(), map()) :: result()
  def add_assumption(plan, attrs) when is_map(attrs) do
    update_draft(plan, &LessonPlan.put_assumption(&1, attrs))
  end

  def add_assumption(_plan, _attrs),
    do: invalid_arguments("assumption", "assumption attributes must be an object")

  @spec finalize_lesson_plan(LessonPlan.t()) :: result()
  def finalize_lesson_plan(plan), do: LessonPlan.finalize(plan)

  defp update_draft(plan, operation) do
    with {:ok, normalized} <- ensure_draft(plan) do
      normalized
      |> operation.()
      |> LessonPlan.validate()
    end
  end

  defp ensure_draft(plan) do
    with {:ok, normalized} <- LessonPlan.validate(plan) do
      if normalized["status"] == "draft" do
        {:ok, normalized}
      else
        invalid_arguments("status", "a finalized lesson plan cannot be changed")
      end
    end
  end

  defp append_to_screen(plan, screen_key, collection, value) do
    update_screen(plan, screen_key, fn screen ->
      Map.update!(screen, collection, &(&1 ++ [value]))
    end)
  end

  defp update_screen(plan, screen_key, operation) do
    with {:ok, normalized} <- ensure_draft(plan) do
      screens = normalized["lesson"]["screens"]

      case Enum.find_index(screens, &(&1["key"] == screen_key)) do
        nil ->
          not_found("screen", screen_key)

        index ->
          normalized
          |> update_in(["lesson", "screens", Access.at(index)], operation)
          |> LessonPlan.validate()
      end
    end
  end

  defp update_interaction(plan, screen_key, interaction_key, operation) do
    with {:ok, normalized} <- ensure_draft(plan),
         {:ok, screen_index, screen} <- find_screen(normalized, screen_key),
         {:ok, interaction_index} <- find_interaction(screen, interaction_key) do
      normalized
      |> update_in(
        [
          "lesson",
          "screens",
          Access.at(screen_index),
          "interactions",
          Access.at(interaction_index)
        ],
        operation
      )
      |> LessonPlan.validate()
    end
  end

  defp ensure_screen(plan, screen_key) do
    case find_screen(plan, screen_key) do
      {:ok, _index, _screen} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  defp find_screen(plan, screen_key) do
    screens = plan["lesson"]["screens"]

    case Enum.find_index(screens, &(&1["key"] == screen_key)) do
      nil -> not_found("screen", screen_key)
      index -> {:ok, index, Enum.at(screens, index)}
    end
  end

  defp find_interaction(screen, interaction_key) do
    case Enum.find_index(screen["interactions"], &(&1["key"] == interaction_key)) do
      nil -> not_found("interaction", interaction_key)
      index -> {:ok, index}
    end
  end

  defp interaction_feedback(plan, screen_key, interaction_key) do
    with {:ok, _screen_index, screen} <- find_screen(plan, screen_key),
         {:ok, interaction_index} <- find_interaction(screen, interaction_key) do
      get_in(screen, ["interactions", Access.at(interaction_index), "feedback"]) || %{}
    else
      _ -> %{}
    end
  end

  defp maybe_add_media_blocker(plan, screen_key, %{"kind" => "image"} = part) do
    if present?(part["accessibility"]["altText"]) do
      plan
    else
      LessonPlan.put_blocker(plan, %{
        "code" => "missing_alt_text",
        "target" => part_target(screen_key, part["key"]),
        "message" => "Image alt text must be reviewed before generation",
        "sourceRefs" => part["sourceRefs"]
      })
    end
  end

  defp maybe_add_media_blocker(plan, screen_key, %{"kind" => "video"} = part) do
    if present?(part["accessibility"]["captions"]) do
      plan
    else
      LessonPlan.put_blocker(plan, %{
        "code" => "missing_captions",
        "target" => part_target(screen_key, part["key"]),
        "message" =>
          "Enter an absolute HTTPS URL for a reviewed WebVTT caption track before generation",
        "sourceRefs" => part["sourceRefs"]
      })
    end
  end

  defp maybe_add_media_blocker(plan, screen_key, %{"kind" => "audio"} = part) do
    if present?(part["accessibility"]["transcript"]) do
      plan
    else
      LessonPlan.put_blocker(plan, %{
        "code" => "missing_transcript",
        "target" => part_target(screen_key, part["key"]),
        "message" => "An audio transcript is required before generation",
        "sourceRefs" => part["sourceRefs"]
      })
    end
  end

  defp maybe_add_media_blocker(plan, _screen_key, _part), do: plan

  defp maybe_add_graphic_blocker(
         plan,
         screen_key,
         %{"kind" => kind, "content" => %{"sourceObjectId" => object_id}} = part
       )
       when kind in ["chart", "shape", "line", "word_art"] and
              is_binary(object_id) and object_id != "" do
    if not graphic_requires_alt?(kind, part["content"]) or
         present?(part["accessibility"]["altText"]) do
      plan
    else
      LessonPlan.put_blocker(plan, %{
        "code" => "missing_alt_text",
        "target" => part_target(screen_key, part["key"]),
        "message" => "Graphic alt text must be reviewed before generation",
        "sourceRefs" => part["sourceRefs"]
      })
    end
  end

  defp maybe_add_graphic_blocker(plan, _screen_key, _part), do: plan

  defp graphic_requires_alt?("word_art", _content), do: false

  defp graphic_requires_alt?("shape", content),
    do: not present?(content["text"])

  defp graphic_requires_alt?(kind, _content), do: kind in ["chart", "line"]

  defp maybe_add_transcript_warning(plan, screen_key, %{"kind" => "video"} = part) do
    if present?(part["accessibility"]["transcript"]) do
      plan
    else
      LessonPlan.put_warning(plan, %{
        "code" => "missing_transcript",
        "target" => part_target(screen_key, part["key"]),
        "message" => "A transcript is recommended for video content",
        "sourceRefs" => part["sourceRefs"]
      })
    end
  end

  defp maybe_add_transcript_warning(plan, _screen_key, _part), do: plan

  defp maybe_add_runtime_ai_blockers(
         plan,
         target,
         %{"runtimeAi" => %{"enabled" => true} = runtime_ai, "static" => static_feedback}
       ) do
    plan =
      if runtime_ai["authorOptIn"] == true do
        plan
      else
        LessonPlan.put_blocker(plan, %{
          "code" => "runtime_ai_opt_in",
          "target" => target,
          "message" => "Runtime AI feedback requires explicit author opt-in"
        })
      end

    fallback_key = runtime_ai["staticFallbackKey"]

    if is_binary(fallback_key) and is_map(static_feedback) and
         present?(static_feedback[fallback_key]) do
      plan
    else
      LessonPlan.put_blocker(plan, %{
        "code" => "runtime_ai_static_fallback",
        "target" => target,
        "message" => "Runtime AI feedback requires reviewed static fallback feedback"
      })
    end
    |> then(fn plan ->
      if present?(runtime_ai["prompt"]) do
        plan
      else
        LessonPlan.put_blocker(plan, %{
          "code" => "runtime_ai_prompt",
          "target" => target,
          "message" => "Runtime AI feedback requires a focused feedback prompt"
        })
      end
    end)
  end

  defp maybe_add_runtime_ai_blockers(plan, _target, _feedback), do: plan

  defp maybe_add_profile_blocker(plan, %{"selectionRequiresConfirmation" => true} = profile) do
    LessonPlan.put_blocker(plan, %{
      "code" => "style_profile_confirmation",
      "target" => "layout.styleProfile",
      "message" => "Confirm the stylesheet configuration for #{profile["label"]}"
    })
  end

  defp maybe_add_profile_blocker(plan, _profile), do: plan

  defp resolve_on_success({:ok, plan}, blocker_key),
    do: {:ok, LessonPlan.resolve_blocker(plan, blocker_key)}

  defp resolve_on_success(error, _blocker_key), do: error

  defp empty_feedback do
    %{
      "static" => %{},
      "runtimeAi" => %{
        "recommended" => false,
        "enabled" => false,
        "authorOptIn" => false,
        "staticFallbackKey" => nil
      }
    }
  end

  defp normalize_scoring(nil), do: %{"mode" => "formative", "points" => 0}

  defp normalize_scoring(scoring) when is_map(scoring) do
    scoring = stringify_keys(scoring)

    %{"mode" => "formative", "points" => 0}
    |> Map.merge(scoring)
  end

  defp normalize_scoring(_), do: %{"mode" => "formative", "points" => 0}

  defp source_grounded_correct_response(attrs, component_key) do
    response = attrs["correctResponse"]
    evidence = source_refs(attrs["correctResponseEvidence"])

    if Catalog.automatically_evaluated?(component_key) and not is_nil(response) and
         evidence != [] do
      {response, "source_evidence", evidence}
    else
      {nil, nil, []}
    end
  end

  defp infer_variable_type(value) when is_boolean(value), do: "boolean"
  defp infer_variable_type(value) when is_integer(value), do: "integer"
  defp infer_variable_type(value) when is_float(value), do: "number"
  defp infer_variable_type(_value), do: "string"

  defp normalize_kind(kind) when is_atom(kind), do: normalize_kind(Atom.to_string(kind))

  defp normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_kind(_kind), do: ""

  defp source_refs(nil), do: []

  defp source_refs(refs) when is_list(refs) do
    Enum.map(refs, fn
      ref when is_map(ref) -> stringify_keys(ref)
      ref when is_binary(ref) -> %{"slideId" => ref}
      ref when is_integer(ref) -> %{"slideIndex" => ref}
      ref -> %{"reference" => to_string(ref)}
    end)
  end

  defp source_refs(ref) when is_map(ref), do: [stringify_keys(ref)]
  defp source_refs(ref), do: source_refs([ref])

  defp interaction_target(screen_key, interaction_key),
    do: "screen:#{screen_key}:interaction:#{interaction_key || "unknown"}"

  defp part_target(screen_key, part_key),
    do: "screen:#{screen_key}:part:#{part_key || "unknown"}"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp safe_https_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp safe_https_url?(_url), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp invalid_arguments(path, message) do
    {:error, [%{"path" => path, "code" => "invalid_arguments", "message" => message}]}
  end

  defp not_found(kind, key) do
    {:error,
     [
       %{
         "path" => kind,
         "code" => "not_found",
         "message" => "#{kind} #{inspect(key)} was not found"
       }
     ]}
  end
end
