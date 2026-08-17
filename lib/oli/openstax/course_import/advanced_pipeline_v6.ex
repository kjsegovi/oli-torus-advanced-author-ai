defmodule Oli.OpenStax.CourseImport.AdvancedPipelineV6 do
  @moduledoc """
  Resumable schema 6 Advanced workflow. The same architect and activity-writer
  roles repair their own candidates after independent criticism. There is no
  deterministic Advanced filler or schema downgrade path.
  """

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution
  alias Oli.OpenStax.CourseImport.{AdvancedPlanV6, QualityCritic}

  @feature :openstax_course_import
  @max_candidates 4

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

  def plan(_lesson, _index, _services, _opts), do: {:error, :invalid_v6_pipeline_context}

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
        architecture_loop(
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
        architecture_loop(lesson, index, services, opts, 1, nil, [], [], nil, false)
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
           architecture_candidate(lesson, index, services.architect, repair, opts) do
      attempts = attempts ++ [%{"attempt" => attempt, "model_usage" => stringify(usage)}]

      case AdvancedPlanV6.build_architecture(candidate, lesson, index) do
        {:ok, content} ->
          with {:ok, review} <- review_content(lesson, content, services.critic, opts) do
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
    fingerprint = QualityCritic.fingerprint(review)

    with :ok <-
           checkpoint(opts, "advanced_content_repair_pending", %{
             content_payload: valid_content,
             content_reviews: reviews,
             content_attempts: attempts,
             repair_candidate: candidate,
             repair_findings: QualityCritic.repair_findings(review),
             previous_fingerprint: fingerprint,
             next_attempt: attempt + 1
           }) do
      cond do
        attempt >= @max_candidates and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "content_quality_exhausted")}

        fingerprint == previous and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "content_quality_stalled")}

        attempt >= @max_candidates ->
          {:error, {:advanced_content_contract_exhausted, quality_failure(review, reviews)}}

        fingerprint == previous ->
          {:error, {:advanced_content_contract_stalled, quality_failure(review, reviews)}}

        true ->
          architecture_loop(
            lesson,
            index,
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
          activity_loop(lesson, architecture, services, opts, 1, nil, [], [], nil, false)
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
             opts
           ) do
      attempts = attempts ++ [%{"attempt" => attempt, "model_usage" => stringify(usage)}]

      case AdvancedPlanV6.attach_activities(architecture.content_payload, candidate, lesson) do
        {:ok, content} ->
          with {:ok, review} <- review_activities(lesson, content, services.activity_critic, opts) do
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
        attempt >= @max_candidates and is_map(valid_content) ->
          {:ok,
           attention(valid_content, reviews, attempts, resumed, "activity_quality_exhausted")}

        fingerprint == previous and is_map(valid_content) ->
          {:ok, attention(valid_content, reviews, attempts, resumed, "activity_quality_stalled")}

        attempt >= @max_candidates ->
          {:error, {:advanced_activity_contract_exhausted, quality_failure(review, reviews)}}

        fingerprint == previous ->
          {:error, {:advanced_activity_contract_stalled, quality_failure(review, reviews)}}

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

  defp architecture_candidate(lesson, index, service, repair, opts) do
    generate(
      :v6_experience_architect,
      architect_prompt(),
      AdvancedPlanV6.prompt_contract(lesson),
      repair,
      service,
      opts,
      index
    )
  end

  defp activity_candidate(lesson, content, service, repair, opts) do
    contract = %{
      "source_contract" => AdvancedPlanV6.prompt_contract(lesson),
      "objective_catalog" => content["objective_catalog"],
      "content_groups" => content["content_groups"],
      "experience_blueprint" => content["experience_blueprint"]
    }

    generate(:v6_activity_writer, activity_prompt(), contract, repair, service, opts, nil)
  end

  defp generate(phase, system_prompt, contract, repair, service, opts, index) do
    messages = [Message.new(:system, system_prompt), Message.new(:user, Jason.encode!(contract))]

    messages =
      case repair do
        %{candidate: candidate, findings: findings} ->
          messages ++
            [
              Message.new(:assistant, Jason.encode!(candidate)),
              Message.new(
                :user,
                Jason.encode!(%{
                  "required_action" => "Repair every finding and return the complete candidate.",
                  "critic_findings" => findings
                })
              )
            ]

        _ ->
          messages
      end

    context = %{request_type: :generate, feature: @feature, phase: phase, lesson_index: index}
    execution = Keyword.get(opts, :v6_execution_fun, &Execution.generate_with_metadata/4)

    result =
      case Function.info(execution, :arity) do
        {:arity, 3} -> execution.(context, messages, service)
        _ -> execution.(context, messages, [], service)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, candidate} <- Jason.decode(strip_code_fence(raw)),
         true <- is_map(candidate) do
      {:ok, candidate, metadata || %{}}
    else
      false -> {:error, {:invalid_provider_response, phase}}
      {:error, reason} -> {:error, {:provider_failed, phase, reason}}
      other -> {:error, {:provider_failed, phase, other}}
    end
  end

  defp review_content(lesson, content, service, opts) do
    fun =
      Keyword.get(opts, :advanced_content_critic_fun, &QualityCritic.review_advanced_content/4)

    fun.(lesson, content, service, Keyword.take(opts, [:critic_execution_fun]))
  end

  defp review_activities(lesson, content, service, opts) do
    fun =
      Keyword.get(
        opts,
        :advanced_activity_critic_fun,
        &QualityCritic.review_advanced_activities/4
      )

    fun.(lesson, content, service, Keyword.take(opts, [:critic_execution_fun]))
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
      "pipeline" => "openstax_advanced_v6",
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
      "summary" => "The deterministic schema 6 contract rejected this candidate.",
      "model_usage" => %{"strategy" => "deterministic_contract"}
    }
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
    You are the Terra experience architect for a source-faithful OpenStax schema 6
    Exploration. Organize every supplied source block exactly once into substantive
    content groups, then create one coherent sequence of orientation, prediction,
    investigation/evidence, interpretation, transfer, and synthesis stages. Roles may
    be combined. Cite only supplied ids. Do not paraphrase source content or invent
    evidence. Add activity slots only for genuine learner work and give each a
    remediation content-group id, evidence ids, objective ids, recommended supported
    interaction types, and an honest 4–20 minute estimate. Do not pad duration.

    Return JSON only with the complete schema 5 organization fields (title,
    orientation, content_groups, generated_alt_text, synthesis, question_slots=[])
    plus experience_blueprint {driving_question, stages, activity_slots}. Stage items
    are {kind:"content_group|activity_slot",ref_id:string}.
    """
  end

  defp activity_prompt do
    """
    You are the Terra activity writer for an approved schema 6 Exploration. Create
    exactly one complete source-grounded activity for every approved slot. Each needs
    id, slot_id, context, prompt, interaction_type, response contract, correct_feedback,
    default incorrect_feedback, allow_not_sure=true, hint, remediation_content_group_id,
    objective_ids, and evidence_block_ids. Choice interactions need 2–6 choices,
    exactly one correct, and targeted feedback on every incorrect choice. Numeric
    interactions need a correct_response; sliders also need configuration min, max,
    and step. Do not author Torus rules, URLs, storage keys, or navigation ids.

    Return JSON only: {"activities":[...]}. Preserve all ids from the approved slots.
    """
  end
end
