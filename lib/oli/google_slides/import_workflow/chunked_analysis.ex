defmodule Oli.GoogleSlides.ImportWorkflow.ChunkedAnalysis do
  @moduledoc """
  Checkpointed schema-v3 Google Slides analysis workflow.

  Every invocation advances at most one durable work unit. Source fragments and
  validated partial plans are checkpointed between jobs, keeping provider
  prompts bounded while preserving cross-slide planning state.
  """

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleDocs.SlidesClient

  alias Oli.GoogleSlides.{
    Credentials,
    ImportRuns,
    PresentationParser
  }

  alias Oli.GoogleSlides.AI.{ImportPlan, LessonPlan}

  alias Oli.GoogleSlides.ImportWorkflow.{
    FidelityValidator,
    ObjectiveCatalog,
    Planner,
    PreservationFallback,
    ProvenanceValidator,
    SourceCorpus
  }

  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias Oli.Resources.ResourceType

  @pass_prompt_budget 400_000
  @reviewable_blocker_codes ~w(
    missing_correct_response
    missing_captions
    missing_transcript
    objective_confirmation
    runtime_ai_opt_in
  )

  @spec perform(Ecto.UUID.t()) ::
          {:checkpoint, map()}
          | {:ok, :awaiting_structure | :awaiting_budget | :awaiting_answers | :ready_for_review,
             map()}
          | {:error, term()}
  def perform(run_id) do
    started_at = System.monotonic_time()
    result = perform_unit(run_id)
    emit_telemetry(run_id, result, started_at)
    result
  end

  @doc false
  @spec propose_structure([map()], [map()], non_neg_integer()) :: map()
  def propose_structure(chunks, maps, slide_count)
      when is_list(chunks) and is_list(maps) and is_integer(slide_count) and slide_count >= 0,
      do: build_structure_proposal(chunks, maps, slide_count)

  defp perform_unit(run_id) do
    with %{} = run <- ImportRuns.fetch_run(run_id),
         %Project{} = project <- Repo.get(Project, run.project_id),
         %Author{} = author <- Repo.get(Author, run.author_id),
         :ok <- ensure_available(project, author) do
      dispatch(run, project, author, run.analysis_state || %{})
    else
      nil -> {:error, :import_run_context_not_found}
      {:error, _} = error -> error
      other -> {:error, {:analysis_failed, other}}
    end
  end

  defp dispatch(run, project, author, %{"phase" => "inventory"} = state),
    do: inventory(run, project, author, state)

  defp dispatch(run, _project, _author, %{"phase" => "structure_map"} = state),
    do: structure_map(run, state)

  defp dispatch(run, _project, _author, %{"phase" => "structure_reduce"} = state),
    do: structure_reduce(run, state)

  defp dispatch(run, project, _author, %{"phase" => "detail"} = state),
    do: detail(run, project, state)

  defp dispatch(run, _project, _author, %{"phase" => "pathway"} = state),
    do: pathway(run, state)

  defp dispatch(run, project, author, %{"phase" => "validation"} = state),
    do: final_validation(run, project, author, state)

  defp dispatch(_run, _project, _author, state),
    do: {:error, {:invalid_analysis_phase, state["phase"]}}

  defp inventory(run, project, author, state) do
    with {:ok, presentation_json, slides, parse_warnings} <- fetch_source(run, project),
         {:ok, corpus} <- SourceCorpus.build(presentation_json, slides, run.presentation_url),
         :ok <- source_unchanged(run, corpus.manifest),
         chunk_count = length(corpus.chunks),
         total_units = chunk_count * 2 + 3,
         presentation = corpus.manifest["presentation"],
         next_state <-
           state
           |> Map.put("phase", "structure_map")
           |> Map.put("current_phase", "structure_map")
           |> Map.put("completed_units", 0)
           |> Map.put("total_units", total_units)
           |> Map.put("structure_cursor", 0)
           |> Map.put("detail_cursor", 0)
           |> Map.put("structure_maps", [])
           |> Map.put("current_slide_range", nil),
         attrs = %{
           presentation_id: presentation["id"],
           presentation_revision: presentation["revisionId"],
           presentation_fingerprint: presentation["fingerprint"],
           presentation_metadata:
             Map.take(presentation, ["id", "revisionId", "title", "pageSize", "slideCount"]),
           source_snapshot: corpus.manifest,
           analysis_state: next_state,
           warnings:
             normalize_warnings(parse_warnings) ++
               prior_import_warnings(project, author, run, presentation["id"])
         },
         {:ok, _run} <-
           ImportRuns.initialize_analysis_chunks(
             run.id,
             checkpoint_version(state),
             corpus.chunks,
             attrs
           ) do
      :ok
    end
  end

  defp structure_map(run, state) do
    chunks = ImportRuns.list_analysis_chunks(run.id)
    cursor = non_negative_integer(state["structure_cursor"], 0)

    case Enum.at(chunks, cursor) do
      nil ->
        {:checkpoint,
         %{
           analysis_state:
             state
             |> Map.put("phase", "structure_reduce")
             |> Map.put("current_slide_range", nil)
         }}

      chunk ->
        range = slide_range(chunk.source_fragment)

        with {:ok, _run} <-
               progress(run, state, "structure_map", range),
             structure_map <- summarize_structure_chunk(chunk),
             next_state <-
               state
               |> Map.update("structure_maps", [structure_map], &(&1 ++ [structure_map]))
               |> Map.put("structure_cursor", cursor + 1)
               |> increment_completed_units()
               |> put_next_unit(
                 if(cursor + 1 >= length(chunks), do: "structure_reduce", else: "structure_map"),
                 next_chunk_range(chunks, cursor)
               ) do
          {:checkpoint, %{analysis_state: next_state}}
        end
    end
  end

  defp structure_reduce(run, state) do
    chunks = ImportRuns.list_analysis_chunks(run.id)
    slide_count = get_in(run.source_snapshot || %{}, ["presentation", "slideCount"]) || 0
    proposal = propose_structure(chunks, state["structure_maps"] || [], slide_count)

    next_state =
      state
      |> Map.put("structure_proposal", proposal)
      |> Map.put("current_slide_range", nil)
      |> increment_completed_units()

    if proposal["split"] do
      {:ok, :awaiting_structure, %{analysis_state: Map.put(next_state, "phase", "detail")}}
    else
      decision = %{
        "proposal_version" => proposal["version"],
        "choice" => "one_lesson",
        "decided_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "automatic" => true
      }

      {:checkpoint,
       %{
         analysis_state:
           next_state
           |> Map.put("structure_decision", decision)
           |> Map.put("phase", "detail")
       }}
    end
  end

  defp detail(run, project, state) do
    chunks = ImportRuns.list_analysis_chunks(run.id)
    cursor = non_negative_integer(state["detail_cursor"], 0)

    cond do
      cursor >= length(chunks) ->
        {:checkpoint,
         %{
           analysis_state:
             state |> Map.put("phase", "pathway") |> Map.put("current_slide_range", nil)
         }}

      budget_exhausted?(state) ->
        {:ok, :awaiting_budget,
         %{
           lesson_plan: run.lesson_plan,
           analysis_state:
             state
             |> Map.put("resume_phase", "detail")
             |> Map.put("phase", "detail")
         }}

      true ->
        plan_detail_chunk(run, project, state, Enum.at(chunks, cursor), cursor, length(chunks))
    end
  end

  defp plan_detail_chunk(run, project, state, chunk, cursor, chunk_count) do
    range = slide_range(chunk.source_fragment)
    assignments = selected_assignments(run, state)
    lesson_index = lesson_index_for_chunk(assignments, range)

    with {:ok, import_plan} <- ensure_import_plan(run, assignments),
         current_plan when is_map(current_plan) <-
           Enum.at(ImportPlan.lessons(import_plan), lesson_index),
         {:ok, _run} <- progress(run, state, "detail", range),
         {:ok, _chunk} <-
           ImportRuns.update_analysis_chunk(run.id, chunk.ordinal, %{
             status: :processing,
             attempt_count: chunk.attempt_count + 1,
             error: nil
           }) do
      context = %{
        source_snapshot: chunk.source_fragment,
        lesson_plan: current_plan,
        tool_state: current_plan,
        prompt_lesson_plan: compact_plan(current_plan),
        answers: run.answers || %{},
        layout_mode: get_in(run.options || %{}, ["layout_mode"]) || "responsive",
        allow_triggers: project.allow_triggers == true,
        objectives: project_objectives(project),
        global_registry: registry(import_plan),
        neighboring_screen_summaries: neighboring_screens(current_plan, range),
        unresolved_pathway_intents: state["pathway_intents"] || [],
        current_slide_range: range,
        selected_lesson: Enum.at(assignments, lesson_index)
      }

      config = config()
      planner = config_value(config, :planner, Planner)
      pass_budget = config_value(config, :analysis_pass_prompt_budget, @pass_prompt_budget)

      case planner.plan(context,
             max_input_tokens: pass_budget,
             checkpoint_on_input_budget: true,
             finalize: false
           ) do
        {:ok, updated_plan, metadata} ->
          with {:ok, updated_import_plan} <-
                 ImportPlan.replace_lesson(import_plan, lesson_index, updated_plan),
               {:ok, _chunk} <-
                 ImportRuns.update_analysis_chunk(run.id, chunk.ordinal, %{
                   status: :completed,
                   usage: usage_from_metadata(metadata),
                   error: nil
                 }) do
            next_state =
              state
              |> accumulate_usage(metadata)
              |> Map.put("detail_cursor", cursor + 1)
              |> put_next_unit(
                if(cursor + 1 >= chunk_count, do: "pathway", else: "detail"),
                next_chunk_range(ImportRuns.list_analysis_chunks(run.id), cursor)
              )
              |> Map.put("no_progress_count", 0)
              |> Map.put("validated_plan_digest", plan_digest(updated_import_plan))
              |> increment_completed_units()

            {:checkpoint,
             %{
               lesson_plan: updated_import_plan,
               analysis_state: next_state,
               model_usage: state_usage(next_state)
             }}
          end

        {:checkpoint, updated_plan, metadata} ->
          with {:ok, updated_import_plan} <-
                 ImportPlan.replace_lesson(import_plan, lesson_index, updated_plan) do
            next_state =
              state
              |> accumulate_usage(metadata)
              |> update_no_progress(import_plan, updated_import_plan, cursor)
              |> Map.put("current_slide_range", range)
              |> Map.put("validated_plan_digest", plan_digest(updated_import_plan))

            if next_state["no_progress_count"] >= 3 do
              {:error, :planner_no_progress}
            else
              {:checkpoint,
               %{
                 lesson_plan: updated_import_plan,
                 analysis_state: next_state,
                 model_usage: state_usage(next_state)
               }}
            end
          end

        {:error, reason} ->
          _ =
            ImportRuns.update_analysis_chunk(run.id, chunk.ordinal, %{
              status: :failed,
              error: sanitized_chunk_error(reason)
            })

          {:error, reason}
      end
    else
      nil -> {:error, :lesson_assignment_not_found}
      {:error, _} = error -> error
    end
  end

  defp pathway(run, state) do
    with {:ok, import_plan} <- ImportPlan.validate(run.lesson_plan),
         :ok <- validate_registry(import_plan) do
      {:checkpoint,
       %{
         lesson_plan: import_plan,
         analysis_state:
           state
           |> Map.put("phase", "validation")
           |> Map.put("current_slide_range", nil)
           |> increment_completed_units()
       }}
    end
  end

  defp final_validation(run, project, author, state) do
    with {:ok, presentation_json, slides, parse_warnings} <- fetch_source(run, project),
         {:ok, corpus} <- SourceCorpus.build(presentation_json, slides, run.presentation_url),
         :ok <- source_unchanged(run, corpus.manifest),
         {:ok, import_plan} <-
           validate_lessons(
             run.lesson_plan,
             corpus.validation_snapshot,
             project,
             selected_assignments(run, state)
           ),
         :ok <- ensure_only_reviewable_blockers(import_plan),
         questions <- grouped_questions(import_plan, corpus.validation_snapshot),
         outcome <- if(questions == [], do: :ready_for_review, else: :awaiting_answers),
         next_state <-
           state
           |> Map.put("phase", "complete")
           |> Map.put("current_slide_range", nil)
           |> increment_completed_units(),
         warnings <-
           normalize_warnings(parse_warnings) ++
             prior_import_warnings(
               project,
               author,
               run,
               corpus.manifest["presentation"]["id"]
             ) ++ import_warnings(import_plan) do
      {:ok, outcome,
       %{
         source_snapshot: corpus.manifest,
         questions: questions,
         lesson_plan: import_plan,
         warnings: warnings,
         analysis_state: next_state,
         validation_results: %{
           "status" => if(outcome == :ready_for_review, do: "ready", else: "blocked"),
           "blockerCount" => blocker_count(import_plan),
           "warningCount" => length(warnings),
           "lessonCount" => length(ImportPlan.lessons(import_plan))
         },
         model_usage: state_usage(next_state)
       }}
    end
  end

  defp validate_lessons(import_plan, snapshot, project, assignments) do
    import_plan
    |> ImportPlan.lessons()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, import_plan}, fn {plan, index}, {:ok, current} ->
      lesson_snapshot = snapshot_for_assignment(snapshot, Enum.at(assignments, index))

      with {:ok, plan} <- ObjectiveCatalog.canonicalize(plan, project_objectives(project)),
           {:ok, plan} <- PreservationFallback.apply(plan, lesson_snapshot),
           :ok <- ProvenanceValidator.validate(plan, lesson_snapshot),
           :ok <- FidelityValidator.validate(plan, lesson_snapshot),
           {:ok, plan} <- finalize_or_validate(plan),
           {:ok, current} <- ImportPlan.replace_lesson(current, index, plan) do
        {:cont, {:ok, current}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> ImportPlan.validate(validated)
      {:error, _} = error -> error
    end
  end

  defp ensure_only_reviewable_blockers(import_plan) do
    unsupported_codes =
      import_plan
      |> ImportPlan.lessons()
      |> Enum.flat_map(&(&1["blockers"] || []))
      |> Enum.map(& &1["code"])
      |> Enum.reject(&(&1 in @reviewable_blocker_codes))
      |> Enum.uniq()
      |> Enum.sort()

    case unsupported_codes do
      [] -> :ok
      codes -> {:error, {:unresolved_automatic_blockers, codes}}
    end
  end

  defp snapshot_for_assignment(snapshot, nil), do: snapshot

  defp snapshot_for_assignment(snapshot, assignment) do
    slides =
      snapshot
      |> Map.get("slides", [])
      |> Enum.filter(fn slide ->
        slide["index"] >= assignment["startSlide"] and
          slide["index"] <= assignment["endSlide"]
      end)

    inventory = Enum.flat_map(slides, &Map.get(&1, "sourceInventory", []))

    snapshot
    |> Map.put("slides", slides)
    |> Map.put("slideAccounting", %{
      "discovered" => length(slides),
      "included" => length(slides),
      "omitted" => 0
    })
    |> Map.put("inventoryAccounting", %{
      "discovered" => length(inventory),
      "included" => length(inventory),
      "omitted" => 0,
      "bySourceType" => Enum.frequencies_by(inventory, &(&1["sourceType"] || "unknown"))
    })
  end

  defp finalize_or_validate(%{"blockers" => []} = plan), do: LessonPlan.finalize(plan)
  defp finalize_or_validate(plan), do: LessonPlan.validate(plan)

  defp grouped_questions(import_plan, snapshot) do
    import_plan
    |> ImportPlan.lessons()
    |> Enum.with_index()
    |> Enum.flat_map(fn {plan, lesson_index} ->
      plan
      |> Map.get("blockers", [])
      |> Enum.reject(&(&1["code"] == "source_inventory_unaccounted"))
      |> Enum.group_by(&question_group_key(&1, lesson_index))
      |> Enum.map(fn {{_lesson_index, slide_id}, blockers} ->
        refs = blockers |> Enum.flat_map(&(&1["sourceRefs"] || [])) |> Enum.uniq()
        details = (List.first(blockers) || %{})["details"] || %{}

        %{
          "id" => "lesson-#{lesson_index}:slide-#{slide_id || "general"}",
          "key" => "lesson-#{lesson_index}:slide-#{slide_id || "general"}",
          "lessonIndex" => lesson_index,
          "lessonTitle" => get_in(plan, ["lesson", "title"]),
          "slideId" => slide_id,
          "source" => source_label(slide_id, snapshot),
          "sourceRefs" => refs,
          "details" => put_question_geometry(details, refs, snapshot),
          "fields" =>
            Enum.map(blockers, fn blocker ->
              %{
                "id" => blocker["key"],
                "key" => blocker["key"],
                "code" => blocker["code"],
                "prompt" => blocker["message"],
                "details" => blocker["details"] || %{},
                "options" => blocker_options(blocker["code"]),
                "required" => true
              }
            end),
          "required" => true
        }
      end)
    end)
  end

  defp put_question_geometry(details, refs, snapshot) do
    geometry =
      Enum.find_value(refs, fn ref ->
        with slide_id when is_binary(slide_id) <- ref["slideId"],
             object_id when is_binary(object_id) <- ref["objectId"],
             %{} = slide <-
               Enum.find(snapshot["slides"] || [], &(&1["objectId"] == slide_id)),
             %{} = entry <-
               Enum.find(
                 slide["sourceInventory"] || [],
                 &(&1["objectId"] == object_id)
               ) do
          entry["geometry"]
        else
          _ -> nil
        end
      end)

    if is_map(geometry), do: Map.put_new(details, "geometry", geometry), else: details
  end

  defp blocker_options(code) when code in ["objective_confirmation", "runtime_ai_opt_in"] do
    [
      %{"value" => "yes", "label" => "Yes"},
      %{"value" => "no", "label" => "No"}
    ]
  end

  defp blocker_options(_code), do: []

  defp question_group_key(blocker, lesson_index) do
    slide_id =
      blocker
      |> Map.get("sourceRefs", [])
      |> Enum.find_value(&(&1["slideId"] || &1["slide_id"]))

    {lesson_index, slide_id}
  end

  defp source_label(nil, _snapshot), do: "Lesson-wide decision"

  defp source_label(slide_id, snapshot) do
    case Enum.find(snapshot["slides"] || [], &(&1["objectId"] == slide_id)) do
      nil -> "Source slide"
      slide -> "Slide #{slide["index"]}: #{slide["title"]}"
    end
  end

  defp ensure_import_plan(run, assignments) do
    case run.lesson_plan do
      %{} = import_plan ->
        ImportPlan.validate(import_plan)

      nil ->
        plans = Enum.map(assignments, &new_lesson_plan(run, &1))

        case plans do
          [plan] -> {:ok, plan}
          plans -> ImportPlan.new_set(plans)
        end
    end
  end

  defp new_lesson_plan(run, assignment) do
    presentation = run.source_snapshot["presentation"] || %{}

    {:ok, plan} =
      LessonPlan.new(%{
        "title" => assignment["title"],
        "lessonKey" => assignment["key"],
        "presentationId" => presentation["id"],
        "revisionId" => presentation["revisionId"],
        "fingerprint" => presentation["fingerprint"],
        "url" => presentation["url"],
        "layoutMode" => get_in(run.options || %{}, ["layout_mode"]) || "responsive",
        "styleProfile" => "torus-default"
      })

    plan
  end

  defp selected_assignments(run, state) do
    proposal = state["structure_proposal"] || %{}
    decision = get_in(state, ["structure_decision", "choice"]) || "one_lesson"

    case decision do
      "split" -> get_in(proposal, ["split", "lessons"]) || []
      _ -> [proposal["oneLesson"] || default_one_lesson(run)]
    end
  end

  defp default_one_lesson(run) do
    presentation = run.source_snapshot["presentation"] || %{}

    %{
      "key" => "imported-lesson",
      "title" => presentation["title"] || "Imported Slides Lesson",
      "startSlide" => 1,
      "endSlide" => presentation["slideCount"] || 1
    }
  end

  defp lesson_index_for_chunk(assignments, %{"start" => start_slide}) do
    Enum.find_index(assignments, fn assignment ->
      start_slide >= assignment["startSlide"] and start_slide <= assignment["endSlide"]
    end) || 0
  end

  defp build_structure_proposal(chunks, maps, slide_count) do
    version = 1
    title = maps |> Enum.flat_map(& &1["slides"]) |> List.first() |> title_or_default()
    edges = Enum.flat_map(maps, & &1["pathwayEdges"])
    section_count = maps |> Enum.flat_map(& &1["explicitSections"]) |> length()
    ask_split? = slide_count >= 40 or section_count >= 2

    split =
      if ask_split? do
        chunks
        |> proposed_ranges(slide_count, maps)
        |> merge_pathway_crossings(edges)
        |> validate_split_ranges(slide_count)
      end

    %{
      "version" => version,
      "reason" =>
        if(slide_count >= 40,
          do: "large_deck",
          else: if(section_count >= 2, do: "explicit_sections", else: "single_lesson")
        ),
      "oneLesson" => %{
        "key" => "imported-lesson",
        "title" => title,
        "startSlide" => 1,
        "endSlide" => max(slide_count, 1)
      },
      "split" => split,
      "pathwayEdges" => edges
    }
  end

  defp proposed_ranges(chunks, slide_count, maps) do
    desired_count =
      maps
      |> Enum.flat_map(& &1["explicitSections"])
      |> length()
      |> case do
        count when count >= 2 -> min(count, 10)
        _ -> min(max(ceil_div(slide_count, 30), 2), 10)
      end

    boundary_units = slide_boundary_units(chunks)
    chunk_groups = balanced_groups(boundary_units, min(desired_count, length(boundary_units)))

    lessons =
      chunk_groups
      |> Enum.with_index(1)
      |> Enum.map(fn {group, index} ->
        flattened_group = List.flatten(group)
        start_slide = flattened_group |> List.first() |> chunk_start()
        end_slide = flattened_group |> List.last() |> chunk_end()

        %{
          "key" => "imported-lesson-#{index}",
          "title" => range_title(maps, start_slide, index),
          "startSlide" => start_slide,
          "endSlide" => end_slide,
          "chunkOrdinals" => Enum.map(flattened_group, & &1.ordinal)
        }
      end)

    %{"lessons" => lessons}
  end

  defp balanced_groups([], _count), do: []

  defp balanced_groups(chunks, count) do
    chunks
    |> Enum.with_index()
    |> Enum.group_by(fn {_chunk, index} -> min(div(index * count, length(chunks)), count - 1) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_group, entries} -> Enum.map(entries, &elem(&1, 0)) end)
  end

  defp slide_boundary_units(chunks) do
    chunks
    |> Enum.reduce([], fn chunk, units ->
      case List.pop_at(units, -1) do
        {nil, []} ->
          [[chunk]]

        {previous_unit, prior_units} ->
          if chunk_start(chunk) <= chunk_end(List.last(previous_unit)) do
            prior_units ++ [previous_unit ++ [chunk]]
          else
            units ++ [[chunk]]
          end
      end
    end)
  end

  defp merge_pathway_crossings(%{"lessons" => lessons}, edges) do
    merged =
      Enum.reduce(edges, lessons, fn edge, ranges ->
        from_index = range_index(ranges, edge["fromSlide"])
        to_index = range_index(ranges, edge["toSlide"])

        if is_integer(from_index) and is_integer(to_index) and from_index != to_index do
          merge_range_span(ranges, min(from_index, to_index), max(from_index, to_index))
        else
          ranges
        end
      end)

    %{"lessons" => rekey_ranges(merged)}
  end

  defp validate_split_ranges(%{"lessons" => lessons} = split, slide_count)
       when length(lessons) >= 2 and length(lessons) <= 10 do
    expected = Enum.to_list(1..slide_count)

    covered =
      Enum.flat_map(lessons, fn lesson ->
        Enum.to_list(lesson["startSlide"]..lesson["endSlide"])
      end)

    if covered == expected, do: split, else: nil
  end

  defp validate_split_ranges(_split, _slide_count), do: nil

  defp range_index(ranges, slide) when is_integer(slide) do
    Enum.find_index(ranges, &(slide >= &1["startSlide"] and slide <= &1["endSlide"]))
  end

  defp range_index(_ranges, _slide), do: nil

  defp merge_range_span(ranges, first, last) do
    prefix = Enum.take(ranges, first)
    span = Enum.slice(ranges, first..last)
    suffix = Enum.drop(ranges, last + 1)

    merged = %{
      "key" => hd(span)["key"],
      "title" => hd(span)["title"],
      "startSlide" => hd(span)["startSlide"],
      "endSlide" => List.last(span)["endSlide"],
      "chunkOrdinals" => Enum.flat_map(span, &(&1["chunkOrdinals"] || []))
    }

    prefix ++ [merged] ++ suffix
  end

  defp rekey_ranges(ranges) do
    ranges
    |> Enum.with_index(1)
    |> Enum.map(fn {range, index} ->
      range
      |> Map.put("key", "imported-lesson-#{index}")
      |> Map.put_new("title", "Imported lesson #{index}")
    end)
  end

  defp summarize_structure_chunk(chunk) do
    slides = get_in(chunk.source_fragment, ["slides"]) || []

    %{
      "ordinal" => chunk.ordinal,
      "range" => slide_range(chunk.source_fragment),
      "slides" =>
        Enum.map(slides, fn slide ->
          %{
            "index" => slide["index"],
            "id" => slide["objectId"],
            "title" => slide["title"]
          }
        end),
      "explicitSections" => Enum.filter(slides, &explicit_section?/1) |> Enum.map(& &1["index"]),
      "pathwayEdges" => Enum.flat_map(slides, &pathway_edges/1)
    }
  end

  defp explicit_section?(slide) do
    title = slide["title"] |> to_string() |> String.trim()

    title != "" and
      (Regex.match?(~r/^(unit|module|section|part|chapter|lesson)\b/i, title) or
         String.ends_with?(title, [":", " overview", " introduction"]))
  end

  defp pathway_edges(slide) do
    text =
      [
        slide["notes"],
        slide["title"],
        Enum.join(slide["paragraphs"] || [], " ")
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    Regex.scan(~r/\b(?:go|navigate|continue|return|jump)\s+to\s+slide\s+(\d{1,3})\b/i, text)
    |> Enum.flat_map(fn
      [_match, target] ->
        case Integer.parse(target) do
          {target_slide, ""} ->
            [
              %{
                "fromSlide" => slide["index"],
                "toSlide" => target_slide,
                "evidence" => "explicit slide navigation"
              }
            ]

          _ ->
            []
        end
    end)
  end

  defp validate_registry(import_plan) do
    case ImportPlan.validate(import_plan) do
      {:ok, _plan} -> :ok
      {:error, errors} -> {:error, {:invalid_import_plan, errors}}
    end
  end

  defp registry(import_plan) do
    plans = ImportPlan.lessons(import_plan)

    %{
      "lessonKeys" => Enum.map(plans, &get_in(&1, ["lesson", "key"])),
      "screenKeys" =>
        Enum.flat_map(plans, fn plan ->
          plan |> get_in(["lesson", "screens"]) |> List.wrap() |> Enum.map(& &1["key"])
        end),
      "variableKeys" =>
        Enum.flat_map(plans, fn plan -> Enum.map(plan["variables"] || [], & &1["key"]) end),
      "objectiveKeys" =>
        Enum.flat_map(plans, fn plan ->
          proposed = Enum.map(get_in(plan, ["objectives", "proposed"]) || [], & &1["key"])

          mapped =
            Enum.map(
              get_in(plan, ["objectives", "mapped"]) || [],
              &(&1["key"] || &1["objectiveId"])
            )

          proposed ++ mapped
        end),
      "pathwayKeys" =>
        Enum.flat_map(plans, fn plan ->
          plan
          |> get_in(["lesson", "screens"])
          |> List.wrap()
          |> Enum.flat_map(fn screen ->
            Enum.map(screen["adaptivity"] || [], & &1["key"])
          end)
        end)
    }
  end

  defp compact_plan(plan) do
    %{
      "source" => plan["source"],
      "lesson" => %{
        "key" => get_in(plan, ["lesson", "key"]),
        "title" => get_in(plan, ["lesson", "title"]),
        "screens" =>
          plan
          |> get_in(["lesson", "screens"])
          |> List.wrap()
          |> Enum.map(fn screen ->
            %{
              "key" => screen["key"],
              "title" => screen["title"],
              "sourceRefs" => screen["sourceRefs"],
              "partKeys" => Enum.map(screen["parts"] || [], & &1["key"]),
              "interactionKeys" => Enum.map(screen["interactions"] || [], & &1["key"])
            }
          end)
      },
      "variables" => plan["variables"],
      "objectives" => plan["objectives"],
      "blockers" => plan["blockers"]
    }
  end

  defp neighboring_screens(plan, %{"start" => start_slide, "end" => end_slide}) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.filter(fn screen ->
      Enum.any?(screen["sourceRefs"] || [], fn ref ->
        index = ref["slideIndex"]
        is_integer(index) and index >= start_slide - 1 and index <= end_slide + 1
      end)
    end)
    |> Enum.map(&Map.take(&1, ["key", "title", "sourceRefs"]))
  end

  defp slide_range(fragment) do
    indices =
      fragment
      |> Map.get("slides", [])
      |> Enum.map(& &1["index"])
      |> Enum.filter(&is_integer/1)

    %{"start" => Enum.min(indices, fn -> 0 end), "end" => Enum.max(indices, fn -> 0 end)}
  end

  defp chunk_start(chunk), do: slide_range(chunk.source_fragment)["start"]
  defp chunk_end(chunk), do: slide_range(chunk.source_fragment)["end"]

  defp range_title(maps, start_slide, index) do
    maps
    |> Enum.flat_map(& &1["slides"])
    |> Enum.find(&(&1["index"] == start_slide))
    |> title_or_default("Imported lesson #{index}")
  end

  defp title_or_default(value, fallback \\ "Imported Slides Lesson")
  defp title_or_default(%{"title" => title}, fallback), do: present(title, fallback)
  defp title_or_default(_value, fallback), do: fallback

  defp progress(run, state, phase, range) do
    ImportRuns.update_analysis_progress(run.id, checkpoint_version(state), %{
      "phase" => phase,
      "current_phase" => phase,
      "current_slide_range" => range
    })
  end

  defp put_next_unit(state, phase, range) do
    state
    |> Map.put("phase", phase)
    |> Map.put("current_phase", phase)
    |> Map.put("current_slide_range", range)
  end

  defp next_chunk_range(chunks, cursor) do
    case Enum.at(chunks, cursor + 1) do
      nil -> nil
      chunk -> slide_range(chunk.source_fragment)
    end
  end

  defp increment_completed_units(state) do
    Map.update(state, "completed_units", 1, &(&1 + 1))
  end

  defp accumulate_usage(state, metadata) do
    usage = usage_from_metadata(metadata)

    Map.update(state, "accumulated_usage", usage, fn current ->
      %{
        "prompt_tokens" =>
          non_negative_integer(current["prompt_tokens"], 0) + usage["prompt_tokens"],
        "completion_tokens" =>
          non_negative_integer(current["completion_tokens"], 0) + usage["completion_tokens"]
      }
    end)
  end

  defp usage_from_metadata(metadata) when is_map(metadata) do
    executions = metadata[:executions] || metadata["executions"] || []

    prompt_tokens =
      metadata[:prompt_tokens] || metadata["prompt_tokens"] ||
        Enum.reduce(executions, 0, fn execution, total ->
          total +
            non_negative_integer(
              execution[:charged_input_tokens] || execution["charged_input_tokens"],
              0
            )
        end)

    completion_tokens =
      Enum.reduce(executions, 0, fn execution, total ->
        usage = execution[:usage] || execution["usage"] || %{}

        total +
          non_negative_integer(
            usage[:completion_tokens] || usage["completion_tokens"] ||
              usage[:output_tokens] || usage["output_tokens"],
            0
          )
      end)

    %{"prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens}
  end

  defp usage_from_metadata(_metadata), do: %{"prompt_tokens" => 0, "completion_tokens" => 0}

  defp state_usage(state), do: state["accumulated_usage"] || %{}

  defp budget_exhausted?(state) do
    used = get_in(state, ["accumulated_usage", "prompt_tokens"]) || 0
    limit = state["budget_limit_tokens"] || 2_000_000
    used >= limit
  end

  defp update_no_progress(state, old_plan, new_plan, cursor) do
    previous_cursor = non_negative_integer(state["detail_cursor"], cursor)
    old_digest = plan_digest(old_plan)
    new_digest = plan_digest(new_plan)

    if previous_cursor == cursor and old_digest == new_digest do
      Map.update(state, "no_progress_count", 1, &(&1 + 1))
    else
      Map.put(state, "no_progress_count", 0)
    end
  end

  defp plan_digest(plan) when is_map(plan) do
    plan
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sanitized_chunk_error(reason) do
    %{
      "code" =>
        case reason do
          reason when is_atom(reason) -> Atom.to_string(reason)
          {tag, _detail} when is_atom(tag) -> Atom.to_string(tag)
          _ -> "analysis_failed"
        end,
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp fetch_source(run, project) do
    config = config()
    slides_client = config_value(config, :slides_client, SlidesClient)
    credentials_module = config_value(config, :credentials, Credentials)
    parser = config_value(config, :presentation_parser, PresentationParser)

    with {:ok, credentials} <- credentials_module.get_credentials_map(project.id),
         {:ok, access_token} <- slides_client.fetch_access_token(credentials),
         {:ok, presentation_json} <-
           slides_client.fetch_presentation_json(
             run.presentation_url,
             access_token,
             credentials
           ),
         {:ok, slides, parse_warnings} <-
           parser.parse(presentation_json, access_token: access_token) do
      {:ok, presentation_json, slides, parse_warnings}
    end
  end

  defp source_unchanged(%{presentation_fingerprint: nil}, _manifest), do: :ok

  defp source_unchanged(run, %{"presentation" => %{"fingerprint" => fingerprint}}) do
    if run.presentation_fingerprint == fingerprint, do: :ok, else: {:error, :stale_source}
  end

  defp ensure_available(project, author) do
    if Oli.GoogleSlides.ImportWorkflow.available?(project, author) do
      :ok
    else
      {:error, :import_unavailable}
    end
  end

  defp project_objectives(project) do
    project.slug
    |> AuthoringResolver.revisions_of_type(ResourceType.id_for_objective())
    |> Enum.map(fn objective ->
      %{
        "objectiveId" => Integer.to_string(objective.resource_id),
        "title" => objective.title
      }
    end)
  end

  defp prior_import_warnings(project, author, run, presentation_id)
       when is_binary(presentation_id) do
    case ImportRuns.find_prior_completed_import(project, author, presentation_id, run.id) do
      {:ok, nil} ->
        []

      {:ok, prior} ->
        [
          %{
            "code" => "presentation_reimport",
            "message" =>
              "This presentation was imported before. Generating this plan will create new lesson content.",
            "priorRunId" => prior.id,
            "priorRevisionId" => prior.result_revision_id
          }
        ]

      _ ->
        []
    end
  end

  defp prior_import_warnings(_project, _author, _run, _presentation_id), do: []

  defp normalize_warnings(warnings) when is_list(warnings) do
    Enum.map(warnings, fn
      warning when is_map(warning) ->
        Map.new(warning, fn {key, value} -> {to_string(key), value} end)

      warning ->
        %{"code" => "source_warning", "message" => inspect(warning)}
    end)
  end

  defp normalize_warnings(_warnings), do: []

  defp import_warnings(import_plan) do
    import_plan
    |> ImportPlan.lessons()
    |> Enum.flat_map(&(&1["warnings"] || []))
  end

  defp blocker_count(import_plan) do
    import_plan
    |> ImportPlan.lessons()
    |> Enum.reduce(0, &(length(&1["blockers"] || []) + &2))
  end

  defp checkpoint_version(%{"checkpoint_version" => version}) when is_integer(version),
    do: version

  defp checkpoint_version(_state), do: 0

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp present(value, _fallback) when is_binary(value) and value != "", do: value
  defp present(_value, fallback), do: fallback

  defp config, do: Application.get_env(:oli, :google_slides_ai_import, [])

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp config_value(_config, _key, default), do: default

  defp emit_telemetry(run_id, result, started_at) do
    run = ImportRuns.fetch_run(run_id)
    attrs = result_attrs(result)

    state =
      attrs[:analysis_state] || attrs["analysis_state"] ||
        if(run, do: run.analysis_state || %{}, else: %{})

    lesson_plan =
      attrs[:lesson_plan] || attrs["lesson_plan"] ||
        if(run, do: run.lesson_plan, else: nil)

    questions =
      attrs[:questions] || attrs["questions"] ||
        if(run, do: run.questions, else: [])

    usage = state["accumulated_usage"] || %{}
    next_checkpoint = if match?({:checkpoint, _attrs}, result), do: 1, else: 0

    measurements = %{
      duration: System.monotonic_time() - started_at,
      chunk_count: if(run, do: length(ImportRuns.list_analysis_chunks(run_id)), else: 0),
      continuation_count: max((state["checkpoint_version"] || 0) + next_checkpoint - 1, 0),
      prompt_tokens: usage["prompt_tokens"] || 0,
      question_count: question_count(questions),
      fallback_count: fallback_count(lesson_plan)
    }

    metadata = %{
      run_id: run_id,
      analysis_version: if(run, do: run.analysis_version, else: 2),
      phase: state["phase"] || "unknown",
      outcome: telemetry_outcome(result),
      terminal_reason: telemetry_reason(result)
    }

    :telemetry.execute(
      [:oli, :google_slides, :import_analysis, :unit],
      measurements,
      metadata
    )
  rescue
    _ -> :ok
  end

  defp result_attrs({:checkpoint, attrs}) when is_map(attrs), do: attrs
  defp result_attrs({:ok, _status, attrs}) when is_map(attrs), do: attrs
  defp result_attrs(_result), do: %{}

  defp question_count(questions) do
    questions
    |> List.wrap()
    |> Enum.reduce(0, fn question, count ->
      count + max(length(question["fields"] || []), 1)
    end)
  end

  defp fallback_count(lesson_plan) do
    lesson_plan
    |> ImportPlan.lessons()
    |> Enum.flat_map(&(&1["warnings"] || []))
    |> Enum.count(&(&1["code"] == "source_preservation_fallback"))
  end

  defp telemetry_outcome({:checkpoint, _attrs}), do: :checkpoint
  defp telemetry_outcome({:ok, status, _attrs}), do: status
  defp telemetry_outcome({:error, _reason}), do: :error
  defp telemetry_outcome(:ok), do: :continued
  defp telemetry_outcome(_result), do: :unknown

  defp telemetry_reason({:error, reason}) when is_atom(reason), do: reason
  defp telemetry_reason({:error, {tag, _detail}}) when is_atom(tag), do: tag
  defp telemetry_reason({:error, {tag, _left, _right}}) when is_atom(tag), do: tag
  defp telemetry_reason(_result), do: nil
end
