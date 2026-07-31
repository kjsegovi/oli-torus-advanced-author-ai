defmodule Oli.GoogleSlides.ImportWorkflow.ProvenanceValidator do
  @moduledoc """
  Cross-checks model-authored provenance against the immutable source snapshot.

  Semantic tools require source references, but a model could otherwise invent
  a slide id or quote. This validator ensures references resolve to the current
  deck and that every claimed explicit interaction includes evidence found in
  the cited slide text, notes, or extracted links.
  """

  @minimum_evidence_length 4

  @spec validate(map(), map()) :: :ok | {:error, [map()]}
  def validate(plan, %{"presentation" => presentation, "slides" => slides})
      when is_map(plan) and is_map(presentation) and is_list(slides) do
    index = source_index(slides)

    errors =
      []
      |> validate_source_identity(plan["source"] || %{}, presentation)
      |> validate_plan_refs(plan, index)
      |> validate_interaction_evidence(plan, index)
      |> validate_adaptivity_evidence(plan, index)
      |> validate_grounded_payloads(plan, index)
      |> Enum.reverse()

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_plan, _snapshot) do
    {:error, [error("sourceSnapshot", "invalid_source_snapshot", "source snapshot is invalid")]}
  end

  defp validate_source_identity(errors, source, presentation) do
    errors
    |> require_equal(
      source["presentationId"],
      presentation["id"],
      "source.presentationId",
      "presentation id does not match the analyzed source"
    )
    |> require_equal(
      source["fingerprint"],
      presentation["fingerprint"],
      "source.fingerprint",
      "source fingerprint does not match the analyzed source"
    )
  end

  defp validate_plan_refs(errors, plan, index) do
    screens = get_in(plan, ["lesson", "screens"]) || []

    errors =
      screens
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {screen, screen_index}, acc ->
        path = "lesson.screens[#{screen_index}]"

        acc =
          validate_refs(acc, screen["sourceRefs"], "#{path}.sourceRefs", index)

        acc =
          (screen["parts"] || [])
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {part, part_index}, nested ->
            validate_refs(
              nested,
              part["sourceRefs"],
              "#{path}.parts[#{part_index}].sourceRefs",
              index
            )
          end)

        acc =
          (screen["interactions"] || [])
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {interaction, interaction_index}, nested ->
            interaction_path = "#{path}.interactions[#{interaction_index}]"

            nested
            |> validate_refs(
              interaction["sourceEvidence"],
              "#{interaction_path}.sourceEvidence",
              index
            )
            |> validate_refs(
              interaction["correctResponseEvidence"],
              "#{interaction_path}.correctResponseEvidence",
              index
            )
          end)

        (screen["adaptivity"] || [])
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {rule, rule_index}, nested when is_map(rule) ->
            validate_refs(
              nested,
              rule["sourceRefs"],
              "#{path}.adaptivity[#{rule_index}].sourceRefs",
              index
            )

          {_rule, _rule_index}, nested ->
            nested
        end)
      end)

    errors
    |> validate_objective_refs(plan["objectives"] || %{}, index)
    |> validate_variable_refs(plan["variables"] || [], index)
  end

  defp validate_objective_refs(errors, objectives, index) do
    Enum.reduce(["mapped", "proposed"], errors, fn group, acc ->
      (objectives[group] || [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {objective, objective_index}, nested ->
        validate_refs(
          nested,
          objective["sourceRefs"],
          "objectives.#{group}[#{objective_index}].sourceRefs",
          index
        )
      end)
    end)
  end

  defp validate_variable_refs(errors, variables, index) do
    variables
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {variable, variable_index}, acc ->
      validate_refs(
        acc,
        variable["sourceRefs"],
        "variables[#{variable_index}].sourceRefs",
        index
      )
    end)
  end

  defp validate_refs(errors, refs, path, index) when is_list(refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {ref, ref_index}, acc ->
      case resolve_slide(ref, index) do
        {:ok, slide} ->
          case validate_object_reference(ref, slide) do
            :ok -> acc
            {:error, message} -> [error("#{path}[#{ref_index}]", "unknown_object", message) | acc]
          end

        {:error, message} ->
          [error("#{path}[#{ref_index}]", "unknown_source", message) | acc]
      end
    end)
  end

  defp validate_refs(errors, _refs, _path, _index), do: errors

  defp validate_interaction_evidence(errors, plan, index) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {screen, screen_index}, acc ->
      (screen["interactions"] || [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {interaction, interaction_index}, nested ->
        path =
          "lesson.screens[#{screen_index}].interactions[#{interaction_index}].sourceEvidence"

        nested =
          if grounded_interaction?(interaction["sourceEvidence"], index) do
            nested
          else
            [
              error(
                path,
                "ungrounded_interaction",
                "explicit interaction evidence must quote text, notes, or a link from the cited slide"
              )
              | nested
            ]
          end

        validate_correct_response_evidence(
          nested,
          interaction,
          "lesson.screens[#{screen_index}].interactions[#{interaction_index}]",
          index
        )
      end)
    end)
  end

  defp grounded_interaction?(refs, index) when is_list(refs) do
    Enum.any?(refs, fn ref ->
      evidence = normalize_text(ref["evidence"])

      with true <- String.length(evidence) >= @minimum_evidence_length,
           {:ok, slide} <- resolve_slide(ref, index) do
        source = slide_search_text(slide)
        String.contains?(source, evidence)
      else
        _ -> false
      end
    end)
  end

  defp grounded_interaction?(_refs, _index), do: false

  defp validate_adaptivity_evidence(errors, plan, index) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {screen, screen_index}, acc ->
      (screen["adaptivity"] || [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {rule, rule_index}, nested when is_map(rule) ->
          if grounded_evidence?(rule["sourceRefs"], index) do
            nested
          else
            [
              error(
                "lesson.screens[#{screen_index}].adaptivity[#{rule_index}].sourceRefs",
                "ungrounded_adaptivity",
                "adaptivity must quote explicit source text, notes, or a link from the cited slide"
              )
              | nested
            ]
          end

        {_rule, _rule_index}, nested ->
          nested
      end)
    end)
  end

  defp grounded_evidence?(refs, index) when is_list(refs) do
    Enum.any?(refs, fn ref ->
      evidence = normalize_text(ref["evidence"])

      with true <- String.length(evidence) >= @minimum_evidence_length,
           {:ok, slide} <- resolve_slide(ref, index) do
        text_present?(slide_search_text(slide), evidence)
      else
        _ -> false
      end
    end)
  end

  defp grounded_evidence?(_refs, _index), do: false

  defp validate_correct_response_evidence(
         errors,
         %{"correctResponseSource" => "source_evidence"} = interaction,
         path,
         index
       ) do
    response_text = correct_response_text(interaction)

    grounded? =
      Enum.any?(interaction["correctResponseEvidence"] || [], fn ref ->
        evidence = normalize_text(ref["evidence"])

        with true <- String.length(evidence) >= @minimum_evidence_length,
             true <- correctness_cue?(evidence),
             true <- text_present?(evidence, response_text),
             {:ok, slide} <- resolve_slide(ref, index) do
          text_present?(slide_search_text(slide), evidence)
        else
          _ -> false
        end
      end)

    if grounded? do
      errors
    else
      [
        error(
          "#{path}.correctResponseEvidence",
          "ungrounded_correct_response",
          "correct-response evidence must quote a source cue that identifies the configured answer"
        )
        | errors
      ]
    end
  end

  defp validate_correct_response_evidence(errors, _interaction, _path, _index), do: errors

  defp correct_response_text(interaction) do
    response =
      case interaction["correctResponse"] do
        %{"index" => index} when is_integer(index) -> index
        %{"value" => value} -> value
        %{"mustContain" => value} -> value
        value -> value
      end

    options =
      get_in(interaction, ["configuration", "choices"]) ||
        get_in(interaction, ["configuration", "optionLabels"]) ||
        get_in(interaction, ["configuration", "sliderOptionLabels"])

    case {response, options} do
      {index, options} when is_integer(index) and is_list(options) ->
        Enum.at(options, index) |> normalize_text()

      {value, _options} when is_number(value) or is_boolean(value) ->
        value |> to_string() |> normalize_text()

      {value, _options} ->
        normalize_text(value)
    end
  end

  defp correctness_cue?(text) do
    normalized = normalize_text(text)

    Regex.match?(~r/\b(answer|correct|solution|key|expected)\b/u, normalized) or
      String.contains?(text, ["✓", "✔", "✅"])
  end

  defp validate_grounded_payloads(errors, plan, index) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {screen, screen_index}, acc ->
      path = "lesson.screens[#{screen_index}]"

      acc =
        (screen["parts"] || [])
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {part, part_index}, nested ->
          validate_grounded_part(
            nested,
            part,
            "#{path}.parts[#{part_index}]",
            index
          )
        end)

      (screen["interactions"] || [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {interaction, interaction_index}, nested ->
        validate_grounded_interaction_payload(
          nested,
          interaction,
          "#{path}.interactions[#{interaction_index}]",
          index
        )
      end)
    end)
  end

  defp validate_grounded_part(errors, part, path, index) do
    content = part["content"] || %{}
    refs = part["sourceRefs"] || []
    object_id = content["sourceObjectId"]

    errors =
      if is_binary(object_id) and object_id != "" and not grounded_object?(refs, object_id, index) do
        [
          error(
            "#{path}.content.sourceObjectId",
            "ungrounded_source_object",
            "media object must exist on a cited source slide"
          )
          | errors
        ]
      else
        errors
      end

    errors =
      if part["kind"] in ["audio", "iframe"] and is_binary(content["src"]) and
           not grounded_url?(refs, content["src"], index) do
        [
          error(
            "#{path}.content.src",
            "ungrounded_url",
            "external media or embed URL must be present on a cited source slide"
          )
          | errors
        ]
      else
        errors
      end

    captions = get_in(part, ["accessibility", "captions"])
    captions_source = get_in(part, ["accessibility", "captionsSource"])

    if is_binary(captions) and captions != "" and captions_source != "author_answer" and
         not grounded_url?(refs, captions, index) do
      [
        error(
          "#{path}.accessibility.captions",
          "ungrounded_url",
          "caption track must be present in the source or supplied by the author"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_grounded_interaction_payload(errors, interaction, path, index) do
    errors
    |> validate_grounded_options(interaction, path, index)
    |> validate_grounded_iframe(interaction, path, index)
  end

  defp validate_grounded_options(errors, interaction, path, index) do
    configuration = interaction["configuration"] || %{}

    options =
      case interaction["componentKey"] do
        "multiple_choice" -> configuration["choices"]
        "dropdown" -> configuration["optionLabels"] || configuration["choices"]
        "text_slider" -> configuration["sliderOptionLabels"] || configuration["choices"]
        _ -> nil
      end

    if is_list(options) do
      options
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {option, option_index}, acc ->
        if grounded_text?(interaction["sourceEvidence"], option, index) do
          acc
        else
          [
            error(
              "#{path}.configuration.options[#{option_index}]",
              "ungrounded_option",
              "choice labels must occur on a cited source slide"
            )
            | acc
          ]
        end
      end)
    else
      errors
    end
  end

  defp validate_grounded_iframe(errors, %{"componentKey" => "iframe"} = interaction, path, index) do
    src = get_in(interaction, ["configuration", "src"])

    if grounded_url?(interaction["sourceEvidence"], src, index) do
      errors
    else
      [
        error(
          "#{path}.configuration.src",
          "ungrounded_url",
          "iframe URL must be present on a cited source slide"
        )
        | errors
      ]
    end
  end

  defp validate_grounded_iframe(errors, _interaction, _path, _index), do: errors

  defp grounded_text?(refs, value, index) when is_list(refs) and is_binary(value) do
    Enum.any?(refs, fn ref ->
      case resolve_slide(ref, index) do
        {:ok, slide} -> text_present?(slide_search_text(slide), value)
        _ -> false
      end
    end)
  end

  defp grounded_text?(_refs, _value, _index), do: false

  defp grounded_object?(refs, object_id, index) when is_list(refs) do
    Enum.any?(refs, fn ref ->
      case resolve_slide(ref, index) do
        {:ok, slide} -> object_id in slide_object_ids(slide)
        _ -> false
      end
    end)
  end

  defp grounded_object?(_refs, _object_id, _index), do: false

  defp grounded_url?(refs, url, index) when is_list(refs) and is_binary(url) and url != "" do
    Enum.any?(refs, fn ref ->
      case resolve_slide(ref, index) do
        {:ok, slide} ->
          url in (slide["links"] || []) or
            url in collect_field_values(slide["contentBlocks"] || [], "src")

        _ ->
          false
      end
    end)
  end

  defp grounded_url?(_refs, _url, _index), do: false

  defp collect_field_values(value, field) when is_map(value) do
    Enum.flat_map(value, fn
      {^field, found} when is_binary(found) -> [found]
      {_key, nested} -> collect_field_values(nested, field)
    end)
  end

  defp collect_field_values(value, field) when is_list(value),
    do: Enum.flat_map(value, &collect_field_values(&1, field))

  defp collect_field_values(_value, _field), do: []

  defp source_index(slides) do
    %{
      by_id:
        Map.new(slides, fn slide ->
          {to_string(slide["objectId"]), slide}
        end),
      by_index:
        Map.new(slides, fn slide ->
          {normalize_index(slide["index"]), slide}
        end)
    }
  end

  defp resolve_slide(ref, %{by_id: by_id, by_index: by_index}) when is_map(ref) do
    by_slide_id =
      case ref["slideId"] do
        nil -> nil
        slide_id -> Map.get(by_id, to_string(slide_id))
      end

    by_slide_index =
      case normalize_index(ref["slideIndex"]) do
        nil -> nil
        slide_index -> Map.get(by_index, slide_index)
      end

    case {by_slide_id, by_slide_index} do
      {nil, nil} ->
        {:error, "source reference does not identify a slide in this presentation"}

      {%{} = slide, nil} ->
        {:ok, slide}

      {nil, %{} = slide} ->
        {:ok, slide}

      {%{} = slide, %{} = slide} ->
        {:ok, slide}

      {%{}, %{}} ->
        {:error, "slide id and slide index refer to different slides"}
    end
  end

  defp resolve_slide(_ref, _index), do: {:error, "source reference must be an object"}

  defp validate_object_reference(%{"objectId" => object_id}, slide)
       when is_binary(object_id) and object_id != "" do
    if slide_reference?(object_id, slide) or object_id in slide_object_ids(slide) do
      :ok
    else
      {:error, "source object #{inspect(object_id)} was not found on the cited slide"}
    end
  end

  defp validate_object_reference(_ref, _slide), do: :ok

  # Screen-level provenance sometimes includes the Google Slides page id in
  # both fields (`slideId` and `objectId`). The page itself is not a page
  # element and therefore is not repeated in `contentBlocks` or
  # `sourceInventory`. Treat that exact, already-resolved page identity as a
  # valid slide-level reference. Media payloads remain independently checked
  # against actual page-element ids by `validate_grounded_part/4`.
  defp slide_reference?(object_id, slide) do
    object_id == to_string(slide["objectId"])
  end

  # `contentBlocks` intentionally excludes structural objects, unsupported
  # objects, and a TITLE placeholder promoted to the screen title. The source
  # inventory is the authoritative identity ledger for those elements. It is
  # nested under the resolved slide, so accepting an inventory id here keeps
  # object references scoped to the cited slide rather than treating ids from
  # the whole presentation as interchangeable.
  defp slide_object_ids(slide) do
    collect_object_ids(slide["contentBlocks"] || []) ++
      collect_inventory_object_ids(slide["sourceInventory"] || [])
  end

  defp collect_inventory_object_ids(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{"objectId" => object_id} when is_binary(object_id) and object_id != "" ->
        [object_id]

      _entry ->
        []
    end)
  end

  defp collect_inventory_object_ids(_entries), do: []

  defp collect_object_ids(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"objectId", object_id} when is_binary(object_id) -> [object_id]
      {_key, nested} -> collect_object_ids(nested)
    end)
  end

  defp collect_object_ids(value) when is_list(value),
    do: Enum.flat_map(value, &collect_object_ids/1)

  defp collect_object_ids(_value), do: []

  defp slide_search_text(slide) do
    [
      human_text(slide["title"]),
      human_text(slide["paragraphs"]),
      human_text(slide["listItems"]),
      content_block_text(slide["contentBlocks"]),
      human_text(slide["notes"]),
      human_text(slide["links"])
    ]
    |> List.flatten()
    |> Enum.map_join(" ", &normalize_text/1)
    |> normalize_text()
  end

  # The snapshot also contains model-facing metadata such as type names,
  # object ids, dimensions, transforms, and truncation flags. Those values may
  # help the planner locate content, but they cannot establish that an
  # interaction was explicitly requested by the author. Only known
  # learner-facing text fields and extracted links are searchable evidence.
  defp content_block_text(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{"type" => type, "text" => text}
      when type in ["paragraph", "heading", "table", "word_art"] ->
        human_text(text)

      %{"type" => "list", "items" => items} ->
        human_text(items)

      %{"type" => "image", "altText" => alt_text} ->
        human_text(alt_text)

      %{"type" => "video", "alt" => alt_text} ->
        human_text(alt_text)

      _other ->
        []
    end)
  end

  defp content_block_text(_blocks), do: []

  defp human_text(value) when is_binary(value), do: [value]

  defp human_text(values) when is_list(values),
    do: Enum.flat_map(values, &human_text/1)

  defp human_text(_value), do: []

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(_value), do: ""

  defp text_present?(text, excerpt) do
    text = normalize_text(text)
    excerpt = normalize_text(excerpt)
    excerpt != "" and String.contains?(text, excerpt)
  end

  defp normalize_index(value) when is_integer(value), do: value

  defp normalize_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_index(_value), do: nil

  defp require_equal(errors, value, value, _path, _message) when not is_nil(value), do: errors

  defp require_equal(errors, _actual, _expected, path, message),
    do: [error(path, "source_mismatch", message) | errors]

  defp error(path, code, message) do
    %{"path" => path, "code" => code, "message" => message}
  end
end
