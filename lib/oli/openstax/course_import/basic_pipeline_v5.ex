defmodule Oli.OpenStax.CourseImport.BasicPipelineV5 do
  @moduledoc """
  Resumable v5 Basic lesson workflow: architect, independent content critic,
  architect repair, question writer, independent question critic, and writer
  repair. Each specialist receives one initial candidate and at most three
  repair rounds. Valid but unapproved semantic candidates are preserved for
  author review instead of being reported as crashed lesson jobs.
  """

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    BasicPlanV5,
    QualityCritic,
    QuestionAgent
  }

  @feature :openstax_course_import
  @max_repair_rounds 3
  @max_candidates @max_repair_rounds + 1

  @spec plan(map(), pos_integer(), map(), keyword()) ::
          {:ok, %{content_payload: map(), questions_payload: map(), metadata: map()}}
          | {:error, term()}
  def plan(lesson, index, services, opts)
      when is_map(lesson) and is_integer(index) and index > 0 and is_map(services) do
    checkpoint = normalized_checkpoint(Keyword.get(opts, :generation_checkpoint, %{}))

    with {:ok, content_result} <- content_stage(lesson, index, services, checkpoint, opts) do
      if needs_attention?(content_result) do
        question_result = skipped_question_result()

        with :ok <-
               checkpoint(
                 opts,
                 "quality_attention",
                 Map.merge(content_result, question_result)
               ) do
          {:ok, pipeline_result(content_result, question_result, services)}
        end
      else
        with :ok <- checkpoint_content_approval(opts, checkpoint, content_result),
             {:ok, question_result} <-
               question_stage(lesson, content_result, services, checkpoint, opts),
             :ok <-
               checkpoint(
                 opts,
                 if(needs_attention?(question_result),
                   do: "quality_attention",
                   else: "questions_approved"
                 ),
                 Map.merge(content_result, question_result)
               ) do
          {:ok, pipeline_result(content_result, question_result, services)}
        end
      end
    end
  end

  def plan(_lesson, _index, _services, _opts), do: {:error, :invalid_v5_pipeline_context}

  defp content_stage(lesson, index, services, checkpoint, opts) do
    cond do
      checkpoint.stage in [
        "content_approved",
        "question_repair_pending",
        "questions_approved",
        "quality_attention",
        "completed"
      ] and is_map(checkpoint.payload["content_payload"]) ->
        {:ok,
         %{
           content_payload: checkpoint.payload["content_payload"],
           content_reviews: List.wrap(checkpoint.payload["content_reviews"]),
           content_attempts: List.wrap(checkpoint.payload["content_attempts"]),
           resumed_from_checkpoint: true,
           needs_attention: content_attention?(checkpoint.payload["attention_reason"]),
           attention_reason: checkpoint.payload["attention_reason"]
         }}

      checkpoint.stage == "content_repair_pending" and
          is_map(checkpoint.payload["repair_candidate"]) ->
        architect_loop(
          lesson,
          index,
          services,
          opts,
          checkpoint.payload["next_attempt"] || 2,
          %{
            candidate: checkpoint.payload["repair_candidate"],
            findings: List.wrap(checkpoint.payload["repair_findings"])
          },
          List.wrap(checkpoint.payload["content_attempts"]),
          List.wrap(checkpoint.payload["content_reviews"]),
          checkpoint.payload["previous_fingerprint"],
          true
        )

      true ->
        architect_loop(lesson, index, services, opts, 1, nil, [], [], nil, false)
    end
  end

  defp architect_loop(
         lesson,
         index,
         services,
         opts,
         attempt,
         repair_context,
         attempts,
         reviews,
         previous_fingerprint,
         resumed_from_checkpoint
       ) do
    with {:ok, candidate, usage} <-
           architect_candidate(lesson, index, services.architect, repair_context, opts) do
      architect_attempt = %{"attempt" => attempt, "model_usage" => stringify(usage)}

      case BasicPlanV5.build(candidate, lesson, index) do
        {:ok, content} ->
          with {:ok, review} <- content_critic(lesson, content, services.critic, opts) do
            attempts = attempts ++ [architect_attempt]
            reviews = reviews ++ [Map.put(review, "attempt", attempt)]

            cond do
              QualityCritic.approved?(review) ->
                {:ok,
                 %{
                   content_payload: content,
                   content_reviews: reviews,
                   content_attempts: attempts,
                   resumed_from_checkpoint: resumed_from_checkpoint
                 }}

              true ->
                with :ok <-
                       checkpoint(opts, "content_repair_pending", %{
                         content_attempts: attempts,
                         content_reviews: reviews,
                         repair_candidate: candidate,
                         repair_findings: QualityCritic.repair_findings(review),
                         previous_fingerprint: QualityCritic.fingerprint(review),
                         next_attempt: attempt + 1
                       }) do
                  cond do
                    attempt >= @max_candidates ->
                      {:ok,
                       attention_content_result(
                         content,
                         attempts,
                         reviews,
                         resumed_from_checkpoint,
                         :content_quality_exhausted
                       )}

                    QualityCritic.fingerprint(review) == previous_fingerprint ->
                      {:ok,
                       attention_content_result(
                         content,
                         attempts,
                         reviews,
                         resumed_from_checkpoint,
                         :content_quality_stalled
                       )}

                    true ->
                      architect_loop(
                        lesson,
                        index,
                        services,
                        opts,
                        attempt + 1,
                        %{candidate: candidate, findings: QualityCritic.repair_findings(review)},
                        attempts,
                        reviews,
                        QualityCritic.fingerprint(review),
                        resumed_from_checkpoint
                      )
                  end
                end
            end
          end

        {:error, deterministic_findings} ->
          review = deterministic_review(deterministic_findings)
          attempts = attempts ++ [architect_attempt]
          reviews = reviews ++ [Map.put(review, "attempt", attempt)]

          cond do
            true ->
              with :ok <-
                     checkpoint(opts, "content_repair_pending", %{
                       content_attempts: attempts,
                       content_reviews: reviews,
                       repair_candidate: candidate,
                       repair_findings: deterministic_findings,
                       previous_fingerprint: QualityCritic.fingerprint(review),
                       next_attempt: attempt + 1
                     }) do
                cond do
                  attempt >= @max_candidates ->
                    {:error,
                     {:content_quality_exhausted, quality_failure(attempt, review, reviews)}}

                  QualityCritic.fingerprint(review) == previous_fingerprint ->
                    {:error,
                     {:content_quality_stalled, quality_failure(attempt, review, reviews)}}

                  true ->
                    architect_loop(
                      lesson,
                      index,
                      services,
                      opts,
                      attempt + 1,
                      %{candidate: candidate, findings: deterministic_findings},
                      attempts,
                      reviews,
                      QualityCritic.fingerprint(review),
                      resumed_from_checkpoint
                    )
                end
              end
          end
      end
    end
  end

  defp question_stage(lesson, content_result, services, checkpoint, opts) do
    cond do
      checkpoint.stage in ["questions_approved", "quality_attention", "completed"] and
          is_map(checkpoint.payload["questions_payload"]) ->
        {:ok,
         %{
           questions_payload: checkpoint.payload["questions_payload"],
           question_reviews: List.wrap(checkpoint.payload["question_reviews"]),
           question_attempts: List.wrap(checkpoint.payload["question_attempts"]),
           writer_metadata: checkpoint.payload["writer_metadata"] || %{},
           resumed_from_checkpoint: true,
           content_payload: content_result.content_payload,
           needs_attention: question_attention?(checkpoint.payload["attention_reason"]),
           attention_reason: checkpoint.payload["attention_reason"]
         }}

      checkpoint.stage == "question_repair_pending" and
          is_map(checkpoint.payload["questions_payload"]) ->
        question_loop(
          lesson,
          content_result.content_payload,
          services,
          Keyword.put(opts, :content_checkpoint_state, content_result),
          checkpoint.payload["next_attempt"] || 2,
          %{
            questions_payload: checkpoint.payload["questions_payload"],
            findings: List.wrap(checkpoint.payload["repair_findings"])
          },
          List.wrap(checkpoint.payload["question_attempts"]),
          List.wrap(checkpoint.payload["question_reviews"]),
          checkpoint.payload["previous_fingerprint"],
          true
        )

      content_result.content_payload["question_slots"] == [] ->
        review = %{
          "approved" => true,
          "gate_passed" => true,
          "confidence" => 1.0,
          "threshold" => 0.9,
          "findings" => [],
          "hard_blocker_count" => 0,
          "repair_count" => 0,
          "advisory_count" => 0,
          "summary" =>
            "The architect identified no genuine conceptual boundary requiring a checkpoint.",
          "model_usage" => %{"strategy" => "no_question_slots"},
          "attempt" => 0
        }

        {:ok,
         %{
           questions_payload: %{"items" => []},
           question_reviews: [review],
           question_attempts: [],
           writer_metadata: %{"strategy" => "no_question_slots"},
           resumed_from_checkpoint: false
         }}

      true ->
        question_loop(
          lesson,
          content_result.content_payload,
          services,
          Keyword.put(opts, :content_checkpoint_state, content_result),
          1,
          nil,
          [],
          [],
          nil,
          false
        )
    end
  end

  defp question_loop(
         lesson,
         content,
         services,
         opts,
         attempt,
         repair_context,
         attempts,
         reviews,
         previous_fingerprint,
         resumed_from_checkpoint
       ) do
    writer_fun = Keyword.get(opts, :question_agent_fun, &QuestionAgent.generate/4)
    objective_ledger = List.wrap(Keyword.get(opts, :objective_ledger, []))

    writer_opts =
      opts
      |> Keyword.take([:author_id, :project_id, :llm_bridge, :agent_start_fun, :agent_await_fun])
      |> Keyword.put(:objective_ledger, objective_ledger)
      |> Keyword.put(:question_slots, content["question_slots"])
      |> maybe_put_repair_context(repair_context)

    with {:ok, result} <- writer_fun.(lesson, content, services.question_writer, writer_opts),
         {:ok, review} <-
           question_critic(
             lesson,
             content,
             result.questions_payload,
             objective_ledger,
             services.question_critic,
             opts
           ) do
      attempts =
        attempts ++
          [
            %{
              "attempt" => attempt,
              "model_usage" => result.generation_metadata
            }
          ]

      reviews = reviews ++ [Map.put(review, "attempt", attempt)]

      cond do
        QualityCritic.approved?(review) ->
          {:ok,
           %{
             questions_payload: result.questions_payload,
             question_reviews: reviews,
             question_attempts: attempts,
             writer_metadata: result.generation_metadata,
             resumed_from_checkpoint: resumed_from_checkpoint
           }}

        true ->
          content_state = Keyword.get(opts, :content_checkpoint_state, %{})

          with :ok <-
                 checkpoint(opts, "question_repair_pending", %{
                   content_payload: content,
                   content_reviews: content_state[:content_reviews] || [],
                   content_attempts: content_state[:content_attempts] || [],
                   questions_payload: result.questions_payload,
                   question_attempts: attempts,
                   question_reviews: reviews,
                   writer_metadata: result.generation_metadata,
                   repair_findings: QualityCritic.repair_findings(review),
                   previous_fingerprint: QualityCritic.fingerprint(review),
                   next_attempt: attempt + 1
                 }) do
            cond do
              attempt >= @max_candidates ->
                {:ok,
                 attention_question_result(
                   result,
                   attempts,
                   reviews,
                   resumed_from_checkpoint,
                   :question_quality_exhausted
                 )}

              QualityCritic.fingerprint(review) == previous_fingerprint ->
                {:ok,
                 attention_question_result(
                   result,
                   attempts,
                   reviews,
                   resumed_from_checkpoint,
                   :question_quality_stalled
                 )}

              true ->
                question_loop(
                  lesson,
                  content,
                  services,
                  opts,
                  attempt + 1,
                  %{
                    questions_payload: result.questions_payload,
                    findings: QualityCritic.repair_findings(review)
                  },
                  attempts,
                  reviews,
                  QualityCritic.fingerprint(review),
                  resumed_from_checkpoint
                )
            end
          end
      end
    end
  end

  defp architect_candidate(lesson, index, service_config, repair_context, opts) do
    messages = [
      Message.new(:system, architect_system_prompt()),
      Message.new(:user, Jason.encode!(BasicPlanV5.prompt_contract(lesson)))
    ]

    messages =
      case repair_context do
        %{candidate: candidate, findings: findings} ->
          messages ++
            [
              Message.new(:assistant, Jason.encode!(candidate)),
              Message.new(
                :user,
                Jason.encode!(%{
                  "required_action" =>
                    "Repair every critic finding and return the complete v5 organization object.",
                  "critic_findings" => findings
                })
              )
            ]

        _ ->
          messages
      end

    request_ctx = %{
      request_type: :generate,
      feature: @feature,
      phase: :v5_content_architect,
      lesson_index: index
    }

    execution_fun =
      Keyword.get(opts, :v5_architect_execution_fun, &Execution.generate_with_metadata/4)

    result =
      case Function.info(execution_fun, :arity) do
        {:arity, 3} -> execution_fun.(request_ctx, messages, service_config)
        _ -> execution_fun.(request_ctx, messages, [], service_config)
      end

    with {:ok, %{content: content, metadata: metadata}} <- result,
         {:ok, decoded} <- Jason.decode(strip_code_fence(content)),
         true <- is_map(decoded) do
      {:ok, decoded, metadata || %{}}
    else
      false -> {:error, :invalid_v5_architect_response}
      {:error, reason} -> {:error, {:v5_architect_failed, reason}}
      other -> {:error, {:v5_architect_failed, {:invalid_response, other}}}
    end
  end

  defp content_critic(lesson, content, service_config, opts) do
    critic_fun = Keyword.get(opts, :content_critic_fun, &QualityCritic.review_content/4)
    critic_fun.(lesson, content, service_config, critic_opts(opts))
  end

  defp question_critic(lesson, content, questions, ledger, service_config, opts) do
    critic_fun = Keyword.get(opts, :question_critic_fun, &QualityCritic.review_questions/6)
    critic_fun.(lesson, content, questions, ledger, service_config, critic_opts(opts))
  end

  defp critic_opts(opts) do
    opts
    |> Keyword.take([:critic_execution_fun])
  end

  defp checkpoint(opts, stage, payload) do
    case Keyword.get(opts, :checkpoint_fun) do
      fun when is_function(fun, 2) ->
        checkpoint_payload = %{
          "content_payload" => payload[:content_payload],
          "content_reviews" => payload[:content_reviews] || [],
          "content_attempts" => payload[:content_attempts] || [],
          "questions_payload" => payload[:questions_payload],
          "question_reviews" => payload[:question_reviews] || [],
          "question_attempts" => payload[:question_attempts] || [],
          "writer_metadata" => payload[:writer_metadata] || %{},
          "needs_attention" => payload[:needs_attention] == true,
          "attention_reason" => payload[:attention_reason],
          "repair_candidate" => payload[:repair_candidate],
          "repair_findings" => payload[:repair_findings] || [],
          "previous_fingerprint" => payload[:previous_fingerprint],
          "next_attempt" => payload[:next_attempt]
        }

        case fun.(stage, checkpoint_payload) do
          :ok -> :ok
          {:ok, _checkpoint} -> :ok
          {:error, reason} -> {:error, {:generation_checkpoint_failed, stage, reason}}
          other -> {:error, {:generation_checkpoint_failed, stage, other}}
        end

      _ ->
        :ok
    end
  end

  defp checkpoint_content_approval(_opts, %{stage: stage}, _content_result)
       when stage in [
              "question_repair_pending",
              "questions_approved",
              "quality_attention",
              "completed"
            ],
       do: :ok

  defp checkpoint_content_approval(opts, _checkpoint, content_result),
    do: checkpoint(opts, "content_approved", content_result)

  defp quality_metadata(content_result, question_result, services) do
    content_review = List.last(content_result.content_reviews || []) || %{}
    question_review = List.last(question_result.question_reviews || []) || %{}

    attention_reason =
      Map.get(content_result, :attention_reason) || Map.get(question_result, :attention_reason)

    findings = List.wrap(content_review["findings"]) ++ List.wrap(question_review["findings"])

    %{
      "pipeline" => "openstax_basic_v5",
      "quality_gate" => %{
        "approved" =>
          QualityCritic.approved?(content_review) and QualityCritic.approved?(question_review),
        "confidence" =>
          min(content_review["confidence"] || 0.0, question_review["confidence"] || 0.0),
        "threshold" => 0.9,
        "attention_reason" => attention_reason,
        "hard_blockers" => Enum.filter(findings, &(&1["severity"] == "hard_blocker")),
        "repairs" => Enum.filter(findings, &(&1["severity"] == "repair")),
        "advisories" => Enum.filter(findings, &(&1["severity"] == "advisory")),
        "content_critic" => content_review,
        "question_critic" => question_review
      },
      "content_reviews" => content_result.content_reviews,
      "question_reviews" => question_result.question_reviews,
      "repair_history" => %{
        "content" => content_result.content_attempts,
        "questions" => question_result.question_attempts
      },
      "roles" => %{
        "content_architect" => service_identity(services.architect),
        "content_critic" => service_identity(services.critic),
        "question_writer" => service_identity(services.question_writer),
        "question_critic" => service_identity(services.question_critic)
      },
      "resume" => %{
        "content" => content_result.resumed_from_checkpoint,
        "questions" => question_result.resumed_from_checkpoint
      }
    }
    |> put_quality_outcome()
  end

  defp pipeline_result(content_result, question_result, services) do
    %{
      content_payload: content_result.content_payload,
      questions_payload: question_result.questions_payload,
      metadata: quality_metadata(content_result, question_result, services)
    }
  end

  defp attention_content_result(
         content,
         attempts,
         reviews,
         resumed_from_checkpoint,
         reason
       ) do
    %{
      content_payload: content,
      content_reviews: reviews,
      content_attempts: attempts,
      resumed_from_checkpoint: resumed_from_checkpoint,
      needs_attention: true,
      attention_reason: Atom.to_string(reason)
    }
  end

  defp attention_question_result(
         result,
         attempts,
         reviews,
         resumed_from_checkpoint,
         reason
       ) do
    %{
      questions_payload: result.questions_payload,
      question_reviews: reviews,
      question_attempts: attempts,
      writer_metadata: result.generation_metadata,
      resumed_from_checkpoint: resumed_from_checkpoint,
      needs_attention: true,
      attention_reason: Atom.to_string(reason)
    }
  end

  defp skipped_question_result do
    review = %{
      "approved" => true,
      "gate_passed" => true,
      "confidence" => 1.0,
      "threshold" => 0.9,
      "findings" => [],
      "hard_blocker_count" => 0,
      "repair_count" => 0,
      "advisory_count" => 0,
      "summary" =>
        "Question generation was deferred until the content critic findings are resolved.",
      "model_usage" => %{"strategy" => "deferred_for_content_attention"},
      "attempt" => 0
    }

    %{
      questions_payload: %{"items" => []},
      question_reviews: [review],
      question_attempts: [],
      writer_metadata: %{"strategy" => "deferred_for_content_attention"},
      resumed_from_checkpoint: false
    }
  end

  defp needs_attention?(result), do: Map.get(result, :needs_attention, false) == true

  defp content_attention?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "content_quality_")

  defp content_attention?(_reason), do: false

  defp question_attention?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "question_quality_")

  defp question_attention?(_reason), do: false

  defp put_quality_outcome(metadata) do
    approved = get_in(metadata, ["quality_gate", "approved"]) == true

    put_in(
      metadata,
      ["quality_gate", "outcome"],
      if(approved, do: "approved", else: "needs_attention")
    )
  end

  defp normalized_checkpoint(checkpoint) when is_map(checkpoint) do
    %{
      stage: checkpoint["stage"] || checkpoint[:stage],
      payload: checkpoint["payload"] || checkpoint[:payload] || %{}
    }
  end

  defp normalized_checkpoint(_checkpoint), do: %{stage: nil, payload: %{}}

  defp deterministic_review(findings) do
    %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.0,
      "threshold" => 0.9,
      "findings" => findings,
      "hard_blocker_count" => length(findings),
      "repair_count" => 0,
      "advisory_count" => 0,
      "summary" => "The deterministic source-fidelity contract rejected this candidate.",
      "model_usage" => %{"strategy" => "deterministic_contract"}
    }
  end

  defp quality_failure(attempt, review, history) do
    %{
      "attempts" => attempt,
      "confidence" => review["confidence"],
      "findings" => QualityCritic.repair_findings(review),
      "review_history" => history
    }
  end

  defp service_identity(%{primary_model: model}) when is_map(model) do
    %{
      "provider" => model.provider,
      "model" => model.model,
      "service" => model.name
    }
  end

  defp service_identity(_service), do: %{}

  defp maybe_put_repair_context(opts, nil), do: opts

  defp maybe_put_repair_context(opts, context) do
    opts
    |> Keyword.put(:previous_questions_payload, context.questions_payload)
    |> Keyword.put(:critic_findings, context.findings)
  end

  defp stringify(metadata) when is_map(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_metadata), do: %{}

  defp strip_code_fence(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
  end

  defp architect_system_prompt do
    """
    You are the Terra content architect for a source-faithful OpenStax Basic page.
    Organize every supplied source_block id exactly once. Never summarize, paraphrase,
    delete, duplicate, or invent source content; the server will hydrate your IDs with
    the deterministic AST. Choose a readable REAL CHEM-style rhythm with descriptive
    content group headings, instructional purposes, minimal transitions, adjacent
    media, and question slots only at genuine objective or conceptual boundaries.
    Preserve source order unless a specific pedagogical dependency justifies a change.
    Draft contextual alt text only for media whose source alt is missing.

    Use instructional_purpose exactly as one of: orientation, reading, concept,
    evidence, example, application, synthesis, reference. Use objective_ids only
    from objective_catalog, never the objective text. Use recommended_types only
    from: multiple_choice, short_answer. These literal values are a strict server
    contract. The source_contract supplies the exact allowed values and IDs.

    A source heading marked rendering=lesson_title is already represented by the lesson
    title. Assign it with the related opening source blocks instead of isolating it in a
    title-only group; the compiler preserves its disposition without rendering it twice.

    Consolidate adjacent source blocks that teach the same idea into a comfortable
    reading group. Do not turn a paragraph, observation, definition, or brief example
    sentence into a standalone card. Use example or application purpose only when the
    group contains a genuine source example, exercise, problem, or concepts-in-practice
    callout with enough context to stand alone. Otherwise keep it in the normal reading
    flow. Never use generic titles such as Worked Example 1, Core Concept 2, or Apply
    what you learned 3. Prefer one strong checkpoint at a boundary; a single question
    slot may cover multiple related objective IDs. Avoid slots that would repeat an
    example, application, or another checkpoint.

    Return JSON only with: title; orientation {overview}; content_groups [{id,title,
    instructional_purpose,transition,source_block_ids}]; question_slots [{id,purpose,
    placement_after_group_id,objective_ids,evidence_block_ids,recommended_types}];
    generated_alt_text [{source_media_id,alt}]; synthesis {heading,summary,takeaways}.
    There is no fixed section, question, example, or word-count quota.
    """
  end
end
