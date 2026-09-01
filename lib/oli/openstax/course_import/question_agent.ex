defmodule Oli.OpenStax.CourseImport.QuestionAgent do
  @moduledoc """
  Runs the bounded, Basic-only OpenStax question-generation agent.
  """

  alias Oli.GenAI.Agent
  alias Oli.GenAI.Agent.Persistence

  alias Oli.OpenStax.CourseImport.{
    AIPricing,
    AIUsageLedger,
    QuestionAgentPolicy,
    QuestionAgentToolBroker,
    QuestionAgentValidator
  }

  @deadline_seconds 600

  @spec generate(map(), map(), struct(), keyword()) ::
          {:ok, %{questions_payload: map(), generation_metadata: map()}} | {:error, term()}
  def generate(lesson, content_payload, service_config, opts \\ [])

  def generate(lesson, content_payload, service_config, opts)
      when is_map(lesson) and is_map(content_payload) do
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())
    start_fun = Keyword.get(opts, :agent_start_fun, &Agent.start_run/1)
    await_fun = Keyword.get(opts, :agent_await_fun, &Agent.await_result/2)

    # The caller may scope :run_id per lesson/attempt to keep the agent-run id
    # unique (agent_runs primary key / Registry), while still tracking ledger
    # usage under the parent import run via :import_run_id.
    ledger_opts =
      case Keyword.fetch(opts, :import_run_id) do
        {:ok, import_id} -> Keyword.put(opts, :run_id, import_id)
        :error -> opts
      end

    args =
      %{
        run_id: run_id,
        run_type: "openstax_basic_questions",
        goal:
          "Create the smallest high-value set of source-grounded formative questions for this Basic lesson.",
        plan: [
          "Choose 1 to 10 questions based on objectives and instructional density",
          "Validate and submit the complete candidate set in one tool call",
          "Repair every deterministic finding before the next validation call"
        ],
        service_config: service_config,
        policy: QuestionAgentPolicy,
        tool_broker: QuestionAgentToolBroker,
        tool_context: %{
          lesson_id: lesson["id"] || lesson[:id],
          lesson: lesson,
          content_payload: content_payload,
          approved_prior_objective_ledger: Keyword.get(opts, :objective_ledger, [])
        },
        system_instructions: system_instructions(),
        initial_messages: [
          %{role: :user, content: candidate_context(lesson, content_payload, opts)}
        ],
        context_summary:
          "The private tool context contains the complete lesson evidence. Never reproduce raw source in tool output.",
        budgets: %{
          max_steps: 4,
          max_tokens: 40_000,
          max_cost_cents: 300,
          deadline_at: DateTime.add(DateTime.utc_now(), @deadline_seconds, :second)
        },
        metadata: %{
          feature: "openstax_basic_questions",
          lesson_id: lesson["id"] || lesson[:id],
          max_tokens_per_step: 10_000
        },
        author_id: Keyword.get(opts, :author_id),
        project_id: Keyword.get(opts, :project_id),
        request_context_factory: fn step ->
          AIUsageLedger.request_context(ledger_opts, :basic_question_writer, %{
            candidate_number: step,
            operation_id: run_id
          })
        end,
        max_provider_retries: 1
      }
      |> maybe_put(:llm_bridge, Keyword.get(opts, :llm_bridge))

    with {:ok, _pid} <- start_fun.(args),
         {:ok, result} <- await_fun.(run_id, @deadline_seconds * 1_000 + 5_000),
         :ok <- ensure_completed(result),
         {:ok, draft} <- accepted_draft(run_id) do
      steps = Persistence.get_steps(run_id)
      payload = draft.patch["questions_payload"] || draft.patch[:questions_payload]
      metadata = generation_metadata(result, draft, steps, service_config)

      {:ok,
       %{
         questions_payload: payload,
         generation_metadata: metadata
       }}
    else
      {:error, reason} -> {:error, classify_failure(reason, run_id)}
      other -> {:error, {:question_agent_failed, other}}
    end
  end

  def generate(_lesson, _content_payload, _service_config, _opts),
    do: {:error, :invalid_question_agent_context}

  defp ensure_completed(%{status: "completed"}), do: :ok
  defp ensure_completed(%{terminal_status: :completed}), do: :ok
  defp ensure_completed(result), do: {:error, {:terminal_failure, result}}

  defp accepted_draft(run_id) do
    case Enum.find(Persistence.list_drafts(run_id), &(&1.status == :accepted)) do
      nil -> {:error, :accepted_question_draft_missing}
      draft -> {:ok, draft}
    end
  end

  defp generation_metadata(result, draft, steps, service_config) do
    validation_attempts = count_tool_steps(steps, "validate_and_submit_openstax_questions")

    model = result.metadata[:model] || result.metadata["model"]
    provider = result.metadata[:provider] || result.metadata["provider"]

    service_tier =
      case service_config do
        %{primary_model: %{service_tier: tier}} when is_binary(tier) -> tier
        _ -> "default"
      end

    usage = %{
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      cached_input_tokens: 0
    }

    %{
      "run_id" => result.run_id,
      "chosen_count_rationale" => draft.metadata["count_rationale"],
      "question_count" => draft.metadata["question_count"],
      "attempts" => %{
        "validations" => validation_attempts
      },
      "token_usage" => %{
        "input" => result.input_tokens,
        "output" => result.output_tokens,
        "total" => result.tokens_used,
        "cached_input" => 0,
        "reasoning" => 0
      },
      "estimated_cost_microdollars" =>
        AIPricing.estimate_microdollars(model, service_tier, usage),
      "pricing_version" => AIPricing.pricing_version(),
      "provider" => provider,
      "model" => model,
      "service_tier" => service_tier,
      "cache_status" => "unknown",
      "terminal_status" => to_string(result.terminal_status)
    }
  end

  defp count_tool_steps(steps, name) do
    Enum.count(steps, fn step ->
      step.action["type"] == "tool" and step.action["name"] == name
    end)
  end

  defp classify_failure(
         {:terminal_failure, %{terminal_status: :provider_failure} = result},
         _run_id
       ),
       do: {:provider_failure, safe_provider_failure(result)}

  defp classify_failure({:terminal_failure, result}, _run_id),
    do: {:terminal_question_agent_failure, result.terminal_status, result.reason}

  defp classify_failure(:await_timeout, _run_id), do: {:retryable_provider_failure, :timeout}
  defp classify_failure(reason, run_id), do: {:question_agent_failed, run_id, reason}

  defp safe_provider_failure(result) do
    result.metadata[:provider_failure] || result.metadata["provider_failure"] ||
      provider_failure_from_reason(result.reason)
  end

  defp provider_failure_from_reason(reason) when is_binary(reason) do
    case Regex.run(~r/(?:status_code|status):\s*(\d{3})/, reason, capture: :all_but_first) do
      [status] -> %{"status_code" => String.to_integer(status), "category" => "parsed_reason"}
      _ -> %{"category" => "unknown"}
    end
  end

  defp provider_failure_from_reason(_reason), do: %{"category" => "unknown"}

  defp candidate_context(lesson, content_payload, opts) do
    content_groups =
      content_payload
      |> Map.get("content_groups", [])
      |> Enum.map(fn group ->
        Map.take(group, [
          "id",
          "title",
          "instructional_purpose",
          "source_block_ids"
        ])
      end)

    evidence_catalog =
      lesson
      |> Map.get("source_blocks", [])
      |> flatten_blocks()
      |> Enum.map(&Map.take(&1, ["id", "kind", "heading_path", "title"]))

    Jason.encode!(%{
      "title" => content_payload["title"] || lesson["title"],
      "objective_catalog" => QuestionAgentValidator.objective_catalog(content_payload),
      "content_groups" => content_groups,
      "synthesis" => content_payload["synthesis"],
      "question_slots" =>
        Keyword.get(opts, :question_slots, content_payload["question_slots"] || []),
      "approved_prior_objective_ledger" => Keyword.get(opts, :objective_ledger, []),
      "previous_questions_payload" => Keyword.get(opts, :previous_questions_payload),
      "critic_findings" => Keyword.get(opts, :critic_findings, []),
      "regeneration_context" =>
        prompt_repair_context(lesson["repair_context"] || lesson[:repair_context]),
      "evidence_catalog" => evidence_catalog
    })
  end

  defp flatten_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        [block] ++
          flatten_blocks(block["blocks"] || block[:blocks]) ++
          flatten_blocks(block["children"] || block[:children]) ++
          flatten_blocks(block["items"] || block[:items])

      _ ->
        []
    end)
  end

  defp prompt_repair_context(context) when is_map(context),
    do:
      Map.drop(context, [
        "previous_candidates",
        :previous_candidates,
        "critic_findings",
        :critic_findings,
        "phase_findings",
        :phase_findings
      ])

  defp prompt_repair_context(_context), do: nil

  defp system_instructions do
    """
    You generate questions only for the supplied finalized Basic lesson. Quality is
    more important than speed. Create no more than one question for each supplied
    question slot, and omit any slot that would add interruption without meaningful
    learning value. One question may cover several related objective IDs; do not make
    one question per objective. Explain the chosen count only in count_rationale.

    Use only validate_and_submit_openstax_questions. Submit the entire proposed set
    in one call. A valid set is persisted atomically; an invalid set returns bounded
    findings that must all be repaired before the next call.

    Mix multiple-choice and short-answer only when each format serves the learning
    goal. Prompts must be distinct and source-grounded. Multiple-choice items need one
    correct answer, plausible distractors, and feedback targeted to each misconception.
    Short-answer items must be reflection or application prompts and include concise
    answer_guidance plus answer_keywords. Copy objective_catalog[].id exactly into each
    question's objective_ids. Never put objective text, evidence IDs, or block IDs in
    objective_ids. Use only supplied content-group, objective, media, and evidence identifiers.
    For short answers, answer_keywords are a compact author-review aid, not a complete
    semantic rubric and not an exhaustive synonym list. Put every substantive acceptance
    criterion and relationship in the prompt and answer_guidance. Presentation suggestions
    such as a response length or creative format must either appear in the prompt or be
    explicitly described as ungraded guidance; do not let them change correctness.
    Keep the prompt, answer guidance, answer keywords, correct feedback, incorrect
    feedback, hint, and remediation on one consistent acceptance contract. Every
    observation offered as evidence must directly support the specific claim it is
    attached to; contextual or same-lesson observations are not interchangeable with
    causal evidence. Do not introduce optional alternative evidence during repair unless
    it supports the same claim and every grading and feedback field accepts it. When
    critic findings are supplied, make the smallest complete correction and re-check all
    related fields so repairing one finding cannot contradict another field.
    If regeneration_context is present, resolve its applicable author feedback and
    generated-question findings in the new complete question set. Source-owned
    diagnostics describe authoritative textbook input and are not question-writing
    tasks.
    For v7, place questions only in supplied question_slots. Recall questions may use
    only approved_prior_objective_ledger entries; never infer a prerequisite from future
    or unapproved lessons. If previous_questions_payload and critic_findings are present,
    repair that complete set and disposition every finding before review.
    Do not repeat or lightly rephrase a nearby source example, application, another
    question, or the synthesis. Prefer no question over a low-value generic check.
    Never call or request a general authoring mutation tool.
    """
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
