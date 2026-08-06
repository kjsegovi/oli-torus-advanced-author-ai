defmodule Oli.OpenStax.CourseImport.AuthoringCompiler do
  @moduledoc """
  Compiles provider-neutral course-import plans into validated Torus authoring
  artifacts without writing resources.

  Basic lessons use the canonical TorusDoc activity converters. Advanced
  lessons reuse the reviewed Adaptive Author part and rule builders already
  used by the Google Slides importer, but consume only the provider-neutral
  OpenStax plan contract.
  """

  alias Oli.Activities.Model
  alias Oli.GoogleSlides.Adaptive.{PartBuilders, TrapStateRulesBuilder}
  alias Oli.OpenStax.CourseImport.GeneratedSimulation
  alias Oli.TorusDoc.{ActivityConverter, ActivityParser}
  alias Oli.Utils.SchemaResolver

  @default_width 1200
  @default_height 540
  @narrative_words_per_screen 80
  @minimum_reflection_length 40
  @screen_bottom_padding 48
  @maximum_media_height 420

  @type artifact :: %{required(String.t()) => term()}

  @spec compile(String.t(), String.t(), map(), map() | list(), String.t()) ::
          {:ok, artifact()} | {:error, term()}
  def compile(mode, title, content_payload, questions_payload, stable_key) do
    compile(mode, title, content_payload, questions_payload, stable_key, [])
  end

  @spec compile(String.t(), String.t(), map(), map() | list(), String.t(), keyword()) ::
          {:ok, artifact()} | {:error, term()}
  def compile(mode, title, content_payload, questions_payload, stable_key, opts)
      when mode in ["basic", "advanced"] and is_binary(title) and is_map(content_payload) and
             is_binary(stable_key) and is_list(opts) do
    questions = questions(questions_payload)

    with {:ok, normalized_questions} <- validate_questions(questions),
         {:ok, media_assets} <- resolve_media_assets(content_payload, opts),
         attribution <- normalize_attribution(content_payload, opts),
         {:ok, artifact} <-
           compile_mode(
             mode,
             title,
             content_payload,
             normalized_questions,
             stable_key,
             media_assets,
             attribution,
             opts
           ),
         :ok <- validate_realized_page(artifact) do
      {:ok, artifact}
    end
  end

  def compile(_, _, _, _, _, _), do: {:error, :invalid_authoring_artifact}

  defp compile_mode(
         "advanced",
         title,
         content,
         questions,
         stable_key,
         media_assets,
         attribution,
         opts
       ),
       do:
         compile_advanced(
           title,
           content,
           questions,
           stable_key,
           media_assets,
           attribution,
           opts
         )

  defp compile_mode(
         "basic",
         title,
         content,
         questions,
         stable_key,
         media_assets,
         attribution,
         _opts
       ),
       do:
         compile_basic(
           title,
           content,
           questions,
           stable_key,
           media_assets,
           attribution
         )

  @doc """
  Replaces compiler-only activity keys with persisted resource ids.
  """
  @spec realize_page(map(), %{required(String.t()) => integer()}) ::
          {:ok, map()} | {:error, term()}
  def realize_page(template, activity_ids)
      when is_map(template) and is_map(activity_ids) do
    case realize_node(template, activity_ids) do
      {:ok, page} ->
        if contains_activity_key?(page),
          do: {:error, :unresolved_activity_reference},
          else: {:ok, page}

      {:error, _} = error ->
        error
    end
  end

  def realize_page(_, _), do: {:error, :invalid_page_template}

  defp validate_realized_page(artifact) do
    activity_ids =
      artifact
      |> Map.get("activities", [])
      |> Enum.with_index(1)
      |> Map.new(fn {activity, index} -> {activity["key"], index} end)

    schema_name =
      if artifact["mode"] == "advanced",
        do: "page-content-adaptive.schema.json",
        else: "page-content-basic.schema.json"

    with {:ok, realized} <- realize_page(artifact["page_content_template"], activity_ids),
         :ok <-
           schema_name
           |> SchemaResolver.resolve()
           |> ExJsonSchema.Validator.validate(realized) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_realized_page, reason}}
      errors when is_list(errors) -> {:error, {:invalid_realized_page, errors}}
    end
  end

  defp compile_basic(title, content, questions, stable_key, media_assets, attribution) do
    with {:ok, activity_specs} <-
           compile_basic_questions(title, questions, stable_key, media_assets) do
      references =
        Enum.map(activity_specs, fn spec ->
          {spec["placement_after_section_id"], activity_reference(spec)}
        end)

      section_ids =
        content
        |> instructional_sections()
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      {placed_references, final_references} =
        Enum.split_with(references, fn {placement, _reference} ->
          is_binary(placement) and MapSet.member?(section_ids, placement)
        end)

      page_content = %{
        "version" => "0.1.0",
        "model" =>
          basic_instructional_blocks(
            content,
            stable_key,
            media_assets,
            attribution,
            Map.new(section_ids, &{&1, placed_references_for(placed_references, &1)})
          ) ++ final_practice_blocks(final_references, stable_key)
      }

      {:ok,
       %{
         "mode" => "basic",
         "activities" => activity_specs,
         "page_content_template" => page_content,
         "required_media_ids" => required_media_ids(media_assets),
         "attribution" => attribution_payload(attribution)
       }}
    end
  end

  defp activity_reference(spec) do
    %{
      "id" => stable_id("reference", spec["key"]),
      "type" => "activity-reference",
      "activity_key" => spec["key"]
    }
  end

  defp placed_references_for(references, section_id) do
    references
    |> Enum.filter(fn {placement, _reference} -> placement == section_id end)
    |> Enum.map(fn {_placement, reference} -> reference end)
  end

  defp basic_instructional_blocks(
         content,
         stable_key,
         media_assets,
         attribution,
         references_by_section
       ) do
    objectives = learning_objectives(content)
    sections = instructional_sections(content)
    curated = normalize_curated_enrichments(content["curated_enrichments"])
    section_ids = MapSet.new(sections, & &1["id"])

    unplaced_curated =
      Enum.reject(curated, fn enrichment ->
        placement = enrichment["placement_after_section_id"]
        is_binary(placement) and MapSet.member?(section_ids, placement)
      end)

    [
      lesson_overview_block(content, objectives, sections, stable_key)
    ] ++
      opening_hook_blocks(content, stable_key) ++
      why_this_matters_blocks(content, stable_key) ++
      rich_callout_blocks(content["callouts"], "#{stable_key}:source-callouts") ++
      media_blocks(media_assets, nil, "#{stable_key}:opening-media") ++
      curiosity_blocks(content["curiosity_prompts"], "#{stable_key}:curiosity") ++
      (sections
       |> Enum.with_index(1)
       |> Enum.flat_map(fn {section, index} ->
         instructional_section_blocks(
           section,
           index,
           stable_key,
           media_assets,
           Map.get(references_by_section, section["id"], []),
           curated_for_placement(curated, section["id"])
         )
       end)) ++
      worked_example_blocks(content["worked_examples"], stable_key) ++
      application_problem_blocks(content["application_problems"], stable_key) ++
      curated_enrichment_blocks(unplaced_curated, "#{stable_key}:curated") ++
      key_takeaways_block(content, stable_key) ++
      source_evidence_block(content["source_evidence_links"], stable_key) ++
      attribution_blocks(attribution, stable_key)
  end

  defp lesson_overview_block(content, objectives, sections, stable_key) do
    introduction =
      first_present([
        content["introduction"],
        content["overview"],
        if(explicit_instructional_sections?(content), do: content["narrative"]),
        if(sections == [], do: content["narrative"])
      ])

    children =
      [
        text_element("h2", "Learning Objectives", "#{stable_key}:objectives-heading"),
        string_list_element("ul", objectives, "#{stable_key}:objectives")
      ] ++ paragraph_elements(introduction, "#{stable_key}:introduction")

    content_block(children, "#{stable_key}:overview")
  end

  defp explicit_instructional_sections?(content) do
    [
      content["instructional_sections"],
      content["lesson_sections"],
      content["sections"]
    ]
    |> Enum.any?(fn sections ->
      is_list(sections) and Enum.any?(sections)
    end)
  end

  defp opening_hook_blocks(content, stable_key) do
    callout_blocks(
      content["opening_hook"],
      "manystudentswonder",
      "Start here",
      "#{stable_key}:opening-hook"
    )
  end

  defp why_this_matters_blocks(content, stable_key) do
    callout_blocks(
      content["why_this_matters"],
      "learnmore",
      "Why this matters",
      "#{stable_key}:why-this-matters"
    )
  end

  defp curiosity_blocks(prompts, stable_key) do
    callout_blocks(prompts, "manystudentswonder", "Think about it", stable_key)
  end

  defp rich_callout_blocks(callouts, stable_key) do
    callouts
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {callout, index} ->
      callout_blocks(
        [callout],
        callout_purpose(callout),
        "Source connection",
        "#{stable_key}:#{index}"
      )
    end)
  end

  defp callout_purpose(%{"type" => type})
       when type in ["example", "concepts_in_practice"],
       do: "example"

  defp callout_purpose(%{"type" => "curiosity"}), do: "manystudentswonder"
  defp callout_purpose(_), do: "learnmore"

  defp instructional_section_blocks(
         section,
         index,
         stable_key,
         media_assets,
         references,
         curated
       ) do
    section_key = "#{stable_key}:section:#{section["id"] || index}"

    section_children =
      [text_element("h2", section["title"], "#{section_key}:heading")] ++
        paragraph_elements(section["explanation"], "#{section_key}:explanation") ++
        section_takeaway_elements(section["key_takeaways"], section_key) ++
        source_evidence_elements(section["source_evidence_links"], section_key)

    [content_block(section_children, section_key)] ++
      callout_blocks(section["callouts"], "learnmore", "Go deeper", "#{section_key}:callouts") ++
      media_blocks(media_assets, section["id"], "#{section_key}:media") ++
      curiosity_blocks(section["curiosity_prompts"], "#{section_key}:curiosity") ++
      worked_example_blocks(section["examples"], "#{section_key}:examples") ++
      curated_enrichment_blocks(curated, "#{section_key}:curated") ++
      practice_group(references, "#{section_key}:practice")
  end

  defp curated_enrichment_blocks(enrichments, stable_key) do
    enrichments
    |> Enum.with_index(1)
    |> Enum.map(fn {enrichment, index} ->
      key = "#{stable_key}:#{index}"
      title = enrichment["title"]

      children =
        [text_element("h3", title, "#{key}:heading")] ++
          paragraph_elements(enrichment["annotation"], "#{key}:annotation") ++
          [text_element("h4", "Try this resource", "#{key}:task-heading")] ++
          paragraph_elements(enrichment["learner_task"], "#{key}:task") ++
          [
            source_link_list(
              [%{url: enrichment["url"], label: "Open #{title}"}],
              "#{key}:link"
            )
          ]

      %{
        "id" => stable_id("curated-group", key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => "learnmore",
        "children" => [content_block(children, "#{key}:content")]
      }
    end)
  end

  defp worked_example_blocks(examples, stable_key) do
    examples
    |> normalize_examples()
    |> Enum.with_index(1)
    |> Enum.map(fn {example, index} ->
      example_key = "#{stable_key}:example:#{index}"

      children =
        [
          text_element(
            "h3",
            example["title"] || "Worked Example #{index}",
            "#{example_key}:heading"
          )
        ] ++
          paragraph_elements(example["scenario"], "#{example_key}:scenario") ++
          paragraph_elements(example["explanation"], "#{example_key}:explanation") ++
          ordered_step_elements(example["steps"], example_key) ++
          paragraph_elements(example["conclusion"], "#{example_key}:conclusion") ++
          source_evidence_elements(example["source_evidence_links"], example_key)

      %{
        "id" => stable_id("example-group", example_key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => "example",
        "children" => [content_block(children, "#{example_key}:content")]
      }
    end)
  end

  defp key_takeaways_block(content, stable_key) do
    takeaways = normalize_strings(content["key_takeaways"])

    case takeaways do
      [] ->
        []

      _ ->
        [
          content_block(
            [
              text_element("h2", "Key Takeaways", "#{stable_key}:takeaways-heading"),
              string_list_element("ul", takeaways, "#{stable_key}:takeaways")
            ],
            "#{stable_key}:takeaways"
          )
        ]
    end
  end

  defp application_problem_blocks(problems, stable_key) do
    problems
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {problem, index} ->
      problem_key = "#{stable_key}:application:#{index}"

      {title, prompt, guidance} =
        case problem do
          value when is_binary(value) ->
            {"Apply what you learned #{index}", present_string(value), nil}

          value when is_map(value) ->
            {
              first_present([
                value["title"],
                value["heading"],
                "Apply what you learned #{index}"
              ]),
              first_present([
                value["prompt"],
                value["problem"],
                value["scenario"],
                value["body"],
                value["text"]
              ]),
              first_present([
                value["guidance"],
                value["hint"],
                value["instructions"]
              ])
            }

          _ ->
            {nil, nil, nil}
        end

      if present_text?(prompt) do
        children =
          [
            text_element("h3", title, "#{problem_key}:heading")
          ] ++
            paragraph_elements(prompt, "#{problem_key}:prompt") ++
            paragraph_elements(guidance, "#{problem_key}:guidance")

        [
          %{
            "id" => stable_id("application-group", problem_key),
            "type" => "group",
            "layout" => "vertical",
            "purpose" => "learnbydoing",
            "children" => [content_block(children, "#{problem_key}:content")]
          }
        ]
      else
        []
      end
    end)
  end

  defp callout_blocks(value, purpose, default_title, stable_key)
       when purpose in ["manystudentswonder", "learnmore", "learnbydoing", "example"] do
    value
    |> normalize_callouts(default_title)
    |> Enum.with_index(1)
    |> Enum.map(fn {callout, index} ->
      callout_key = "#{stable_key}:#{index}"

      %{
        "id" => stable_id("callout-group", callout_key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => purpose,
        "children" => [
          content_block(
            [
              text_element("h3", callout["title"], "#{callout_key}:heading")
              | paragraph_elements(callout["body"], "#{callout_key}:body")
            ],
            "#{callout_key}:content"
          )
        ]
      }
    end)
  end

  defp normalize_callouts(value, default_title) do
    value
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {entry, index} when is_binary(entry) ->
        case present_string(entry) do
          nil ->
            []

          body ->
            [
              %{
                "title" => callout_title(default_title, index),
                "body" => body
              }
            ]
        end

      {entry, index} when is_map(entry) ->
        body =
          first_present([
            entry["body"],
            entry["content"],
            entry["text"],
            entry["prompt"],
            entry["question"],
            entry["description"]
          ])

        if present_text?(body) do
          [
            %{
              "title" =>
                first_present([
                  entry["title"],
                  entry["heading"],
                  callout_title(default_title, index)
                ]),
              "body" => body
            }
          ]
        else
          []
        end

      _entry ->
        []
    end)
  end

  defp callout_title(default_title, 1), do: default_title
  defp callout_title(default_title, index), do: "#{default_title} #{index}"

  defp media_blocks(media_assets, placement, stable_key) do
    media_assets
    |> media_for_placement(placement)
    |> Enum.with_index(1)
    |> Enum.map(fn {asset, index} ->
      media_key = "#{stable_key}:#{index}"
      caption = Enum.filter([asset.caption, asset.credit], &present_text?/1) |> Enum.join(" — ")

      image =
        %{
          "id" => stable_id("image", media_key),
          "type" => "img",
          "src" => asset.url,
          "alt" => asset.alt,
          "display" => "block",
          "height" => asset.height,
          "width" => "100%",
          "children" => [%{"text" => ""}]
        }
        |> maybe_put_present("caption", caption)

      content_block([image], "#{media_key}:content")
    end)
  end

  defp attribution_blocks(attribution, stable_key) do
    lines = attribution_lines(attribution)

    case {lines, attribution.links} do
      {[], []} ->
        []

      {lines, links} ->
        children =
          [text_element("h2", "Attribution", "#{stable_key}:attribution-heading")] ++
            paragraph_elements(lines, "#{stable_key}:attribution-lines") ++
            if(links == [],
              do: [],
              else: [source_link_list(links, "#{stable_key}:attribution-links")]
            )

        [content_block(children, "#{stable_key}:attribution")]
    end
  end

  defp source_evidence_block(links, stable_key) do
    case normalize_source_links(links) do
      [] ->
        []

      source_links ->
        [
          content_block(
            [
              text_element("h2", "Sources", "#{stable_key}:sources-heading"),
              source_link_list(source_links, "#{stable_key}:sources")
            ],
            "#{stable_key}:sources"
          )
        ]
    end
  end

  defp formative_practice_block(stable_key) do
    content_block(
      [
        text_element(
          "h2",
          "Check Your Understanding",
          "#{stable_key}:formative-practice-heading"
        ),
        text_element(
          "p",
          "Use the lesson material above to answer the following questions.",
          "#{stable_key}:formative-practice-introduction"
        )
      ],
      "#{stable_key}:formative-practice"
    )
  end

  defp final_practice_blocks([], _stable_key), do: []

  defp final_practice_blocks(references, stable_key) do
    [formative_practice_block(stable_key) | Enum.map(references, &elem(&1, 1))]
  end

  defp practice_group([], _stable_key), do: []

  defp practice_group(references, stable_key) do
    introduction =
      content_block(
        [
          text_element("h3", "Practice the concept", "#{stable_key}:heading"),
          text_element(
            "p",
            "Check your understanding before moving to the next section.",
            "#{stable_key}:introduction"
          )
        ],
        "#{stable_key}:introduction"
      )

    [
      %{
        "id" => stable_id("practice-group", stable_key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => "learnbydoing",
        "children" => [introduction | references]
      }
    ]
  end

  defp compile_basic_questions(title, questions, stable_key, media_assets) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {question, index}, {:ok, specs} ->
      key = "#{stable_key}:question:#{index}"
      activity_title = "#{title} – Question #{index}"

      with {:ok, question} <- attach_question_media(question, media_assets),
           {:ok, source} <- basic_question_source(question, activity_title, key),
           {:ok, parsed} <- ActivityParser.parse_activity(source),
           {:ok, converted_model} <- ActivityConverter.to_torus_json(parsed),
           model <- stabilize_model_ids(converted_model, key),
           {:ok, _parsed_model} <- Model.parse(model) do
        spec = %{
          "key" => key,
          "activity_type_slug" => source["type"],
          "title" => activity_title,
          "model" => model,
          "placement_after_section_id" => question["placement_after_section_id"],
          "objective_ids" => normalize_identifier_list(question["objective_ids"]),
          "evidence_block_ids" => normalize_identifier_list(question["evidence_block_ids"])
        }

        {:cont, {:ok, specs ++ [spec]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:question_compile_failed, index, reason}}}
      end
    end)
  end

  defp basic_question_source(%{"type" => "short_answer"} = question, title, _stable_key) do
    {:ok,
     %{
       "type" => "oli_short_answer",
       "title" => title,
       "stem_md" => question["prompt"],
       "input_type" => "text",
       "hints" => question_hints(question)
     }}
  end

  defp basic_question_source(%{"type" => "multiple_choice"} = question, title, stable_key) do
    choices =
      question["normalized_choices"]
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        %{
          "id" => stable_id("choice", "#{stable_key}:#{index}"),
          "score" => if(index == question["correct_index"], do: 1, else: 0),
          "body_md" => choice["text"],
          "feedback_md" =>
            choice["feedback"] ||
              if(index == question["correct_index"],
                do: question_feedback(question, "correct", "Correct."),
                else: question_feedback(question, "incorrect", "Review the lesson and try again.")
              )
        }
      end)

    choices =
      if question["allow_not_sure"] == true do
        choices ++
          [
            %{
              "id" => stable_id("choice", "#{stable_key}:not-sure"),
              "score" => 0,
              "body_md" => "Not sure",
              "feedback_md" =>
                first_present([
                  question["hint"],
                  question["remediation"],
                  "That is okay. Review the preceding explanation and use the hint before trying again."
                ])
            }
          ]
      else
        choices
      end

    {:ok,
     %{
       "type" => "oli_multiple_choice",
       "title" => title,
       "stem_md" => question["prompt"],
       "choices" => choices,
       "shuffle" => question["shuffle"] == true and question["allow_not_sure"] != true,
       "incorrect_feedback_md" =>
         question_feedback(question, "incorrect", "Review the lesson and try again."),
       "explanation_md" => present_string(question["explanation"]),
       "hints" => question_hints(question)
     }}
  end

  defp basic_question_source(_, _title, _stable_key),
    do: {:error, :unsupported_question_type}

  defp attach_question_media(question, media_assets) do
    media_ids = normalize_identifier_list(question["media_ids"])
    assets_by_id = Map.new(media_assets, &{&1.id, &1})
    missing = Enum.reject(media_ids, &Map.has_key?(assets_by_id, &1))

    if missing == [] do
      media_markdown =
        media_ids
        |> Enum.map(&Map.fetch!(assets_by_id, &1))
        |> Enum.map_join("\n\n", fn asset ->
          caption = if present_text?(asset.caption), do: "\n\n_#{asset.caption}_", else: ""
          "![#{markdown_alt(asset.alt)}](#{asset.url})#{caption}"
        end)

      prompt =
        [media_markdown, question["prompt"]]
        |> Enum.filter(&present_text?/1)
        |> Enum.join("\n\n")

      {:ok, Map.put(question, "prompt", prompt)}
    else
      {:error, {:unknown_question_media_ids, missing}}
    end
  end

  defp question_hints(question) do
    question["hint"]
    |> List.wrap()
    |> Enum.flat_map(fn hint ->
      case present_string(hint) do
        nil -> []
        value -> [%{"body_md" => value}]
      end
    end)
  end

  defp markdown_alt(value) do
    value
    |> to_string()
    |> String.replace(["[", "]", "\n", "\r"], " ")
    |> String.trim()
  end

  defp compile_advanced(
         title,
         content,
         questions,
         stable_key,
         media_assets,
         attribution,
         opts
       ) do
    with {:ok, screens} <-
           advanced_screens(
             title,
             content,
             questions,
             stable_key,
             media_assets,
             attribution,
             opts
           ),
         :ok <- validate_unique_advanced_activity_keys(screens),
         {:ok, activity_specs} <- compile_advanced_screens(screens) do
      {:ok,
       %{
         "mode" => "advanced",
         "activities" => activity_specs,
         "required_media_ids" => required_media_ids(media_assets),
         "attribution" => attribution_payload(attribution),
         "page_content_template" => %{
           "advancedDelivery" => true,
           "advancedAuthoring" => true,
           "displayApplicationChrome" => false,
           "custom" => page_custom(),
           "additionalStylesheets" => [
             "/css/delivery_adaptive_themes_default_light.css"
           ],
           "customCss" => "",
           "model" => [
             %{
               "id" => stable_id("deck", stable_key),
               "type" => "group",
               "layout" => "deck",
               "children" =>
                 Enum.map(activity_specs, fn screen ->
                   %{
                     "type" => "activity-reference",
                     "activity_key" => screen["key"],
                     "custom" => %{
                       "sequenceId" => stable_id("sequence", screen["key"]),
                       "sequenceName" => screen["title"]
                     }
                   }
                 end)
             }
           ]
         }
       }}
    end
  end

  defp advanced_screens(
         title,
         content,
         questions,
         stable_key,
         media_assets,
         attribution,
         opts
       ) do
    objective =
      content["objective"] ||
        List.first(content["learning_objectives"] || []) ||
        "Lesson objective"

    base_content_screens =
      advanced_content_screens(
        title,
        content,
        objective,
        stable_key,
        media_assets,
        attribution
      )

    with {:ok, blueprint_screens} <-
           advanced_blueprint_screens(content, stable_key, base_content_screens, opts) do
      content_screens =
        interleave_blueprint_screens(base_content_screens, blueprint_screens)

      content_screen_count = length(content_screens)
      question_count = length(questions)
      interleave? = content_screen_count >= question_count

      question_screens =
        questions
        |> Enum.with_index(1)
        |> Enum.map(fn {question, index} ->
          key = "#{stable_key}:question:#{index}"
          reminder = remediation_excerpt(question, content, objective, index)
          parts = question_screen_parts(question, reminder, key, index)
          scorable_part = List.last(parts)

          anchor_index =
            question_anchor_index(
              question,
              index,
              question_count,
              content_screens
            )

          remediation_screen = Enum.at(content_screens, anchor_index - 1)

          rules =
            question
            |> adaptivity_config(reminder)
            |> TrapStateRulesBuilder.build_rules(scorable_part, parts, [scorable_part])
            |> add_remediation_navigation(remediation_screen, not is_nil(remediation_screen))
            |> stabilize_rules(key)

          %{
            key: key,
            title: "#{title} — Check #{index}",
            kind: :question,
            parts: parts,
            rules: rules,
            anchor_index: anchor_index
          }
        end)

      screens =
        if interleave? do
          interleave_question_screens(content_screens, question_screens)
        else
          content_screens ++ question_screens
        end

      {:ok, screens}
    end
  end

  defp question_anchor_index(question, index, question_count, content_screens) do
    placement = present_string(question["placement_after_section_id"])

    placed_index =
      if is_binary(placement) do
        content_screens
        |> Enum.with_index(1)
        |> Enum.filter(fn {screen, _index} -> screen[:section_id] == placement end)
        |> List.last()
        |> case do
          {_screen, placed_index} -> placed_index
          nil -> nil
        end
      end

    placed_index ||
      index
      |> Kernel.*(length(content_screens))
      |> Kernel.+(question_count - 1)
      |> div(question_count)
      |> max(1)
      |> min(length(content_screens))
  end

  defp interleave_question_screens(content_screens, question_screens) do
    content_screens
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {content_screen, index} ->
      anchored_questions =
        Enum.filter(question_screens, &(&1.anchor_index == index))

      [content_screen | anchored_questions]
    end)
  end

  defp interleave_blueprint_screens(content_screens, blueprint_screens) do
    {placed, unplaced} =
      Enum.split_with(blueprint_screens, fn blueprint ->
        present_text?(blueprint[:placement]) and
          Enum.any?(content_screens, &(&1[:section_id] == blueprint[:placement]))
      end)

    final_section_screen_indexes =
      content_screens
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {screen, index}, indexes ->
        case screen[:section_id] do
          section_id when is_binary(section_id) -> Map.put(indexes, section_id, index)
          _section_id -> indexes
        end
      end)

    content_screens
    |> Enum.with_index()
    |> Enum.flat_map(fn {content_screen, index} ->
      matching =
        if present_text?(content_screen[:section_id]) and
             final_section_screen_indexes[content_screen[:section_id]] == index do
          Enum.filter(placed, &(&1[:placement] == content_screen[:section_id]))
        else
          []
        end

      [content_screen | matching]
    end)
    |> Kernel.++(unplaced)
  end

  defp advanced_blueprint_screens(content, stable_key, content_screens, opts) do
    blueprint = content["advanced_blueprint"] || %{}
    screens = List.wrap(blueprint["screens"])

    cond do
      content["schema_version"] in [3, 4] and screens == [] ->
        {:error, :missing_advanced_blueprint}

      true ->
        remediation_paths = List.wrap(blueprint["remediation_paths"])

        with :ok <-
               validate_advanced_remediation_integrity(
                 content,
                 screens,
                 remediation_paths,
                 content_screens
               ) do
          screens
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, []}, fn {screen, index}, {:ok, compiled} ->
            case advanced_blueprint_screen(
                   screen,
                   index,
                   stable_key,
                   remediation_paths,
                   content_screens,
                   opts
                 ) do
              {:ok, built} -> {:cont, {:ok, compiled ++ [built]}}
              {:error, reason} -> {:halt, {:error, {:invalid_advanced_blueprint, index, reason}}}
            end
          end)
        end
    end
  end

  defp validate_advanced_remediation_integrity(
         %{"schema_version" => schema_version},
         screens,
         remediation_paths,
         content_screens
       )
       when schema_version in [3, 4] do
    section_ids =
      content_screens
      |> Enum.map(& &1[:section_id])
      |> Enum.filter(&present_text?/1)
      |> MapSet.new()

    interaction_ids =
      screens
      |> Enum.reject(&(&1["kind"] == "content"))
      |> Enum.map(&present_string(&1["id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    with :ok <- validate_unique_advanced_screen_ids(screens),
         :ok <-
           validate_declared_remediation_paths(
             remediation_paths,
             interaction_ids,
             section_ids
           ),
         :ok <-
           validate_interaction_remediation_targets(screens, remediation_paths, section_ids) do
      :ok
    end
  end

  defp validate_advanced_remediation_integrity(
         _content,
         _screens,
         _remediation_paths,
         _content_screens
       ),
       do: :ok

  defp validate_unique_advanced_screen_ids(screens) do
    screen_ids = screens |> Enum.map(&present_string(&1["id"])) |> Enum.reject(&is_nil/1)

    case first_duplicate(screen_ids) do
      nil -> :ok
      duplicate -> {:error, {:duplicate_advanced_screen_id, duplicate}}
    end
  end

  defp validate_unique_advanced_activity_keys(screens) do
    case screens |> Enum.map(& &1.key) |> first_duplicate() do
      nil -> :ok
      duplicate -> {:error, {:duplicate_advanced_activity_key, duplicate}}
    end
  end

  defp first_duplicate(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value),
        do: {:halt, value},
        else: {:cont, MapSet.put(seen, value)}
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  defp validate_declared_remediation_paths(paths, interaction_ids, section_ids) do
    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn
      {%{"from_question_id" => from, "to_section_id" => target}, index}, :ok ->
        cond do
          not MapSet.member?(interaction_ids, from) ->
            {:halt, {:error, {:invalid_advanced_remediation_path, index, :missing_interaction}}}

          not MapSet.member?(section_ids, target) ->
            {:halt, {:error, {:invalid_advanced_remediation_path, index, :missing_section}}}

          true ->
            {:cont, :ok}
        end

      {_path, index}, :ok ->
        {:halt, {:error, {:invalid_advanced_remediation_path, index, :invalid_reference}}}
    end)
  end

  defp validate_interaction_remediation_targets(screens, remediation_paths, section_ids) do
    screens
    |> Enum.reject(&(&1["kind"] == "content"))
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {screen, index}, :ok ->
      screen_id = present_string(screen["id"])

      targets =
        [present_string(screen["remediation_section_id"])] ++
          Enum.flat_map(remediation_paths, fn
            %{"from_question_id" => ^screen_id, "to_section_id" => target} ->
              [present_string(target)]

            _path ->
              []
          end)

      targets = targets |> Enum.reject(&is_nil/1) |> Enum.uniq()

      cond do
        targets == [] ->
          {:halt, {:error, {:missing_advanced_remediation_target, index}}}

        length(targets) > 1 ->
          {:halt, {:error, {:conflicting_advanced_remediation_targets, index}}}

        not MapSet.member?(section_ids, List.first(targets)) ->
          {:halt, {:error, {:invalid_advanced_remediation_target, index}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp advanced_blueprint_screen(
         %{"kind" => "content"} = screen,
         index,
         stable_key,
         _remediation_paths,
         content_screens,
         opts
       ) do
    screen_id = present_string(screen["id"]) || "content-#{index}"
    title = present_string(screen["title"]) || blueprint_title("content", index)
    body = present_string(screen["body"] || screen["content"] || screen["prompt"])
    placement = present_string(screen["placement_after_section_id"])
    key = "#{stable_key}:blueprint:#{screen_id}"

    with true <- not is_nil(body),
         {:ok, parts} <-
           maybe_inject_generated_simulation(
             titled_content_parts(title, body, key),
             screen,
             key,
             :content,
             opts
           ),
         adaptive_screen <- content_screen(key, title, parts),
         {:ok, rules} <-
           generated_capi_branch_rules(adaptive_screen.rules, parts, content_screens, key) do
      {:ok,
       adaptive_screen
       |> Map.put(:rules, rules)
       |> Map.put(:placement, placement)
       |> Map.put(:section_id, placement)}
    else
      false -> {:error, :missing_content_screen_body}
      {:error, _} = error -> error
    end
  end

  defp advanced_blueprint_screen(
         %{} = screen,
         index,
         stable_key,
         remediation_paths,
         content_screens,
         opts
       ) do
    kind = present_string(screen["kind"])
    interaction_type = present_string(screen["interaction_type"])
    screen_id = present_string(screen["id"]) || "interaction-#{index}"
    title = present_string(screen["title"]) || blueprint_title(kind, index)
    prompt = present_string(screen["prompt"]) || title
    key = "#{stable_key}:blueprint:#{screen_id}"

    with true <- kind in ["exploration", "decision", "check", "reflection"],
         {:ok, interaction, common_errors} <-
           blueprint_interaction(screen, interaction_type, prompt, key),
         {:ok, parts} <-
           maybe_inject_generated_simulation(
             blueprint_screen_parts(title, prompt, interaction, key),
             screen,
             key,
             :question,
             opts
           ),
         realized_interaction <- List.last(parts),
         remediation_target <-
           blueprint_remediation_target(
             screen,
             screen_id,
             remediation_paths,
             content_screens
           ),
         base_rules <-
           screen
           |> blueprint_adaptivity(common_errors)
           |> TrapStateRulesBuilder.build_rules(
             realized_interaction,
             parts,
             [realized_interaction]
           )
           |> add_remediation_navigation(remediation_target, not is_nil(remediation_target))
           |> stabilize_rules(key),
         {:ok, rules} <- generated_capi_branch_rules(base_rules, parts, content_screens, key) do
      {:ok,
       %{
         key: key,
         title: title,
         kind: :question,
         parts: parts,
         rules: rules,
         placement: present_string(screen["placement_after_section_id"]),
         section_id: present_string(screen["placement_after_section_id"])
       }}
    else
      false -> {:error, :unsupported_screen_kind}
      {:error, _} = error -> error
    end
  end

  defp advanced_blueprint_screen(_, _index, _stable_key, _paths, _content_screens, _opts),
    do: {:error, :invalid_screen}

  defp maybe_inject_generated_simulation(parts, screen, stable_key, screen_kind, opts) do
    case present_string(screen["enrichment_proposal_id"]) do
      nil ->
        {:ok, parts}

      proposal_id ->
        with :ok <- reject_model_authored_simulation_url(screen),
             {:ok, resolved_spec} <- GeneratedSimulation.resolve(proposal_id, opts) do
          inject_generated_simulation_part(parts, resolved_spec, stable_key, screen_kind)
        end
    end
  end

  defp reject_model_authored_simulation_url(screen) do
    raw_urls = [
      screen["src"],
      screen["url"],
      screen["artifact_url"],
      get_in(screen, ["configuration", "src"]),
      get_in(screen, ["configuration", "url"])
    ]

    if Enum.any?(raw_urls, &present_text?/1),
      do: {:error, :generated_simulation_raw_url_forbidden},
      else: :ok
  end

  defp inject_generated_simulation_part(parts, resolved_spec, stable_key, :question) do
    case Enum.split(parts, -1) do
      {leading_parts, [interaction]} ->
        simulation_y = next_part_y(leading_parts)
        simulation_height = 360

        simulation =
          resolved_spec
          |> PartBuilders.generated_simulation_part(y: simulation_y, height: simulation_height)
          |> Map.put("id", stable_id("generated-simulation", stable_key))

        shifted_interaction =
          put_in(interaction, ["custom", "y"], simulation_y + simulation_height + 16)

        {:ok, leading_parts ++ [simulation, shifted_interaction]}

      _ ->
        {:error, :generated_simulation_placement_invalid}
    end
  end

  defp inject_generated_simulation_part(parts, resolved_spec, stable_key, :content) do
    simulation =
      resolved_spec
      |> PartBuilders.generated_simulation_part(y: next_part_y(parts), height: 360)
      |> Map.put("id", stable_id("generated-simulation", stable_key))

    {:ok, parts ++ [simulation]}
  end

  defp generated_capi_branch_rules(base_rules, parts, content_screens, stable_key) do
    iframe = Enum.find(parts, &(&1["type"] == "janus-capi-iframe"))

    branches =
      case iframe do
        %{"custom" => %{"securityProfile" => "generated_simulation"} = custom} ->
          custom
          |> Map.get("capiOutputs", [])
          |> Enum.filter(&(is_map(&1) and is_map(&1["branching"])))

        _ ->
          []
      end

    branches
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {declaration, index}, {:ok, rules} ->
      branch = declaration["branching"]
      target_section_id = branch["remediation_section_id"]

      target_screen =
        content_screens
        |> Enum.filter(&(&1[:section_id] == target_section_id))
        |> List.last()

      case target_screen do
        %{key: target_key} ->
          rule_key = "#{stable_key}:capi-branch:#{index}"

          actions =
            [
              %{
                "type" => "navigation",
                "params" => %{"target" => stable_id("sequence", target_key)}
              }
            ] ++ generated_capi_feedback_actions(branch["feedback"], rule_key)

          rule = %{
            "id" => stable_id("rule", rule_key),
            "name" => "generated-capi-branch-#{index}",
            "disabled" => false,
            "additionalScore" => 0.0,
            "forceProgress" => false,
            "default" => false,
            "correct" => false,
            "conditions" => %{
              "all" => [
                %{
                  "fact" => "stage.#{iframe["id"]}.#{declaration["key"]}",
                  "operator" => branch["operator"],
                  "value" => branch["value"]
                }
              ]
            },
            "event" => %{
              "type" => stable_id("event", rule_key),
              "params" => %{"actions" => actions}
            }
          }

          {:cont, {:ok, rules ++ [rule]}}

        nil ->
          {:halt, {:error, {:generated_capi_remediation_target_missing, target_section_id}}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, base_rules}
      {:ok, branch_rules} -> {:ok, branch_rules ++ base_rules}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generated_capi_feedback_actions(feedback, stable_key) when is_binary(feedback) do
    feedback_part =
      feedback
      |> PartBuilders.feedback_text_part()
      |> Map.put("id", stable_id("feedback-part", stable_key))

    [
      %{
        "type" => "feedback",
        "params" => %{
          "id" => stable_id("feedback", stable_key),
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
    ]
  end

  defp generated_capi_feedback_actions(_feedback, _stable_key), do: []

  defp next_part_y(parts) do
    parts
    |> Enum.map(fn part ->
      y = get_in(part, ["custom", "y"])
      height = get_in(part, ["custom", "height"])

      if is_number(y) and is_number(height), do: y + height, else: 0
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(16)
  end

  defp blueprint_title("exploration", index), do: "Explore the idea #{index}"
  defp blueprint_title("decision", index), do: "Make a decision #{index}"
  defp blueprint_title("content", index), do: "Explore the source #{index}"
  defp blueprint_title("reflection", index), do: "Reflect and explain #{index}"
  defp blueprint_title(_kind, index), do: "Check your thinking #{index}"

  defp blueprint_screen_parts(title, prompt, interaction, stable_key) do
    [
      title
      |> PartBuilders.text_flow(:h3, y: 0)
      |> Map.put("id", stable_id("heading", stable_key)),
      prompt
      |> PartBuilders.text_flow(:p, y: 54)
      |> Map.put("id", stable_id("prompt", stable_key)),
      interaction
    ]
  end

  defp blueprint_interaction(screen, type, prompt, stable_key)
       when type in ["multiple_choice", "dropdown"] do
    question = %{
      "prompt" => prompt,
      "type" => "multiple_choice",
      "choices" => screen["choices"] || get_in(screen, ["configuration", "choices"]),
      "correct_choice_id" =>
        screen["correct_choice_id"] || get_in(screen, ["configuration", "correct_choice_id"]),
      "correct_index" =>
        screen["correct_index"] || get_in(screen, ["configuration", "correct_index"])
    }

    with {:ok, normalized} <- normalize_question(question) do
      choices = normalized["normalized_choices"]
      correct_index = normalized["correct_index"]

      spec = %{
        "label" => prompt,
        "choices" => Enum.map(choices, & &1["text"]),
        "correct" => correct_index,
        "correctFeedback" =>
          first_present([
            screen["correct_feedback"],
            "That decision is supported by the evidence."
          ]),
        "incorrectFeedback" =>
          first_present([
            screen["incorrect_feedback"],
            screen["remediation"],
            "Revisit the source-grounded explanation and try again."
          ])
      }

      interaction =
        case type do
          "multiple_choice" ->
            PartBuilders.mcq_part(spec, y: 164)

          "dropdown" ->
            PartBuilders.dropdown_part(Map.put(spec, "optionLabels", spec["choices"]), y: 164)
        end
        |> Map.put("id", stable_id(type, stable_key))

      common_errors =
        choices
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {choice, option} ->
          if option - 1 != correct_index and present_text?(choice["feedback"]),
            do: [%{"option" => option, "feedback" => choice["feedback"]}],
            else: []
        end)

      {:ok, interaction, common_errors}
    end
  end

  defp blueprint_interaction(screen, "slider", prompt, stable_key) do
    configuration = screen["configuration"] || %{}

    with {:ok, minimum} <- blueprint_number(configuration["min"] || screen["min"]),
         {:ok, maximum} <- blueprint_number(configuration["max"] || screen["max"]),
         true <- maximum > minimum,
         {:ok, correct} <-
           blueprint_number(
             screen["correct_response"] || configuration["correct"] || screen["correct"]
           ),
         true <- correct >= minimum and correct <= maximum do
      part =
        %{
          "label" => prompt,
          "min" => minimum,
          "max" => maximum,
          "step" => positive_number(configuration["step"] || screen["step"], 1),
          "correct" => correct,
          "correctFeedback" =>
            first_present([screen["correct_feedback"], "Your prediction matches the model."]),
          "incorrectFeedback" =>
            first_present([
              screen["incorrect_feedback"],
              screen["remediation"],
              "Compare the value with the source example and try again."
            ])
        }
        |> PartBuilders.slider_part(y: 164)
        |> Map.put("id", stable_id("slider", stable_key))

      {:ok, part, []}
    else
      false -> {:error, :invalid_slider_range}
      {:error, _} = error -> error
    end
  end

  defp blueprint_interaction(screen, "number_input", prompt, stable_key) do
    configuration = screen["configuration"] || %{}

    with {:ok, correct} <-
           blueprint_number(
             screen["correct_response"] || configuration["correct"] || screen["correct"]
           ) do
      part =
        %{
          "label" => prompt,
          "prompt" => prompt,
          "unitsLabel" => configuration["units"] || screen["units"] || "",
          "correct" => correct,
          "correctFeedback" =>
            first_present([screen["correct_feedback"], "Your calculation is correct."]),
          "incorrectFeedback" =>
            first_present([
              screen["incorrect_feedback"],
              screen["remediation"],
              "Check the quantities and operation in the worked example."
            ])
        }
        |> PartBuilders.input_number_part(y: 164)
        |> Map.put("id", stable_id("number-input", stable_key))

      {:ok, part, []}
    end
  end

  defp blueprint_interaction(screen, "text", prompt, stable_key) do
    configuration = screen["configuration"] || %{}

    part =
      %{
        "label" => "Your reflection",
        "prompt" => prompt,
        "correctAnswer" => %{
          "minimumLength" =>
            positive_integer(configuration["minimum_length"] || screen["minimum_length"], 40),
          "mustContain" => configuration["must_contain"] || screen["must_contain"] || "",
          "mustNotContain" => ""
        },
        "correctFeedback" =>
          first_present([screen["correct_feedback"], "Your reflection is ready to continue."]),
        "incorrectFeedback" =>
          first_present([
            screen["incorrect_feedback"],
            screen["remediation"],
            "Connect your reasoning to the lesson evidence."
          ])
      }
      |> PartBuilders.input_text_part(y: 164)
      |> Map.put("id", stable_id("reflection", stable_key))

    {:ok, part, []}
  end

  defp blueprint_interaction(_screen, _type, _prompt, _stable_key),
    do: {:error, :unsupported_interaction_type}

  defp blueprint_adaptivity(screen, common_errors) do
    %{
      "maxAttempt" => 2,
      "score" => 0,
      "requireAllModified" => true,
      "correctFeedback" =>
        first_present([screen["correct_feedback"], "Continue to the next part of the lesson."]),
      "blankFeedback" => "Make a selection or enter a response before continuing.",
      "incorrectFeedback" =>
        first_present([
          screen["incorrect_feedback"],
          screen["remediation"],
          "Use the lesson evidence to reconsider your response."
        ]),
      "exhaustedFeedback" =>
        first_present([
          screen["remediation"],
          "Review the linked instruction, then compare it with the revealed response."
        ]),
      "commonErrors" => common_errors,
      "onCorrect" => "navigate next",
      "onIncorrect" => "show feedback"
    }
  end

  defp blueprint_remediation_target(
         screen,
         screen_id,
         remediation_paths,
         content_screens
       ) do
    target_section_id =
      present_string(screen["remediation_section_id"]) ||
        Enum.find_value(remediation_paths, fn
          %{"from_question_id" => ^screen_id, "to_section_id" => target} ->
            present_string(target)

          _ ->
            nil
        end)

    if is_binary(target_section_id) do
      content_screens
      |> Enum.filter(&(&1[:section_id] == target_section_id))
      |> List.last()
    end
  end

  defp blueprint_number(value) when is_integer(value) or is_float(value), do: {:ok, value}

  defp blueprint_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_numeric_response}
    end
  end

  defp blueprint_number(_), do: {:error, :missing_numeric_response}

  defp positive_number(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_number(value, _fallback) when is_float(value) and value > 0, do: value
  defp positive_number(_value, fallback), do: fallback

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp add_remediation_navigation(rules, %{key: target_key}, true) do
    target = stable_id("sequence", target_key)

    Enum.map(rules, fn
      %{"name" => "incorrect-max-attempt"} = rule ->
        update_in(rule, ["event", "params", "actions"], fn actions ->
          List.wrap(actions) ++
            [%{"type" => "navigation", "params" => %{"target" => target}}]
        end)

      rule ->
        rule
    end)
  end

  defp add_remediation_navigation(rules, _screen, _interleave?), do: rules

  defp advanced_content_screens(
         title,
         content,
         objective,
         stable_key,
         media_assets,
         attribution
       ) do
    sections = instructional_sections(content)
    curated = normalize_curated_enrichments(content["curated_enrichments"])
    section_ids = MapSet.new(sections, & &1["id"])

    overview_screens =
      content
      |> Map.get(
        "narrative",
        first_present([
          content["introduction"],
          content["overview"],
          content["why_this_matters"]
        ]) || ""
      )
      |> narrative_segments()
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, index} ->
        key = "#{stable_key}:overview:#{index}"

        content_screen(
          key,
          content_screen_title(title, index),
          content_screen_parts(
            title,
            objective,
            content["learning_objectives"] || [],
            segment,
            key,
            index
          )
        )
      end)

    opening_screens =
      advanced_callout_screens(
        content["opening_hook"],
        "Start here",
        "#{stable_key}:opening-hook"
      ) ++
        advanced_callout_screens(
          content["why_this_matters"],
          "Why this matters",
          "#{stable_key}:why-this-matters"
        ) ++
        advanced_callout_screens(
          content["callouts"],
          "Source connection",
          "#{stable_key}:source-callouts"
        ) ++
        advanced_callout_screens(
          content["curiosity_prompts"],
          "Think about it",
          "#{stable_key}:curiosity"
        ) ++
        advanced_media_screens(media_assets, nil, "#{stable_key}:opening-media")

    instruction_screens =
      sections
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {section, index} ->
        explanation_screens =
          section["explanation"]
          |> narrative_segments()
          |> Enum.with_index(1)
          |> Enum.map(fn {segment, segment_index} ->
            key = "#{stable_key}:instruction:#{index}:#{segment_index}"
            suffix = if segment_index == 1, do: "", else: " — Part #{segment_index}"

            content_screen(
              key,
              "#{section["title"]}#{suffix}",
              titled_content_parts("#{section["title"]}#{suffix}", segment, key)
            )
            |> Map.put(:section_id, section["id"])
          end)

        callout_screens =
          advanced_callout_screens(
            section["callouts"],
            "#{section["title"]} — Go deeper",
            "#{stable_key}:instruction:#{index}:callouts",
            section["id"]
          ) ++
            advanced_callout_screens(
              section["curiosity_prompts"],
              "#{section["title"]} — Think about it",
              "#{stable_key}:instruction:#{index}:curiosity",
              section["id"]
            )

        section_media_screens =
          advanced_media_screens(
            media_assets,
            section["id"],
            "#{stable_key}:instruction:#{index}:media",
            section["id"]
          )

        example_screens =
          section["examples"]
          |> normalize_examples()
          |> Enum.with_index(1)
          |> Enum.map(fn {example, example_index} ->
            key = "#{stable_key}:instruction:#{index}:example:#{example_index}"

            content_screen(
              key,
              worked_example_title(example, example_index),
              worked_example_parts(example, example_index, key)
            )
            |> Map.put(:section_id, section["id"])
          end)

        curated_screens =
          curated
          |> curated_for_placement(section["id"])
          |> advanced_curated_screens(
            "#{stable_key}:instruction:#{index}:curated",
            section["id"]
          )

        explanation_screens ++
          callout_screens ++ section_media_screens ++ example_screens ++ curated_screens
      end)

    unplaced_curated_screens =
      curated
      |> Enum.reject(fn enrichment ->
        placement = enrichment["placement_after_section_id"]
        is_binary(placement) and MapSet.member?(section_ids, placement)
      end)
      |> advanced_curated_screens("#{stable_key}:curated", nil)

    example_screens =
      content
      |> Map.get("worked_examples", [])
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {example, index} ->
        key = "#{stable_key}:example:#{index}"

        content_screen(
          key,
          worked_example_title(example, index),
          worked_example_parts(example, index, key)
        )
      end)

    takeaway_screens =
      content
      |> Map.get("key_takeaways", [])
      |> takeaway_items()
      |> case do
        [] -> []
        takeaways -> [takeaway_screen(title, takeaways, stable_key)]
      end

    application_screens =
      advanced_application_screens(
        content["application_problems"],
        "#{stable_key}:application"
      )

    attribution_screens =
      advanced_attribution_screens(content, attribution, "#{stable_key}:attribution")

    screens =
      overview_screens ++
        opening_screens ++
        instruction_screens ++
        unplaced_curated_screens ++
        example_screens ++
        application_screens ++ takeaway_screens ++ attribution_screens

    case screens do
      [only_screen] ->
        only_screen
        |> then(fn screen ->
          [
            screen,
            takeaway_screen(
              title,
              fallback_takeaways(content, objective),
              "#{stable_key}:fallback"
            )
          ]
        end)

      screens ->
        screens
    end
  end

  defp advanced_curated_screens(enrichments, stable_key, section_id) do
    enrichments
    |> Enum.with_index(1)
    |> Enum.map(fn {enrichment, index} ->
      key = "#{stable_key}:#{index}"
      title = enrichment["title"]

      parts =
        [
          title
          |> PartBuilders.text_flow(:h3, y: 0)
          |> Map.put("id", stable_id("heading", key)),
          enrichment["annotation"]
          |> PartBuilders.text_flow(:p, y: 52)
          |> Map.put("id", stable_id("annotation", key)),
          "Try this resource"
          |> PartBuilders.text_flow(:h4, y: 156)
          |> Map.put("id", stable_id("task-heading", key)),
          enrichment["learner_task"]
          |> PartBuilders.text_flow(:p, y: 196)
          |> Map.put("id", stable_id("task", key)),
          advanced_external_link_part(
            "Open #{title}",
            enrichment["url"],
            "#{key}:link",
            300
          )
        ]

      content_screen(key, title, parts)
      |> Map.put(:section_id, section_id)
    end)
  end

  defp advanced_external_link_part(label, url, stable_key, y) do
    label
    |> PartBuilders.text_flow(:p, y: y)
    |> Map.put("id", stable_id("link", stable_key))
    |> put_in(
      ["custom", "nodes"],
      [
        %{
          "tag" => "a",
          "href" => url,
          "target" => "_blank",
          "children" => [%{"tag" => "text", "text" => label, "children" => []}]
        }
      ]
    )
  end

  defp advanced_callout_screens(value, default_title, stable_key, section_id \\ nil) do
    value
    |> normalize_callouts(default_title)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {callout, index} ->
      callout["body"]
      |> narrative_segments()
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, segment_index} ->
        key = "#{stable_key}:#{index}:#{segment_index}"

        title =
          if segment_index == 1,
            do: callout["title"],
            else: "#{callout["title"]} — Part #{segment_index}"

        content_screen(key, title, titled_content_parts(title, segment, key))
        |> Map.put(:section_id, section_id)
      end)
    end)
  end

  defp advanced_media_screens(
         media_assets,
         placement,
         stable_key,
         section_id \\ nil
       ) do
    media_assets
    |> media_for_placement(placement)
    |> Enum.with_index(1)
    |> Enum.map(fn {asset, index} ->
      key = "#{stable_key}:#{index}"
      title = asset.title || "Explore the source"
      image_height = min(asset.height, @maximum_media_height)

      image =
        asset.url
        |> PartBuilders.image_part(y: 56, height: image_height, alt: asset.alt)
        |> Map.put("id", stable_id("image", key))

      caption =
        [asset.caption, asset.credit]
        |> Enum.filter(&present_text?/1)
        |> Enum.join(" — ")

      parts =
        [
          title
          |> PartBuilders.text_flow(:h3, y: 0)
          |> Map.put("id", stable_id("heading", key)),
          image
        ] ++
          if(present_text?(caption),
            do: [
              caption
              |> PartBuilders.text_flow(:p, y: 72 + image_height)
              |> Map.put("id", stable_id("caption", key))
            ],
            else: []
          )

      content_screen(key, title, parts)
      |> Map.put(:section_id, section_id)
    end)
  end

  defp advanced_application_screens(problems, stable_key) do
    problems
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {problem, index} ->
      {title, body} =
        case problem do
          value when is_binary(value) ->
            {"Apply what you learned #{index}", present_string(value)}

          value when is_map(value) ->
            {
              first_present([
                value["title"],
                value["heading"],
                "Apply what you learned #{index}"
              ]),
              [
                first_present([
                  value["prompt"],
                  value["problem"],
                  value["scenario"],
                  value["body"],
                  value["text"]
                ]),
                first_present([
                  value["guidance"],
                  value["hint"],
                  value["instructions"]
                ])
              ]
              |> Enum.filter(&present_text?/1)
              |> Enum.join("\n\n")
            }

          _ ->
            {nil, nil}
        end

      if present_text?(body) do
        body
        |> narrative_segments()
        |> Enum.with_index(1)
        |> Enum.map(fn {segment, segment_index} ->
          key = "#{stable_key}:#{index}:#{segment_index}"

          screen_title =
            if segment_index == 1, do: title, else: "#{title} — Part #{segment_index}"

          content_screen(
            key,
            screen_title,
            titled_content_parts(screen_title, segment, key)
          )
        end)
      else
        []
      end
    end)
  end

  defp advanced_attribution_screens(content, attribution, stable_key) do
    lines =
      attribution_lines(attribution) ++
        (content["source_evidence_links"]
         |> normalize_source_links()
         |> Enum.map(fn source -> "#{source.label}: #{source.url}" end))

    case Enum.uniq(lines) do
      [] ->
        []

      normalized_lines ->
        [
          content_screen(
            stable_key,
            "Sources and attribution",
            titled_list_parts("Sources and attribution", normalized_lines, stable_key)
          )
        ]
    end
  end

  defp content_screen(key, title, parts) do
    rules =
      nil
      |> TrapStateRulesBuilder.build_rules(nil, parts, [])
      |> Enum.filter(&(&1["name"] == "correct"))
      |> stabilize_rules(key)

    %{key: key, title: title, kind: :content, parts: parts, rules: rules}
  end

  defp compile_advanced_screens(screens) do
    Enum.reduce_while(screens, {:ok, []}, fn screen, {:ok, specs} ->
      model = %{
        "custom" => screen_custom(screen.key, screen.kind, screen_height(screen.parts)),
        "authoring" => %{
          "parts" => Enum.map(screen.parts, &PartBuilders.authoring_part/1),
          "rules" => screen.rules,
          "variablesRequiredForEvaluation" => required_variables(screen.rules),
          "activitiesRequiredForEvaluation" => []
        },
        "partsLayout" => screen.parts
      }

      case Model.parse(model) do
        {:ok, _parsed_model} ->
          spec = %{
            "key" => screen.key,
            "activity_type_slug" => "oli_adaptive",
            "title" => screen.title,
            "model" => model
          }

          {:cont, {:ok, specs ++ [spec]}}

        {:error, reason} ->
          {:halt, {:error, {:advanced_screen_compile_failed, screen.key, reason}}}
      end
    end)
  end

  defp content_screen_parts(title, objective, objectives, segment, stable_key, 1) do
    normalized_objectives =
      objectives
      |> Enum.filter(&present_text?/1)
      |> Enum.uniq()
      |> case do
        [] -> [objective]
        values -> values
      end

    objective_height = max(length(normalized_objectives) * 28, 48)

    [
      title
      |> PartBuilders.text_flow(:h2, y: 0)
      |> Map.put("id", stable_id("title", stable_key)),
      "Learning objectives"
      |> PartBuilders.text_flow(:h3, y: 48)
      |> Map.put("id", stable_id("objectives-heading", stable_key)),
      normalized_objectives
      |> PartBuilders.list_flow(:ul, y: 88)
      |> Map.put("id", stable_id("objectives", stable_key)),
      segment
      |> PartBuilders.text_flow(:p, y: 110 + objective_height)
      |> Map.put("id", stable_id("narrative", stable_key))
    ]
  end

  defp content_screen_parts(_title, _objective, _objectives, segment, stable_key, index) do
    [
      "Explore the concept — Part #{index}"
      |> PartBuilders.text_flow(:h3, y: 0)
      |> Map.put("id", stable_id("heading", stable_key)),
      segment
      |> PartBuilders.text_flow(:p, y: 52)
      |> Map.put("id", stable_id("narrative", stable_key))
    ]
  end

  defp titled_content_parts(title, body, stable_key) do
    [
      title
      |> PartBuilders.text_flow(:h3, y: 0)
      |> Map.put("id", stable_id("heading", stable_key)),
      body
      |> PartBuilders.text_flow(:p, y: 52)
      |> Map.put("id", stable_id("body", stable_key))
    ]
  end

  defp titled_list_parts(title, items, stable_key) do
    [
      title
      |> PartBuilders.text_flow(:h3, y: 0)
      |> Map.put("id", stable_id("heading", stable_key)),
      items
      |> PartBuilders.list_flow(:ul, y: 52)
      |> Map.put("id", stable_id("items", stable_key))
    ]
  end

  defp normalize_content_entries(entries, default_title) do
    entries
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {entry, index} when is_binary(entry) ->
        if present_text?(entry),
          do: [%{title: "#{default_title} #{index}", body: String.trim(entry), examples: []}],
          else: []

      {entry, index} when is_map(entry) ->
        title =
          first_present([
            entry["title"],
            entry["heading"],
            entry["name"],
            "#{default_title} #{index}"
          ])

        body =
          first_present([
            entry["content"],
            entry["body"],
            entry["explanation"],
            entry["narrative"],
            entry["text"]
          ])

        examples = takeaway_items(entry["examples"])

        if present_text?(body),
          do: [%{title: title, body: body, examples: examples}],
          else: []

      {_entry, _index} ->
        []
    end)
  end

  defp worked_example_parts(example, index, stable_key) when is_map(example) do
    title = worked_example_title(example, index)

    scenario =
      first_present([
        example["problem"],
        example["prompt"],
        example["scenario"]
      ])

    explanation =
      first_present([
        example["content"],
        example["body"],
        example["explanation"],
        example["walkthrough"]
      ])

    steps =
      example
      |> Map.get("steps", [])
      |> List.wrap()
      |> Enum.map(&content_entry_text/1)
      |> Enum.filter(&present_text?/1)

    solution =
      first_present([
        example["solution"],
        example["result"],
        example["answer"],
        example["conclusion"],
        example["takeaway"]
      ])

    {parts, next_y} =
      [
        title
        |> PartBuilders.text_flow(:h3, y: 0)
        |> Map.put("id", stable_id("heading", stable_key))
      ]
      |> maybe_append_text(scenario, :p, 52, "scenario", stable_key)

    {parts, next_y} =
      maybe_append_text(parts, explanation, :p, next_y, "explanation", stable_key)

    {parts, next_y} =
      if steps == [] do
        {parts, next_y}
      else
        steps_part =
          steps
          |> PartBuilders.list_flow(:ol, y: next_y)
          |> Map.put("id", stable_id("steps", stable_key))

        {parts ++ [steps_part], next_y + max(length(steps) * 28, 48) + 12}
      end

    {parts, _next_y} =
      maybe_append_text(parts, solution, :p, next_y, "solution", stable_key)

    parts
  end

  defp worked_example_parts(example, index, stable_key) do
    titled_content_parts(
      worked_example_title(example, index),
      content_entry_text(example),
      stable_key
    )
  end

  defp maybe_append_text(parts, text, tag, y, id_prefix, stable_key) do
    if present_text?(text) do
      part =
        text
        |> PartBuilders.text_flow(tag, y: y)
        |> Map.put("id", stable_id(id_prefix, stable_key))

      {parts ++ [part], y + 108}
    else
      {parts, y}
    end
  end

  defp worked_example_title(example, index) when is_map(example) do
    first_present([
      example["title"],
      example["heading"],
      "Worked example #{index}"
    ])
  end

  defp worked_example_title(_example, index), do: "Worked example #{index}"

  defp takeaway_screen(title, takeaways, stable_key) do
    key = "#{stable_key}:takeaways"

    content_screen(
      key,
      "#{title} — Key takeaways",
      [
        "Key takeaways"
        |> PartBuilders.text_flow(:h3, y: 0)
        |> Map.put("id", stable_id("heading", key)),
        takeaways
        |> PartBuilders.list_flow(:ul, y: 52)
        |> Map.put("id", stable_id("takeaways", key))
      ]
    )
  end

  defp takeaway_items(items) do
    items
    |> List.wrap()
    |> Enum.map(&content_entry_text/1)
    |> Enum.filter(&present_text?/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp fallback_takeaways(content, objective) do
    content
    |> Map.get("learning_objectives", [])
    |> takeaway_items()
    |> case do
      [] -> [objective]
      items -> items
    end
  end

  defp content_entry_text(value) when is_binary(value), do: String.trim(value)

  defp content_entry_text(value) when is_map(value) do
    first_present([
      value["text"],
      value["content"],
      value["body"],
      value["takeaway"],
      value["description"],
      value["title"]
    ])
  end

  defp content_entry_text(_value), do: ""

  defp question_screen_parts(question, reminder, stable_key, index) do
    prompt =
      "Check your understanding — Question #{index}"
      |> PartBuilders.text_flow(:h3, y: 0)
      |> Map.put("id", stable_id("prompt", stable_key))

    guidance =
      question_guidance(question)
      |> PartBuilders.text_flow(:p, y: 54)
      |> Map.put("id", stable_id("guidance", stable_key))

    interaction = question_interaction_part(question, reminder, stable_key, index)

    [prompt, guidance, interaction]
  end

  defp question_guidance(%{"type" => "multiple_choice"}) do
    "Choose the response best supported by the lesson. Feedback will guide you back to the relevant explanation when needed."
  end

  defp question_guidance(_question) do
    "Use the lesson evidence to explain your reasoning. A short or incomplete response will open a review prompt."
  end

  defp question_interaction_part(
         %{"type" => "short_answer"} = question,
         reminder,
         stable_key,
         index
       ) do
    %{
      "label" => "Your response",
      "prompt" => question_prompt(question),
      "correctAnswer" => %{
        "minimumLength" => question_minimum_length(question),
        "mustContain" => question_required_terms(question),
        "mustNotContain" => question_forbidden_terms(question)
      },
      "correctFeedback" =>
        question_feedback(
          question,
          "correct",
          "Your response addresses the prompt. Continue when you are ready."
        ),
      "incorrectFeedback" =>
        question_feedback(question, "incorrect", "Revisit this idea: #{reminder}")
    }
    |> PartBuilders.input_text_part(y: 164)
    |> Map.put("id", stable_id("question", "#{stable_key}:#{index}"))
  end

  defp question_interaction_part(
         %{"type" => "multiple_choice"} = question,
         reminder,
         stable_key,
         index
       ) do
    %{
      "label" => question_prompt(question),
      "choices" =>
        Enum.map(question["normalized_choices"], & &1["text"]) ++
          if(question["allow_not_sure"] == true, do: ["Not sure"], else: []),
      "correct" => question["correct_index"],
      "correctFeedback" =>
        question_feedback(question, "correct", "Correct. Continue when you are ready."),
      "incorrectFeedback" =>
        first_present([
          question["hint"],
          question_feedback(question, "incorrect", "Revisit this idea: #{reminder}")
        ])
    }
    |> PartBuilders.mcq_part(y: 164)
    |> Map.put("id", stable_id("question", "#{stable_key}:#{index}"))
  end

  defp adaptivity_config(question, reminder) do
    %{
      "maxAttempt" => 2,
      "score" => 0,
      "requireAllModified" => true,
      "correctFeedback" =>
        question_feedback(
          question,
          "correct",
          "Your response addresses the prompt. Continue when you are ready."
        ),
      "blankFeedback" =>
        question_feedback(
          question,
          "blank",
          "Add a more complete explanation before continuing. Revisit this idea: #{reminder}"
        ),
      "incorrectFeedback" =>
        question_feedback(question, "incorrect", "Revisit this idea: #{reminder}"),
      "exhaustedFeedback" =>
        question_feedback(
          question,
          "exhausted",
          "Compare your response with this source-grounded reminder: #{reminder}"
        ),
      "commonErrors" => question_common_errors(question),
      "onCorrect" => "navigate next",
      "onIncorrect" => "show feedback"
    }
  end

  defp question_common_errors(
         %{
           "type" => "multiple_choice",
           "normalized_choices" => choices,
           "correct_index" => correct_index
         } = question
       ) do
    errors =
      choices
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {choice, option} ->
        if option - 1 != correct_index and present_text?(choice["feedback"]),
          do: [%{"option" => option, "feedback" => choice["feedback"]}],
          else: []
      end)

    if question["allow_not_sure"] == true do
      errors ++
        [
          %{
            "option" => length(choices) + 1,
            "feedback" =>
              first_present([
                question["hint"],
                "Review the preceding explanation, then try again."
              ])
          }
        ]
    else
      errors
    end
  end

  defp question_common_errors(_question), do: []

  defp narrative_segments(narrative) do
    narrative
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        ["Review the lesson objective and use the source evidence in each practice check."]

      text ->
        text
        |> String.split(~r/\s+/u, trim: true)
        |> Enum.chunk_every(@narrative_words_per_screen)
        |> Enum.map(&Enum.join(&1, " "))
    end
  end

  defp content_screen_title(title, 1), do: "#{title} — Explore"
  defp content_screen_title(title, index), do: "#{title} — Explore #{index}"

  defp remediation_excerpt(question, content, objective, index) do
    case present_string(question["remediation"]) do
      remediation when is_binary(remediation) ->
        remediation

      nil ->
        segments =
          [content["narrative"]]
          |> Kernel.++(
            content
            |> Map.get("instructional_sections", [])
            |> normalize_content_entries("Concept")
            |> Enum.map(& &1.body)
          )
          |> Kernel.++(takeaway_items(content["key_takeaways"]))
          |> Enum.filter(&present_text?/1)
          |> Enum.flat_map(&narrative_segments/1)
          |> case do
            [] -> [objective]
            values -> values
          end

        segments
        |> Enum.at(rem(index - 1, length(segments)), objective)
        |> String.slice(0, 360)
        |> String.trim()
        |> case do
          "" -> objective
          excerpt -> excerpt
        end
    end
  end

  defp question_prompt(%{"prompt" => prompt}) when is_binary(prompt), do: String.trim(prompt)
  defp question_prompt(_question), do: "Explain the lesson's central idea."

  defp question_minimum_length(%{"minimum_length" => value})
       when is_integer(value) and value > 0,
       do: min(value, 500)

  defp question_minimum_length(_question), do: @minimum_reflection_length

  defp question_required_terms(question) do
    question
    |> Map.get(
      "answer_keywords",
      Map.get(question, "keywords", get_in(question, ["correct_answer", "mustContain"]) || [])
    )
    |> normalize_terms()
  end

  defp question_forbidden_terms(question) do
    question
    |> Map.get("forbidden_keywords", get_in(question, ["correct_answer", "mustNotContain"]) || [])
    |> normalize_terms()
  end

  defp normalize_terms(terms) when is_list(terms) do
    terms
    |> Enum.filter(&present_text?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.take(2)
    |> Enum.join(",")
  end

  defp normalize_terms(terms) when is_binary(terms), do: String.trim(terms)
  defp normalize_terms(_terms), do: ""

  defp question_feedback(question, kind, fallback) do
    direct_key =
      case kind do
        "correct" -> "correct_feedback"
        "incorrect" -> "incorrect_feedback"
        "blank" -> "incorrect_feedback"
        "exhausted" -> "remediation"
      end

    case question[direct_key] || get_in(question, ["feedback", kind]) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> fallback
          feedback -> feedback
        end

      _ ->
        fallback
    end
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp content_block(children, stable_key) when is_list(children) do
    %{
      "id" => stable_id("content", stable_key),
      "type" => "content",
      "children" => children
    }
  end

  defp text_element(type, text, key) do
    %{
      "id" => stable_id(type, key),
      "type" => type,
      "children" => [%{"text" => to_string(text || "")}]
    }
  end

  defp paragraph_elements(value, stable_key) do
    value
    |> normalize_strings()
    |> Enum.with_index(1)
    |> Enum.map(fn {paragraph, index} ->
      text_element("p", paragraph, "#{stable_key}:paragraph:#{index}")
    end)
  end

  defp string_list_element(type, values, stable_key) when type in ["ul", "ol"] do
    %{
      "id" => stable_id(type, stable_key),
      "type" => type,
      "children" =>
        values
        |> normalize_strings()
        |> Enum.with_index(1)
        |> Enum.map(fn {value, index} ->
          %{
            "id" => stable_id("li", "#{stable_key}:#{index}"),
            "type" => "li",
            "children" => [%{"text" => value}]
          }
        end)
    }
  end

  defp learning_objectives(content) do
    objectives =
      content
      |> Map.get("learning_objectives", [])
      |> normalize_strings()

    case objectives do
      [] ->
        [
          content["objective"]
          |> normalize_strings()
          |> List.first()
          |> case do
            nil -> "Explain and apply the lesson's core ideas."
            objective -> objective
          end
        ]

      objectives ->
        objectives
    end
  end

  defp instructional_sections(content) do
    sections =
      content["instructional_sections"] ||
        content["lesson_sections"] ||
        content["sections"]

    sections
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {section, index} ->
      case normalize_instructional_section(section, index, content) do
        nil -> []
        normalized -> [normalized]
      end
    end)
    |> case do
      [] ->
        case first_present([content["narrative"]]) do
          nil ->
            []

          narrative ->
            [
              %{
                "id" => "core-concepts",
                "title" => "Core Concepts",
                "explanation" => narrative,
                "examples" => [],
                "callouts" => [],
                "curiosity_prompts" => [],
                "media" => [],
                "key_takeaways" => [],
                "source_evidence_links" => content["source_evidence_links"] || []
              }
            ]
        end

      normalized ->
        normalized
    end
  end

  defp normalize_instructional_section(section, index, content) when is_binary(section) do
    case present_string(section) do
      nil ->
        nil

      explanation ->
        %{
          "id" => "section-#{index}",
          "title" => "Core Concept #{index}",
          "explanation" => explanation,
          "examples" => [],
          "callouts" => [],
          "curiosity_prompts" => [],
          "media" => [],
          "key_takeaways" => [],
          "source_evidence_links" => content["source_evidence_links"] || []
        }
    end
  end

  defp normalize_instructional_section(section, index, content) when is_map(section) do
    title =
      first_present([
        section["title"],
        section["heading"],
        "Core Concept #{index}"
      ])

    explanation =
      first_present([
        section["explanation"],
        section["body"],
        section["content"],
        section["narrative"]
      ])

    case explanation do
      nil ->
        nil

      explanation ->
        %{
          "id" => first_present([section["id"], "section-#{index}"]),
          "title" => title,
          "explanation" => explanation,
          "examples" => section["examples"] || section["worked_examples"] || [],
          "callouts" => section["callouts"] || section["callout_blocks"] || [],
          "curiosity_prompts" => section["curiosity_prompts"] || [],
          "media" => section["media"] || section["images"] || [],
          "key_takeaways" => section["key_takeaways"] || section["takeaways"] || [],
          "evidence_block_ids" => normalize_identifier_list(section["evidence_block_ids"]),
          "source_evidence_links" =>
            section["source_evidence_links"] || content["source_evidence_links"] || []
        }
    end
  end

  defp normalize_instructional_section(_, _, _), do: nil

  defp normalize_examples(examples) do
    examples
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {example, index} when is_binary(example) ->
        case present_string(example) do
          nil ->
            []

          explanation ->
            [
              %{
                "title" => "Worked Example #{index}",
                "explanation" => explanation,
                "steps" => [],
                "source_evidence_links" => []
              }
            ]
        end

      {example, index} when is_map(example) ->
        explanation =
          first_present([
            example["explanation"],
            example["walkthrough"],
            example["body"],
            example["content"]
          ])

        steps = normalize_strings(example["steps"])

        if is_nil(explanation) and steps == [] do
          []
        else
          [
            %{
              "title" =>
                first_present([
                  example["title"],
                  example["name"],
                  "Worked Example #{index}"
                ]),
              "scenario" => first_present([example["scenario"], example["problem"]]),
              "explanation" => explanation,
              "steps" => steps,
              "conclusion" =>
                first_present([
                  example["conclusion"],
                  example["solution"],
                  example["result"],
                  example["answer"]
                ]),
              "source_evidence_links" => example["source_evidence_links"] || []
            }
          ]
        end

      _ ->
        []
    end)
  end

  defp ordered_step_elements(steps, stable_key) do
    case normalize_strings(steps) do
      [] ->
        []

      normalized_steps ->
        [
          text_element("h4", "Walkthrough", "#{stable_key}:walkthrough-heading"),
          string_list_element("ol", normalized_steps, "#{stable_key}:walkthrough")
        ]
    end
  end

  defp section_takeaway_elements(takeaways, stable_key) do
    case normalize_strings(takeaways) do
      [] ->
        []

      normalized_takeaways ->
        [
          text_element("h3", "Section Takeaways", "#{stable_key}:takeaways-heading"),
          string_list_element("ul", normalized_takeaways, "#{stable_key}:takeaways")
        ]
    end
  end

  defp source_evidence_elements(links, stable_key) do
    case normalize_source_links(links) do
      [] ->
        []

      source_links ->
        [
          text_element("h4", "Source Evidence", "#{stable_key}:sources-heading"),
          source_link_list(source_links, "#{stable_key}:sources")
        ]
    end
  end

  defp source_link_list(links, stable_key) do
    %{
      "id" => stable_id("ul", stable_key),
      "type" => "ul",
      "children" =>
        links
        |> Enum.with_index(1)
        |> Enum.map(fn {link, index} ->
          %{
            "id" => stable_id("li", "#{stable_key}:#{index}"),
            "type" => "li",
            "children" => [
              %{
                "type" => "a",
                "href" => link.url,
                "target" => "_blank",
                "linkType" => "url",
                "children" => [%{"text" => link.label}]
              }
            ]
          }
        end)
    }
  end

  defp normalize_source_links(links) do
    links
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {url, index} when is_binary(url) ->
        case safe_source_url(url) do
          nil -> []
          safe_url -> [%{url: safe_url, label: "OpenStax source #{index}"}]
        end

      {link, index} when is_map(link) ->
        case safe_source_url(link["url"] || link["href"]) do
          nil ->
            []

          safe_url ->
            [
              %{
                url: safe_url,
                label:
                  first_present([
                    link["title"],
                    link["label"],
                    "OpenStax source #{index}"
                  ])
              }
            ]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp normalize_curated_enrichments(enrichments) do
    enrichments
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = enrichment ->
        with "annotated_link" <- enrichment["delivery_mode"],
             url when is_binary(url) <- safe_curated_url(enrichment["url"]),
             title when is_binary(title) <- present_string(enrichment["title"]),
             annotation when is_binary(annotation) <-
               present_string(enrichment["annotation"]),
             learner_task when is_binary(learner_task) <-
               present_string(enrichment["learner_task"]) do
          [
            %{
              "proposal_id" => enrichment["proposal_id"],
              "title" => title,
              "url" => url,
              "annotation" => annotation,
              "learner_task" => learner_task,
              "placement_after_section_id" =>
                get_in(enrichment, ["placement", "after_section_id"])
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["proposal_id"])
  end

  defp curated_for_placement(enrichments, section_id) do
    Enum.filter(enrichments, &(&1["placement_after_section_id"] == section_id))
  end

  defp safe_curated_url(url) do
    with trimmed when is_binary(trimmed) <- present_string(url),
         %URI{scheme: "https", host: host, userinfo: nil} = uri <- URI.parse(trimmed),
         true <- is_binary(host) and host != "",
         true <- is_nil(uri.port) or uri.port == 443 do
      URI.to_string(uri)
    else
      _ -> nil
    end
  end

  defp safe_source_url(url) do
    with trimmed when is_binary(trimmed) <- present_string(url),
         %URI{scheme: "https", host: host, userinfo: nil} = uri <- URI.parse(trimmed),
         true <- host in ["openstax.org", "www.openstax.org"],
         true <- is_nil(uri.port) or uri.port == 443 do
      URI.to_string(uri)
    else
      _ -> nil
    end
  end

  defp resolve_media_assets(content, opts) do
    media_urls = Keyword.get(opts, :media_urls, %{})

    if is_map(media_urls) do
      content
      |> media_descriptors()
      |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, assets} ->
        case resolve_media_asset(descriptor, media_urls) do
          {:ok, asset} -> {:cont, {:ok, assets ++ [asset]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_media_urls}
    end
  end

  defp media_descriptors(content) do
    top_level =
      content
      |> media_entries()
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} ->
        %{
          entry: entry,
          placement:
            first_present([
              map_value(entry, "placement_after_section_id"),
              map_value(entry, "section_id")
            ]),
          fallback_id: "opening-media-#{index}"
        }
      end)

    section_entries =
      (content["instructional_sections"] ||
         content["lesson_sections"] ||
         content["sections"] ||
         [])
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {section, section_index} when is_map(section) ->
          section_id = first_present([section["id"], "section-#{section_index}"])

          section
          |> media_entries()
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, media_index} ->
            %{
              entry: entry,
              placement: section_id,
              fallback_id: "#{section_id}-media-#{media_index}"
            }
          end)

        _section ->
          []
      end)

    top_level ++ section_entries
  end

  defp media_entries(value) when is_map(value) do
    value["media"] || value["images"] ||
      []
      |> List.wrap()
  end

  defp media_entries(_value), do: []

  defp resolve_media_asset(%{entry: entry} = descriptor, media_urls) do
    normalized_entry = normalize_media_entry(entry, descriptor.fallback_id)
    media_id = normalized_entry.id
    resolved_entry = normalize_media_override(fetch_media_override(media_urls, media_id))

    url = first_present([resolved_entry.url, normalized_entry.url])
    alt = first_present([normalized_entry.alt, resolved_entry.alt])
    caption = first_present([normalized_entry.caption, resolved_entry.caption])
    credit = first_present([normalized_entry.credit, resolved_entry.credit])
    title = first_present([normalized_entry.title, resolved_entry.title])
    height = normalized_media_height(normalized_entry.height || resolved_entry.height)

    cond do
      is_nil(url) ->
        {:error, {:missing_media_url, media_id}}

      is_nil(safe_media_url(url)) ->
        {:error, {:unsafe_media_url, media_id}}

      is_nil(alt) ->
        {:error, {:missing_media_alt, media_id}}

      true ->
        {:ok,
         %{
           id: media_id,
           placement: descriptor.placement,
           url: safe_media_url(url),
           alt: alt,
           caption: caption,
           credit: credit,
           title: title,
           height: height
         }}
    end
  end

  defp normalize_media_entry(entry, fallback_id) when is_binary(entry) do
    %{
      id: present_string(entry) || fallback_id,
      url: nil,
      alt: nil,
      caption: nil,
      credit: nil,
      title: nil,
      height: nil
    }
  end

  defp normalize_media_entry(entry, fallback_id) when is_map(entry) do
    %{
      id:
        first_present([
          map_value(entry, "id"),
          map_value(entry, "media_id"),
          map_value(entry, "source_media_id"),
          fallback_id
        ]),
      url:
        first_present([
          map_value(entry, "url"),
          map_value(entry, "src"),
          map_value(entry, "content_url")
        ]),
      alt:
        first_present([
          map_value(entry, "alt"),
          map_value(entry, "alt_text"),
          map_value(entry, "description")
        ]),
      caption: first_present([map_value(entry, "caption"), map_value(entry, "title")]),
      credit:
        first_present([
          map_value(entry, "credit"),
          map_value(entry, "attribution"),
          map_value(entry, "source")
        ]),
      title: first_present([map_value(entry, "title"), map_value(entry, "heading")]),
      height: map_value(entry, "height")
    }
  end

  defp normalize_media_entry(_entry, fallback_id) do
    normalize_media_entry(fallback_id, fallback_id)
  end

  defp normalize_media_override(value) when is_binary(value) do
    %{
      url: present_string(value),
      alt: nil,
      caption: nil,
      credit: nil,
      title: nil,
      height: nil
    }
  end

  defp normalize_media_override(value) when is_map(value) do
    %{
      url:
        first_present([
          map_value(value, "url"),
          map_value(value, "src"),
          map_value(value, "content_url")
        ]),
      alt: first_present([map_value(value, "alt"), map_value(value, "alt_text")]),
      caption: first_present([map_value(value, "caption"), map_value(value, "title")]),
      credit:
        first_present([
          map_value(value, "credit"),
          map_value(value, "attribution"),
          map_value(value, "source")
        ]),
      title: first_present([map_value(value, "title"), map_value(value, "heading")]),
      height: map_value(value, "height")
    }
  end

  defp normalize_media_override(_value) do
    %{url: nil, alt: nil, caption: nil, credit: nil, title: nil, height: nil}
  end

  defp fetch_media_override(media_urls, media_id) do
    Map.get(media_urls, media_id) ||
      Enum.find_value(media_urls, fn
        {key, value} when is_atom(key) ->
          if Atom.to_string(key) == media_id, do: value

        _entry ->
          nil
      end)
  end

  defp normalized_media_height(value) when is_integer(value),
    do: value |> max(120) |> min(@maximum_media_height)

  defp normalized_media_height(value) when is_float(value),
    do: value |> round() |> normalized_media_height()

  defp normalized_media_height(_value), do: 280

  defp safe_media_url(url) do
    case present_string(url) do
      "/" <> _path = relative_url ->
        relative_url

      normalized_url ->
        case URI.parse(normalized_url || "") do
          %URI{scheme: scheme, host: host, userinfo: nil}
          when scheme in ["http", "https"] and is_binary(host) ->
            normalized_url

          %URI{scheme: "staged", host: host, userinfo: nil} when is_binary(host) ->
            normalized_url

          _uri ->
            nil
        end
    end
  end

  defp media_for_placement(media_assets, placement) do
    Enum.filter(media_assets, &(&1.placement == placement))
  end

  defp required_media_ids(media_assets) do
    media_assets
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp normalize_attribution(content, opts) do
    source = Keyword.get(opts, :attribution) || content["attribution"]

    case source do
      value when is_binary(value) ->
        %{
          lines: normalize_strings(value),
          links: [],
          raw: value
        }

      value when is_map(value) ->
        lines =
          [
            map_value(value, "text"),
            map_value(value, "statement"),
            map_value(value, "attribution"),
            attribution_labeled_value("Source", map_value(value, "source_title")),
            attribution_labeled_value("Book", map_value(value, "book_title")),
            attribution_labeled_value("Authors", map_value(value, "authors")),
            attribution_labeled_value(
              "License",
              map_value(value, "license_name") || map_value(value, "license")
            )
          ]
          |> Enum.flat_map(&normalize_strings/1)
          |> Enum.uniq()

        links =
          [
            {"Source", map_value(value, "source_url") || map_value(value, "url")},
            {"License", map_value(value, "license_url")}
          ]
          |> Enum.flat_map(fn {label, url} ->
            case safe_external_url(url) do
              nil -> []
              safe_url -> [%{label: label, url: safe_url}]
            end
          end)
          |> Enum.uniq_by(& &1.url)

        %{lines: lines, links: links, raw: value}

      _value ->
        %{lines: [], links: [], raw: nil}
    end
  end

  defp attribution_labeled_value(_label, nil), do: nil

  defp attribution_labeled_value(label, value) when is_list(value) do
    value
    |> normalize_strings()
    |> case do
      [] -> nil
      values -> "#{label}: #{Enum.join(values, ", ")}"
    end
  end

  defp attribution_labeled_value(label, value) when is_binary(value) do
    case present_string(value) do
      nil -> nil
      normalized -> "#{label}: #{normalized}"
    end
  end

  defp attribution_labeled_value(_label, _value), do: nil

  defp attribution_lines(attribution), do: attribution.lines

  defp attribution_payload(%{raw: raw}), do: raw

  defp safe_external_url(url) do
    with normalized when is_binary(normalized) <- present_string(url),
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(normalized),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) do
      normalized
    else
      _reason -> nil
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _entry ->
          nil
      end)
  end

  defp maybe_put_present(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_strings(value) when is_binary(value) do
    value
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_strings(value) when is_map(value) do
    value
    |> then(fn entry ->
      first_present([
        entry["text"],
        entry["content"],
        entry["body"],
        entry["takeaway"],
        entry["description"],
        entry["title"]
      ])
    end)
    |> normalize_strings()
  end

  defp normalize_strings(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_strings/1)
    |> Enum.uniq()
  end

  defp normalize_strings(_), do: []

  defp first_present(values), do: Enum.find_value(values, &present_string/1)

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  defp questions(%{"items" => items}) when is_list(items), do: items
  defp questions(%{"questions" => items}) when is_list(items), do: items
  defp questions(items) when is_list(items), do: items
  defp questions(_), do: []

  defp validate_questions(questions) when length(questions) in 2..6 do
    questions
    |> Enum.reduce_while({:ok, []}, fn question, {:ok, normalized} ->
      case normalize_question(question) do
        {:ok, normalized_question} ->
          {:cont, {:ok, normalized ++ [normalized_question]}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_question_payload}}
      end
    end)
  end

  defp validate_questions(_), do: {:error, :invalid_question_count}

  defp normalize_question(%{"prompt" => prompt, "type" => type} = question)
       when is_binary(prompt) and type in ["short_answer", "multiple_choice", "mcq"] do
    case {present_string(prompt), type} do
      {nil, _type} ->
        {:error, :missing_question_prompt}

      {normalized_prompt, "short_answer"} ->
        {:ok,
         question
         |> Map.put("prompt", normalized_prompt)
         |> Map.put("type", "short_answer")}

      {normalized_prompt, _multiple_choice} ->
        with {:ok, choices} <- normalize_question_choices(question["choices"]),
             {:ok, correct_index} <- resolve_correct_index(question, choices) do
          {:ok,
           question
           |> Map.put("prompt", normalized_prompt)
           |> Map.put("type", "multiple_choice")
           |> Map.put("normalized_choices", choices)
           |> Map.put("correct_index", correct_index)}
        end
    end
  end

  defp normalize_question(_question), do: {:error, :unsupported_question_type}

  defp normalize_question_choices(choices) when is_list(choices) and length(choices) in 2..8 do
    choices
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {choice, index}, {:ok, normalized} ->
      case normalize_question_choice(choice, index) do
        {:ok, normalized_choice} ->
          {:cont, {:ok, normalized ++ [normalized_choice]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize_question_choices(_choices), do: {:error, :invalid_multiple_choice_choices}

  defp normalize_question_choice(choice, index) when is_binary(choice) do
    case present_string(choice) do
      nil ->
        {:error, :blank_multiple_choice_choice}

      text ->
        {:ok,
         %{
           "id" => "choice-#{index + 1}",
           "text" => text,
           "feedback" => nil,
           "marked_correct" => false
         }}
    end
  end

  defp normalize_question_choice(choice, index) when is_map(choice) do
    text =
      first_present([
        choice["text"],
        choice["label"],
        choice["body"],
        choice["body_md"],
        choice["value"],
        choice["content"]
      ])

    case text do
      nil ->
        {:error, :blank_multiple_choice_choice}

      normalized_text ->
        {:ok,
         %{
           "id" => first_present([choice["id"], choice["key"], "choice-#{index + 1}"]),
           "text" => normalized_text,
           "feedback" =>
             first_present([
               choice["feedback"],
               choice["feedback_md"],
               choice["rationale"]
             ]),
           "marked_correct" =>
             choice["correct"] == true or
               (is_number(choice["score"]) and choice["score"] > 0)
         }}
    end
  end

  defp normalize_question_choice(_choice, _index),
    do: {:error, :invalid_multiple_choice_choice}

  defp resolve_correct_index(question, choices) do
    candidate_values = [
      question["correct_index"],
      question["correct"],
      question["correct_answer"],
      question["correct_choice_id"],
      question["answer"]
    ]

    explicit_indices =
      candidate_values
      |> Enum.flat_map(&correct_candidate_indices(&1, choices))

    marked_indices =
      choices
      |> Enum.with_index()
      |> Enum.flat_map(fn {choice, index} ->
        if choice["marked_correct"], do: [index], else: []
      end)

    case Enum.uniq(explicit_indices ++ marked_indices) do
      [correct_index] -> {:ok, correct_index}
      [] -> {:error, :missing_multiple_choice_answer}
      _many -> {:error, :ambiguous_multiple_choice_answer}
    end
  end

  defp correct_candidate_indices(value, choices)
       when is_integer(value) and value >= 0 and value < length(choices),
       do: [value]

  defp correct_candidate_indices(value, choices) when is_binary(value) do
    normalized = String.trim(value)

    choices
    |> Enum.with_index()
    |> Enum.flat_map(fn {choice, index} ->
      if normalized in [choice["id"], choice["text"]], do: [index], else: []
    end)
  end

  defp correct_candidate_indices(_value, _choices), do: []

  defp normalize_identifier_list(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        case present_string(value) do
          nil -> []
          normalized -> [normalized]
        end

      _value ->
        []
    end)
    |> Enum.uniq()
  end

  defp screen_height(parts) do
    parts
    |> Enum.map(fn part ->
      custom = part["custom"] || %{}
      y = numeric_dimension(custom["y"], 0)
      height = numeric_dimension(custom["height"], 80)
      y + height
    end)
    |> Enum.max(fn -> @default_height - @screen_bottom_padding end)
    |> Kernel.+(@screen_bottom_padding)
    |> max(@default_height)
  end

  defp numeric_dimension(value, _fallback) when is_integer(value), do: value
  defp numeric_dimension(value, _fallback) when is_float(value), do: round(value)
  defp numeric_dimension(_value, fallback), do: fallback

  defp screen_custom(stable_key, kind, height) when kind in [:content, :question] do
    %{
      "applyBtnFlag" => false,
      "applyBtnLabel" => "",
      "checkButtonLabel" => if(kind == :content, do: "Continue", else: "Check response"),
      "combineFeedback" => false,
      "customCssClass" => "layout-section openstax-import-#{sanitize_key(stable_key)}",
      "facts" => [],
      "lockCanvasSize" => false,
      "mainBtnLabel" => "",
      "maxAttempt" => if(kind == :question, do: 2, else: 0),
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
      "width" => @default_width,
      "height" => max(height, @default_height),
      "x" => 0,
      "y" => 0,
      "z" => 0
    }
  end

  defp page_custom do
    %{
      "contentMode" => "expert",
      "defaultScreenHeight" => @default_height,
      "defaultScreenWidth" => @default_width,
      "enableHistory" => true,
      "maxScore" => 0,
      "responsiveLayout" => true,
      "themeId" => "torus-default-light",
      "totalScore" => 0,
      "variables" => []
    }
  end

  defp stabilize_rules(rules, stable_key) do
    rules
    |> Enum.with_index()
    |> Enum.map(fn {rule, index} ->
      id = stable_id("rule", "#{stable_key}:#{index}")

      rule
      |> Map.put("id", id)
      |> put_in(["event", "type"], id)
      |> stabilize_actions(stable_key, index)
    end)
  end

  defp stabilize_actions(rule, stable_key, rule_index) do
    update_in(rule, ["event", "params", "actions"], fn actions ->
      actions
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"type" => "feedback"} = action, action_index} ->
          action_id = stable_id("feedback", "#{stable_key}:#{rule_index}:#{action_index}")

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

  defp required_variables(rules) do
    rules
    |> collect_values("fact")
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
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

  defp realize_node(%{"type" => "activity-reference", "activity_key" => key} = reference, ids) do
    case Map.fetch(ids, key) do
      {:ok, resource_id} when is_integer(resource_id) ->
        {:ok,
         reference
         |> Map.delete("activity_key")
         |> Map.put("activity_id", resource_id)}

      _ ->
        {:error, {:missing_compiled_activity, key}}
    end
  end

  defp realize_node(value, ids) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      case realize_node(nested, ids) do
        {:ok, realized} -> {:cont, {:ok, Map.put(acc, key, realized)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp realize_node(value, ids) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, acc} ->
      case realize_node(nested, ids) do
        {:ok, realized} -> {:cont, {:ok, acc ++ [realized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp realize_node(value, _ids), do: {:ok, value}

  defp contains_activity_key?(value) when is_map(value) do
    Map.has_key?(value, "activity_key") or
      Enum.any?(Map.values(value), &contains_activity_key?/1)
  end

  defp contains_activity_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_activity_key?/1)

  defp contains_activity_key?(_), do: false

  defp stabilize_model_ids(model, stable_key),
    do: stabilize_model_ids(model, stable_key, [])

  defp stabilize_model_ids(value, stable_key, path) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.with_index()
    |> Map.new(fn {{key, nested}, index} ->
      next_path = path ++ ["#{key}:#{index}"]

      normalized =
        if key == "id" do
          stable_id("model", Enum.join([stable_key | next_path], ":"))
        else
          stabilize_model_ids(nested, stable_key, next_path)
        end

      {key, normalized}
    end)
  end

  defp stabilize_model_ids(value, stable_key, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {nested, index} ->
      stabilize_model_ids(nested, stable_key, path ++ ["item:#{index}"])
    end)
  end

  defp stabilize_model_ids(value, _stable_key, _path), do: value

  defp stable_id(prefix, key) do
    digest =
      :crypto.hash(:sha256, "#{prefix}:#{key}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    "ci_#{sanitize_key(prefix)}_#{digest}"
  end

  defp sanitize_key(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "item"
      key -> key
    end
  end
end
