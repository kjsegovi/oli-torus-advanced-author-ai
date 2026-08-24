defmodule Oli.OpenStax.CourseImport.AdvancedPipelineV7 do
  @moduledoc """
  Resumable schema 7 Advanced workflow. The same architect and activity-writer
  roles repair their own candidates after independent criticism. There is no
  deterministic Advanced filler or schema downgrade path.
  """

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    AdvancedPlanV7,
    AIUsageLedger,
    ModelRoutingPolicy,
    QualityCritic,
    StructuredPatch
  }

  @max_candidates 2

  @spec plan(map(), pos_integer(), map(), keyword()) ::
          {:ok, %{content_payload: map(), questions_payload: map(), metadata: map()}}
          | {:error, term()}
  def plan(lesson, index, services, opts)
      when is_map(lesson) and is_integer(index) and index > 0 and is_map(services) do
    checkpoint = normalize_checkpoint(Keyword.get(opts, :generation_checkpoint, %{}))

    with {:ok, architecture} <- architecture_stage(lesson, index, services, checkpoint, opts),
         {:ok, activities} <- activity_stage(lesson, architecture, services, checkpoint, opts),
         :ok <- checkpoint(opts, final_stage(architecture, activities), architecture, activities) do
      {:ok, result(architecture, activities, services, opts)}
    end
  end

  def plan(_lesson, _index, _services, _opts), do: {:error, :invalid_v7_pipeline_context}

  defp architecture_stage(lesson, index, services, checkpoint, opts) do
    cond do
      checkpoint.stage in ~w(advanced_content_approved advanced_activity_repair_pending advanced_approved advanced_quality_attention completed) and
          is_map(checkpoint.payload["content_payload"]) ->
        {:ok,
         %{
           content_payload: checkpoint.payload["content_payload"],
           reviews: List.wrap(checkpoint.payload["content_reviews"]),
           attempts: List.wrap(checkpoint.payload["content_attempts"]),
           resumed: true,
           needs_attention: content_attention?(checkpoint.payload["attention_reason"]),
           attention_reason: checkpoint.payload["attention_reason"]
         }}

      checkpoint.stage == "advanced_content_repair_pending" and
          is_map(checkpoint.payload["repair_candidate"]) ->
        resume_architecture_repair(lesson, index, services, checkpoint.payload, opts)

      true ->
        architecture_loop(
          lesson,
          index,
          services,
          opts,
          1,
          initial_repair(lesson, "experience"),
          [],
          [],
          nil,
          false
        )
    end
  end

  defp resume_architecture_repair(lesson, index, services, payload, opts) do
    candidate = payload["repair_candidate"]
    attempts = List.wrap(payload["content_attempts"])
    reviews = List.wrap(payload["content_reviews"])
    next_attempt = payload["next_attempt"] || 2
    candidate_attempt = max(next_attempt - 1, 1)

    case AdvancedPlanV7.build_architecture(candidate, lesson, index) do
      {:ok, content} ->
        critic_opts =
          opts
          |> Keyword.put(:critic_attempt, candidate_attempt)
          |> Keyword.put(:candidate_number, candidate_attempt)

        with {:ok, review} <- review_content(lesson, content, services.critic, critic_opts) do
          reviews = reviews ++ [Map.put(review, "attempt", candidate_attempt)]

          if QualityCritic.approved?(review) do
            {:ok,
             %{
               content_payload: content,
               reviews: reviews,
               attempts: attempts,
               resumed: true
             }}
          else
            continue_architecture(
              lesson,
              index,
              services,
              opts,
              candidate_attempt,
              candidate,
              content,
              review,
              attempts,
              reviews,
              payload["previous_fingerprint"],
              true
            )
          end
        end

      {:error, _findings} ->
        architecture_loop(
          lesson,
          index,
          services,
          opts,
          next_attempt,
          %{
            candidate: candidate,
            findings: List.wrap(payload["repair_findings"])
          },
          attempts,
          reviews,
          payload["previous_fingerprint"],
          true
        )
    end
  end

  defp architecture_loop(
         lesson,
         index,
         services,
         opts,
         attempt,
         repair,
         attempts,
         reviews,
         previous,
         resumed
       ) do
    with {:ok, candidate, usage} <-
           architecture_candidate(lesson, index, services.architect, repair, attempt, opts) do
      attempts = attempts ++ [%{"attempt" => attempt, "model_usage" => stringify(usage)}]

      case AdvancedPlanV7.build_architecture(candidate, lesson, index) do
        {:ok, content} ->
          critic_opts =
            opts
            |> Keyword.put(:critic_attempt, attempt)
            |> Keyword.put(:candidate_number, attempt)

          with {:ok, review} <- review_content(lesson, content, services.critic, critic_opts) do
            reviews = reviews ++ [Map.put(review, "attempt", attempt)]

            if QualityCritic.approved?(review) do
              {:ok,
               %{content_payload: content, reviews: reviews, attempts: attempts, resumed: resumed}}
            else
              continue_architecture(
                lesson,
                index,
                services,
                opts,
                attempt,
                candidate,
                content,
                review,
                attempts,
                reviews,
                previous,
                resumed
              )
            end
          end

        {:error, findings} ->
          review = deterministic_review(findings)
          reviews = reviews ++ [Map.put(review, "attempt", attempt)]

          continue_architecture(
            lesson,
            index,
            services,
            opts,
            attempt,
            candidate,
            nil,
            review,
            attempts,
            reviews,
            previous,
            resumed
          )
      end
    end
  end

  defp continue_architecture(
         lesson,
         index,
         services,
         opts,
         attempt,
         candidate,
         valid_content,
         review,
         attempts,
         reviews,
         previous,
         resumed
       ) do
    partition =
      QualityCritic.partition_repair_findings(review, :advanced_content_architect)

    review =
      QualityCritic.demote_source_owned_findings(
        review,
        partition.source_resolvable ++ partition.source_advisory
      )

    reviews = List.replace_at(reviews, -1, Map.put(review, "attempt", attempt))
    repairable_findings = partition.repairable
    fingerprint = QualityCritic.fingerprint_findings(repairable_findings)

    with :ok <-
           checkpoint(opts, "advanced_content_repair_pending", %{
             content_payload: valid_content,
             content_reviews: reviews,
             content_attempts: attempts,
             repair_candidate: candidate,
             repair_findings: repairable_findings,
             previous_fingerprint: fingerprint,
             next_attempt: attempt + 1
           }) do
      cond do
        partition.source_resolvable != [] and repairable_findings == [] and
            is_map(valid_content) ->
          {:ok,
           %{
             content_payload: valid_content,
             reviews: reviews,
             attempts: attempts,
             resumed: resumed
           }}

        repairable_findings == [] and is_map(valid_content) ->
          {:ok,
           attention(
             valid_content,
             reviews,
             attempts,
             resumed,
             "content_critic_gate_failed"
           )}

        full_critic_count(reviews) >= 2 and is_map(valid_content) ->
          {:ok,
           attention(
             valid_content,
             reviews,
             attempts,
             resumed,
             "content_quality_re_review_failed"
           )}

        attempt > 1 and fingerprint == previous and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "content_quality_stalled")}

        attempt >= @max_candidates and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "content_quality_exhausted")}

        attempt > 1 and fingerprint == previous ->
          {:error, {:advanced_content_contract_stalled, quality_failure(review, reviews)}}

        attempt >= @max_candidates ->
          {:error, {:advanced_content_contract_exhausted, quality_failure(review, reviews)}}

        true ->
          architecture_loop(
            lesson,
            index,
            services,
            opts,
            attempt + 1,
            %{candidate: candidate, findings: repairable_findings},
            attempts,
            reviews,
            fingerprint,
            resumed
          )
      end
    end
  end

  defp activity_stage(
         _lesson,
         %{needs_attention: true} = architecture,
         _services,
         _checkpoint,
         _opts
       ) do
    {:ok,
     %{
       content_payload: architecture.content_payload,
       reviews: [],
       attempts: [],
       resumed: false,
       needs_attention: true,
       attention_reason: architecture.attention_reason
     }}
  end

  defp activity_stage(lesson, architecture, services, checkpoint, opts) do
    cond do
      checkpoint.stage in ~w(advanced_approved advanced_quality_attention completed) and
          is_map(checkpoint.payload["content_payload"]) ->
        {:ok,
         %{
           content_payload: checkpoint.payload["content_payload"],
           reviews: List.wrap(checkpoint.payload["activity_reviews"]),
           attempts: List.wrap(checkpoint.payload["activity_attempts"]),
           resumed: true,
           needs_attention: activity_attention?(checkpoint.payload["attention_reason"]),
           attention_reason: checkpoint.payload["attention_reason"]
         }}

      checkpoint.stage == "advanced_activity_repair_pending" and
          is_map(checkpoint.payload["activity_candidate"]) ->
        activity_loop(
          lesson,
          architecture,
          services,
          opts,
          checkpoint.payload["next_attempt"] || 2,
          %{
            candidate: checkpoint.payload["activity_candidate"],
            findings: List.wrap(checkpoint.payload["repair_findings"])
          },
          List.wrap(checkpoint.payload["activity_attempts"]),
          List.wrap(checkpoint.payload["activity_reviews"]),
          checkpoint.payload["previous_fingerprint"],
          true
        )

      true ->
        with :ok <- checkpoint(opts, "advanced_content_approved", architecture, nil) do
          activity_loop(
            lesson,
            architecture,
            services,
            opts,
            1,
            initial_repair(lesson, "activities"),
            [],
            [],
            nil,
            false
          )
        end
    end
  end

  defp activity_loop(
         lesson,
         architecture,
         services,
         opts,
         attempt,
         repair,
         attempts,
         reviews,
         previous,
         resumed
       ) do
    with {:ok, candidate, usage} <-
           activity_candidate(
             lesson,
             architecture.content_payload,
             services.activity_writer,
             repair,
             attempt,
             opts
           ) do
      attempts = attempts ++ [%{"attempt" => attempt, "model_usage" => stringify(usage)}]

      case AdvancedPlanV7.attach_activities(architecture.content_payload, candidate, lesson) do
        {:ok, content} ->
          critic_opts =
            opts
            |> Keyword.put(:critic_attempt, attempt)
            |> Keyword.put(:candidate_number, attempt)

          with {:ok, review} <-
                 review_activities(lesson, content, services.activity_critic, critic_opts) do
            reviews = reviews ++ [Map.put(review, "attempt", attempt)]

            if QualityCritic.approved?(review) do
              {:ok,
               %{content_payload: content, reviews: reviews, attempts: attempts, resumed: resumed}}
            else
              continue_activities(
                lesson,
                architecture,
                services,
                opts,
                attempt,
                candidate,
                content,
                review,
                attempts,
                reviews,
                previous,
                resumed
              )
            end
          end

        {:error, findings} ->
          review = deterministic_review(findings)
          reviews = reviews ++ [Map.put(review, "attempt", attempt)]

          continue_activities(
            lesson,
            architecture,
            services,
            opts,
            attempt,
            candidate,
            nil,
            review,
            attempts,
            reviews,
            previous,
            resumed
          )
      end
    end
  end

  defp continue_activities(
         lesson,
         architecture,
         services,
         opts,
         attempt,
         candidate,
         valid_content,
         review,
         attempts,
         reviews,
         previous,
         resumed
       ) do
    fingerprint = QualityCritic.fingerprint(review)

    with :ok <-
           checkpoint(opts, "advanced_activity_repair_pending", architecture, %{
             content_payload: valid_content || architecture.content_payload,
             activity_candidate: candidate,
             activity_reviews: reviews,
             activity_attempts: attempts,
             repair_findings: QualityCritic.repair_findings(review),
             previous_fingerprint: fingerprint,
             next_attempt: attempt + 1
           }) do
      cond do
        full_critic_count(reviews) >= 2 and is_map(valid_content) ->
          {:ok,
           attention(
             valid_content,
             reviews,
             attempts,
             resumed,
             "activity_quality_re_review_failed"
           )}

        attempt > 1 and fingerprint == previous and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "activity_quality_stalled")}

        attempt >= @max_candidates and is_map(valid_content) ->
          {:ok,
           attention(valid_content, reviews, attempts, resumed, "activity_quality_exhausted")}

        attempt > 1 and fingerprint == previous ->
          {:error, {:advanced_activity_contract_stalled, quality_failure(review, reviews)}}

        attempt >= @max_candidates ->
          {:error, {:advanced_activity_contract_exhausted, quality_failure(review, reviews)}}

        true ->
          activity_loop(
            lesson,
            architecture,
            services,
            opts,
            attempt + 1,
            %{candidate: candidate, findings: QualityCritic.repair_findings(review)},
            attempts,
            reviews,
            fingerprint,
            resumed
          )
      end
    end
  end

  defp architecture_candidate(lesson, index, service, repair, attempt, opts) do
    generate(
      :advanced_experience_architect,
      architect_prompt(),
      AdvancedPlanV7.prompt_contract(lesson),
      repair,
      service,
      attempt,
      opts,
      index,
      :advanced_experience_architect
    )
  end

  defp activity_candidate(lesson, content, service, repair, attempt, opts) do
    contract = %{
      "source_contract" => AdvancedPlanV7.prompt_contract(lesson),
      "objective_catalog" => content["objective_catalog"],
      "content_groups" => content["content_groups"],
      "experience_blueprint" => content["experience_blueprint"]
    }

    generate(
      :advanced_activity_writer,
      activity_prompt(),
      contract,
      repair,
      service,
      attempt,
      opts,
      nil,
      :advanced_activity_writer
    )
  end

  defp generate(phase, system_prompt, contract, repair, service, attempt, opts, index, owner) do
    messages = [Message.new(:system, system_prompt), Message.new(:user, Jason.encode!(contract))]

    messages =
      case repair do
        %{candidate: candidate, findings: findings} = repair ->
          messages ++
            [
              Message.new(:assistant, Jason.encode!(candidate)),
              Message.new(
                :user,
                Jason.encode!(%{
                  "required_action" =>
                    "Return only a bounded JSON patch as {\"patch\":[{\"op\":\"add|replace|remove\",\"path\":\"/...\",\"value\":...}]}. Repair every finding and preserve unrelated fields. Allowed roots: #{Enum.join(StructuredPatch.allowed_roots(owner), ", ")}.",
                  "critic_findings" => findings,
                  "author_feedback" => repair[:author_feedback]
                })
              )
            ]

        _ ->
          messages
      end

    {service, ledger_role} =
      if is_map(repair) do
        {
          ModelRoutingPolicy.service_config(service, :repair_patch_writer,
            first_pass: false,
            cache_material: contract
          ),
          :repair_patch_writer
        }
      else
        {ModelRoutingPolicy.for_attempt(service, attempt, phase, contract), phase}
      end

    context =
      opts
      |> Keyword.put(:authoring_mode, "advanced")
      |> AIUsageLedger.request_context(ledger_role, %{
        candidate_number: attempt,
        retry_category: if(attempt > 1, do: "contract_repair"),
        finding_fingerprint:
          repair && QualityCritic.fingerprint_findings(List.wrap(repair.findings))
      })
      |> Map.put(:lesson_index, index)

    execution = Keyword.get(opts, :v7_execution_fun, &Execution.generate_with_metadata/4)

    result =
      case Function.info(execution, :arity) do
        {:arity, 3} -> execution.(context, messages, service)
        _ -> execution.(context, messages, [], service)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, candidate} <- Jason.decode(strip_code_fence(raw)),
         true <- is_map(candidate),
         {:ok, candidate} <- repaired_candidate(candidate, repair, owner) do
      {:ok, candidate, metadata || %{}}
    else
      false ->
        {:error, {:invalid_provider_response, phase}}

      {:error, findings} when is_list(findings) ->
        {:error, {:invalid_repair_patch, phase, findings}}

      {:error, reason} ->
        {:error, {:provider_failed, phase, reason}}

      other ->
        {:error, {:provider_failed, phase, other}}
    end
  end

  defp repaired_candidate(decoded, repair, owner) when is_map(repair),
    do: StructuredPatch.apply(repair.candidate, decoded, owner)

  defp repaired_candidate(decoded, _repair, _owner), do: {:ok, decoded}

  defp review_content(lesson, content, service, opts) do
    fun =
      Keyword.get(opts, :advanced_content_critic_fun, &QualityCritic.review_advanced_content/4)

    service =
      ModelRoutingPolicy.for_attempt(
        service,
        Keyword.get(opts, :critic_attempt, 1),
        :advanced_experience_critic,
        AdvancedPlanV7.prompt_contract(lesson)
      )

    fun.(lesson, content, service, critic_opts(opts, "advanced"))
  end

  defp review_activities(lesson, content, service, opts) do
    fun =
      Keyword.get(
        opts,
        :advanced_activity_critic_fun,
        &QualityCritic.review_advanced_activities/4
      )

    service =
      ModelRoutingPolicy.for_attempt(
        service,
        Keyword.get(opts, :critic_attempt, 1),
        :advanced_activity_critic,
        AdvancedPlanV7.prompt_contract(lesson)
      )

    fun.(lesson, content, service, critic_opts(opts, "advanced"))
  end

  defp critic_opts(opts, mode) do
    opts
    |> Keyword.take([:critic_execution_fun, :run_id, :lesson_id, :candidate_number])
    |> Keyword.put(:authoring_mode, mode)
  end

  defp checkpoint(opts, stage, architecture, activities \\ nil) do
    case Keyword.get(opts, :checkpoint_fun) do
      fun when is_function(fun, 2) ->
        payload = checkpoint_payload(architecture, activities)

        case fun.(stage, payload) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:generation_checkpoint_failed, stage, reason}}
          other -> {:error, {:generation_checkpoint_failed, stage, other}}
        end

      _ ->
        :ok
    end
  end

  defp checkpoint_payload(%{} = architecture, activities) do
    architecture = normalize_result_map(architecture)
    activities = normalize_result_map(activities || %{})

    %{
      "content_payload" => activities[:content_payload] || architecture[:content_payload],
      "content_reviews" => architecture[:reviews] || architecture[:content_reviews] || [],
      "content_attempts" => architecture[:attempts] || architecture[:content_attempts] || [],
      "activity_reviews" => activities[:reviews] || activities[:activity_reviews] || [],
      "activity_attempts" => activities[:attempts] || activities[:activity_attempts] || [],
      "activity_candidate" => activities[:activity_candidate],
      "repair_candidate" => architecture[:repair_candidate],
      "repair_findings" => activities[:repair_findings] || architecture[:repair_findings] || [],
      "previous_fingerprint" =>
        activities[:previous_fingerprint] || architecture[:previous_fingerprint],
      "next_attempt" => activities[:next_attempt] || architecture[:next_attempt],
      "needs_attention" =>
        activities[:needs_attention] == true or architecture[:needs_attention] == true,
      "attention_reason" => activities[:attention_reason] || architecture[:attention_reason]
    }
  end

  defp normalize_result_map(value) when is_map(value), do: value
  defp normalize_result_map(_value), do: %{}

  defp result(architecture, activities, services, opts) do
    content_review = List.last(architecture.reviews || []) || %{}
    activity_review = List.last(activities.reviews || []) || %{}
    findings = List.wrap(content_review["findings"]) ++ List.wrap(activity_review["findings"])
    attention_reason = architecture[:attention_reason] || activities[:attention_reason]

    metadata = %{
      "pipeline" => "openstax_advanced_v7",
      "suitability" => stringify(Keyword.get(opts, :advanced_suitability, %{})),
      "quality_gate" => %{
        "approved" =>
          QualityCritic.approved?(content_review) and QualityCritic.approved?(activity_review),
        "confidence" =>
          min(content_review["confidence"] || 0.0, activity_review["confidence"] || 0.0),
        "threshold" => 0.9,
        "outcome" => if(attention_reason, do: "needs_attention", else: "approved"),
        "attention_reason" => attention_reason,
        "hard_blockers" => Enum.filter(findings, &(&1["severity"] == "hard_blocker")),
        "repairs" => Enum.filter(findings, &(&1["severity"] == "repair")),
        "advisories" => Enum.filter(findings, &(&1["severity"] == "advisory")),
        "experience_critic" => content_review,
        "activity_critic" => activity_review
      },
      "content_reviews" => architecture.reviews,
      "activity_reviews" => activities.reviews,
      "repair_history" => %{
        "experience" => architecture.attempts,
        "activities" => activities.attempts
      },
      "roles" => %{
        "experience_architect" => service_identity(services.architect),
        "experience_critic" => service_identity(services.critic),
        "activity_writer" => service_identity(services.activity_writer),
        "activity_critic" => service_identity(services.activity_critic)
      },
      "resume" => %{"experience" => architecture.resumed, "activities" => activities.resumed}
    }

    %{
      content_payload: activities.content_payload,
      questions_payload: %{"items" => []},
      metadata: metadata
    }
  end

  defp final_stage(%{needs_attention: true}, _activities), do: "advanced_quality_attention"
  defp final_stage(_architecture, %{needs_attention: true}), do: "advanced_quality_attention"
  defp final_stage(_architecture, _activities), do: "advanced_approved"

  defp attention(content, reviews, attempts, resumed, reason),
    do: %{
      content_payload: content,
      reviews: reviews,
      attempts: attempts,
      resumed: resumed,
      needs_attention: true,
      attention_reason: reason
    }

  defp content_attention?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "content_")

  defp content_attention?(_reason), do: false

  defp activity_attention?(reason) when is_binary(reason),
    do: String.starts_with?(reason, "activity_")

  defp activity_attention?(_reason), do: false

  defp deterministic_review(findings) do
    %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.0,
      "threshold" => 0.9,
      "findings" => findings,
      "summary" => "The deterministic schema 7 contract rejected this candidate.",
      "model_usage" => %{"strategy" => "deterministic_contract"}
    }
  end

  defp full_critic_count(reviews) do
    Enum.count(reviews, fn review ->
      get_in(review, ["model_usage", "strategy"]) != "deterministic_contract"
    end)
  end

  defp quality_failure(review, history),
    do: %{
      "confidence" => review["confidence"],
      "findings" => QualityCritic.repair_findings(review),
      "review_history" => history
    }

  defp service_identity(%{primary_model: model}) when is_map(model),
    do: %{"provider" => model.provider, "model" => model.model, "service" => model.name}

  defp service_identity(_service), do: %{}

  defp initial_repair(lesson, phase) do
    context = lesson["repair_context"] || lesson[:repair_context] || %{}
    candidates = context["previous_candidates"] || context[:previous_candidates] || %{}
    phase_findings = context["phase_findings"] || context[:phase_findings] || %{}
    candidate = phase_value(candidates, phase)

    if is_map(candidate) and candidate != %{} do
      %{
        candidate: candidate,
        findings: List.wrap(phase_value(phase_findings, phase)),
        author_feedback: context["author_feedback"] || context[:author_feedback]
      }
    end
  end

  defp phase_value(values, "experience"), do: values["experience"] || values[:experience]
  defp phase_value(values, "activities"), do: values["activities"] || values[:activities]

  defp normalize_checkpoint(checkpoint) when is_map(checkpoint),
    do: %{
      stage: checkpoint["stage"] || checkpoint[:stage],
      payload: checkpoint["payload"] || checkpoint[:payload] || %{}
    }

  defp normalize_checkpoint(_checkpoint), do: %{stage: nil, payload: %{}}

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp strip_code_fence(content),
    do:
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")

  defp architect_prompt do
    """
    You are the Terra experience architect for a source-faithful OpenStax schema 7
    Exploration. Organize every supplied source block exactly once into substantive
    content groups, then create one coherent sequence of orientation, prediction,
    investigation/observation/evidence, interpretation, transfer, and synthesis stages.
    Roles may be combined. Cite only supplied ids. Never replace or rewrite the source
    blocks. You may author compact connective instruction around them: every stage has
    an introduction plus source-grounded prediction, observation, interpretation,
    transfer, or synthesis guidance appropriate to its roles. Across the complete
    experience all five guidance kinds are required. Each introduction and guidance
    item cites the source block ids that support it and must not invent evidence.

    When repair_context is present, this is a user-requested regeneration. Disposition
    every supplied author-feedback item and generated-content critic finding. Do not
    alter authoritative source blocks to conceal a source-owned diagnostic.

    Give every stage one supported high-level presentation_pattern. The deterministic
    compiler, not you, owns Torus layout and behavior. Do not emit rules, navigation
    targets, URLs, raw HTML, or rendering instructions. Add activity slots only for
    genuine learner work. Use the exact activity-slot keys stage_id, purpose,
    objective_ids, evidence_block_ids, recommended_types,
    remediation_content_group_id, and estimated_minutes. recommended_types must be
    an array containing only values from allowed_activity_types. stage_id must match
    the stage whose items include that activity slot. Use an honest 4–20 minute
    estimate. When a stage has activity slots, choose one of those slots as
    native_follow_up_slot_id so an optional generated simulation has an explicit native
    follow-up. remediation_content_group_id is the single best starting point if the
    learner needs review. An integrated activity may cite several groups; its target
    does not need to contain every cited concept. Do not pad duration.

    Return JSON only with the complete schema 7 organization fields (title,
    orientation, content_groups, generated_alt_text, synthesis, question_slots=[])
    plus experience_blueprint {driving_question, stages, activity_slots}. Each stage
    contains presentation_pattern, introduction {heading,body,evidence_block_ids},
    guidance [{kind,heading,body,evidence_block_ids}], native_follow_up_slot_id when it
    has activity slots, and items. Stage items are
    {kind:"content_group|activity_slot",ref_id:string}.
    """
  end

  defp activity_prompt do
    """
    You are the Terra activity writer for an approved schema 7 Exploration. Create
    exactly one complete source-grounded activity for every approved slot. Each needs
    id, slot_id, context, prompt, interaction_type, response contract, correct_feedback,
    incorrect_feedback, allow_not_sure=true, hint, remediation_content_group_id,
    objective_ids, and evidence_block_ids. Choice interactions need 2–6 choices,
    each using the exact boolean key correct, exactly one correct=true, and targeted
    feedback on every incorrect choice. Numeric
    interactions need a correct_response; sliders also need configuration min, max,
    and step. Do not author Torus rules, URLs, storage keys, or navigation ids.

    Copy remediation_content_group_id exactly from the approved slot. That destination
    is architecture-owned and the deterministic compiler will enforce it. For an
    integrated activity spanning several content groups, it is the single best starting
    point for remediation; it is not required to contain every cited concept.

    When source_contract.repair_context is present, make the new activity set resolve
    every applicable generated-activity finding and author request. Source-owned
    diagnostics describe the textbook input and are not activity-writing tasks.

    Return JSON only: {"activities":[...]}. Preserve all ids from the approved slots.
    """
  end
end
