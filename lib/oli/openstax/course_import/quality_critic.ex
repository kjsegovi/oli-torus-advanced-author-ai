defmodule Oli.OpenStax.CourseImport.QualityCritic do
  @moduledoc """
  Independent v5 content and question criticism. A review passes only with an
  explicit approval, confidence of at least 0.90, and no hard blockers.
  """

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution
  alias Oli.OpenStax.CourseImport.BasicPlanV5

  @feature :openstax_course_import
  @confidence_threshold 0.90
  @max_findings 30
  @allowed_severities ~w(hard_blocker repair advisory)

  @spec review_content(map(), map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def review_content(lesson, content, service_config, opts \\ []) do
    review(
      :content,
      %{
        "source_contract" => BasicPlanV5.prompt_contract(lesson),
        "content_plan" => critic_content_plan(content)
      },
      service_config,
      opts
    )
  end

  @spec review_questions(map(), map(), map(), [map()], struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def review_questions(lesson, content, questions, objective_ledger, service_config, opts \\ []) do
    review(
      :questions,
      %{
        "source_contract" => BasicPlanV5.prompt_contract(lesson),
        "content_plan" =>
          Map.take(
            content,
            ~w(title learning_objectives objective_catalog content_groups question_slots)
          ),
        "questions_payload" => questions,
        "approved_prior_objective_ledger" => objective_ledger
      },
      service_config,
      opts
    )
  end

  @spec approved?(map()) :: boolean()
  def approved?(review) when is_map(review) do
    review["approved"] == true and numeric(review["confidence"]) >= @confidence_threshold and
      hard_blockers(review) == [] and repair_findings(review) == []
  end

  def approved?(_review), do: false

  @spec hard_blockers(map()) :: [map()]
  def hard_blockers(review) when is_map(review),
    do: Enum.filter(List.wrap(review["findings"]), &(&1["severity"] == "hard_blocker"))

  def hard_blockers(_review), do: []

  @spec repair_findings(map()) :: [map()]
  def repair_findings(review) when is_map(review) do
    Enum.filter(List.wrap(review["findings"]), &(&1["severity"] in ["hard_blocker", "repair"]))
  end

  def repair_findings(_review), do: []

  @spec fingerprint(map()) :: String.t()
  def fingerprint(review) do
    review
    |> repair_findings()
    |> Enum.map(&{&1["severity"], &1["code"], &1["path"]})
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp review(kind, payload, service_config, opts) do
    messages = [
      Message.new(:system, system_prompt(kind)),
      Message.new(:user, Jason.encode!(payload))
    ]

    request_ctx = %{
      request_type: :generate,
      feature: @feature,
      phase: String.to_atom("#{kind}_critic")
    }

    execution_fun = Keyword.get(opts, :critic_execution_fun, &Execution.generate_with_metadata/4)

    result =
      case Function.info(execution_fun, :arity) do
        {:arity, 3} -> execution_fun.(request_ctx, messages, service_config)
        _ -> execution_fun.(request_ctx, messages, [], service_config)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, decoded} <- Jason.decode(strip_code_fence(raw)),
         {:ok, review} <- normalize_review(decoded, metadata) do
      {:ok, review}
    else
      {:error, reason} -> {:error, {:critic_failed, kind, reason}}
      other -> {:error, {:critic_failed, kind, {:invalid_response, other}}}
    end
  end

  defp normalize_review(decoded, metadata) when is_map(decoded) do
    raw_findings =
      decoded
      |> Map.get("findings", [])
      |> List.wrap()
      |> Enum.take(@max_findings)
      |> Enum.map(&normalize_finding/1)

    confidence = numeric(decoded["confidence"])
    explicit_approval = decoded["approved"] == true

    findings =
      raw_findings
      |> ensure_actionable_gate_findings(explicit_approval, confidence)
      |> Enum.take(@max_findings)

    review = %{
      "approved" => explicit_approval,
      "confidence" => confidence,
      "threshold" => @confidence_threshold,
      "findings" => findings,
      "summary" => present(decoded["summary"]) || "Independent quality review completed.",
      "model_usage" => stringify_metadata(metadata),
      "hard_blocker_count" => Enum.count(findings, &(&1["severity"] == "hard_blocker")),
      "repair_count" => Enum.count(findings, &(&1["severity"] == "repair")),
      "advisory_count" => Enum.count(findings, &(&1["severity"] == "advisory"))
    }

    {:ok, Map.put(review, "gate_passed", approved?(review))}
  end

  defp normalize_review(_decoded, _metadata), do: {:error, :invalid_review_object}

  defp critic_content_plan(content) do
    Map.take(
      content,
      ~w(schema_version authoring_mode title orientation learning_objectives objective_catalog content_groups question_slots media synthesis coverage_manifest)
    )
  end

  defp ensure_actionable_gate_findings(findings, explicit_approval, confidence) do
    actionable? = Enum.any?(findings, &(&1["severity"] in ["hard_blocker", "repair"]))

    findings =
      if confidence < @confidence_threshold and not actionable? do
        [
          %{
            "severity" => "repair",
            "code" => "critic_low_confidence",
            "path" => "$",
            "message" =>
              "The critic could not approve this candidate at the required confidence threshold."
          }
          | findings
        ]
      else
        findings
      end

    actionable? = Enum.any?(findings, &(&1["severity"] in ["hard_blocker", "repair"]))

    if explicit_approval or actionable? do
      findings
    else
      [
        %{
          "severity" => "repair",
          "code" => "critic_not_approved",
          "path" => "$",
          "message" => "The critic withheld approval without supplying an actionable finding."
        }
        | findings
      ]
    end
  end

  defp normalize_finding(finding) when is_map(finding) do
    severity = to_string(finding["severity"] || finding[:severity] || "hard_blocker")

    %{
      "severity" => if(severity in @allowed_severities, do: severity, else: "hard_blocker"),
      "code" => to_string(finding["code"] || finding[:code] || "unspecified_finding"),
      "path" => to_string(finding["path"] || finding[:path] || "$"),
      "message" =>
        present(finding["message"] || finding[:message]) ||
          "The candidate does not satisfy the v5 quality contract."
    }
  end

  defp normalize_finding(_finding) do
    %{
      "severity" => "hard_blocker",
      "code" => "invalid_critic_finding",
      "path" => "$",
      "message" => "The critic returned a malformed finding."
    }
  end

  defp system_prompt(:content) do
    """
    You are the independent Sol content critic for an OpenStax Basic lesson. The
    deterministic source contract is authoritative. Review accuracy, completeness,
    ordering, figure adjacency, captions, equations, tables, alt text, instructional
    coherence, and whether transitions add minimal value without replacing source
    content. Missing substantive blocks, contradictions, invalid media/equations,
    unsafe content, or schema failures are hard_blocker findings. Repairable ordering,
    transition, duplication, alt-text, checkpoint, or presentation issues are repair.
    Purely optional style improvements are advisory.

    The source contract, source attribution, source URLs, and license metadata are
    deterministic server-owned inputs, not content-architect fields. Do not ask the
    architect to rewrite them or issue findings based on external guesses about a
    book's license. Review only whether learner content preserves the supplied source
    and attribution consistently; the server validates source licensing separately.

    Evaluate only the canonical v5 fields supplied in content_plan. Compatibility
    fields used by legacy readers are intentionally absent and do not render twice.
    A source heading block marked rendering=lesson_title is already represented by the
    lesson title and is intentionally suppressed inside its content group. Source
    blocks render in array order, including figure AST nodes at their exact source
    position; media placement_after_section_id is a group lookup key, not an instruction
    to move the figure after the whole group. For mathematical accuracy, inspect formula
    nodes in the AST. A source block's plain text is only a search preview and may flatten
    visual notation.

    Reject fragmented plans made of thin or generic cards. Brief examples, definitions,
    observations, and explanatory paragraphs belong in the surrounding reading flow.
    A standalone example or application must be grounded in a genuine source example,
    exercise, problem, or concepts-in-practice callout and must provide enough setup,
    reasoning, and interpretation to help the learner. Require consolidation when
    adjacent groups teach the same idea, and flag generic numbered headings or content
    that duplicates a question, example, application, or synthesis.

    Return JSON only: {"approved": boolean, "confidence": 0.0..1.0,
    "summary": string, "findings": [{"severity":"hard_blocker|repair|advisory",
    "code":string,"path":string,"message":string}]}. Approve only when every source
    block has a correct disposition and there are zero hard blockers. Never approve
    with confidence below 0.90.
    """
  end

  defp system_prompt(:questions) do
    """
    You are the independent Sol question critic for an OpenStax Basic lesson. Review
    every question for factual correctness, alignment, answerability from cited
    evidence, exactly correct answers, plausible distractors, targeted feedback,
    useful Not sure support, remediation placement, and recall prerequisites. Recall
    may use only the supplied approved prior-objective ledger. Any future or unapproved
    prerequisite, incorrect answer, unanswerable prompt, contradiction, or unsafe item
    is a hard_blocker. Imprecise feedback or weak placement is repair. Optional style
    refinement is advisory.

    Treat the prompt, answer guidance, answer keywords, choices, correct feedback,
    incorrect feedback, hint, and remediation as one grading contract. They must agree
    on what evidence is required and what answers are accepted. Evidence must directly
    support the particular claim for which it is offered; being true elsewhere in the
    same lesson is insufficient. Flag repair regressions that fix one field while making
    another field contradictory or factually overbroad.

    In a Basic short-answer item, answer_keywords are compact author-review metadata,
    not an automated semantic rubric, an all-terms-must-match rule, or an exhaustive
    synonym list. Judge substantive relationships from the prompt, answer_guidance, and
    feedback; do not require relation-aware structures that are absent from the supplied
    schema. Treat harmless presentation differences such as a suggested sentence count
    or creative title as advisory at most unless they change which substantive answers
    are considered correct.

    For a multiple-choice item with allow_not_sure=true, the hint is the targeted
    feedback shown when the learner chooses Not sure. Do not require a separate
    not_sure_feedback field; it is not part of the Basic question schema.

    There is no question quota and not every objective needs a separate question. Use
    at most one high-value question per approved slot; one question may align to several
    related objectives. Flag repeated prompts, questions that merely restate a nearby
    worked example or application, and low-value checkpoints that interrupt reading.

    Return JSON only: {"approved": boolean, "confidence": 0.0..1.0,
    "summary": string, "findings": [{"severity":"hard_blocker|repair|advisory",
    "code":string,"path":string,"message":string}]}. Never approve with a hard
    blocker or confidence below 0.90.
    """
  end

  defp stringify_metadata(metadata) when is_map(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp stringify_metadata(_metadata), do: %{}

  defp numeric(value) when is_integer(value), do: value / 1
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      _ -> 0.0
    end
  end

  defp numeric(_value), do: 0.0

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil

  defp strip_code_fence(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
  end
end
