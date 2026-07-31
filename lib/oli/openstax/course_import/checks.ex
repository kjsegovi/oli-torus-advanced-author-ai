defmodule Oli.OpenStax.CourseImport.Checks do
  @moduledoc """
  Runs three bounded lesson-plan checks that surface reviewer-facing concerns.

  These checks guide author review and repair; an author may explicitly approve
  a lesson with outstanding findings. Structural compiler and media-safety
  validation remain hard requirements during apply.
  """

  @check_types [:source_fidelity, :pedagogy_assessment, :torus_accessibility]

  # This intentionally favors a small, explainable grounding signal over a
  # broad similarity score. A claim only fails when it introduces at least two
  # substantive terms that never occur in the ingested excerpt, source
  # objectives, or lesson title. Generic instructional language is ignored so
  # defensible plans are not rejected merely for saying "explain" or "apply".
  @grounding_stop_words MapSet.new(~w(
    about accurately affect after again against also an and answer application
    applications apply are as at be been before begin best between beyond breaks by
    can central change changes check checks choice choosing cited cites compare
    comparison concept conclusion connect connection connects constraints continue
    continuing core could course decision defend definition describe demonstrate do
    down each evidence example examples examine explain explanation explains for from
    give good guidance holds how idea ideas identify in instead introduction is
    isolated it its learner lesson lesson's locate main mapped material matters more
    new objective of on only or our overview part practice predict prediction
    question real reason reasoning recalling related relevant response result review
    section show shows situation solution source state steps strong student supported
    supports take than that the their then these this through to transfer transfers
    trying unrelated use uses using what when where which why with work words your
  ))

  @type result :: %{
          required(:check_type) => String.t(),
          required(:status) => String.t(),
          required(:findings) => map(),
          required(:repair_plan) => map() | nil
        }

  @spec run(map(), map()) :: [result()]
  def run(lesson, plan) when is_map(lesson) and is_map(plan) do
    Enum.map(@check_types, &run_check(&1, lesson, plan))
  end

  @spec passed?([result()]) :: boolean()
  def passed?(results) when is_list(results),
    do: results != [] and Enum.all?(results, &(&1.status == "passed"))

  defp run_check(:source_fidelity, lesson, plan) do
    source_sections =
      (Map.get(lesson, :source_sections) || Map.get(lesson, "source_sections") || [])
      |> Enum.filter(&openstax_link?/1)
      |> MapSet.new()

    content_links =
      plan
      |> content()
      |> Map.get("source_evidence_links", [])
      |> List.wrap()
      |> MapSet.new()

    question_links =
      plan
      |> questions()
      |> Enum.map(fn question ->
        question
        |> Map.get("source_evidence_links", [])
        |> List.wrap()
        |> MapSet.new()
      end)

    url_failures =
      []
      |> maybe_add(
        MapSet.size(source_sections) == 0,
        "The lesson has no canonical OpenStax source sections"
      )
      |> maybe_add(
        MapSet.size(content_links) == 0 or
          not MapSet.subset?(content_links, source_sections),
        "Lesson claims must cite only their selected OpenStax source sections"
      )
      |> maybe_add(
        Enum.any?(
          question_links,
          &(MapSet.size(&1) == 0 or not MapSet.subset?(&1, source_sections))
        ),
        "Every formative question must cite one of the lesson's OpenStax source sections"
      )

    grounding = deterministic_grounding(lesson, plan, source_sections)
    coverage = block_coverage(lesson, plan)

    failures = url_failures ++ coverage.issues ++ grounding.issues

    source_result(failures, grounding, coverage)
  end

  defp run_check(:pedagogy_assessment, lesson, plan) do
    content = content(plan)
    objectives = content["learning_objectives"] || []
    instructional_sections = instructional_sections(content)
    worked_examples = worked_examples(content)
    key_takeaways = key_takeaways(content)
    curiosity_prompts = content_list(content, "curiosity_prompts")
    application_problems = content_list(content, "application_problems")
    questions = questions(plan)
    mode = content["authoring_mode"] || "basic"

    advanced_blueprint_issues =
      if mode == "advanced" and v3_plan?(plan) do
        validate_advanced_blueprint(lesson, content)
      else
        []
      end

    instructional_words = instructional_word_count(content)
    rich_source? = rich_source?(lesson)
    minimum_words = minimum_instructional_words(lesson)
    minimum_sections = if rich_source?, do: 4, else: 2
    minimum_questions = if rich_source?, do: 4, else: 2
    multiple_choice_count = Enum.count(questions, &(&1["type"] == "multiple_choice"))

    source_objectives_complete? =
      not (v3_plan?(plan) and rich_source?) or
        source_objectives_complete?(lesson, content, questions)

    source_objectives_taught? =
      not (v3_plan?(plan) and rich_source?) or
        source_objectives_taught?(lesson, instructional_sections)

    failures =
      []
      |> maybe_add(objectives == [], "Add at least one measurable learning objective")
      |> maybe_add(
        length(instructional_sections) < minimum_sections,
        "Add at least #{minimum_sections} substantive instructional sections before assessment"
      )
      |> maybe_add(
        length(instructional_sections) > 7,
        "Limit a lesson to seven instructional sections and split it at an objective boundary"
      )
      |> maybe_add(
        instructional_words < minimum_words,
        "Expand learner-facing instruction to at least #{minimum_words} words for this source"
      )
      |> maybe_add(worked_examples == [], "Add at least one guided or worked example")
      |> maybe_add(
        rich_source? and length(curiosity_prompts) < 2,
        "Add at least two source-grounded curiosity or prediction prompts"
      )
      |> maybe_add(
        rich_source? and length(application_problems) < 3,
        "Add at least three original application or synthesis problems"
      )
      |> maybe_add(length(key_takeaways) < 3, "Add at least three lesson takeaways")
      |> maybe_add(
        length(questions) < minimum_questions,
        "Add at least #{minimum_questions} formative questions"
      )
      |> maybe_add(length(questions) > 6, "Limit formative questions to six")
      |> maybe_add(
        Enum.any?(questions, &(not present?(&1["prompt"]))),
        "Every question needs a learner-facing prompt"
      )
      |> maybe_add(
        rich_source? and multiple_choice_count < 2,
        "Add at least two meaningful multiple-choice checks with misconception feedback"
      )
      |> maybe_add(
        Enum.any?(questions, &invalid_question?/1),
        "Every formative question must have a valid supported response contract"
      )
      |> maybe_add(
        not objectives_assessed?(objectives, questions, rich_source?),
        "Map every learning objective to at least one formative question"
      )
      |> maybe_add(
        not source_objectives_complete?,
        "Preserve every source learning objective in the lesson plan and formative assessment mapping"
      )
      |> maybe_add(
        not source_objectives_taught?,
        "Cite the source learning-objective blocks from learner-facing instruction"
      )
      |> maybe_add(
        mode == "advanced" and v3_plan?(plan) and advanced_blueprint_issues == [] and
          not meaningful_advanced_blueprint?(content),
        "Advanced lessons need a real exploration or decision screen and a remediation path"
      )
      |> Kernel.++(advanced_blueprint_issues)

    result(:pedagogy_assessment, failures, %{
      "ensure_objective" => true,
      "instructional_section_range" => [minimum_sections, 7],
      "minimum_instructional_words" => minimum_words,
      "ensure_worked_example" => true,
      "curiosity_prompt_range" => if(rich_source?, do: [2, 3], else: [0, 3]),
      "application_problem_range" => if(rich_source?, do: [3, 5], else: [0, 5]),
      "minimum_takeaways" => 3,
      "question_range" => [minimum_questions, 6],
      "minimum_multiple_choice" => if(rich_source?, do: 2, else: 0),
      "objective_assessment_mapping" => true,
      "advanced_blueprint" => mode == "advanced"
    })
  end

  defp run_check(:torus_accessibility, lesson, plan) do
    content = content(plan)
    mode = content["authoring_mode"] || Map.get(lesson, :plan_mode) || "basic"
    media = content_list(content, "media")
    v3_media_issues = if v3_plan?(plan), do: validate_v3_media(lesson, media), else: []

    failures =
      []
      |> maybe_add(mode not in ["basic", "advanced"], "Use a supported authoring mode")
      |> maybe_add(not present?(content["title"]), "Add a descriptive lesson title")
      |> maybe_add(not present?(content["narrative"]), "Add a readable lesson narrative")
      |> maybe_add(
        Enum.any?(
          questions(plan),
          &(Map.get(&1, "type") not in ["short_answer", "multiple_choice"])
        ),
        "Use a supported accessible question type"
      )
      |> maybe_add(
        duplicate_ids?(questions(plan)),
        "Give each formative question a stable unique id"
      )
      |> maybe_add(
        v3_plan?(plan) and Enum.any?(questions(plan), &(not safe_v3_id?(&1["id"]))),
        "Use question ids containing only letters, digits, underscores, or hyphens and at most 64 characters"
      )
      |> maybe_add(
        Enum.any?(media, &invalid_media?/1),
        "Every selected figure needs a server-issued id, useful alt text, caption, and credit"
      )
      |> maybe_add(
        Enum.any?(media, &(&1["rights_status"] == "blocked")),
        "Remove or replace figures whose rights do not allow project ingestion"
      )
      |> Kernel.++(v3_media_issues)

    result(:torus_accessibility, failures, %{
      "supported_modes" => ["basic", "advanced"],
      "supported_question_types" => ["short_answer", "multiple_choice"],
      "media_requires" => ["source_media_id", "alt", "caption", "credit"],
      "stable_question_ids" => true,
      "v3_question_id_pattern" => "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$",
      "v3_media_rights_status" => "approved"
    })
  end

  defp result(check_type, [], _repair_plan) do
    %{
      check_type: Atom.to_string(check_type),
      status: "passed",
      findings: %{"issues" => []},
      repair_plan: nil
    }
  end

  defp result(check_type, failures, repair_plan) do
    %{
      check_type: Atom.to_string(check_type),
      status: "failed",
      findings: %{"issues" => Enum.reverse(failures)},
      repair_plan: repair_plan
    }
  end

  defp source_result([], grounding, coverage) do
    %{
      check_type: "source_fidelity",
      status: "passed",
      findings: %{
        "issues" => [],
        "evaluation" => Map.put(grounding.evaluation, "coverage", coverage.evaluation)
      },
      repair_plan: nil
    }
  end

  defp source_result(failures, grounding, coverage) do
    %{
      check_type: "source_fidelity",
      status: "failed",
      findings: %{
        "issues" => failures,
        "evaluation" => Map.put(grounding.evaluation, "coverage", coverage.evaluation)
      },
      repair_plan: %{
        "add_source_evidence_links" => true,
        "add_block_evidence" => true,
        "reground_to_source" => true,
        "cited_source_sections" => grounding.evaluation["cited_source_sections"],
        "unsupported_claims" => grounding.evaluation["unsupported_claims"],
        "uncovered_major_block_ids" => coverage.evaluation["uncovered_major_block_ids"],
        "unknown_block_ids" => coverage.evaluation["unknown_block_ids"]
      }
    }
  end

  defp block_coverage(lesson, plan) do
    available_blocks = source_blocks(lesson)
    available_ids = MapSet.new(Enum.map(available_blocks, & &1["id"]))

    if MapSet.size(available_ids) == 0 do
      %{
        issues: [],
        evaluation: %{
          "strategy" => "legacy_page_url",
          "available_block_count" => 0,
          "covered_block_count" => 0,
          "uncovered_major_block_ids" => [],
          "unknown_block_ids" => []
        }
      }
    else
      referenced_ids = referenced_block_ids(plan)
      excluded = excluded_blocks(plan, available_ids)
      excluded_ids = MapSet.new(Enum.map(excluded, & &1["id"]))
      known_referenced = MapSet.intersection(referenced_ids, available_ids)
      unknown_ids = MapSet.difference(referenced_ids, available_ids)

      major_ids =
        available_blocks
        |> Enum.filter(&major_source_block?/1)
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      uncovered_major =
        major_ids
        |> MapSet.difference(MapSet.union(known_referenced, excluded_ids))

      evidence_failures =
        []
        |> maybe_add(
          MapSet.size(unknown_ids) > 0,
          "The plan references source block ids that were not issued by the importer"
        )
        |> maybe_add(
          missing_section_evidence?(plan),
          "Every instructional section must cite at least one source block"
        )
        |> maybe_add(
          missing_question_evidence?(plan),
          "Every formative question must cite at least one source block"
        )
        |> maybe_add(
          v3_plan?(plan) and missing_v3_learner_evidence?(plan),
          "Every curiosity prompt, application problem, and Advanced screen must cite at least one source block"
        )
        |> maybe_add(
          MapSet.size(uncovered_major) > 0,
          "Cover or explicitly explain the exclusion of every objective, heading, callout, and figure"
        )

      %{
        issues: Enum.reverse(evidence_failures),
        evaluation: %{
          "strategy" => "semantic_block_coverage",
          "available_block_count" => MapSet.size(available_ids),
          "covered_block_count" => MapSet.size(known_referenced),
          "excluded_blocks" => excluded,
          "uncovered_major_block_ids" => MapSet.to_list(uncovered_major) |> Enum.sort(),
          "unknown_block_ids" => MapSet.to_list(unknown_ids) |> Enum.sort()
        }
      }
    end
  end

  defp deterministic_grounding(lesson, plan, source_sections) do
    source_tokens = source_tokens(lesson)
    source_blocks_by_id = Map.new(source_blocks(lesson), &{&1["id"], &1})

    # A schema-v3-shaped fallback plan may still belong to a legacy URL/excerpt
    # run. Block-scoped V3 grounding is only meaningful when normalized source
    # blocks were actually ingested; otherwise retain the legacy excerpt
    # compatibility boundary.
    block_grounded_v3? = v3_plan?(plan) and map_size(source_blocks_by_id) > 0

    unsupported_claims =
      if MapSet.size(source_tokens) == 0 do
        []
      else
        plan
        |> source_claims(block_grounded_v3?)
        |> Enum.flat_map(fn %{kind: kind, text: text} = claim ->
          claim_tokens =
            if block_grounded_v3? do
              evidence_source_tokens(claim, source_blocks_by_id, source_tokens)
            else
              source_tokens
            end

          unsupported_claim(text, kind, claim_tokens, block_grounded_v3?)
        end)
      end

    issues =
      Enum.map(unsupported_claims, fn %{
                                        kind: kind,
                                        text: text,
                                        unsupported_terms: unsupported_terms
                                      } ->
        "#{humanize_claim_kind(kind)} is not grounded in the ingested source: #{inspect(text)} " <>
          "(unsupported terms: #{Enum.join(unsupported_terms, ", ")})"
      end)

    %{
      issues: issues,
      evaluation: %{
        "strategy" => "deterministic_semantic_grounding",
        "source_content_available" => MapSet.size(source_tokens) > 0,
        "cited_source_sections" => MapSet.to_list(source_sections) |> Enum.sort(),
        "source_objectives" => source_objectives(lesson),
        "claims_evaluated" => length(source_claims(plan, block_grounded_v3?)),
        "unsupported_claims" => unsupported_claims
      }
    }
  end

  defp source_claims(plan, v3?) do
    content = content(plan)

    objective_claims =
      content
      |> Map.get("learning_objectives", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&%{kind: "learning_objective", text: &1})

    narrative_claims =
      case content["narrative"] do
        narrative when is_binary(narrative) ->
          if String.trim(narrative) == "",
            do: [],
            else: [%{kind: "narrative", text: narrative}]

        _ ->
          []
      end

    opening_claims =
      [
        {"opening_hook", content["opening_hook"]},
        {"why_this_matters", content["why_this_matters"]}
      ]
      |> Enum.flat_map(fn
        {kind, text} when is_binary(text) ->
          if String.trim(text) == "", do: [], else: [%{kind: kind, text: text}]

        _ ->
          []
      end)

    question_claims =
      questions(plan)
      |> Enum.flat_map(fn
        %{"prompt" => prompt} = question when is_binary(prompt) ->
          claim_with_evidence("question", prompt, question)

        _ ->
          []
      end)

    instructional_claims =
      instructional_sections(content)
      |> Enum.flat_map(fn section ->
        explanation_claims =
          case section["explanation"] do
            explanation when is_binary(explanation) ->
              claim_with_evidence("instructional_section", explanation, section)

            _ ->
              []
          end

        example_claims =
          section
          |> Map.get("examples", [])
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.flat_map(&claim_with_evidence("instructional_example", &1, section))

        explanation_claims ++ example_claims
      end)

    worked_example_claims =
      worked_examples(content)
      |> Enum.flat_map(fn example ->
        [example["scenario"], example["conclusion"] | List.wrap(example["steps"])]
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(&claim_with_evidence("worked_example", &1, example))
      end)

    takeaway_claims =
      key_takeaways(content)
      |> Enum.map(&%{kind: "key_takeaway", text: &1})

    callout_claims =
      content
      |> content_list("callouts")
      |> Enum.flat_map(fn callout ->
        [callout["title"], callout["body"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(&claim_with_evidence("callout", &1, callout))
      end)

    curiosity_claims =
      content
      |> content_list("curiosity_prompts")
      |> Enum.flat_map(fn prompt ->
        claim_with_evidence("curiosity_prompt", prompt["prompt"] || prompt["text"], prompt)
      end)

    application_claims =
      content
      |> content_list("application_problems")
      |> Enum.flat_map(fn problem ->
        [problem["prompt"], problem["guidance"], problem["answer_outline"]]
        |> Enum.flat_map(&claim_with_evidence("application_problem", &1, problem))
      end)

    advanced_screen_claims =
      content
      |> advanced_blueprint_screens()
      |> Enum.flat_map(&advanced_screen_claims/1)

    v3_claims =
      if v3? do
        opening_claims ++ curiosity_claims ++ application_claims ++ advanced_screen_claims
      else
        []
      end

    objective_claims ++
      narrative_claims ++
      instructional_claims ++
      worked_example_claims ++
      callout_claims ++
      v3_claims ++
      takeaway_claims ++ question_claims
  end

  defp evidence_source_tokens(claim, source_blocks_by_id, fallback_tokens) do
    evidence_ids = Map.get(claim, :evidence_block_ids, [])

    case evidence_ids do
      [] ->
        fallback_tokens

      ids ->
        ids
        |> Enum.flat_map(fn id ->
          case source_blocks_by_id[id] do
            %{"text" => text} when is_binary(text) -> [text]
            _ -> []
          end
        end)
        |> Enum.map(&substantive_tokens/1)
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    end
  end

  defp claim_with_evidence(kind, text, item) when is_binary(text) and is_map(item) do
    if String.trim(text) == "" do
      []
    else
      [
        %{
          kind: kind,
          text: text,
          evidence_block_ids: normalize_block_ids(item)
        }
      ]
    end
  end

  defp claim_with_evidence(_kind, _text, _item), do: []

  defp advanced_screen_claims(screen) do
    direct_claims =
      [
        screen["prompt"],
        screen["correct_feedback"],
        screen["incorrect_feedback"],
        screen["remediation"]
      ]
      |> Enum.flat_map(&claim_with_evidence("advanced_screen", &1, screen))

    choice_claims =
      screen
      |> advanced_screen_choices()
      |> Enum.flat_map(fn choice ->
        [choice["text"], choice["feedback"]]
        |> Enum.flat_map(&claim_with_evidence("advanced_screen", &1, screen))
      end)

    direct_claims ++ choice_claims
  end

  defp unsupported_claim(text, kind, source_tokens, strict?) do
    claim_tokens = substantive_tokens(text)
    overlap = MapSet.intersection(claim_tokens, source_tokens)

    unsupported_terms =
      MapSet.difference(claim_tokens, source_tokens) |> MapSet.to_list() |> Enum.sort()

    minimum_overlap =
      if strict?,
        do: min(MapSet.size(claim_tokens), 2),
        else: 1

    if MapSet.size(claim_tokens) >= 2 and MapSet.size(overlap) < minimum_overlap and
         length(unsupported_terms) >= 2 do
      [%{kind: kind, text: truncate_claim(text), unsupported_terms: unsupported_terms}]
    else
      []
    end
  end

  defp source_tokens(lesson) do
    block_text = lesson |> source_blocks() |> Enum.map(& &1["text"])

    [
      lesson_value(lesson, :title),
      lesson_value(lesson, :source_excerpt)
      | source_objectives(lesson) ++ block_text
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&substantive_tokens/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp source_objectives(lesson) do
    lesson_value(lesson, :source_objectives)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp lesson_value(lesson, key) do
    Map.get(lesson, key) || Map.get(lesson, Atom.to_string(key))
  end

  defp substantive_tokens(value) when is_binary(value) do
    value
    |> String.downcase()
    |> then(&Regex.scan(~r/[[:alpha:]][[:alpha:]'-]*/, &1))
    |> List.flatten()
    |> Enum.map(&String.trim(&1, "'-"))
    |> Enum.filter(&(String.length(&1) >= 4 and not MapSet.member?(@grounding_stop_words, &1)))
    |> MapSet.new()
  end

  defp substantive_tokens(_), do: MapSet.new()

  defp humanize_claim_kind("learning_objective"), do: "Learning objective"
  defp humanize_claim_kind("narrative"), do: "Narrative"
  defp humanize_claim_kind("opening_hook"), do: "Opening hook"
  defp humanize_claim_kind("why_this_matters"), do: "Why this matters"
  defp humanize_claim_kind("instructional_section"), do: "Instructional section"
  defp humanize_claim_kind("instructional_example"), do: "Instructional example"
  defp humanize_claim_kind("worked_example"), do: "Worked example"
  defp humanize_claim_kind("callout"), do: "Callout"
  defp humanize_claim_kind("curiosity_prompt"), do: "Curiosity prompt"
  defp humanize_claim_kind("application_problem"), do: "Application problem"
  defp humanize_claim_kind("advanced_screen"), do: "Advanced screen"
  defp humanize_claim_kind("key_takeaway"), do: "Key takeaway"
  defp humanize_claim_kind("question"), do: "Question"
  defp humanize_claim_kind(kind), do: kind

  defp truncate_claim(text), do: String.slice(text, 0, 280)

  defp content(%{"content_payload" => content}) when is_map(content), do: content
  defp content(plan) when is_map(plan), do: plan

  defp questions(%{"questions_payload" => %{"items" => items}}) when is_list(items), do: items
  defp questions(%{"questions" => items}) when is_list(items), do: items
  defp questions(_), do: []

  defp instructional_sections(content) do
    case content["instructional_sections"] do
      sections when is_list(sections) -> Enum.filter(sections, &is_map/1)
      _ -> []
    end
  end

  defp worked_examples(content) do
    case content["worked_examples"] do
      examples when is_list(examples) -> Enum.filter(examples, &is_map/1)
      _ -> []
    end
  end

  defp key_takeaways(content) do
    case content["key_takeaways"] do
      takeaways when is_list(takeaways) -> Enum.filter(takeaways, &present?/1)
      _ -> []
    end
  end

  defp instructional_word_count(content) do
    section_text =
      instructional_sections(content)
      |> Enum.flat_map(fn section ->
        [section["heading"], section["explanation"] | List.wrap(section["examples"])]
      end)

    example_text =
      worked_examples(content)
      |> Enum.flat_map(fn example ->
        [
          example["title"],
          example["scenario"],
          example["conclusion"] | List.wrap(example["steps"])
        ]
      end)

    (section_text ++ example_text)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp normalize_keywords(question) do
    case question["answer_keywords"] do
      keywords when is_list(keywords) -> Enum.filter(keywords, &present?/1)
      _ -> []
    end
  end

  defp content_list(content, key) when is_map(content) do
    case content[key] do
      values when is_list(values) -> Enum.filter(values, &is_map/1)
      _ -> []
    end
  end

  defp rich_source?(lesson), do: source_blocks(lesson) != []

  defp minimum_instructional_words(lesson) do
    if rich_source?(lesson) do
      source_words =
        case lesson_value(lesson, :source_word_count) do
          count when is_integer(count) and count > 0 -> count
          _ -> source_block_word_count(lesson)
        end

      source_words
      |> Kernel.*(0.6)
      |> Float.ceil()
      |> trunc()
      |> max(600)
      |> min(2_400)
    else
      100
    end
  end

  defp source_block_word_count(lesson) do
    lesson
    |> source_blocks()
    |> Enum.map(& &1["text"])
    |> Enum.join(" ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp invalid_question?(%{"type" => "multiple_choice"} = question) do
    choices = List.wrap(question["choices"])
    correct_id = question["correct_choice_id"]

    length(choices) not in 2..6 or
      not present?(correct_id) or
      Enum.count(choices, fn choice ->
        is_map(choice) and
          (choice["correct"] == true or choice["id"] == correct_id)
      end) != 1 or
      Enum.any?(choices, &(not is_map(&1) or not present?(&1["text"])))
  end

  defp invalid_question?(%{"type" => "short_answer"} = question) do
    question["response_kind"] not in [nil, "reflection", "application"] or
      normalize_keywords(question) == []
  end

  defp invalid_question?(_), do: true

  defp objectives_assessed?([], _questions, _rich_source?), do: false

  defp objectives_assessed?(objectives, questions, rich_source?) do
    mapped =
      questions
      |> Enum.flat_map(&List.wrap(&1["objective_ids"]))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    normalized_objectives =
      objectives
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    if rich_source?,
      do: MapSet.subset?(normalized_objectives, mapped),
      else: MapSet.size(mapped) == 0 or MapSet.subset?(normalized_objectives, mapped)
  end

  defp source_objectives_complete?(lesson, content, questions) do
    source_objectives =
      lesson
      |> source_objectives()
      |> normalized_text_set()

    plan_objectives =
      content
      |> Map.get("learning_objectives", [])
      |> normalized_text_set()

    assessed_objectives =
      questions
      |> Enum.flat_map(&List.wrap(&1["objective_ids"]))
      |> normalized_text_set()

    MapSet.subset?(source_objectives, plan_objectives) and
      MapSet.subset?(source_objectives, assessed_objectives)
  end

  defp source_objectives_taught?(lesson, instructional_sections) do
    objective_block_ids =
      lesson
      |> source_blocks()
      |> Enum.filter(&(&1["kind"] in ["objective", "objectives"]))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    instruction_evidence_ids =
      instructional_sections
      |> Enum.flat_map(&normalize_block_ids/1)
      |> MapSet.new()

    if MapSet.size(objective_block_ids) == 0 do
      source_objectives(lesson) == []
    else
      MapSet.subset?(objective_block_ids, instruction_evidence_ids)
    end
  end

  defp normalized_text_set(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn value ->
      value
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp validate_advanced_blueprint(lesson, content) do
    screens = advanced_blueprint_screens(content)
    remediation_paths = advanced_remediation_paths(content)

    section_ids =
      content
      |> instructional_sections()
      |> Enum.map(& &1["id"])
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    screen_ids =
      screens
      |> Enum.map(& &1["id"])
      |> Enum.filter(&present?/1)

    screen_id_set = MapSet.new(screen_ids)
    available_block_ids = MapSet.new(Enum.map(source_blocks(lesson), & &1["id"]))

    []
    |> maybe_add(screens == [], "Add at least one Advanced Author screen")
    |> maybe_add(
      length(screen_ids) != length(screens) or length(screen_ids) != length(Enum.uniq(screen_ids)),
      "Give every Advanced Author screen a stable unique id"
    )
    |> maybe_add(
      not Enum.any?(screens, &meaningful_advanced_interaction?/1),
      "Advanced lessons need a real exploration or decision screen"
    )
    |> Kernel.++(
      screens
      |> Enum.flat_map(&advanced_screen_issues(&1, section_ids, available_block_ids))
    )
    |> Kernel.++(
      advanced_remediation_issues(
        remediation_paths,
        screens,
        screen_id_set,
        section_ids
      )
    )
    |> Enum.uniq()
  end

  defp advanced_screen_issues(screen, section_ids, available_block_ids) do
    screen_id = screen["id"] || "(unnamed)"
    kind = screen["kind"]
    interaction_type = screen["interaction_type"]
    placement_target = screen["placement_after_section_id"]
    remediation_target = screen["remediation_section_id"]
    evidence_ids = normalize_block_ids(screen)

    []
    |> maybe_add(
      kind not in ["content", "exploration", "decision", "check", "reflection"],
      "Advanced screen #{inspect(screen_id)} uses an unsupported kind"
    )
    |> maybe_add(
      kind != "content" and
        interaction_type not in ["multiple_choice", "dropdown", "slider", "number_input", "text"],
      "Advanced screen #{inspect(screen_id)} uses an unsupported interaction type"
    )
    |> maybe_add(
      kind == "content" and
        not present?(screen["body"] || screen["content"] || screen["prompt"]),
      "Advanced content screen #{inspect(screen_id)} needs source-grounded learner content"
    )
    |> maybe_add(
      present?(placement_target) and not MapSet.member?(section_ids, placement_target),
      "Advanced screen #{inspect(screen_id)} points to a missing placement section"
    )
    |> maybe_add(
      present?(remediation_target) and not MapSet.member?(section_ids, remediation_target),
      "Advanced screen #{inspect(screen_id)} points to a missing remediation section"
    )
    |> maybe_add(
      evidence_ids == [] or
        Enum.any?(evidence_ids, &(not MapSet.member?(available_block_ids, &1))),
      "Advanced screen #{inspect(screen_id)} must cite only valid source block ids"
    )
    |> Kernel.++(advanced_interaction_issues(screen, screen_id))
  end

  defp advanced_interaction_issues(
         %{"interaction_type" => interaction_type} = screen,
         screen_id
       )
       when interaction_type in ["multiple_choice", "dropdown"] do
    choices = advanced_screen_choices(screen)

    correct_choice_id =
      screen["correct_choice_id"] ||
        get_in(screen, ["configuration", "correct_choice_id"])

    correct_choices =
      Enum.filter(choices, fn choice ->
        choice["correct"] == true or
          (present?(correct_choice_id) and choice["id"] == correct_choice_id)
      end)

    incorrect_choices =
      Enum.reject(choices, fn choice ->
        choice["correct"] == true or
          (present?(correct_choice_id) and choice["id"] == correct_choice_id)
      end)

    []
    |> maybe_add(
      length(choices) not in 2..6 or Enum.any?(choices, &(not present?(&1["text"]))),
      "Advanced screen #{inspect(screen_id)} needs two to six labeled choices"
    )
    |> maybe_add(
      length(correct_choices) != 1,
      "Advanced screen #{inspect(screen_id)} must identify exactly one correct choice"
    )
    |> maybe_add(
      Enum.any?(incorrect_choices, &(not present?(&1["feedback"]))),
      "Every incorrect choice on Advanced screen #{inspect(screen_id)} needs option-specific feedback"
    )
  end

  defp advanced_interaction_issues(
         %{"interaction_type" => "slider"} = screen,
         screen_id
       ) do
    configuration = screen["configuration"] || %{}
    minimum = numeric_value(configuration["min"] || screen["min"])
    maximum = numeric_value(configuration["max"] || screen["max"])
    step = numeric_value(configuration["step"] || screen["step"])

    correct =
      numeric_value(screen["correct_response"] || configuration["correct"] || screen["correct"])

    []
    |> maybe_add(
      is_nil(minimum) or is_nil(maximum) or maximum <= minimum,
      "Advanced slider #{inspect(screen_id)} needs numeric bounds with min less than max"
    )
    |> maybe_add(
      is_nil(step) or step <= 0,
      "Advanced slider #{inspect(screen_id)} needs a positive step"
    )
    |> maybe_add(
      is_nil(correct) or
        (is_number(minimum) and correct < minimum) or
        (is_number(maximum) and correct > maximum),
      "Advanced slider #{inspect(screen_id)} needs a correct value within its bounds"
    )
    |> maybe_add(
      not targeted_incorrect_feedback?(screen),
      "Advanced slider #{inspect(screen_id)} needs targeted incorrect feedback or remediation"
    )
  end

  defp advanced_interaction_issues(
         %{"interaction_type" => "number_input"} = screen,
         screen_id
       ) do
    configuration = screen["configuration"] || %{}

    correct =
      numeric_value(screen["correct_response"] || configuration["correct"] || screen["correct"])

    []
    |> maybe_add(
      is_nil(correct),
      "Advanced numeric input #{inspect(screen_id)} needs a numeric correct value"
    )
    |> maybe_add(
      not targeted_incorrect_feedback?(screen),
      "Advanced numeric input #{inspect(screen_id)} needs targeted incorrect feedback or remediation"
    )
  end

  defp advanced_interaction_issues(_screen, _screen_id), do: []

  defp advanced_remediation_issues(
         remediation_paths,
         screens,
         screen_ids,
         section_ids
       ) do
    interaction_screen_ids =
      screens
      |> Enum.filter(&meaningful_advanced_interaction?/1)
      |> Enum.map(& &1["id"])
      |> Enum.filter(&present?/1)
      |> MapSet.new()

    valid_path_sources =
      remediation_paths
      |> Enum.flat_map(fn
        %{"from_question_id" => from, "to_section_id" => target}
        when is_binary(from) and is_binary(target) ->
          if MapSet.member?(screen_ids, from) and MapSet.member?(section_ids, target),
            do: [from],
            else: []

        _ ->
          []
      end)
      |> MapSet.new()

    []
    |> maybe_add(
      remediation_paths == [],
      "Add a remediation path from an Advanced interaction to an instructional section"
    )
    |> maybe_add(
      Enum.any?(remediation_paths, fn
        %{"from_question_id" => from, "to_section_id" => target} ->
          not present?(from) or not MapSet.member?(screen_ids, from) or
            not present?(target) or not MapSet.member?(section_ids, target)

        _ ->
          true
      end),
      "Every Advanced remediation path must reference an existing screen and instructional section"
    )
    |> maybe_add(
      MapSet.size(interaction_screen_ids) > 0 and
        MapSet.disjoint?(interaction_screen_ids, valid_path_sources),
      "At least one exploration or decision screen must have a valid remediation path"
    )
  end

  defp advanced_blueprint_screens(content) when is_map(content) do
    content
    |> Map.get("advanced_blueprint", %{})
    |> case do
      %{"screens" => screens} when is_list(screens) -> Enum.filter(screens, &is_map/1)
      _ -> []
    end
  end

  defp advanced_remediation_paths(content) when is_map(content) do
    content
    |> Map.get("advanced_blueprint", %{})
    |> case do
      %{"remediation_paths" => paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  defp advanced_screen_choices(screen) do
    case screen["choices"] || get_in(screen, ["configuration", "choices"]) do
      choices when is_list(choices) -> Enum.filter(choices, &is_map/1)
      _ -> []
    end
  end

  defp targeted_incorrect_feedback?(screen) do
    present?(screen["incorrect_feedback"]) or present?(screen["remediation"])
  end

  defp numeric_value(value) when is_integer(value) or is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric_value(_), do: nil

  defp meaningful_advanced_blueprint?(content) do
    blueprint = content["advanced_blueprint"] || %{}
    screens = List.wrap(blueprint["screens"])
    remediation_paths = List.wrap(blueprint["remediation_paths"])

    Enum.any?(screens, &meaningful_advanced_interaction?/1) and
      Enum.any?(screens, &advanced_interaction_feedback?/1) and
      Enum.any?(remediation_paths, fn
        %{"from_question_id" => from, "to_section_id" => target} ->
          present?(from) and present?(target)

        _ ->
          false
      end)
  end

  defp meaningful_advanced_interaction?(%{
         "kind" => kind,
         "interaction_type" => interaction_type
       })
       when kind in ["exploration", "decision"] and
              interaction_type in ["multiple_choice", "dropdown", "slider", "number_input"] do
    true
  end

  defp meaningful_advanced_interaction?(_), do: false

  defp advanced_interaction_feedback?(%{
         "interaction_type" => interaction_type,
         "choices" => choices
       })
       when interaction_type in ["multiple_choice", "dropdown"] and is_list(choices) do
    Enum.any?(choices, fn
      %{"correct" => true} -> false
      %{"feedback" => feedback} -> present?(feedback)
      _ -> false
    end)
  end

  defp advanced_interaction_feedback?(%{"interaction_type" => interaction_type} = screen)
       when interaction_type in ["slider", "number_input"] do
    present?(screen["incorrect_feedback"] || screen["remediation"])
  end

  defp advanced_interaction_feedback?(_), do: false

  defp validate_v3_media(lesson, selected_media) do
    source_media_by_id =
      lesson
      |> lesson_value(:source_media)
      |> List.wrap()
      |> Enum.reduce(%{}, fn
        %{} = media, acc ->
          case media_value(media, "id") || media_value(media, "source_media_id") do
            id when is_binary(id) and id != "" -> Map.put(acc, id, media)
            _ -> acc
          end

        _, acc ->
          acc
      end)

    unknown_selection? =
      Enum.any?(selected_media, fn media ->
        source_media_id = media["source_media_id"]
        not present?(source_media_id) or not Map.has_key?(source_media_by_id, source_media_id)
      end)

    unapproved_rights? =
      Enum.any?(selected_media, fn media ->
        source_media_id = media["source_media_id"]
        source_media = source_media_by_id[source_media_id]

        media["rights_status"] != "approved" or
          is_nil(source_media) or media_value(source_media, "rights_status") != "approved"
      end)

    []
    |> maybe_add(
      unknown_selection?,
      "Every V3 selected figure must use a source_media_id issued for this lesson"
    )
    |> maybe_add(
      unapproved_rights?,
      "Every V3 selected figure must have approved source rights"
    )
  end

  defp media_value(media, key) when is_map(media) do
    Map.get(media, key) ||
      case key do
        "id" -> Map.get(media, :id)
        "source_media_id" -> Map.get(media, :source_media_id)
        "rights_status" -> Map.get(media, :rights_status)
      end
  end

  defp safe_v3_id?(id) when is_binary(id),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/, id)

  defp safe_v3_id?(_), do: false

  defp invalid_media?(media) when is_map(media) do
    not present?(media["source_media_id"] || media["id"]) or
      not present?(media["alt"]) or
      not present?(media["caption"]) or
      not present?(media["credit"])
  end

  defp invalid_media?(_), do: true

  defp duplicate_ids?(items) do
    ids =
      items
      |> Enum.map(& &1["id"])
      |> Enum.filter(&present?/1)

    length(ids) != length(Enum.uniq(ids)) or length(ids) != length(items)
  end

  defp source_blocks(lesson) do
    lesson_value(lesson, :source_blocks)
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        id = block["id"] || block[:id]
        kind = block["kind"] || block[:kind]
        text = block["text"] || block[:text] || ""

        if present?(id) and present?(kind),
          do: [%{"id" => id, "kind" => kind, "text" => text}],
          else: []

      _ ->
        []
    end)
  end

  defp referenced_block_ids(plan) do
    content = content(plan)

    content_items =
      instructional_sections(content) ++
        worked_examples(content) ++
        content_list(content, "callouts") ++
        content_list(content, "curiosity_prompts") ++
        content_list(content, "application_problems") ++
        content_list(content, "media") ++
        advanced_blueprint_screens(content)

    (content_items ++ questions(plan))
    |> Enum.flat_map(&List.wrap(&1["evidence_block_ids"]))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp excluded_blocks(plan, available_ids) do
    content(plan)
    |> Map.get("coverage_manifest", %{})
    |> Map.get("excluded_blocks", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"id" => id, "reason" => reason}
      when is_binary(id) and is_binary(reason) ->
        if MapSet.member?(available_ids, id) and String.trim(reason) != "",
          do: [%{"id" => id, "reason" => String.trim(reason)}],
          else: []

      _ ->
        []
    end)
  end

  defp major_source_block?(%{"kind" => kind})
       when kind in ["objective", "objectives", "heading", "callout", "figure"],
       do: true

  defp major_source_block?(_), do: false

  defp missing_section_evidence?(plan) do
    plan
    |> content()
    |> instructional_sections()
    |> Enum.any?(&(normalize_block_ids(&1) == []))
  end

  defp missing_question_evidence?(plan) do
    plan
    |> questions()
    |> Enum.any?(&(normalize_block_ids(&1) == []))
  end

  defp missing_v3_learner_evidence?(plan) do
    content = content(plan)

    (content_list(content, "curiosity_prompts") ++
       content_list(content, "application_problems") ++ advanced_blueprint_screens(content))
    |> Enum.any?(&(normalize_block_ids(&1) == []))
  end

  defp normalize_block_ids(item) do
    item
    |> Map.get("evidence_block_ids", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp v3_plan?(plan) do
    case content(plan)["schema_version"] do
      version when is_integer(version) -> version >= 3
      version when is_binary(version) -> version in ["3", "v3"]
      _ -> false
    end
  end

  defp maybe_add(items, true, message), do: [message | items]
  defp maybe_add(items, false, _message), do: items

  defp openstax_link?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "openstax.org", path: "/books/" <> _} -> true
      _ -> false
    end
  end

  defp openstax_link?(_), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
