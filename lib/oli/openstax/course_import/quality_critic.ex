defmodule Oli.OpenStax.CourseImport.QualityCritic do
  @moduledoc """
  Independent current-schema content and activity criticism. A review passes only with an
  explicit approval, confidence of at least 0.90, and no hard blockers.
  """

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    AIUsageLedger,
    AdvancedPlanV7,
    BasicPlanV7,
    CriticResultCache
  }

  @confidence_threshold 0.90
  @max_findings 30
  @allowed_severities ~w(hard_blocker repair advisory)

  @type repair_owner :: :basic_content_architect | :advanced_content_architect

  @spec review_content(map(), map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def review_content(lesson, content, service_config, opts \\ []) do
    review(
      :content,
      %{
        "source_contract" => BasicPlanV7.prompt_contract(lesson),
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
        "source_contract" => BasicPlanV7.prompt_contract(lesson),
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

  @spec review_advanced_content(map(), map(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def review_advanced_content(lesson, content, service_config, opts \\ []) do
    review(
      :advanced_content,
      %{
        "source_contract" => AdvancedPlanV7.prompt_contract(lesson),
        "experience_blueprint" => content["experience_blueprint"],
        "content_groups" => content["content_groups"],
        "coverage_manifest" => content["coverage_manifest"],
        "media" => content["media"]
      },
      service_config,
      opts
    )
  end

  @spec review_advanced_activities(map(), map(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def review_advanced_activities(lesson, content, service_config, opts \\ []) do
    source_contract =
      lesson
      |> AdvancedPlanV7.prompt_contract()
      |> Map.put("review_phase", "realized_activities")
      |> Map.put("allowed_realized_stage_item_kinds", ["content_group", "activity"])
      |> Map.put("activity_slots_are_realized_as_activity_items", true)
      |> Map.put("remediation_target_authority", "approved_activity_slot")

    review(
      :advanced_activities,
      %{
        "source_contract" => source_contract,
        "objective_catalog" => content["objective_catalog"],
        "content_groups" => content["content_groups"],
        "experience_blueprint" => content["experience_blueprint"]
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

  @doc "Classifies actionable findings without asking a model to repair source-owned fields."
  @spec partition_repair_findings(map() | [map()], repair_owner()) ::
          %{
            repairable: [map()],
            source_resolvable: [map()],
            source_advisory: [map()],
            unowned: [map()]
          }
  def partition_repair_findings(review_or_findings, owner)
      when owner in [:basic_content_architect, :advanced_content_architect] do
    findings =
      if is_map(review_or_findings),
        do: repair_findings(review_or_findings),
        else: List.wrap(review_or_findings)

    classified =
      Enum.reduce(
        findings,
        %{repairable: [], source_resolvable: [], source_advisory: [], unowned: []},
        fn finding, acc -> classify_finding(finding, owner, acc) end
      )

    Map.new(classified, fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  @doc "Preserves source-owned critic findings as diagnostics without blocking lesson approval."
  @spec demote_source_owned_findings(map(), [map()]) :: map()
  def demote_source_owned_findings(review, source_findings)
      when is_map(review) and is_list(source_findings) do
    source_fingerprints =
      source_findings
      |> Enum.map(&finding_identity/1)
      |> MapSet.new()

    findings =
      review
      |> Map.get("findings", [])
      |> List.wrap()
      |> Enum.map(fn finding ->
        if MapSet.member?(source_fingerprints, finding_identity(finding)) do
          finding
          |> Map.put("severity", "advisory")
          |> Map.put("source_owned", true)
          |> Map.put("ownership", "source_advisory")
          |> Map.put("blocking", false)
        else
          finding
        end
      end)

    approved =
      numeric(review["confidence"]) >= @confidence_threshold and
        Enum.all?(findings, &(&1["severity"] == "advisory"))

    review
    |> Map.put("approved", approved)
    |> Map.put("gate_passed", approved)
    |> Map.put("findings", findings)
    |> Map.put("hard_blocker_count", Enum.count(findings, &(&1["severity"] == "hard_blocker")))
    |> Map.put("repair_count", Enum.count(findings, &(&1["severity"] == "repair")))
    |> Map.put("advisory_count", Enum.count(findings, &(&1["severity"] == "advisory")))
    |> Map.put("source_diagnostics_accepted", approved)
  end

  def demote_source_owned_findings(review, _source_findings), do: review

  @spec fingerprint(map()) :: String.t()
  def fingerprint(review) do
    review
    |> repair_findings()
    |> fingerprint_findings()
  end

  @spec fingerprint_findings([map()]) :: String.t()
  def fingerprint_findings(findings) do
    findings
    |> List.wrap()
    |> Enum.map(&{&1["severity"], &1["code"], &1["path"]})
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp classify_finding(finding, owner, acc) do
    path = finding |> Map.get("path", "$") |> finding_path()

    cond do
      server_owned_content_path?(path) and finding["severity"] == "advisory" ->
        finding = Map.put(finding, "ownership", "source_advisory")

        acc
        |> Map.update!(:source_advisory, &[finding | &1])
        |> Map.update!(:unowned, &[finding | &1])

      server_owned_content_path?(path) ->
        finding = Map.put(finding, "ownership", "source_resolvable")

        acc
        |> Map.update!(:source_resolvable, &[finding | &1])
        |> Map.update!(:unowned, &[finding | &1])

      phase_owned_content_path?(path, owner) ->
        Map.update!(acc, :unowned, &[finding | &1])

      true ->
        finding = Map.put(finding, "ownership", "model_repairable")
        Map.update!(acc, :repairable, &[finding | &1])
    end
  end

  defp finding_path(path) when is_binary(path), do: String.downcase(path)
  defp finding_path(path) when is_atom(path), do: path |> Atom.to_string() |> String.downcase()
  defp finding_path(_path), do: "$"

  defp finding_identity(finding) when is_map(finding) do
    {
      to_string(finding["code"] || finding[:code] || ""),
      to_string(finding["path"] || finding[:path] || "$"),
      to_string(finding["message"] || finding[:message] || "")
    }
  end

  defp finding_identity(_finding), do: {"", "$", ""}

  defp server_owned_content_path?(path) do
    String.contains?(path, "coverage_manifest") or
      (String.contains?(path, "content_groups") and String.contains?(path, "source_blocks")) or
      String.contains?(path, "content_plan.source_block_ids") or
      String.contains?(path, "objective_catalog") or
      String.contains?(path, "source_evidence_links") or
      String.contains?(path, "attribution") or
      String.contains?(path, "source_id") or
      String.contains?(path, "source_locator") or
      String.contains?(path, "canonical_url") or
      String.contains?(path, "source_section")
  end

  defp phase_owned_content_path?(path, :advanced_content_architect) do
    String.contains?(path, "experience_blueprint.activities") or
      String.contains?(path, "experience_blueprint.duration_manifest") or
      String.contains?(path, "experience_blueprint.estimated_minutes") or
      String.contains?(path, "experience_blueprint.remediation_paths")
  end

  defp phase_owned_content_path?(_path, _owner), do: false

  defp review(kind, payload, service_config, opts) do
    prompt = system_prompt(kind)

    messages = [
      Message.new(:system, prompt),
      Message.new(:user, Jason.encode!(payload))
    ]

    cache_enabled =
      Keyword.get(opts, :critic_cache_enabled, not Keyword.has_key?(opts, :critic_execution_fun))

    cache_key = CriticResultCache.key(kind, payload, prompt, service_config)

    if cache_enabled do
      case CriticResultCache.get(cache_key) do
        {:ok, cached} ->
          {:ok,
           update_in(cached, ["model_usage"], fn usage ->
             Map.merge(usage || %{}, %{"cache_status" => "critic_hit"})
           end)}

        :miss ->
          execute_review(kind, messages, service_config, opts, cache_key, true)
      end
    else
      execute_review(kind, messages, service_config, opts, cache_key, false)
    end
  end

  defp execute_review(kind, messages, service_config, opts, cache_key, cache_enabled) do
    role = String.to_atom("#{kind}_critic")

    request_ctx =
      AIUsageLedger.request_context(opts, role, %{
        candidate_number: Keyword.get(opts, :candidate_number, 1)
      })

    execution_fun = Keyword.get(opts, :critic_execution_fun, &Execution.generate_with_metadata/4)

    result =
      case Function.info(execution_fun, :arity) do
        {:arity, 3} -> execution_fun.(request_ctx, messages, service_config)
        _ -> execution_fun.(request_ctx, messages, [], service_config)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, decoded} <- Jason.decode(strip_code_fence(raw)),
         {:ok, review} <- normalize_review(decoded, metadata) do
      if cache_enabled, do: CriticResultCache.put(cache_key, review)
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
          "The candidate does not satisfy the v7 quality contract."
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
    If the supplied source AST itself appears malformed or internally inconsistent,
    report the exact source_blocks path as an advisory source-quality diagnostic;
    never classify a server-owned source defect as a hard_blocker or repair, and never
    instruct the content architect to edit a hydrated source node.

    Evaluate only the canonical v7 fields supplied in content_plan. Compatibility
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

  defp system_prompt(:advanced_content) do
    """
    You are the independent Sol experience critic for an OpenStax schema 7
    Advanced Exploration. The deterministic source contract and hydrated source
    groups are authoritative. Review complete source disposition, the driving
    investigation, stage coherence, evidence and figure placement, accessibility,
    objective alignment, and whether the source honestly supports 45–75 minutes of
    substantive learner work. Generic padding, invented evidence, missing source,
    duplicate group references, prerequisite violations, inaccessible required
    media, or a merely decorative investigation are hard_blocker findings. Repairable
    ordering, transition, pacing, or activity-slot placement issues are repair.
    Hydrated source_blocks, the coverage manifest, source attribution, and the
    objective catalog are deterministic server-owned fields. If one appears defective,
    report its exact path as an advisory source-quality diagnostic and do not ask the
    experience architect to rewrite it. A server-owned source defect must never be a
    hard_blocker or repair finding for the generated experience.

    This review happens before the separate activity-writing stage. At this point,
    experience_blueprint.activity_slots describe the approved learner work and
    experience_blueprint.activities is intentionally empty. Do not require instantiated
    activities, score the exploration down because they are not present yet, or infer
    a duration defect from their absence. The duration manifest, estimated minutes,
    instantiated activities, and remediation paths are deterministic or later-stage
    fields and are not repair work for the experience architect.

    Return JSON only: {"approved": boolean, "confidence": 0.0..1.0,
    "summary": string, "findings": [{"severity":"hard_blocker|repair|advisory",
    "code":string,"path":string,"message":string}]}. Never approve with a hard
    blocker, a repair finding, or confidence below 0.90.
    """
  end

  defp system_prompt(:advanced_activities) do
    """
    You are the independent Sol activity critic for an OpenStax schema 7 Advanced
    Exploration. Review every activity for correctness, source answerability,
    meaningful context, exactly one correct response where scorable, a default
    incorrect response, misconception-specific feedback, Not sure support, useful
    hints, deterministic response-model compatibility, objective alignment, and
    remediation alignment with the approved slot's exact existing content group.
    Reject duplicate, generic, context-free, future-content, or prerequisite-violating
    work. An incorrect or unanswerable response contract is a hard_blocker; weak
    feedback or remediation is repair. Models do not author Torus rule JSON, URLs,
    storage keys, or navigation ids.

    This is the post-attachment review phase. The deterministic server has replaced
    every architecture-stage activity_slot item with a realized stage item whose kind
    is "activity" and whose ref_id points to experience_blueprint.activities. That is
    the correct final schema; do not require activity_slot items or flag "activity" as
    an invalid item kind.

    The approved activity slot owns remediation_content_group_id. The deterministic
    compiler copies that value to the realized activity and remediation path. Require
    those declarations to agree. For an integrated synthesis that intentionally cites
    several content groups, treat the approved target as the most useful single
    remediation starting point. Do not require one target group to contain every cited
    concept and do not ask the activity writer to regroup content or edit the slot.

    A short_answer or reflection response contract with scoring="completion" and
    semantic_evaluation="author_review" is intentionally unscored. It does not need an
    automatically checkable semantic rubric or must_contain terms. Review its prompt,
    evidence, feedback, and learning value, but do not reject it for lacking automated
    semantic grading.

    Return JSON only: {"approved": boolean, "confidence": 0.0..1.0,
    "summary": string, "findings": [{"severity":"hard_blocker|repair|advisory",
    "code":string,"path":string,"message":string}]}. Never approve with a hard
    blocker, a repair finding, or confidence below 0.90.
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
