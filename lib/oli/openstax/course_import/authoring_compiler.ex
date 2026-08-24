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
  alias Oli.OpenStax.CourseImport.{GeneratedSimulation, ImportContract, SourceASTRenderer}
  alias Oli.TorusDoc.{ActivityConverter, ActivityParser}
  alias Oli.Utils.SchemaResolver

  @basic_content_schema ImportContract.content_schema_version(:basic)
  @advanced_content_schema ImportContract.content_schema_version(:advanced)

  @default_width 1200
  @default_height 540
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

    with :ok <- validate_current_content_contract(mode, content_payload),
         {:ok, normalized_questions} <- validate_questions(questions, mode, content_payload),
         {:ok, media_assets} <- resolve_media_assets(content_payload, opts),
         attribution <-
           content_payload
           |> normalize_attribution(opts)
           |> enrich_attribution(content_payload, media_assets),
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

  defp validate_current_content_contract("basic", %{
         "schema_version" => version,
         "authoring_mode" => "basic"
       })
       when version == @basic_content_schema,
       do: :ok

  defp validate_current_content_contract("advanced", %{
         "schema_version" => version,
         "authoring_mode" => "advanced",
         "experience_blueprint" => %{}
       })
       when version == @advanced_content_schema,
       do: :ok

  defp validate_current_content_contract(mode, content),
    do: {:error, {:unsupported_openstax_content_contract, mode, content["schema_version"]}}

  defp compile_mode(
         "advanced",
         title,
         %{"schema_version" => version} = content,
         [],
         stable_key,
         media_assets,
         attribution,
         opts
       )
       when version == @advanced_content_schema,
       do:
         compile_advanced_v7(
           title,
           content,
           stable_key,
           media_assets,
           attribution,
           opts
         )

  defp compile_mode(
         "basic",
         title,
         %{"schema_version" => version} = content,
         questions,
         stable_key,
         media_assets,
         attribution,
         opts
       )
       when version == @basic_content_schema,
       do:
         compile_basic(
           title,
           content,
           questions,
           stable_key,
           media_assets,
           attribution,
           opts
         )

  defp compile_mode(mode, _title, content, _questions, _stable_key, _media, _attribution, _opts),
    do: {:error, {:unsupported_openstax_content_contract, mode, content["schema_version"]}}

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

  defp compile_basic(title, content, questions, stable_key, media_assets, attribution, opts) do
    with {:ok, activity_specs} <-
           compile_basic_questions(title, questions, stable_key, media_assets),
         references <-
           Enum.map(activity_specs, fn spec ->
             {spec["placement_after_section_id"], activity_reference(spec)}
           end),
         section_ids <-
           content
           |> Map.get("content_groups", [])
           |> List.wrap()
           |> Enum.map(& &1["id"])
           |> MapSet.new(),
         {placed_references, final_references} <-
           Enum.split_with(references, fn {placement, _reference} ->
             is_binary(placement) and MapSet.member?(section_ids, placement)
           end),
         {:ok, instructional_blocks} <-
           basic_instructional_blocks(
             content,
             stable_key,
             media_assets,
             attribution,
             Map.new(section_ids, &{&1, placed_references_for(placed_references, &1)}),
             opts
           ) do
      page_content = %{
        "version" => "0.1.0",
        "model" => instructional_blocks ++ final_practice_blocks(final_references, stable_key)
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
         references_by_section,
         opts
       ) do
    basic_v7_instructional_blocks(
      content,
      stable_key,
      media_assets,
      attribution,
      references_by_section,
      opts
    )
  end

  defp basic_v7_instructional_blocks(
         content,
         stable_key,
         media_assets,
         attribution,
         references_by_group,
         opts
       ) do
    media_lookup = v7_media_lookup(content, media_assets)

    groups = content |> Map.get("content_groups", []) |> List.wrap()

    with {:ok, group_blocks} <-
           groups
           |> Enum.with_index(1)
           |> Enum.reduce_while({:ok, []}, fn {group, index}, {:ok, blocks} ->
             case v7_content_group_blocks(
                    group,
                    index,
                    stable_key,
                    media_lookup,
                    Map.get(references_by_group, group["id"], []),
                    opts
                  ) do
               {:ok, rendered} -> {:cont, {:ok, blocks ++ rendered}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok,
       [v7_orientation_block(content, stable_key)] ++
         group_blocks ++
         v7_synthesis_blocks(content["synthesis"], stable_key) ++
         attribution_blocks(attribution, stable_key)}
    end
  end

  defp v7_orientation_block(content, stable_key) do
    overview = get_in(content, ["orientation", "overview"]) || content["narrative"]

    children =
      [text_element("h2", content["title"] || "Lesson overview", "#{stable_key}:v7:title")] ++
        paragraph_elements(overview, "#{stable_key}:v7:overview") ++
        [
          text_element("h3", "Learning Objectives", "#{stable_key}:v7:objectives-heading"),
          string_list_element(
            "ul",
            learning_objectives(content),
            "#{stable_key}:v7:objectives"
          )
        ]

    content_block(children, "#{stable_key}:v7:orientation")
  end

  defp v7_content_group_blocks(group, index, stable_key, media_lookup, references, opts) do
    group_key = "#{stable_key}:v7:group:#{group["id"] || index}"

    heading_content =
      content_block(
        [text_element("h2", group["title"], "#{group_key}:heading")] ++
          paragraph_elements(group["transition"], "#{group_key}:transition"),
        "#{group_key}:heading-content"
      )

    source_blocks =
      group
      |> Map.get("source_blocks", [])
      |> List.wrap()
      |> Enum.reject(&(&1["rendering"] == "lesson_title"))

    with {:ok, source_children} <-
           source_blocks
           |> Enum.with_index(1)
           |> Enum.reduce_while({:ok, []}, fn {source_block, block_index}, {:ok, children} ->
             case v7_source_block_child(
                    source_block,
                    block_index,
                    group_key,
                    media_lookup,
                    group["instructional_purpose"],
                    opts
                  ) do
               {:ok, child} -> {:cont, {:ok, children ++ [child]}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      group_block = %{
        "id" => stable_id("v7-group", group_key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => v7_group_purpose(group["instructional_purpose"]),
        "children" => [heading_content | source_children]
      }

      {:ok, [group_block] ++ practice_group(references, "#{group_key}:checkpoint")}
    end
  end

  defp v7_source_block_child(
         source_block,
         block_index,
         group_key,
         media_lookup,
         group_purpose,
         opts
       ) do
    block_key = "#{group_key}:source:#{source_block["id"] || block_index}"

    renderer_opts =
      Keyword.merge(opts,
        mode: :basic,
        stable_key: block_key,
        media_lookup: media_lookup,
        source_context: source_block
      )

    ast =
      case List.wrap(source_block["ast"]) do
        [] -> [%{"type" => "p", "children" => [%{"text" => source_block["text"] || ""}]}]
        values -> values
      end

    case SourceASTRenderer.render(ast, renderer_opts) do
      {:ok, source_nodes} ->
        content = content_block(source_nodes, "#{block_key}:content")

        source_purpose =
          if v7_group_purpose(group_purpose) == "none",
            do: v7_source_block_purpose(source_block),
            else: nil

        case source_purpose do
          nil ->
            {:ok, content}

          purpose ->
            {:ok,
             %{
               "id" => stable_id("v7-source-group", block_key),
               "type" => "group",
               "layout" => "vertical",
               "purpose" => purpose,
               "children" => [content]
             }}
        end

      {:attention, findings} ->
        {:error, {:external_media_attention, findings}}
    end
  end

  defp v7_source_block_purpose(%{"kind" => "exercise"}), do: "learnbydoing"

  defp v7_source_block_purpose(%{"kind" => "callout", "callout_type" => type})
       when type in ["concepts_in_practice", "example"],
       do: "example"

  defp v7_source_block_purpose(%{"kind" => kind}) when kind in ["callout", "footnotes"],
    do: "learnmore"

  defp v7_source_block_purpose(_source_block), do: nil

  defp v7_group_purpose("example"), do: "example"
  defp v7_group_purpose("application"), do: "learnbydoing"
  defp v7_group_purpose("reference"), do: "learnmore"
  defp v7_group_purpose(_purpose), do: "none"

  defp v7_synthesis_blocks(synthesis, stable_key) when is_map(synthesis) do
    takeaways = normalize_strings(synthesis["takeaways"])

    children =
      [
        text_element(
          "h2",
          synthesis["heading"] || "Bring the ideas together",
          "#{stable_key}:v7:synthesis-heading"
        )
      ] ++
        paragraph_elements(synthesis["summary"], "#{stable_key}:v7:synthesis") ++
        if(takeaways == [],
          do: [],
          else: [string_list_element("ul", takeaways, "#{stable_key}:v7:synthesis-takeaways")]
        )

    [content_block(children, "#{stable_key}:v7:synthesis")]
  end

  defp v7_synthesis_blocks(_synthesis, _stable_key), do: []

  defp v7_media_lookup(content, media_assets) do
    assets_by_id = Map.new(media_assets, &{&1.id, &1})

    content
    |> Map.get("media", [])
    |> List.wrap()
    |> Enum.reduce(%{}, fn descriptor, lookup ->
      id = descriptor["source_media_id"] || descriptor["id"]

      case assets_by_id[id] do
        nil ->
          lookup

        asset ->
          normalized = %{
            "src" => asset.url,
            "alt" => asset.alt,
            "height" => asset.height,
            "width" => "100%",
            "display" => "block"
          }

          [descriptor["src"], descriptor["url"], descriptor["source_url"], asset.url]
          |> Enum.filter(&present_text?/1)
          |> Enum.reduce(lookup, &Map.put(&2, &1, normalized))
      end
    end)
  end

  defp attribution_blocks(attribution, stable_key) do
    lines = attribution_lines(attribution)

    case {lines, attribution.links} do
      {[], []} ->
        []

      {lines, links} ->
        children =
          [
            text_element(
              "h2",
              "Sources and Credits",
              "#{stable_key}:attribution-heading"
            )
          ] ++
            paragraph_elements(lines, "#{stable_key}:attribution-lines") ++
            if(links == [],
              do: [],
              else: [source_link_list(links, "#{stable_key}:attribution-links")]
            )

        [content_block(children, "#{stable_key}:attribution")]
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
    [
      %{
        "id" => stable_id("practice-group", stable_key),
        "type" => "group",
        "layout" => "vertical",
        "purpose" => "learnbydoing",
        "children" => references
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
       "explanation_md" =>
         question_feedback(
           question,
           "correct",
           "Your response addresses the prompt. Continue when you are ready."
         ),
       "incorrect_feedback_md" =>
         question_feedback(
           question,
           "incorrect",
           "Review the preceding explanation and revise your response."
         ),
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
    cognitive_hint = present_string(question["hint"]) || ""

    bottom_out_hint =
      first_present([
        question["remediation"],
        question["explanation"],
        "Review the worked explanation and connect it to the correct response before trying again."
      ])

    [
      %{"body_md" => ""},
      %{"body_md" => cognitive_hint},
      %{"body_md" => bottom_out_hint}
    ]
  end

  defp markdown_alt(value) do
    value
    |> to_string()
    |> String.replace(["[", "]", "\n", "\r"], " ")
    |> String.trim()
  end

  defp compile_advanced_v7(title, content, stable_key, media_assets, attribution, opts) do
    with {:ok, screens} <-
           advanced_v7_screens(title, content, stable_key, media_assets, attribution, opts),
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
           "additionalStylesheets" => ["/css/delivery_adaptive_themes_default_light.css"],
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

  defp validate_unique_advanced_activity_keys(screens) do
    keys = Enum.map(screens, & &1.key)

    if length(keys) == length(Enum.uniq(keys)),
      do: :ok,
      else: {:error, :duplicate_advanced_activity_key}
  end

  defp advanced_v7_screens(title, content, stable_key, media_assets, attribution, opts) do
    blueprint = explicit_simulation_placements(content["experience_blueprint"] || %{})
    groups = Map.new(List.wrap(content["content_groups"]), &{&1["id"], &1})
    activities = Map.new(List.wrap(blueprint["activities"]), &{&1["id"], &1})
    branch_sets = List.wrap(blueprint["branch_sets"])
    branch_by_activity = Map.new(branch_sets, &{&1["decision_activity_id"], &1})
    stages = List.wrap(blueprint["stages"])
    media_lookup = v7_media_lookup(content, media_assets)

    orientation = advanced_v7_orientation_screen(title, content, blueprint, stable_key)

    with {:ok, content_screens_by_group} <-
           Enum.reduce_while(groups, {:ok, %{}}, fn {group_id, group}, {:ok, compiled} ->
             case advanced_v7_group_screens(
                    group,
                    stable_key,
                    media_assets,
                    media_lookup,
                    opts
                  ) do
               {:ok, screens} -> {:cont, {:ok, Map.put(compiled, group_id, screens)}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end),
         all_content_screens <- content_screens_by_group |> Map.values() |> List.flatten(),
         {:ok, stage_screens} <-
           stages
           |> Enum.with_index(1)
           |> Enum.reduce_while({:ok, []}, fn {stage, stage_index}, {:ok, compiled} ->
             stage_screen = advanced_v7_stage_screen(stage, stage_index, stable_key)

             stage["items"]
             |> List.wrap()
             |> Enum.with_index(1)
             |> Enum.reduce_while({:ok, []}, fn {item, item_index}, {:ok, stage_items} ->
               case item do
                 %{"kind" => "content_group", "ref_id" => group_id} ->
                   case Map.fetch(content_screens_by_group, group_id) do
                     {:ok, screens} -> {:cont, {:ok, stage_items ++ screens}}
                     :error -> {:halt, {:error, {:unknown_v7_content_group, group_id}}}
                   end

                 %{"kind" => "activity", "ref_id" => activity_id} ->
                   with {:ok, activity} <- Map.fetch(activities, activity_id),
                        {:ok, screen} <-
                          advanced_v7_activity_screen(
                            activity,
                            stage,
                            stage_index,
                            item_index,
                            stable_key,
                            all_content_screens,
                            branch_by_activity[activity_id],
                            opts
                          ) do
                     {:cont, {:ok, stage_items ++ [screen]}}
                   else
                     :error -> {:halt, {:error, {:unknown_v7_activity, activity_id}}}
                     {:error, reason} -> {:halt, {:error, reason}}
                   end

                 _ ->
                   {:halt, {:error, :invalid_v7_stage_item}}
               end
             end)
             |> case do
               {:ok, screens} -> {:cont, {:ok, compiled ++ [stage_screen] ++ screens}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      stage_screens = wire_branch_rejoins(stage_screens, branch_sets, stages, stable_key)
      synthesis = advanced_v7_synthesis_screen(content, stable_key)

      attribution_screens =
        advanced_attribution_screens(content, attribution, "#{stable_key}:v7:attribution")

      {:ok, [orientation] ++ stage_screens ++ List.wrap(synthesis) ++ attribution_screens}
    end
  end

  defp explicit_simulation_placements(blueprint) do
    stages = Map.new(List.wrap(blueprint["stages"]), &{&1["id"], &1})

    explicit_targets =
      blueprint
      |> Map.get("enrichment_references", [])
      |> List.wrap()
      |> Enum.reduce(%{}, fn reference, targets ->
        stage = stages[reference["stage_id"]] || %{}
        proposal_id = present_string(reference["proposal_id"])
        activity_id = present_string(stage["native_follow_up_activity_id"])

        if is_binary(proposal_id) and is_binary(activity_id),
          do: Map.put(targets, proposal_id, activity_id),
          else: targets
      end)

    case explicit_targets do
      targets when map_size(targets) == 0 ->
        blueprint

      targets ->
        proposal_by_activity =
          Map.new(targets, fn {proposal_id, activity_id} -> {activity_id, proposal_id} end)

        proposal_ids = targets |> Map.keys() |> MapSet.new()

        activities =
          blueprint
          |> Map.get("activities", [])
          |> List.wrap()
          |> Enum.map(fn activity ->
            case Map.fetch(proposal_by_activity, activity["id"]) do
              {:ok, proposal_id} ->
                Map.put(activity, "enrichment_proposal_id", proposal_id)

              :error ->
                if MapSet.member?(proposal_ids, activity["enrichment_proposal_id"]),
                  do: Map.delete(activity, "enrichment_proposal_id"),
                  else: activity
            end
          end)

        Map.put(blueprint, "activities", activities)
    end
  end

  defp advanced_v7_orientation_screen(title, content, blueprint, stable_key) do
    key = "#{stable_key}:v7:orientation"
    duration = get_in(blueprint, ["duration_manifest", "total_minutes"])
    overview = get_in(content, ["orientation", "overview"]) || content["narrative"] || ""
    driving_question = blueprint["driving_question"]

    parts =
      [
        title
        |> PartBuilders.text_flow(:h2, y: 0)
        |> Map.put("id", stable_id("title", key)),
        "Driving question"
        |> PartBuilders.text_flow(:h3, y: 52)
        |> Map.put("id", stable_id("driving-question-heading", key)),
        driving_question
        |> PartBuilders.text_flow(:p, y: 92)
        |> Map.put("id", stable_id("driving-question", key)),
        "About #{duration} minutes"
        |> PartBuilders.text_flow(:p, y: 146)
        |> Map.put("id", stable_id("duration", key)),
        "Learning objectives"
        |> PartBuilders.text_flow(:h3, y: 190)
        |> Map.put("id", stable_id("objectives-heading", key)),
        learning_objectives(content)
        |> PartBuilders.list_flow(:ul, y: 230)
        |> Map.put("id", stable_id("objectives", key)),
        overview
        |> PartBuilders.text_flow(:p, y: 310)
        |> Map.put("id", stable_id("overview", key))
      ]

    content_screen(key, title, parts)
  end

  defp advanced_v7_stage_screen(stage, stage_index, stable_key) do
    stage_id = stage["id"] || stage_index
    key = "#{stable_key}:v7:stage:#{stage_id}"
    introduction = stage["introduction"] || %{}

    guidance =
      stage
      |> Map.get("guidance", [])
      |> List.wrap()
      |> Enum.filter(&present_text?(&1["body"]))

    parts =
      [
        [stage["title"], "Exploration stage #{stage_index}"]
        |> first_present()
        |> PartBuilders.text_flow(:h2, y: 0)
        |> Map.put("id", stable_id("stage-title", key)),
        [introduction["heading"], "Prepare to investigate"]
        |> first_present()
        |> PartBuilders.text_flow(:h3, y: 52)
        |> Map.put("id", stable_id("stage-introduction-heading", key)),
        [
          introduction["body"],
          stage["purpose"],
          "Connect the source evidence to the next learner task."
        ]
        |> first_present()
        |> PartBuilders.text_flow(:p, y: 96)
        |> Map.put("id", stable_id("stage-introduction", key))
      ] ++ advanced_v7_guidance_parts(guidance, key, 184)

    content_screen(key, stage["title"] || "Exploration stage #{stage_index}", parts)
    |> Map.put(:stage_id, stage["id"])
    |> Map.put(:presentation_pattern, stage["presentation_pattern"] || "guided_reading")
  end

  defp advanced_v7_guidance_parts(guidance, stable_key, starting_y) do
    guidance
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {item, index} ->
      y = starting_y + (index - 1) * 128

      [
        (item["heading"] || advanced_v7_guidance_heading(item["kind"]))
        |> PartBuilders.text_flow(:h3, y: y)
        |> Map.put("id", stable_id("guidance-heading-#{index}", stable_key)),
        item["body"]
        |> PartBuilders.text_flow(:p, y: y + 44)
        |> Map.put("id", stable_id("guidance-body-#{index}", stable_key))
      ]
    end)
  end

  defp advanced_v7_guidance_heading("prediction"), do: "Predict before you inspect"
  defp advanced_v7_guidance_heading("observation"), do: "Observe and record"
  defp advanced_v7_guidance_heading("interpretation"), do: "Interpret the evidence"
  defp advanced_v7_guidance_heading("transfer"), do: "Transfer the relationship"
  defp advanced_v7_guidance_heading("synthesis"), do: "Synthesize your explanation"
  defp advanced_v7_guidance_heading(_kind), do: "Investigate the evidence"

  defp advanced_v7_group_screens(group, stable_key, media_assets, media_lookup, opts) do
    group_id = group["id"]
    key = "#{stable_key}:v7:group:#{group_id}"

    blocks =
      group
      |> Map.get("source_blocks", [])
      |> List.wrap()
      |> Enum.reject(&(&1["rendering"] == "lesson_title"))

    with {:ok, source_parts} <- advanced_v7_group_parts(group, blocks, key, media_lookup, opts) do
      source_screens =
        if blocks == [] do
          []
        else
          [
            content_screen(key, group["title"], source_parts)
            |> Map.put(:section_id, group_id)
          ]
        end

      media_screens =
        advanced_media_screens(
          media_assets,
          group_id,
          "#{stable_key}:v7:group:#{group_id}:media",
          group_id
        )

      {:ok, source_screens ++ media_screens}
    end
  end

  defp advanced_v7_group_parts(group, source_blocks, stable_key, media_lookup, opts) do
    purpose = present_string(group["instructional_purpose"])

    heading =
      [group["title"], "Source evidence"]
      |> first_present()
      |> PartBuilders.text_flow(:h2, y: 0)
      |> Map.put("id", stable_id("group-heading", stable_key))

    purpose_parts =
      if is_binary(purpose) do
        [
          "Evidence focus: #{purpose}"
          |> PartBuilders.text_flow(:p, y: 56)
          |> Map.put("id", stable_id("group-purpose", stable_key))
        ]
      else
        []
      end

    starting_y = if(purpose_parts == [], do: 64, else: 144)

    starting_parts = [heading] ++ purpose_parts

    source_blocks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, starting_parts}, fn {block, index}, {:ok, parts} ->
      block_key = "#{stable_key}:source-block-#{block["id"] || index}"
      ast = source_ast_or_fallback(block)
      y = max(next_part_y(parts), starting_y)

      renderer_opts =
        Keyword.merge(opts,
          mode: :advanced,
          stable_key: block_key,
          media_lookup: media_lookup,
          source_context:
            Map.put(block, "title", advanced_v7_block_title(block, "Source evidence")),
          y: y,
          vertical_gap: 112
        )

      case SourceASTRenderer.render(ast, renderer_opts) do
        {:ok, rendered} -> {:cont, {:ok, parts ++ rendered}}
        {:attention, findings} -> {:halt, {:error, {:external_media_attention, findings}}}
      end
    end)
  end

  defp source_ast_or_fallback(block) do
    case List.wrap(block["ast"]) do
      [] ->
        [
          %{
            "type" => "p",
            "children" => [
              %{"text" => block["text"] || "Source content retained for this stage."}
            ]
          }
        ]

      ast ->
        ast
    end
  end

  defp advanced_v7_block_title(block, fallback) do
    case block["kind"] do
      "equation" -> "Work with the relationship"
      "table" -> "Analyze the source table"
      "figure" -> "Examine the source figure"
      "exercise" -> "Use the source evidence"
      "callout" -> "Connect the idea"
      _ -> fallback
    end
  end

  defp advanced_v7_activity_screen(
         activity,
         stage,
         stage_index,
         item_index,
         stable_key,
         content_screens,
         branch_set,
         opts
       ) do
    activity = advanced_v7_activity_as_internal_screen(activity, stage)

    with {:ok, screen} <-
           adaptive_activity_screen(
             activity,
             stage_index * 100 + item_index,
             "#{stable_key}:v7",
             [],
             content_screens,
             opts
           ),
         {:ok, screen} <-
           add_answer_branch_rules(screen, activity, branch_set, content_screens, stable_key) do
      {:ok, screen}
    end
  end

  defp add_answer_branch_rules(screen, _activity, nil, _content_screens, _stable_key),
    do: {:ok, screen}

  defp add_answer_branch_rules(screen, activity, branch_set, content_screens, stable_key) do
    interaction =
      Enum.find(screen.parts, &(&1["type"] in ["janus-mcq", "janus-dropdown"]))

    choices = List.wrap(activity["choices"])

    branch_set["pathways"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {pathway, pathway_index}, {:ok, rules} ->
      choice_index = Enum.find_index(choices, &(&1["id"] == pathway["choice_id"]))

      target =
        Enum.find(content_screens, &(&1[:section_id] == pathway["target_content_group_id"]))

      case {interaction, choice_index, target} do
        {%{"id" => part_id, "type" => type}, choice_index, %{key: target_key}}
        when is_integer(choice_index) ->
          rule_key = "#{stable_key}:branch:#{branch_set["id"]}:#{pathway_index}"

          condition = %{
            "fact" => branch_fact(type, part_id),
            "operator" => "equal",
            "value" => to_string(choice_index + 1),
            "type" => 1
          }

          actions =
            generated_capi_feedback_actions(pathway["feedback"], rule_key) ++
              [
                %{
                  "type" => "navigation",
                  "params" => %{"target" => stable_id("sequence", target_key)}
                }
              ]

          rule = %{
            "id" => stable_id("rule", rule_key),
            "name" => "answer-branch-#{pathway_index}",
            "disabled" => false,
            "additionalScore" => 0.0,
            "forceProgress" => true,
            "default" => false,
            "correct" => choice_correct?(activity, pathway["choice_id"], choice_index),
            "conditions" => %{"all" => [condition]},
            "event" => %{
              "type" => stable_id("event", rule_key),
              "params" => %{"actions" => actions}
            }
          }

          {:cont, {:ok, rules ++ [rule]}}

        {nil, _choice_index, _target} ->
          {:halt, {:error, {:branch_interaction_missing, branch_set["id"]}}}

        {_interaction, nil, _target} ->
          {:halt, {:error, {:branch_choice_missing, pathway["choice_id"]}}}

        {_interaction, _choice_index, nil} ->
          {:halt, {:error, {:branch_target_missing, pathway["target_content_group_id"]}}}
      end
    end)
    |> case do
      {:ok, branch_rules} ->
        {:ok,
         screen
         |> Map.put(:rules, branch_rules ++ screen.rules)
         |> Map.put(:branch_set_id, branch_set["id"])
         |> Map.put(:branch_rejoin_stage_id, branch_set["rejoin_stage_id"])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp branch_fact("janus-mcq", part_id), do: "stage.#{part_id}.selectedChoice"
  defp branch_fact("janus-dropdown", part_id), do: "stage.#{part_id}.selectedIndex"

  defp choice_correct?(activity, choice_id, choice_index) do
    activity["correct_choice_id"] == choice_id or
      activity["correct_index"] == choice_index or
      get_in(Enum.at(List.wrap(activity["choices"]), choice_index) || %{}, ["correct"]) == true
  end

  defp wire_branch_rejoins(screens, branch_sets, stages, stable_key) do
    stage_ids = MapSet.new(Enum.map(stages, & &1["id"]))

    Enum.reduce(branch_sets, screens, fn branch_set, updated_screens ->
      rejoin_stage_id = branch_set["rejoin_stage_id"]

      if MapSet.member?(stage_ids, rejoin_stage_id) do
        rejoin_target =
          stable_id("sequence", "#{stable_key}:v7:stage:#{rejoin_stage_id}")

        branch_set["pathways"]
        |> List.wrap()
        |> Enum.map(& &1["target_content_group_id"])
        |> Enum.uniq()
        |> Enum.reduce(updated_screens, fn target_group_id, path_screens ->
          last_index =
            path_screens
            |> Enum.with_index()
            |> Enum.filter(fn {screen, _index} -> screen[:section_id] == target_group_id end)
            |> List.last()
            |> case do
              {_screen, index} -> index
              nil -> nil
            end

          if is_integer(last_index) do
            List.update_at(path_screens, last_index, fn screen ->
              Map.update!(screen, :rules, &put_rejoin_navigation(&1, rejoin_target))
            end)
          else
            path_screens
          end
        end)
      else
        updated_screens
      end
    end)
  end

  defp put_rejoin_navigation(rules, target) do
    Enum.map(rules, fn
      %{"name" => "correct"} = rule ->
        update_in(rule, ["event", "params", "actions"], fn actions ->
          actions = Enum.reject(List.wrap(actions), &(&1["type"] == "navigation"))
          actions ++ [%{"type" => "navigation", "params" => %{"target" => target}}]
        end)

      rule ->
        rule
    end)
  end

  defp advanced_v7_activity_as_internal_screen(activity, stage) do
    type = activity["interaction_type"]
    interaction_type = if(type in ["short_answer", "reflection"], do: "text", else: type)
    context = present_string(activity["context"])
    prompt = present_string(activity["prompt"])
    hint = present_string(activity["hint"])

    activity
    |> Map.put("kind", if(type == "reflection", do: "reflection", else: "decision"))
    |> Map.put("title", activity["title"] || stage["title"] || "Investigate the evidence")
    |> Map.put("interaction_type", interaction_type)
    |> Map.put(
      "prompt",
      Enum.filter([context, prompt, "Not sure? #{hint}"], &present_text?/1) |> Enum.join("\n\n")
    )
    |> Map.put("remediation_section_id", activity["remediation_content_group_id"])
  end

  defp advanced_v7_synthesis_screen(content, stable_key) do
    synthesis = content["synthesis"] || %{}
    takeaways = normalize_strings(synthesis["takeaways"])
    key = "#{stable_key}:v7:synthesis"

    parts =
      titled_content_parts(
        synthesis["heading"] || "Synthesize the investigation",
        synthesis["summary"] || "Connect the evidence to the driving question.",
        key
      ) ++
        if(takeaways == [],
          do: [],
          else: [
            takeaways
            |> PartBuilders.list_flow(:ul, y: 150)
            |> Map.put("id", stable_id("takeaways", key))
          ]
        )

    content_screen(key, synthesis["heading"] || "Synthesize the investigation", parts)
  end

  defp adaptive_activity_screen(
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

  defp adaptive_activity_screen(
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

  defp adaptive_activity_screen(_, _index, _stable_key, _paths, _content_screens, _opts),
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
        |> Enum.find(&(&1[:section_id] == target_section_id))

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
          %{
            "from_activity_id" => ^screen_id,
            "to_content_group_id" => target
          } ->
            present_string(target)

          _ ->
            nil
        end)

    if is_binary(target_section_id) do
      content_screens
      |> Enum.find(&(&1[:section_id] == target_section_id))
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

  defp advanced_media_screens(
         media_assets,
         placement,
         stable_key,
         section_id
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
        [asset.caption, asset.proximal_attribution]
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
            "Sources and Credits",
            titled_list_parts("Sources and Credits", normalized_lines, stable_key)
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

    top_level
  end

  defp media_entries(value) when is_map(value) do
    value
    |> Map.get("media", [])
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
           proximal_attribution: normalized_entry.proximal_attribution,
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
      proximal_attribution: nil,
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
      proximal_attribution:
        if(map_value(entry, "proximal_attribution_required") == true,
          do: first_present([map_value(entry, "byline"), map_value(entry, "credit")]),
          else: nil
        ),
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
      proximal_attribution: nil,
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
      proximal_attribution:
        if(map_value(value, "proximal_attribution_required") == true,
          do: first_present([map_value(value, "byline"), map_value(value, "credit")]),
          else: nil
        ),
      title: first_present([map_value(value, "title"), map_value(value, "heading")]),
      height: map_value(value, "height")
    }
  end

  defp normalize_media_override(_value) do
    %{
      url: nil,
      alt: nil,
      caption: nil,
      credit: nil,
      proximal_attribution: nil,
      title: nil,
      height: nil
    }
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

  defp enrich_attribution(attribution, content, media_assets) do
    source_blocks =
      content
      |> Map.get("content_groups", [])
      |> List.wrap()
      |> Enum.flat_map(&List.wrap(&1["source_blocks"]))

    source_credit_lines =
      source_blocks
      |> Enum.flat_map(fn block ->
        label = first_present([block["title"], block["caption"], block["id"], "Source item"])

        [
          if(present_text?(block["credit"]), do: "#{label} — #{block["credit"]}"),
          if(present_text?(block["license"]), do: "#{label} — License: #{block["license"]}")
        ]
      end)

    media_credit_lines =
      media_assets
      |> Enum.flat_map(fn asset ->
        if present_text?(asset.credit) do
          ["#{asset.title || asset.caption || asset.id} — #{asset.credit}"]
        else
          []
        end
      end)

    source_links = normalize_source_links(content["source_evidence_links"])

    %{
      attribution
      | lines:
          (attribution.lines ++ source_credit_lines ++ media_credit_lines)
          |> normalize_strings()
          |> Enum.uniq(),
        links: Enum.uniq_by(attribution.links ++ source_links, & &1.url)
    }
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

  defp validate_questions(questions, "basic", %{"schema_version" => 7})
       when length(questions) in 0..10,
       do: normalize_questions_for_compile(questions)

  defp validate_questions([], "advanced", %{"schema_version" => 7}), do: {:ok, []}

  defp validate_questions(_, _, _), do: {:error, :invalid_question_count}

  defp normalize_questions_for_compile(questions) do
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
