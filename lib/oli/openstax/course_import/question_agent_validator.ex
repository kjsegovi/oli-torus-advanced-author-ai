defmodule Oli.OpenStax.CourseImport.QuestionAgentValidator do
  @moduledoc """
  Deterministically validates a complete Basic lesson question batch.

  The validator is intentionally independent of the model. It is used by both
  question-agent tools so submission can never bypass the review contract.
  """

  @max_findings 20
  @max_reported_objective_ids 24
  @generic_feedback [
    "try again",
    "incorrect",
    "review the lesson",
    "review the material",
    "not quite"
  ]
  @template_prompts [
    ~r/^many students wonder\b/i,
    ~r/^start here\b/i,
    ~r/^what changes when you use the ideas\b/i
  ]

  @type validation :: %{
          required(:valid) => boolean(),
          required(:findings) => [map()],
          required(:questions_payload) => map(),
          required(:candidate_hash) => String.t()
        }

  @spec validate(map(), map()) :: validation()
  def validate(candidate, context) when is_map(candidate) and is_map(context) do
    questions = candidate_questions(candidate)
    count_rationale = present_string(candidate["count_rationale"] || candidate[:count_rationale])
    content = context[:content_payload] || context["content_payload"] || %{}
    lesson = context[:lesson] || context["lesson"] || %{}
    content_group_ids = content |> Map.get("content_groups", []) |> ids("id")

    slot_group_ids =
      content
      |> Map.get("question_slots", [])
      |> Enum.map(
        &(&1["placement_after_group_id"] || &1[:placement_after_group_id] ||
            &1["placement_after_section_id"] || &1[:placement_after_section_id])
      )
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    allowed_group_ids =
      if MapSet.size(slot_group_ids) > 0, do: slot_group_ids, else: content_group_ids

    current_objective_catalog = objective_catalog(content)
    prior_objective_catalog = prior_objective_catalog(context)
    objective_catalog = current_objective_catalog ++ prior_objective_catalog
    objective_lookup = Map.new(objective_catalog, &{&1["id"], &1["text"]})
    objective_ids = objective_lookup |> Map.keys() |> MapSet.new()

    evidence_ids =
      lesson
      |> source_blocks()
      |> recursive_ids()
      |> Kernel.++(Enum.flat_map(prior_objective_catalog, & &1["evidence_block_ids"]))
      |> MapSet.new()

    source_links = source_links(lesson)

    {normalized, item_findings} =
      questions
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {question, index}, findings ->
        {normalized_question, question_findings} =
          validate_question(
            question,
            index,
            allowed_group_ids,
            objective_ids,
            objective_lookup,
            evidence_ids,
            source_links
          )

        {normalized_question, findings ++ question_findings}
      end)

    slot_count = MapSet.size(slot_group_ids)
    allowed_question_count = if slot_count > 0, do: min(slot_count, 10), else: 10

    findings =
      []
      |> add_unless(
        length(questions) in 1..allowed_question_count,
        "invalid_question_count",
        question_count_message(slot_count, allowed_question_count)
      )
      |> add_unless(
        count_rationale != nil,
        "missing_count_rationale",
        "Explain why this number of questions fits the objectives and lesson density."
      )
      |> Kernel.++(item_findings)
      |> Kernel.++(duplicate_prompt_findings(normalized))
      |> Kernel.++(duplicate_placement_findings(normalized, slot_count))
      |> Enum.take(@max_findings)

    payload = %{"items" => normalized}

    %{
      valid: findings == [],
      findings: findings,
      questions_payload: payload,
      count_rationale: count_rationale,
      candidate_hash: candidate_hash(candidate)
    }
  end

  def validate(_candidate, _context) do
    %{
      valid: false,
      findings: [finding("invalid_candidate", "Submit a question batch object.")],
      questions_payload: %{"items" => []},
      count_rationale: nil,
      candidate_hash: candidate_hash(%{})
    }
  end

  @doc false
  @spec objective_catalog(map()) :: [map()]
  def objective_catalog(content) when is_map(content) do
    case Map.get(content, "objective_catalog") || Map.get(content, :objective_catalog) do
      catalog when is_list(catalog) and catalog != [] ->
        catalog
        |> Enum.flat_map(fn
          entry when is_map(entry) ->
            id = present_string(entry["id"] || entry[:id])
            text = present_string(entry["text"] || entry[:text])

            if id && text,
              do: [%{"id" => id, "text" => text}],
              else: []

          _ ->
            []
        end)

      _ ->
        content
        |> then(&(Map.get(&1, "learning_objectives") || Map.get(&1, :learning_objectives) || []))
        |> normalize_strings()
        |> Enum.with_index(1)
        |> Enum.map(fn {text, index} -> %{"id" => "objective-#{index}", "text" => text} end)
    end
  end

  def objective_catalog(_content), do: []

  defp prior_objective_catalog(context) do
    context
    |> then(
      &(Map.get(&1, :approved_prior_objective_ledger) ||
          Map.get(&1, "approved_prior_objective_ledger") || [])
    )
    |> List.wrap()
    |> Enum.flat_map(fn
      entry when is_map(entry) ->
        id = present_string(entry["id"] || entry[:id])
        text = present_string(entry["text"] || entry[:text])
        evidence = normalize_strings(entry["evidence_block_ids"] || entry[:evidence_block_ids])

        if id && text,
          do: [%{"id" => id, "text" => text, "evidence_block_ids" => evidence}],
          else: []

      _ ->
        []
    end)
  end

  @spec candidate_hash(map()) :: String.t()
  def candidate_hash(candidate) do
    candidate
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_question(
         question,
         index,
         content_group_ids,
         objective_ids,
         objective_lookup,
         evidence_ids,
         source_links
       )
       when is_map(question) do
    prompt = present_string(question["prompt"] || question[:prompt])
    type = question["type"] || question[:type]
    placement = question["placement_after_section_id"] || question[:placement_after_section_id]

    mapped_objective_ids =
      normalize_strings(question["objective_ids"] || question[:objective_ids])

    resolved_objectives =
      mapped_objective_ids
      |> Enum.flat_map(fn objective_id ->
        case Map.fetch(objective_lookup, objective_id) do
          {:ok, objective_text} -> [objective_text]
          :error -> []
        end
      end)
      |> Enum.uniq()

    mapped_evidence =
      normalize_strings(question["evidence_block_ids"] || question[:evidence_block_ids])

    normalized =
      question
      |> stringify_keys()
      |> Map.put("id", "q#{index}")
      |> Map.put("prompt", prompt || "")
      |> Map.put("placement_after_section_id", placement)
      |> Map.put("objective_ids", mapped_objective_ids)
      |> Map.put("mapped_objectives", resolved_objectives)
      |> Map.put("evidence_block_ids", mapped_evidence)
      |> Map.put("source_evidence_links", source_links)

    findings =
      []
      |> add_unless(
        prompt != nil and String.length(prompt) >= 20,
        "weak_prompt",
        "Question #{index} needs a substantive learner-facing prompt."
      )
      |> add_unless(
        prompt != nil and not Enum.any?(@template_prompts, &Regex.match?(&1, prompt)),
        "template_prompt",
        "Question #{index} uses a generic prompt template."
      )
      |> add_unless(
        MapSet.member?(content_group_ids, placement),
        "invalid_content_group_placement",
        "Question #{index} must follow an approved content group."
      )
      |> add_unless(
        mapped_objective_ids != [] and subset?(mapped_objective_ids, objective_ids),
        "invalid_objective_mapping",
        "Question #{index} must use only IDs copied from objective_catalog.",
        %{
          "allowed_objective_ids" =>
            objective_ids
            |> MapSet.to_list()
            |> Enum.sort()
            |> Enum.take(@max_reported_objective_ids)
        }
      )
      |> add_unless(
        mapped_evidence != [] and subset?(mapped_evidence, evidence_ids),
        "invalid_evidence",
        "Question #{index} must cite server-issued source evidence ids."
      )

    case type do
      "multiple_choice" ->
        validate_multiple_choice(normalized, index, findings)

      "short_answer" ->
        validate_short_answer(normalized, index, findings)

      _ ->
        {normalized,
         findings ++
           [
             finding(
               "invalid_question_type",
               "Question #{index} must be multiple choice or short answer."
             )
           ]}
    end
  end

  defp validate_question(
         _question,
         index,
         _content_group_ids,
         _objective_ids,
         _objective_lookup,
         _evidence_ids,
         _links
       ) do
    {%{"id" => "q#{index}"},
     [finding("invalid_question", "Question #{index} must be an object.")]}
  end

  defp validate_multiple_choice(question, index, findings) do
    raw_choices = List.wrap(question["choices"])
    valid_choice_objects? = Enum.all?(raw_choices, &is_map/1)

    choices =
      Enum.map(raw_choices, fn
        %{} = choice -> stringify_keys(choice)
        _invalid -> %{}
      end)

    choice_texts = Enum.map(choices, &present_string(&1["text"]))
    correct = Enum.count(choices, &(&1["correct"] == true))
    incorrect = Enum.reject(choices, &(&1["correct"] == true))

    findings =
      findings
      |> add_unless(
        length(choices) in 2..6,
        "invalid_choice_count",
        "Question #{index} needs 2 to 6 choices."
      )
      |> add_unless(
        valid_choice_objects? and Enum.all?(choice_texts, &(&1 != nil)) and
          Enum.uniq(Enum.map(choice_texts, &normalize_text/1)) ==
            Enum.map(choice_texts, &normalize_text/1),
        "invalid_choices",
        "Question #{index} choices must be non-empty and distinct."
      )
      |> add_unless(
        correct == 1,
        "ambiguous_answer",
        "Question #{index} must have exactly one correct choice."
      )
      |> add_unless(
        Enum.all?(incorrect, &targeted_feedback?/1),
        "untargeted_feedback",
        "Question #{index} needs misconception-specific feedback for every distractor."
      )

    correct_choice = Enum.find(choices, &(&1["correct"] == true))

    normalized =
      question
      |> Map.put("type", "multiple_choice")
      |> Map.put("choices", normalize_choices(choices, index))
      |> Map.put("correct_choice_id", correct_choice_id(correct_choice, choices, index))

    {normalized, findings}
  end

  defp validate_short_answer(question, index, findings) do
    response_kind = question["response_kind"]
    answer_guidance = present_string(question["answer_guidance"])
    answer_keywords = normalize_strings(question["answer_keywords"])

    findings =
      findings
      |> add_unless(
        response_kind in ["reflection", "application"],
        "invalid_short_answer_contract",
        "Question #{index} short answer must be a reflection or application."
      )
      |> add_unless(
        answer_guidance != nil and answer_keywords != [],
        "missing_answer_guidance",
        "Question #{index} needs answer guidance and answer keywords."
      )

    normalized =
      question
      |> Map.put("type", "short_answer")
      |> Map.put("response_kind", response_kind)
      |> Map.put("answer_guidance", answer_guidance)
      |> Map.put("answer_keywords", answer_keywords)

    {normalized, findings}
  end

  defp duplicate_prompt_findings(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {left, left_index} ->
      questions
      |> Enum.drop(left_index)
      |> Enum.with_index(left_index + 1)
      |> Enum.flat_map(fn {right, right_index} ->
        if materially_duplicate?(left["prompt"], right["prompt"]) do
          [
            finding(
              "duplicate_questions",
              "Questions #{left_index} and #{right_index} materially duplicate one another."
            )
          ]
        else
          []
        end
      end)
    end)
  end

  defp duplicate_placement_findings(_questions, 0), do: []

  defp duplicate_placement_findings(questions, _slot_count) do
    questions
    |> Enum.group_by(& &1["placement_after_section_id"])
    |> Enum.flat_map(fn
      {placement, items} when is_binary(placement) and length(items) > 1 ->
        [
          finding(
            "duplicate_question_boundary",
            "Use at most one consolidated question at checkpoint #{placement}."
          )
        ]

      _ ->
        []
    end)
  end

  defp materially_duplicate?(left, right) do
    left_tokens = token_set(left)
    right_tokens = token_set(right)
    union = MapSet.union(left_tokens, right_tokens)

    MapSet.size(union) > 0 and
      MapSet.size(MapSet.intersection(left_tokens, right_tokens)) / MapSet.size(union) >= 0.8
  end

  defp question_count_message(0, _allowed),
    do: "Choose between 1 and 10 questions."

  defp question_count_message(_slot_count, 1),
    do: "Create one high-value question for the approved checkpoint slot."

  defp question_count_message(_slot_count, allowed),
    do:
      "Create no more than one high-value question per approved checkpoint slot (maximum #{allowed})."

  defp normalize_choices(choices, question_index) do
    choices
    |> Enum.with_index(1)
    |> Enum.map(fn {choice, choice_index} ->
      choice
      |> stringify_keys()
      |> Map.put("id", "q#{question_index}-choice-#{choice_index}")
      |> Map.put("text", present_string(choice["text"]) || "")
      |> Map.put("correct", choice["correct"] == true)
    end)
  end

  defp correct_choice_id(nil, _choices, _question_index), do: nil

  defp correct_choice_id(correct, choices, question_index) do
    choice_index = Enum.find_index(choices, &(&1 == correct)) || 0
    "q#{question_index}-choice-#{choice_index + 1}"
  end

  defp targeted_feedback?(choice) do
    case present_string(choice["feedback"]) do
      nil ->
        false

      feedback ->
        normalized = normalize_text(feedback)
        String.length(feedback) >= 12 and normalized not in @generic_feedback
    end
  end

  defp candidate_questions(candidate) do
    case candidate["questions_payload"] || candidate[:questions_payload] || candidate do
      %{"items" => items} when is_list(items) -> items
      %{items: items} when is_list(items) -> items
      %{"questions" => items} when is_list(items) -> items
      _ -> []
    end
  end

  defp source_blocks(lesson) do
    lesson["source_blocks"] || lesson[:source_blocks] || lesson["blocks"] || lesson[:blocks] || []
  end

  defp recursive_ids(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        List.wrap(block["id"] || block[:id]) ++
          recursive_ids(block["blocks"] || block[:blocks]) ++
          recursive_ids(block["children"] || block[:children]) ++
          recursive_ids(block["items"] || block[:items])

      _ ->
        []
    end)
    |> Enum.filter(&is_binary/1)
  end

  defp source_links(lesson) do
    lesson["source_evidence_links"] || lesson[:source_evidence_links] ||
      lesson["source_sections"] || lesson[:source_sections] || []
  end

  defp ids(values, key) do
    values
    |> List.wrap()
    |> Enum.map(&(&1[key] || &1[String.to_atom(key)]))
    |> string_set()
  end

  defp string_set(values), do: values |> normalize_strings() |> MapSet.new()

  defp normalize_strings(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      case present_string(value) do
        nil -> []
        string -> [string]
      end
    end)
    |> Enum.uniq()
  end

  defp subset?(values, allowed), do: MapSet.subset?(MapSet.new(values), allowed)

  defp token_set(value) do
    value
    |> to_string()
    |> normalize_text()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp present_string(_value), do: nil

  defp add_unless(findings, true, _code, _message), do: findings
  defp add_unless(findings, false, code, message), do: findings ++ [finding(code, message)]

  defp add_unless(findings, true, _code, _message, _details), do: findings

  defp add_unless(findings, false, code, message, details),
    do: findings ++ [Map.merge(finding(code, message), details)]

  defp finding(code, message), do: %{"code" => code, "message" => message}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort()
    |> Map.new()
  end

  defp canonicalize(values) when is_list(values), do: Enum.map(values, &canonicalize/1)
  defp canonicalize(value), do: value
end
