defmodule Oli.OpenStax.CourseImport.Planner do
  @moduledoc """
  Provider-neutral lesson and unit-assessment planner.

  The deterministic builder remains the no-provider fallback for the AI
  planner. Its payload is also used to initialize outline-only lesson metadata.
  """

  @keyword_stop_words MapSet.new(~w(
    apply chapter concept define describe explain from introduction lesson main
    objective openstax source the this topic understand using with
  ))

  # Advanced Author lessons are intentionally a minority of a generated course.
  # Independent per-lesson jobs all receive the same stable planning position,
  # so this cadence keeps the mix deterministic without requiring shared worker
  # state or allowing completion order to influence the authoring mode.
  @advanced_window_size 3
  @advanced_window_slot 1

  # A substantial structured lesson can always support a source-grounded
  # knowledge check with targeted remediation, even when the source does not
  # literally use words such as "misconception" or "scenario". Requiring
  # those rare keywords caused most three-lesson windows to contain no
  # Advanced Author lesson at all.
  @knowledge_check_min_words 450
  @knowledge_check_min_instructional_blocks 4

  @higher_order_objective_terms ~w(
    analyze choose classify compare decide design diagnose distinguish evaluate
    justify model predict prioritize select simulate test troubleshoot
  )

  @adaptive_source_kinds ~w(
    exercise exercises problem problems question questions quiz case scenario
  )

  @decision_terms ~w(
    alternative alternatives choice choices choose consequence consequences
    constraint constraints decision decisions option options scenario scenarios
    strategy strategies tradeoff tradeoffs
  )

  @contrast_terms ~w(
    common confuse confusion contrast differ difference distinguish error errors
    incorrect misconception misconceptions versus
  )

  @quantitative_terms ~w(
    calculate calculation estimate graph input inputs measure model output outputs
    probability rate simulate simulation variable variables
  )

  @spec build_lesson_plan(map(), pos_integer()) :: {String.t(), map()}
  def build_lesson_plan(lesson, index) when is_map(lesson) and is_integer(index) do
    title = lesson["title"] || "OpenStax lesson #{index}"
    evidence_links = lesson["source_evidence_links"] || lesson["source_sections"] || []
    objectives = normalize_objectives(lesson["source_objectives"], title)
    narrative = narrative(lesson, title)
    instructional_sections = instructional_sections(lesson, title, evidence_links)
    worked_examples = worked_examples(title, objectives, instructional_sections, evidence_links)
    key_takeaways = key_takeaways(objectives, instructional_sections, title)
    source_block_ids = Enum.map(source_blocks(lesson), & &1["id"])
    callouts = source_callouts(lesson)
    media = source_media(lesson)
    curiosity_prompts = curiosity_prompts(instructional_sections)
    application_problems = application_problems(instructional_sections)

    mode_recommendation = authoring_mode_recommendation(lesson, index)
    plan_mode = mode_recommendation["mode"]
    answer_keywords = answer_keywords(title, objectives)

    questions =
      1..question_count(lesson, objectives)
      |> Enum.map(fn question_index ->
        formative_question(
          title,
          objectives,
          instructional_sections,
          evidence_links,
          answer_keywords,
          question_index,
          question_count(lesson, objectives),
          source_objective_block_ids(lesson),
          source_blocks(lesson) != []
        )
      end)

    advanced_blueprint =
      build_advanced_blueprint(
        plan_mode,
        mode_recommendation,
        instructional_sections,
        questions
      )

    {
      plan_mode,
      %{
        "content_payload" => %{
          "schema_version" => 3,
          "title" => title,
          "objective" => List.first(objectives),
          "learning_objectives" => objectives,
          "opening_hook" =>
            "What changes when you use the ideas in #{title} to examine a real situation?",
          "why_this_matters" =>
            "The source connects #{title} to decisions and applications beyond a definition.",
          "narrative" => narrative,
          "instructional_sections" => instructional_sections,
          "callouts" => callouts,
          "media" => media,
          "worked_examples" => worked_examples,
          "curiosity_prompts" => curiosity_prompts,
          "application_problems" => application_problems,
          "key_takeaways" => key_takeaways,
          "estimated_minutes" => estimated_minutes(lesson),
          "source_evidence_links" => evidence_links,
          "source_block_ids" => source_block_ids,
          "coverage_manifest" => %{
            "available_block_ids" => source_block_ids,
            "included_block_ids" => plan_evidence_ids(instructional_sections, callouts, media),
            "excluded_blocks" => [],
            "source_word_count" => lesson["source_word_count"] || source_word_count(lesson)
          },
          "attribution" => source_attribution(lesson, evidence_links),
          "advanced_blueprint" => advanced_blueprint,
          "authoring_mode" => plan_mode
        },
        "questions_payload" => %{"items" => questions}
      }
    }
  end

  @spec build_unit_assessment(map(), [map()]) :: map()
  def build_unit_assessment(unit, lessons) do
    lesson_evidence_links =
      lessons
      |> Enum.flat_map(&Map.get(&1, "source_evidence_links", []))
      |> Enum.uniq()

    mapped_assessment_evidence =
      unit
      |> Map.get("assessment_evidence", [])
      |> List.wrap()
      |> map_assessment_evidence(lessons)

    questions =
      case mapped_assessment_evidence do
        [] -> legacy_unit_questions(lessons)
        mapped -> mapped |> select_assessment_questions(lessons) |> assessment_questions()
      end

    conceptual_evidence_links =
      mapped_assessment_evidence
      |> Enum.map(& &1["source_url"])
      |> Enum.filter(&present?/1)
      |> Enum.uniq()

    %{
      "title" => "#{unit["unit_name"] || "Unit"} assessment",
      # The current unit quiz is a linear assessment. Keep it in Basic Author
      # until its plan includes a genuine adaptive decision/exploration
      # blueprint rather than labeling a list of questions as adaptive.
      "authoring_mode" => "basic",
      "questions" => questions,
      "assessment_evidence" => mapped_assessment_evidence,
      "source_evidence_links" => Enum.uniq(lesson_evidence_links ++ conceptual_evidence_links)
    }
  end

  defp legacy_unit_questions(lessons) do
    lessons
    |> assessment_lesson_sample()
    |> Enum.with_index(1)
    |> Enum.map(fn {lesson, index} ->
      lesson_title = lesson["title"] || "lesson #{index}"
      objectives = normalize_objectives(lesson["source_objectives"], lesson_title)

      %{
        "id" => "unit-q#{index}",
        "prompt" => "Apply the central idea from #{lesson_title} (question #{index}).",
        "type" => "short_answer",
        "answer_keywords" => answer_keywords(lesson_title, objectives),
        "correct_feedback" => "Your response connects the lesson idea to the unit goal.",
        "incorrect_feedback" => "Review the lesson material before trying again.",
        "remediation" => "Revisit #{lesson_title} and identify its main objective.",
        "source_evidence_links" => lesson["source_evidence_links"] || []
      }
    end)
  end

  defp map_assessment_evidence(evidence, []), do: evidence

  defp map_assessment_evidence(evidence, lessons) do
    lesson_profiles =
      lessons
      |> Enum.with_index()
      |> Enum.map(fn {lesson, index} ->
        %{
          index: index,
          lesson: lesson,
          tokens: lesson_assessment_tokens(lesson),
          source_slugs: lesson_source_slugs(lesson),
          blocks: source_blocks(lesson)
        }
      end)

    evidence
    |> Enum.with_index()
    |> Enum.map(fn {question, question_index} ->
      question_tokens = keyword_tokens(question["prompt"])

      profile =
        exact_assessment_profile(question, lesson_profiles) ||
          lesson_profiles
          |> Enum.max_by(
            fn profile -> token_overlap(question_tokens, profile.tokens) end,
            fn -> Enum.at(lesson_profiles, rem(question_index, length(lesson_profiles))) end
          )
          |> case do
            %{tokens: tokens} = selected ->
              if token_overlap(question_tokens, tokens) == 0,
                do: Enum.at(lesson_profiles, rem(question_index, length(lesson_profiles))),
                else: selected
          end

      lesson = profile.lesson
      lesson_title = lesson["title"] || "Lesson #{profile.index + 1}"
      objectives = normalize_objectives(lesson["source_objectives"], lesson_title)
      objective = best_text_match(question_tokens, objectives) || List.first(objectives)

      instruction_block_ids =
        profile.blocks
        |> Enum.sort_by(
          &token_overlap(question_tokens, keyword_tokens(&1["text"])),
          :desc
        )
        |> Enum.filter(&(token_overlap(question_tokens, keyword_tokens(&1["text"])) > 0))
        |> Enum.take(3)
        |> Enum.map(& &1["id"])
        |> case do
          [] -> profile.blocks |> Enum.take(1) |> Enum.map(& &1["id"])
          ids -> ids
        end

      question
      |> Map.put("mapped_lesson_index", profile.index)
      |> Map.put("mapped_lesson_title", lesson_title)
      |> Map.put("mapped_source_sections", lesson["source_sections"] || [])
      |> Map.put("mapped_objective_ids", [objective])
      |> Map.put("instruction_evidence_block_ids", instruction_block_ids)
    end)
  end

  defp select_assessment_questions(mapped, lessons) do
    desired_count = min(max(length(lessons), 2), 4)

    per_lesson =
      mapped
      |> Enum.uniq_by(& &1["mapped_lesson_index"])

    selected_ids = MapSet.new(per_lesson, & &1["id"])

    (per_lesson ++ Enum.reject(mapped, &MapSet.member?(selected_ids, &1["id"])))
    |> Enum.take(min(desired_count, length(mapped)))
    |> Enum.sort_by(& &1["order"])
  end

  defp assessment_questions(mapped) do
    Enum.map(mapped, fn evidence ->
      lesson_title = evidence["mapped_lesson_title"] || "the related lesson"
      objectives = evidence["mapped_objective_ids"] || []

      %{
        "id" => evidence["id"],
        "prompt" => evidence["prompt"],
        "type" => "short_answer",
        "response_kind" => "application",
        "answer_keywords" => answer_keywords(lesson_title, objectives),
        "correct_feedback" => "Your response accurately applies the relevant lesson evidence.",
        "incorrect_feedback" => "Review the mapped lesson evidence and revise your explanation.",
        "remediation" =>
          "Revisit #{lesson_title}, especially #{List.first(objectives) || "its main objective"}.",
        "objective_ids" => objectives,
        "evidence_block_ids" => evidence["instruction_evidence_block_ids"] || [],
        "source_question_block_ids" => evidence["source_block_ids"] || [],
        "source_question_id" => evidence["id"],
        "source_evidence_links" =>
          Enum.uniq(
            (evidence["mapped_source_sections"] || []) ++
              List.wrap(evidence["source_url"])
          )
      }
    end)
  end

  defp lesson_assessment_tokens(lesson) do
    [
      lesson["title"],
      Enum.join(lesson["source_objectives"] || [], " "),
      lesson["source_excerpt"],
      Enum.map_join(source_blocks(lesson), " ", & &1["text"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> keyword_tokens()
  end

  defp exact_assessment_profile(question, lesson_profiles) do
    related_slugs = MapSet.new(question["related_section_slugs"] || [])

    Enum.find(lesson_profiles, fn profile ->
      not MapSet.disjoint?(related_slugs, profile.source_slugs)
    end)
  end

  defp lesson_source_slugs(lesson) do
    lesson
    |> Map.get("source_sections", [])
    |> Enum.map(fn url ->
      url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> String.split("/")
      |> List.last()
    end)
    |> Enum.filter(&present?/1)
    |> MapSet.new()
  end

  defp keyword_tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 4 or MapSet.member?(@keyword_stop_words, &1)))
    |> MapSet.new()
  end

  defp keyword_tokens(_), do: MapSet.new()

  defp token_overlap(left, right), do: MapSet.intersection(left, right) |> MapSet.size()

  defp best_text_match(_question_tokens, []), do: nil

  defp best_text_match(question_tokens, values) do
    Enum.max_by(
      values,
      &token_overlap(question_tokens, keyword_tokens(&1)),
      fn -> nil end
    )
  end

  @spec repair_lesson_plan(map(), map(), map()) :: map()
  def repair_lesson_plan(plan_payload, repair_plan, source_context \\ %{})

  def repair_lesson_plan(plan_payload, _repair_plan, _source_context)
      when is_map(plan_payload) do
    content = plan_payload["content_payload"] || %{}
    questions = plan_payload["questions_payload"] || %{}

    # A repair pass may normalize an existing plan, but it must never discard a
    # rich draft and replace it with a thin deterministic lesson. Structured
    # validation runs again after this bounded pass; unresolved failures become
    # reviewer-visible needs_attention state.
    repair_generic_plan(content, questions)
  end

  def repair_lesson_plan(plan_payload, _repair_plan, _source_context) when is_map(plan_payload),
    do:
      repair_generic_plan(
        plan_payload["content_payload"] || %{},
        plan_payload["questions_payload"] || %{}
      )

  defp repair_generic_plan(content, questions) do
    title = content["title"] || "this lesson"
    evidence_links = content["source_evidence_links"] || []
    rich_plan? = content["schema_version"] == 3

    objectives =
      content
      |> Map.get("learning_objectives", [])
      |> case do
        [] -> ["Explain and apply the lesson's core concept"]
        values -> values
      end

    items =
      questions
      |> Map.get("items", [])
      |> Enum.filter(&(is_map(&1) and present?(&1["prompt"])))
      |> Enum.take(6)
      |> maybe_ensure_minimum_questions(rich_plan?, title, evidence_links)
      |> Enum.map(&ensure_question_support(&1, title, objectives, content))

    instructional_sections =
      if rich_plan? do
        normalize_existing_instructional_sections(
          content["instructional_sections"],
          evidence_links
        )
      else
        normalize_instructional_sections(
          content["instructional_sections"],
          content["narrative"],
          title,
          evidence_links
        )
      end

    repaired_examples =
      if rich_plan? do
        normalize_existing_worked_examples(content["worked_examples"], evidence_links)
      else
        normalize_worked_examples(
          content["worked_examples"],
          title,
          objectives,
          instructional_sections,
          evidence_links
        )
      end

    repaired_takeaways =
      if rich_plan? do
        normalize_string_list(content["key_takeaways"], 8)
      else
        normalize_takeaways(
          content["key_takeaways"],
          objectives,
          instructional_sections,
          title
        )
      end

    %{
      "content_payload" =>
        content
        |> Map.put("learning_objectives", objectives)
        |> Map.put_new("objective", List.first(objectives))
        |> Map.put_new("narrative", "Review the source evidence and apply the core concept.")
        |> Map.put("instructional_sections", instructional_sections)
        |> Map.put("worked_examples", repaired_examples)
        |> Map.put("key_takeaways", repaired_takeaways),
      "questions_payload" => %{"items" => items}
    }
  end

  @doc """
  Recommends Basic or Advanced Author from durable source evidence.

  Structured-source lessons must contain enough evidence for a source-grounded
  knowledge check, decision, exploration, or misconception-remediation path.
  Suitable lessons are then placed in one stable slot per three planning
  positions so a course remains a deliberate mixture rather than becoming an
  all-Advanced sequence. Legacy excerpt-only runs retain their v1 behavior.
  """
  @spec authoring_mode_recommendation(map(), pos_integer()) :: map()
  def authoring_mode_recommendation(lesson, index)
      when is_map(lesson) and is_integer(index) and index > 0 do
    case source_blocks(lesson) do
      [] ->
        mode = legacy_recommend_mode(lesson, index)

        %{
          "mode" => mode,
          "strategy" => "legacy_v1",
          "candidate" => mode == "advanced",
          "selected_for_mix" => mode == "advanced",
          "signals" => [],
          "recommended_interactions" => [],
          "reasons" => ["Preserve the authoring-mode behavior of an existing excerpt-only run."]
        }

      blocks ->
        signals = advanced_suitability_signals(lesson, blocks)
        candidate? = advanced_candidate?(signals)
        selected_for_mix? = candidate? and advanced_mix_slot?(index)

        %{
          "mode" => if(selected_for_mix?, do: "advanced", else: "basic"),
          "strategy" => "pedagogical_mix_v2",
          "candidate" => candidate?,
          "selected_for_mix" => selected_for_mix?,
          "signals" => signals,
          "recommended_interactions" => recommended_interactions(signals),
          "mix" => %{
            "window_size" => @advanced_window_size,
            "advanced_slot" => @advanced_window_slot,
            "planning_position" => index
          },
          "reasons" => recommendation_reasons(candidate?, selected_for_mix?, signals)
        }
    end
  end

  def authoring_mode_recommendation(_lesson, _index) do
    %{
      "mode" => "basic",
      "strategy" => "pedagogical_mix_v2",
      "candidate" => false,
      "selected_for_mix" => false,
      "signals" => [],
      "recommended_interactions" => [],
      "reasons" => ["The lesson does not provide enough source evidence for adaptivity."]
    }
  end

  defp advanced_suitability_signals(lesson, blocks) do
    objective_tokens =
      lesson
      |> Map.get("source_objectives", [])
      |> List.wrap()
      |> Enum.join(" ")
      |> signal_tokens()

    source_tokens =
      [
        lesson["title"],
        Enum.map_join(blocks, " ", fn block ->
          [block["text"], block["callout_body"], block["title"], block["subtitle"]]
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")
        end)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> signal_tokens()

    kinds =
      blocks
      |> Enum.map(&String.downcase(to_string(&1["kind"])))
      |> MapSet.new()

    instructional_block_count =
      Enum.count(blocks, fn block ->
        block["kind"] in [
          "paragraph",
          "list",
          "table",
          "code",
          "callout",
          "exercise",
          "exercises",
          "problem",
          "problems",
          "question",
          "questions"
        ] and present?(block["text"])
      end)

    source_word_count = lesson["source_word_count"] || source_word_count(lesson)

    source_grounded_knowledge_check? =
      source_word_count >= @knowledge_check_min_words and
        instructional_block_count >= @knowledge_check_min_instructional_blocks

    [
      {"higher_order_objective",
       contains_signal?(objective_tokens, @higher_order_objective_terms)},
      {"source_practice_or_case", Enum.any?(@adaptive_source_kinds, &MapSet.member?(kinds, &1))},
      {"decision_context", contains_signal?(source_tokens, @decision_terms)},
      {"misconception_or_contrast", contains_signal?(source_tokens, @contrast_terms)},
      {"quantitative_exploration", contains_signal?(source_tokens, @quantitative_terms)},
      {"source_grounded_knowledge_check", source_grounded_knowledge_check?}
    ]
    |> Enum.flat_map(fn
      {signal, true} -> [signal]
      {_signal, false} -> []
    end)
  end

  defp advanced_candidate?(signals) do
    signal_set = MapSet.new(signals)

    cognitive_demand? = MapSet.member?(signal_set, "higher_order_objective")

    source_grounded_knowledge_check? =
      MapSet.member?(signal_set, "source_grounded_knowledge_check")

    pathway_evidence? =
      Enum.any?(
        [
          "source_practice_or_case",
          "misconception_or_contrast",
          "quantitative_exploration"
        ],
        &MapSet.member?(signal_set, &1)
      )

    source_grounded_knowledge_check? or
      (cognitive_demand? and pathway_evidence? and length(signals) >= 3)
  end

  defp advanced_mix_slot?(index) do
    rem(index - 1, @advanced_window_size) + 1 == @advanced_window_slot
  end

  defp recommended_interactions(signals) do
    signal_set = MapSet.new(signals)

    []
    |> maybe_recommend(
      MapSet.member?(signal_set, "decision_context"),
      "decision_pathway"
    )
    |> maybe_recommend(
      MapSet.member?(signal_set, "quantitative_exploration"),
      "prediction_exploration"
    )
    |> maybe_recommend(
      MapSet.member?(signal_set, "source_practice_or_case") or
        MapSet.member?(signal_set, "misconception_or_contrast") or
        MapSet.member?(signal_set, "source_grounded_knowledge_check"),
      "misconception_knowledge_check"
    )
    |> maybe_recommend(signals != [], "remediation_pathway")
  end

  defp maybe_recommend(values, true, value), do: values ++ [value]
  defp maybe_recommend(values, false, _value), do: values

  defp recommendation_reasons(true, true, signals) do
    [
      "The source supports a source-grounded knowledge check, decision, or exploration with targeted remediation.",
      "This lesson occupies the stable Advanced Author slot in its three-lesson planning window.",
      "Suitability signals: #{Enum.join(signals, ", ")}"
    ]
  end

  defp recommendation_reasons(true, false, signals) do
    [
      "The source could support adaptivity, but this lesson remains Basic to keep Advanced Author lessons bounded to one per three planning positions.",
      "Suitability signals: #{Enum.join(signals, ", ")}"
    ]
  end

  defp recommendation_reasons(false, _selected_for_mix?, signals) do
    detail =
      case signals do
        [] -> "No reliable adaptive-pathway signals were found in the structured source."
        values -> "Available signals are insufficient on their own: #{Enum.join(values, ", ")}."
      end

    [
      "Use Basic Author for direct instruction with interleaved formative checks.",
      detail
    ]
  end

  defp signal_tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> MapSet.new()
  end

  defp signal_tokens(_), do: MapSet.new()

  defp contains_signal?(tokens, terms) do
    Enum.any?(terms, &MapSet.member?(tokens, &1))
  end

  defp build_advanced_blueprint("advanced", recommendation, sections, questions) do
    section_ids =
      sections
      |> Enum.map(& &1["id"])
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    question =
      Enum.find(questions, fn question ->
        question["type"] == "multiple_choice" and
          length(List.wrap(question["choices"])) in 2..6
      end)

    target_section =
      case question do
        %{"placement_after_section_id" => placement} when is_binary(placement) ->
          if MapSet.member?(section_ids, placement),
            do: Enum.find(sections, &(&1["id"] == placement)),
            else: List.first(sections)

        _ ->
          List.first(sections)
      end

    case {question, target_section} do
      {%{} = question, %{} = section} ->
        screen_id = "adaptive-knowledge-check-1"
        section_id = section["id"]
        signals = MapSet.new(recommendation["signals"] || [])

        screen_kind =
          if MapSet.member?(signals, "quantitative_exploration"),
            do: "exploration",
            else: "decision"

        evidence_block_ids =
          (List.wrap(question["evidence_block_ids"]) ++
             List.wrap(section["evidence_block_ids"]))
          |> Enum.filter(&present?/1)
          |> Enum.uniq()

        source_hint =
          section
          |> Map.get("explanation", section["heading"])
          |> first_sentence()

        %{
          "screens" => [
            %{
              "id" => screen_id,
              "kind" => screen_kind,
              "title" => "Choose the evidence-supported explanation",
              "prompt" => question["prompt"],
              "interaction_type" => "multiple_choice",
              "choices" => question["choices"],
              "correct_choice_id" => question["correct_choice_id"],
              "correct_feedback" => "This choice matches the source explanation: #{source_hint}",
              "incorrect_feedback" =>
                "Compare your choice with this source explanation: #{source_hint}",
              "remediation" => "Review #{section["heading"]} before trying again: #{source_hint}",
              "placement_after_section_id" => section_id,
              "remediation_section_id" => section_id,
              "evidence_block_ids" => evidence_block_ids
            }
          ],
          "remediation_paths" => [
            %{
              "from_question_id" => screen_id,
              "to_section_id" => section_id,
              "misconception" =>
                "The learner selected an explanation that is not supported by the cited source evidence."
            }
          ]
        }

      _ ->
        # The suitability heuristic only selects structured lessons, whose first
        # two formative activities are deterministic MCQs. Keep this fallback
        # fail-closed for unexpected or manually assembled source maps.
        %{"screens" => [], "remediation_paths" => []}
    end
  end

  defp build_advanced_blueprint(_mode, _recommendation, _sections, _questions), do: %{}

  defp legacy_recommend_mode(lesson, index) do
    section_count = length(lesson["source_sections"] || [])
    excerpt_length = String.length(lesson["source_excerpt"] || "")

    if rem(index, 2) == 0 or section_count >= 3 or excerpt_length > 7_000,
      do: "advanced",
      else: "basic"
  end

  defp normalize_objectives(values, _title) when is_list(values) and values != [] do
    values
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> case do
      [] -> ["Explain the lesson's core idea"]
      objectives -> objectives
    end
  end

  defp normalize_objectives(_, title), do: ["Explain and apply the core ideas in #{title}"]

  defp narrative(lesson, title) do
    case String.trim(lesson["source_excerpt"] || "") do
      "" ->
        "This lesson introduces #{title}, connects it to the unit goals, and gives learners guided practice."

      excerpt ->
        source_introduction(excerpt, title)
    end
  end

  defp estimated_minutes(lesson) do
    12 + min(length(lesson["source_sections"] || []) * 6, 18)
  end

  defp assessment_lesson_sample([]), do: []

  defp assessment_lesson_sample(lessons) do
    lessons
    |> Stream.cycle()
    |> Enum.take(lessons |> length() |> max(2) |> min(4))
  end

  defp question_count(lesson, objectives) do
    if source_blocks(lesson) != [] do
      objectives
      |> length()
      |> max(4)
      |> min(6)
    else
      lesson
      |> Map.get("source_sections", [])
      |> length()
      |> Kernel.+(2)
      |> min(4)
      |> max(2)
    end
  end

  defp question_prompt(title, _objectives, 1),
    do: "In your own words, explain the central idea of #{title}."

  defp question_prompt(_title, objectives, 2),
    do: "Give an example that demonstrates: #{List.first(objectives)}."

  defp question_prompt(title, _objectives, index),
    do: "Apply a concept from #{title} to a new situation (part #{index - 2})."

  defp formative_question(
         title,
         objectives,
         instructional_sections,
         evidence_links,
         answer_keywords,
         question_index,
         question_count,
         objective_block_ids,
         rich_source?
       ) do
    section =
      Enum.at(
        instructional_sections,
        rem(question_index - 1, max(length(instructional_sections), 1)),
        %{}
      )

    objective_ids = question_objective_ids(objectives, question_index, question_count)

    base = %{
      "id" => "q#{question_index}",
      "prompt" => question_prompt(title, objectives, question_index),
      "correct_feedback" => "Good work. Your response uses the central ideas from the lesson.",
      "incorrect_feedback" =>
        "Revisit the instructional sections and connect your answer to the lesson objective.",
      "remediation" => remediation_text(instructional_sections, title),
      "placement_after_section_id" => question_placement(instructional_sections, question_index),
      "objective_ids" => objective_ids,
      "evidence_block_ids" =>
        Enum.uniq(
          question_evidence(instructional_sections, question_index) ++
            objective_block_ids
        ),
      "source_evidence_links" => evidence_links
    }

    if rich_source? and question_index <= 2 do
      question_heading = section["heading"] || title

      correct_text =
        section
        |> Map.get("explanation", List.first(objective_ids) || title)
        |> first_sentence()
        |> case do
          "" -> List.first(objective_ids) || title
          text -> text
        end

      Map.merge(base, %{
        "prompt" =>
          "Which explanation of #{question_heading} is best supported by the lesson evidence?",
        "type" => "multiple_choice",
        "choices" => [
          %{
            "id" => "q#{question_index}-supported",
            "text" => correct_text,
            "correct" => true,
            "feedback" => "This explanation is supported by the cited lesson evidence."
          },
          %{
            "id" => "q#{question_index}-partial",
            "text" =>
              "The idea is only a definition and has no connection to the lesson evidence.",
            "correct" => false,
            "feedback" =>
              "The lesson develops the idea through evidence, examples, and application."
          },
          %{
            "id" => "q#{question_index}-unrelated",
            "text" =>
              "The idea is unrelated to the objective and does not affect the explanation.",
            "correct" => false,
            "feedback" =>
              "Review the mapped objective and the instructional section before choosing again."
          }
        ],
        "correct_choice_id" => "q#{question_index}-supported"
      })
    else
      Map.merge(base, %{
        "type" => "short_answer",
        "response_kind" => "application",
        "answer_keywords" => answer_keywords
      })
    end
  end

  defp question_objective_ids(objectives, question_index, question_count) do
    objectives
    |> Enum.with_index()
    |> Enum.filter(fn {_objective, objective_index} ->
      rem(objective_index, question_count) == question_index - 1
    end)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> [Enum.at(objectives, rem(question_index - 1, length(objectives)))]
      assigned -> assigned
    end
  end

  defp ensure_minimum_questions(items, _title, _evidence_links) when length(items) >= 2,
    do: items

  defp ensure_minimum_questions(items, title, evidence_links) do
    missing = 2 - length(items)

    generated =
      1..missing
      |> Enum.map(fn index ->
        %{
          "id" => "repair-q#{length(items) + index}",
          "prompt" => "Explain one important idea from #{title}.",
          "type" => "short_answer",
          "source_evidence_links" => evidence_links
        }
      end)

    items ++ generated
  end

  defp maybe_ensure_minimum_questions(items, true, _title, _evidence_links), do: items

  defp maybe_ensure_minimum_questions(items, false, title, evidence_links),
    do: ensure_minimum_questions(items, title, evidence_links)

  defp instructional_sections(lesson, title, evidence_links) do
    case source_sections_from_blocks(lesson, evidence_links) do
      [] ->
        lesson
        |> Map.get("source_excerpt", "")
        |> source_sections_from_excerpt(title, evidence_links)
        |> ensure_instructional_sections(title, evidence_links)

      sections ->
        sections
        |> Enum.take(7)
        |> ensure_instructional_sections(title, evidence_links)
    end
  end

  defp source_sections_from_blocks(lesson, evidence_links) do
    lesson
    |> source_blocks()
    |> Enum.reduce({[], nil, []}, fn block, {sections, current_heading, pending_ids} ->
      kind = block["kind"]
      heading = block_heading(block, current_heading)

      cond do
        kind == "heading" and present?(block["text"]) ->
          {sections, block["text"], Enum.uniq(pending_ids ++ [block["id"]])}

        kind in ["objective", "objectives"] ->
          {sections, current_heading, Enum.uniq(pending_ids ++ [block["id"]])}

        kind in ["figure", "footnote"] ->
          {sections, current_heading, pending_ids}

        kind == "callout" ->
          {sections, current_heading, pending_ids}

        present?(block["text"]) ->
          section_heading = heading || "Core ideas"

          updated =
            append_source_block(
              sections,
              section_heading,
              block,
              evidence_links,
              pending_ids
            )

          {updated, section_heading, []}

        true ->
          {sections, current_heading, pending_ids}
      end
    end)
    |> elem(0)
    |> Enum.map(fn section ->
      Map.update!(section, "explanation", &String.trim/1)
    end)
    |> Enum.filter(&(present?(&1["heading"]) and present?(&1["explanation"])))
  end

  defp append_source_block(sections, heading, block, evidence_links, pending_ids) do
    block_id = block["id"]
    block_ids = Enum.uniq(pending_ids ++ List.wrap(block_id))

    case List.last(sections) do
      %{"heading" => ^heading} = last ->
        updated =
          last
          |> Map.update!(
            "explanation",
            &String.trim(&1 <> "\n\n" <> block["text"])
          )
          |> Map.update!(
            "evidence_block_ids",
            fn ids -> Enum.uniq(ids ++ block_ids) end
          )

        List.replace_at(sections, length(sections) - 1, updated)

      _ ->
        sections ++
          [
            %{
              "id" => "section-#{length(sections) + 1}",
              "heading" => heading,
              "explanation" => String.trim(block["text"]),
              "examples" => [],
              "evidence_block_ids" => block_ids,
              "source_evidence_links" => evidence_links
            }
          ]
    end
  end

  defp block_heading(block, current_heading) do
    case block["heading_path"] do
      headings when is_list(headings) and headings != [] ->
        headings
        |> Enum.filter(&present?/1)
        |> List.last()
        |> case do
          nil -> current_heading
          heading -> heading
        end

      _ ->
        current_heading
    end
  end

  defp source_sections_from_excerpt(source_excerpt, title, evidence_links)
       when is_binary(source_excerpt) do
    source_excerpt = String.trim(source_excerpt)

    cond do
      source_excerpt == "" ->
        []

      String.contains?(source_excerpt, "## ") ->
        Regex.split(~r/(?m)^##\s+/, source_excerpt, trim: true)
        |> Enum.map(fn block ->
          case String.split(block, "\n", parts: 2) do
            [heading, explanation] ->
              instructional_section(heading, explanation, evidence_links)

            [explanation] ->
              instructional_section(title, explanation, evidence_links)
          end
        end)

      true ->
        source_excerpt
        |> split_source_paragraphs()
        |> Enum.chunk_every(2)
        |> Enum.with_index(1)
        |> Enum.map(fn {paragraphs, index} ->
          instructional_section(
            section_heading(index, title),
            Enum.join(paragraphs, "\n\n"),
            evidence_links
          )
        end)
    end
  end

  defp source_sections_from_excerpt(_, _title, _evidence_links), do: []

  defp normalize_instructional_sections(sections, narrative, title, evidence_links)
       when is_list(sections) do
    sections
    |> Enum.flat_map(fn
      %{} = section ->
        heading = section["heading"] || section[:heading] || section["title"] || section[:title]

        explanation =
          section["explanation"] || section[:explanation] || section["body"] || section[:body]

        if present?(heading) and present?(explanation) do
          [
            %{
              "heading" => String.trim(heading),
              "explanation" => String.trim(explanation),
              "examples" =>
                section
                |> Map.get("examples", Map.get(section, :examples, []))
                |> normalize_string_list(3),
              "source_evidence_links" => evidence_links
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> ensure_instructional_sections(title, evidence_links, narrative)
  end

  defp normalize_instructional_sections(_, narrative, title, evidence_links),
    do:
      narrative
      |> to_string()
      |> source_sections_from_excerpt(title, evidence_links)
      |> ensure_instructional_sections(title, evidence_links, narrative)

  defp normalize_existing_instructional_sections(sections, evidence_links)
       when is_list(sections) do
    sections
    |> Enum.flat_map(fn
      %{} = section ->
        heading = section["heading"] || section[:heading] || section["title"] || section[:title]

        explanation =
          section["explanation"] || section[:explanation] || section["body"] || section[:body]

        if present?(heading) and present?(explanation) do
          [
            %{
              "id" => section["id"] || section[:id],
              "heading" => String.trim(heading),
              "explanation" => String.trim(explanation),
              "examples" =>
                section
                |> Map.get("examples", Map.get(section, :examples, []))
                |> normalize_string_list(3),
              "evidence_block_ids" =>
                section["evidence_block_ids"] || section[:evidence_block_ids] || [],
              "source_evidence_links" =>
                section["source_evidence_links"] ||
                  section[:source_evidence_links] || evidence_links
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.take(7)
  end

  defp normalize_existing_instructional_sections(_, _evidence_links), do: []

  defp ensure_instructional_sections(
         sections,
         title,
         evidence_links,
         fallback_text \\ nil
       ) do
    sections =
      sections
      |> Enum.filter(&(present?(&1["heading"]) and present?(&1["explanation"])))
      |> Enum.take(6)

    case sections do
      [] ->
        fallback =
          case fallback_text do
            value when is_binary(value) and value != "" -> value
            _ -> "The selected OpenStax material introduces the central ideas in #{title}."
          end

        [
          instructional_section("Core ideas", fallback, evidence_links),
          instructional_section(
            "Connecting the ideas",
            "Use the lesson objective to identify how the concepts in #{title} relate, then compare that explanation with the cited OpenStax sections.",
            evidence_links
          )
        ]

      [section] ->
        sections ++
          [
            instructional_section(
              "Putting the idea in context",
              "Connect #{section["heading"]} to the lesson objective. Identify the evidence that supports the idea, explain why it matters, and consider where it can be applied.",
              evidence_links
            )
          ]

      _ ->
        sections
    end
  end

  defp instructional_section(heading, explanation, evidence_links) do
    %{
      "id" => "section-#{:erlang.phash2({heading, explanation})}",
      "heading" => String.trim(to_string(heading)),
      "explanation" => explanation |> to_string() |> String.trim() |> String.slice(0, 3_500),
      "examples" => [],
      "evidence_block_ids" => [],
      "source_evidence_links" => evidence_links
    }
  end

  defp worked_examples(title, objectives, instructional_sections, evidence_links) do
    substantial_case_count =
      if length(instructional_sections) >= 4,
        do: min(length(instructional_sections), 3),
        else: 1

    instructional_sections
    |> Enum.take(substantial_case_count)
    |> Enum.with_index(1)
    |> Enum.map(fn {section, index} ->
      objective = Enum.at(objectives, rem(index - 1, max(length(objectives), 1)))
      heading = section["heading"] || first_section_heading(instructional_sections)

      source_statement =
        section
        |> Map.get("explanation", "")
        |> first_sentence()
        |> case do
          "" -> "The source develops #{heading} through explanation and evidence."
          statement -> statement
        end

      %{
        "id" => "worked-example-#{index}",
        "title" => "Worked case: #{heading}",
        "scenario" => source_statement,
        "steps" => [
          "Start with this source statement for #{heading}: #{source_statement}",
          "Trace the evidence and reasoning in this source statement: #{source_statement}",
          "Use that reasoning to address the mapped objective: #{objective}."
        ],
        "conclusion" =>
          "The worked case connects the source explanation of #{heading} to #{objective}.",
        "evidence_block_ids" => List.wrap(section["evidence_block_ids"]) |> Enum.uniq(),
        "source_evidence_links" => evidence_links
      }
    end)
    |> case do
      [] ->
        [
          %{
            "id" => "worked-example-1",
            "title" => "Guided analysis: #{title}",
            "scenario" =>
              "Use the lesson material for #{title} to work through the central idea.",
            "steps" => [
              "State the objective in your own words: #{List.first(objectives)}.",
              "Locate the source explanation and identify the evidence that supports it.",
              "Connect the evidence to a new situation and check the conclusion."
            ],
            "conclusion" =>
              "A strong solution uses the source idea and checks the conclusion against the lesson objective.",
            "evidence_block_ids" => [],
            "source_evidence_links" => evidence_links
          }
        ]

      examples ->
        examples
    end
  end

  defp normalize_worked_examples(
         examples,
         title,
         objectives,
         instructional_sections,
         evidence_links
       )
       when is_list(examples) do
    normalized =
      examples
      |> Enum.flat_map(fn
        %{} = example ->
          example_title = example["title"] || example[:title]
          scenario = example["scenario"] || example[:scenario] || example["problem"]
          steps = normalize_string_list(example["steps"] || example[:steps] || [], 8)
          conclusion = example["conclusion"] || example[:conclusion] || example["solution"]

          if present?(example_title) and present?(scenario) and steps != [] and
               present?(conclusion) do
            [
              %{
                "title" => String.trim(example_title),
                "scenario" => String.trim(scenario),
                "steps" => steps,
                "conclusion" => String.trim(conclusion),
                "source_evidence_links" => evidence_links
              }
            ]
          else
            []
          end

        _ ->
          []
      end)
      |> Enum.take(3)

    case normalized do
      [] -> worked_examples(title, objectives, instructional_sections, evidence_links)
      examples -> examples
    end
  end

  defp normalize_worked_examples(
         _,
         title,
         objectives,
         instructional_sections,
         evidence_links
       ),
       do: worked_examples(title, objectives, instructional_sections, evidence_links)

  defp normalize_existing_worked_examples(examples, evidence_links)
       when is_list(examples) do
    examples
    |> Enum.flat_map(fn
      %{} = example ->
        example_title = example["title"] || example[:title]
        scenario = example["scenario"] || example[:scenario] || example["problem"]
        steps = normalize_string_list(example["steps"] || example[:steps] || [], 8)
        conclusion = example["conclusion"] || example[:conclusion] || example["solution"]

        if present?(example_title) and present?(scenario) and length(steps) >= 2 and
             present?(conclusion) do
          [
            %{
              "id" => example["id"] || example[:id],
              "title" => String.trim(example_title),
              "scenario" => String.trim(scenario),
              "steps" => steps,
              "conclusion" => String.trim(conclusion),
              "evidence_block_ids" =>
                example["evidence_block_ids"] || example[:evidence_block_ids] || [],
              "source_evidence_links" =>
                example["source_evidence_links"] ||
                  example[:source_evidence_links] || evidence_links
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.take(3)
  end

  defp normalize_existing_worked_examples(_, _evidence_links), do: []

  defp key_takeaways(objectives, instructional_sections, title) do
    section_takeaways =
      Enum.map(instructional_sections, fn section ->
        section["explanation"]
        |> first_sentence()
      end)

    (objectives ++ section_takeaways)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.take(6)
    |> ensure_takeaway_count(title)
  end

  defp normalize_takeaways(takeaways, objectives, instructional_sections, title) do
    takeaways
    |> normalize_string_list(8)
    |> case do
      values when length(values) >= 3 -> values
      _ -> key_takeaways(objectives, instructional_sections, title)
    end
  end

  defp ensure_takeaway_count(takeaways, _title) when length(takeaways) >= 3, do: takeaways

  defp ensure_takeaway_count(takeaways, title) do
    (takeaways ++
       [
         "Use the cited explanation from #{title} when explaining the lesson's central idea.",
         "Test an idea from #{title} by applying it to a new situation.",
         "Check a result for #{title} against the stated learning objective."
       ])
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp ensure_question_support(question, title, objectives, content) do
    question
    |> Map.put_new("type", "short_answer")
    |> Map.put_new("answer_keywords", answer_keywords(title, objectives))
    |> Map.put_new(
      "correct_feedback",
      "Good work. Your response uses the central ideas from the lesson."
    )
    |> Map.put_new(
      "incorrect_feedback",
      "Review the instructional material and connect your answer to the lesson objective."
    )
    |> Map.put_new(
      "remediation",
      remediation_text(content["instructional_sections"] || [], title)
    )
  end

  defp answer_keywords(title, objectives) do
    [title | objectives]
    |> Enum.join(" ")
    |> String.downcase()
    |> then(&Regex.scan(~r/[[:alpha:]][[:alpha:]'-]*/, &1))
    |> List.flatten()
    |> Enum.map(&String.trim(&1, "'-"))
    |> Enum.filter(&(String.length(&1) >= 4 and not MapSet.member?(@keyword_stop_words, &1)))
    |> Enum.uniq()
    |> Enum.take(4)
    |> case do
      [] -> ["evidence"]
      keywords -> keywords
    end
  end

  defp remediation_text(instructional_sections, title) do
    case List.first(List.wrap(instructional_sections)) do
      %{"explanation" => explanation} when is_binary(explanation) and explanation != "" ->
        "Review this idea before trying again: #{String.slice(explanation, 0, 600)}"

      _ ->
        "Review the instructional material for #{title}, then connect the source evidence to the question."
    end
  end

  defp source_introduction(source_excerpt, title) do
    source_excerpt
    |> String.replace(~r/(?m)^##\s+.+$/, "")
    |> split_source_paragraphs()
    |> Enum.take(2)
    |> Enum.join(" ")
    |> String.slice(0, 1_000)
    |> case do
      "" -> "This lesson develops the central ideas in #{title}."
      introduction -> introduction
    end
  end

  defp split_source_paragraphs(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp first_section_heading([%{"heading" => heading} | _]) when is_binary(heading), do: heading
  defp first_section_heading(_), do: "the instructional material"

  defp first_sentence(text) when is_binary(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.slice(0, 280)
  end

  defp first_sentence(_), do: ""

  defp source_blocks(lesson) do
    lesson
    |> Map.get("source_blocks", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        id = block["id"] || block[:id]
        kind = block["kind"] || block[:kind]
        text = block["text"] || block[:text] || ""
        heading_path = block["heading_path"] || block[:heading_path] || []
        metadata = block["metadata"] || block[:metadata] || %{}
        semantic_payload = metadata["semantic_payload"] || metadata[:semantic_payload] || %{}
        existing_callout = block["callout"] || block[:callout] || %{}

        callout_type =
          Enum.find(
            [
              block["callout_type"],
              block[:callout_type],
              semantic_payload["callout_type"],
              semantic_payload[:callout_type],
              existing_callout["kind"],
              existing_callout[:kind],
              existing_callout["type"],
              existing_callout[:type]
            ],
            &present?/1
          )

        callout_title =
          Enum.find(
            [
              block["title"],
              block[:title],
              semantic_payload["title"],
              semantic_payload[:title],
              existing_callout["title"],
              existing_callout[:title]
            ],
            &present?/1
          )

        callout_subtitle =
          Enum.find(
            [
              block["subtitle"],
              block[:subtitle],
              semantic_payload["subtitle"],
              semantic_payload[:subtitle],
              existing_callout["subtitle"],
              existing_callout[:subtitle]
            ],
            &present?/1
          )

        callout_body =
          Enum.find(
            [
              block["callout_body"],
              block[:callout_body],
              semantic_payload["callout_body"],
              semantic_payload[:callout_body],
              semantic_payload["text"],
              semantic_payload[:text],
              existing_callout["body"],
              existing_callout[:body],
              text
            ],
            &present?/1
          )

        callout =
          if kind == "callout" do
            %{
              "kind" => callout_type,
              "type" => callout_type,
              "title" => callout_title,
              "subtitle" => callout_subtitle,
              "body" => callout_body
            }
          else
            existing_callout
          end

        if present?(id) and present?(kind) do
          [
            %{
              "id" => id,
              "kind" => kind,
              "text" => text,
              "heading_path" => heading_path,
              "callout_type" => callout_type,
              "title" => callout_title,
              "subtitle" => callout_subtitle,
              "callout_body" => callout_body,
              "callout" => callout,
              "media" => block["media"] || block[:media]
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp source_objective_block_ids(lesson) do
    lesson
    |> source_blocks()
    |> Enum.filter(&(&1["kind"] in ["objective", "objectives"]))
    |> Enum.map(& &1["id"])
    |> Enum.filter(&present?/1)
  end

  defp source_callouts(lesson) do
    lesson
    |> source_blocks()
    |> Enum.filter(&(&1["kind"] == "callout"))
    |> Enum.with_index(1)
    |> Enum.map(fn {block, index} ->
      metadata = block["callout"] || %{}

      %{
        "id" => "callout-#{index}",
        "type" =>
          normalize_source_callout_type(
            metadata["type"] || metadata[:type] || metadata["kind"] || metadata[:kind]
          ),
        "title" =>
          metadata["subtitle"] || metadata[:subtitle] ||
            metadata["title"] || metadata[:title] ||
            block_heading(block, nil) || "Source connection",
        "body" => metadata["body"] || metadata[:body] || block["callout_body"] || block["text"],
        "placement_after_section_id" => nil,
        "evidence_block_ids" => [block["id"]]
      }
    end)
    |> Enum.take(6)
  end

  defp normalize_source_callout_type(type)
       when type in [
              "global_issue",
              "industry_spotlight",
              "concepts_in_practice",
              "learn_more",
              "example"
            ],
       do: type

  defp normalize_source_callout_type(_type), do: "learn_more"

  defp source_media(lesson) do
    explicit = lesson |> Map.get("source_media", []) |> List.wrap()

    embedded =
      lesson
      |> source_blocks()
      |> Enum.flat_map(fn block ->
        case block["media"] do
          %{} = media -> [Map.put_new(media, "id", block["id"])]
          _ -> []
        end
      end)

    (explicit ++ embedded)
    |> Enum.flat_map(fn
      %{} = media ->
        id = media["id"] || media[:id] || media["source_media_id"] || media[:source_media_id]
        source_url = media["source_url"] || media[:source_url] || media["src"] || media[:src]

        if present?(id) and present?(source_url) do
          [
            %{
              "id" => id,
              "source_media_id" => id,
              "source_url" => source_url,
              "source_section_url" => media["source_section_url"] || media[:source_section_url],
              "alt" => media["alt"] || media[:alt] || "",
              "caption" => media["caption"] || media[:caption] || "",
              "credit" => media["credit"] || media[:credit] || "",
              "width" => media["width"] || media[:width],
              "height" => media["height"] || media[:height],
              "rights_status" =>
                media["rights_status"] || media[:rights_status] || "requires_review",
              "evidence_block_ids" =>
                media["evidence_block_ids"] || media[:evidence_block_ids] || [id]
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(3)
  end

  defp curiosity_prompts(sections) do
    sections
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.map(fn {section, index} ->
      %{
        "id" => "curiosity-#{index}",
        "prompt" =>
          "Before continuing, predict how #{section["heading"]} could change a real decision or explanation.",
        "placement_after_section_id" => section["id"],
        "evidence_block_ids" => section["evidence_block_ids"] || []
      }
    end)
  end

  defp application_problems(sections) do
    sections
    |> Enum.take(5)
    |> Enum.with_index(1)
    |> Enum.map(fn {section, index} ->
      %{
        "id" => "problem-#{index}",
        "prompt" =>
          "Apply the source explanation of #{section["heading"]} to a new situation. State what transfers, what changes, and what evidence supports your conclusion.",
        "guidance" =>
          "Begin with the lesson's explanation, then identify the relevant constraints in the new situation.",
        "answer_outline" =>
          "A strong response accurately uses #{section["heading"]}, explains the transfer, and cites relevant lesson evidence.",
        "evidence_block_ids" => section["evidence_block_ids"] || []
      }
    end)
    |> ensure_application_problem_count(sections)
  end

  defp ensure_application_problem_count(problems, _sections) when length(problems) >= 3,
    do: problems

  defp ensure_application_problem_count(problems, sections) do
    fallback = List.first(sections, %{"heading" => "the lesson", "evidence_block_ids" => []})

    (problems ++
       Enum.map((length(problems) + 1)..3, fn index ->
         %{
           "id" => "problem-#{index}",
           "prompt" =>
             "Compare two possible applications of #{fallback["heading"]} and defend which is better supported.",
           "guidance" => "Use the lesson explanation as the comparison criterion.",
           "answer_outline" =>
             "The response should compare both applications and justify a conclusion with lesson evidence.",
           "evidence_block_ids" => fallback["evidence_block_ids"] || []
         }
       end))
    |> Enum.take(5)
  end

  defp question_placement([], _index), do: nil

  defp question_placement(sections, index) do
    sections
    |> Enum.at(rem(index - 1, length(sections)), %{})
    |> Map.get("id")
  end

  defp question_evidence([], _index), do: []

  defp question_evidence(sections, index) do
    sections
    |> Enum.at(rem(index - 1, length(sections)), %{})
    |> Map.get("evidence_block_ids", [])
  end

  defp plan_evidence_ids(sections, callouts, media) do
    (sections ++ callouts ++ media)
    |> Enum.flat_map(&List.wrap(&1["evidence_block_ids"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp source_attribution(lesson, evidence_links) do
    case lesson["attribution"] do
      %{} = attribution ->
        attribution

      _ ->
        %{
          "provider" => "OpenStax",
          "source_title" => lesson["title"],
          "source_urls" => evidence_links,
          "license" => "CC BY-NC-SA"
        }
    end
  end

  defp source_word_count(lesson) do
    lesson
    |> source_blocks()
    |> Enum.map(& &1["text"])
    |> Enum.join(" ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp section_heading(1, title), do: "Foundations of #{title}"
  defp section_heading(2, _title), do: "How the ideas connect"
  defp section_heading(index, _title), do: "Concept development #{index}"

  defp normalize_string_list(values, limit) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(limit)
  end

  defp normalize_string_list(_, _limit), do: []

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
