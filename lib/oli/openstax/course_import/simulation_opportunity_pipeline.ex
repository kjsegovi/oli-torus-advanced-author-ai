defmodule Oli.OpenStax.CourseImport.SimulationOpportunityPipeline do
  @moduledoc "Bounded Terra proposal and independent Sol criticism workflow."

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    AIUsageLedger,
    ModelRoutingPolicy,
    QualityCritic,
    SimulationOpportunityV1,
    StructuredPatch
  }

  @max_candidates 2

  @spec plan(map(), map(), map(), keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def plan(lesson, content, services, opts)
      when is_map(lesson) and is_map(content) and is_map(services) do
    started_at = System.monotonic_time(:millisecond)

    lesson
    |> loop(content, services, opts, 1, nil, [])
    |> put_duration(elapsed_milliseconds(started_at))
  end

  def plan(_, _, _, _), do: {:error, :invalid_simulation_opportunity_context}

  defp loop(lesson, content, services, opts, attempt, repair, history) do
    with {:ok, candidate, usage} <-
           generate(lesson, content, services.designer, repair, attempt, opts) do
      case SimulationOpportunityV1.build(candidate, lesson, content) do
        {:ok, []} ->
          {:ok, [],
           %{
             "pipeline" => "simulation_opportunity_v1",
             "attempts" =>
               history ++
                 [
                   %{
                     "attempt" => attempt,
                     "designer_usage" => stringify(usage),
                     "strategy" => "optional_zero_selection"
                   }
                 ],
             "opportunity_count" => 0,
             "repair_count" => attempt - 1,
             "designer" => identity(services.designer),
             "critic" => %{},
             "critic_skipped" => true
           }}

        {:ok, opportunities} ->
          with {:ok, criticism, critic_usage} <-
                 criticize(lesson, content, opportunities, services.critic, attempt, opts) do
            fingerprint = QualityCritic.fingerprint_findings(criticism["findings"] || [])

            history =
              history ++
                [
                  %{
                    "attempt" => attempt,
                    "designer_usage" => stringify(usage),
                    "critic_usage" => stringify(critic_usage),
                    "criticism" => criticism,
                    "finding_fingerprint" => fingerprint
                  }
                ]

            if approved?(criticism) do
              {:ok, opportunities,
               %{
                 "pipeline" => "simulation_opportunity_v1",
                 "attempts" => history,
                 "opportunity_count" => length(opportunities),
                 "repair_count" => attempt - 1,
                 "designer" => identity(services.designer),
                 "critic" => identity(services.critic)
               }}
            else
              repair_or_stop(
                lesson,
                content,
                services,
                opts,
                attempt,
                candidate,
                criticism["findings"] || [],
                history
              )
            end
          end

        {:error, findings} ->
          history =
            history ++
              [
                %{
                  "attempt" => attempt,
                  "usage" => stringify(usage),
                  "findings" => findings,
                  "finding_fingerprint" => QualityCritic.fingerprint_findings(findings)
                }
              ]

          repair_or_stop(lesson, content, services, opts, attempt, candidate, findings, history)
      end
    end
  end

  defp repair_or_stop(_lesson, _content, _services, _opts, attempt, _candidate, findings, history)
       when attempt >= @max_candidates,
       do: {:error, {:simulation_opportunity_exhausted, %{findings: findings, attempts: history}}}

  defp repair_or_stop(lesson, content, services, opts, attempt, candidate, findings, history) do
    fingerprint = QualityCritic.fingerprint_findings(findings)
    prior = history |> Enum.drop(-1) |> List.last()
    prior_prior = history |> Enum.drop(-2) |> List.last()
    repeated = prior && prior["finding_fingerprint"] == fingerprint
    repeated_twice = repeated && prior_prior && prior_prior["finding_fingerprint"] == fingerprint

    if repeated_twice do
      {:error,
       {:simulation_opportunity_needs_attention,
        %{findings: findings, attempts: history, finding_fingerprint: fingerprint}}}
    else
      loop(
        lesson,
        content,
        services,
        opts,
        attempt + 1,
        %{candidate: candidate, findings: findings, force_terra: repeated},
        history
      )
    end
  end

  defp generate(lesson, content, service, repair, attempt, opts) do
    contract = SimulationOpportunityV1.prompt_contract(lesson, content)

    messages = [
      Message.new(:system, """
      Identify zero or one focused 3–8 minute micro-simulation only when dynamic manipulation materially
      improves the approved Advanced experience. Ground every objective and evidence reference in
      the supplied contract. One meaningful learner-controlled variable and one observable outcome
      are sufficient; prefer one to three controls. Return JSON: {"opportunities": [...]}. Do not
      design or code a simulation.
      """),
      Message.new(:user, Jason.encode!(contract))
    ]

    messages =
      case repair do
        %{candidate: candidate, findings: findings} ->
          messages ++
            [
              Message.new(:assistant, Jason.encode!(candidate)),
              Message.new(
                :user,
                Jason.encode!(%{
                  "required_action" =>
                    "Return only a bounded JSON patch. Repair every finding; allowed root: opportunities.",
                  "findings" => findings
                })
              )
            ]

        _ ->
          messages
      end

    service =
      if is_map(repair) do
        configured =
          ModelRoutingPolicy.service_config(service, :repair_patch_writer,
            first_pass: false,
            cache_material: contract
          )

        if repair[:force_terra],
          do: ModelRoutingPolicy.escalate_to_terra(configured, :repair_patch_writer),
          else: configured
      else
        ModelRoutingPolicy.for_attempt(
          service,
          attempt,
          :simulation_opportunity_designer,
          contract
        )
      end

    with {:ok, decoded, usage} <-
           execute(
             if(is_map(repair), do: :repair_patch_writer, else: :simulation_opportunity_designer),
             messages,
             service,
             attempt,
             opts,
             :opportunity_execution_fun,
             repair
           ),
         {:ok, candidate} <- repaired_candidate(decoded, repair) do
      {:ok, candidate, usage}
    end
  end

  defp criticize(lesson, content, opportunities, service, attempt, opts) do
    messages = [
      Message.new(:system, """
      Independently reject decorative, duplicative, uncited, misplaced, or pedagogically weak
      simulation proposals. Return JSON with approved, confidence, findings, and summary. Approval
      requires confidence at least 0.90 and no findings.
      """),
      Message.new(
        :user,
        Jason.encode!(%{
          "contract" => SimulationOpportunityV1.prompt_contract(lesson, content),
          "opportunities" => opportunities
        })
      )
    ]

    with {:ok, criticism, usage} <-
           execute(
             :simulation_opportunity_critic,
             messages,
             ModelRoutingPolicy.for_attempt(
               service,
               attempt,
               :simulation_opportunity_critic,
               SimulationOpportunityV1.prompt_contract(lesson, content)
             ),
             attempt,
             opts,
             :opportunity_critic_fun,
             nil
           ) do
      {:ok, criticism, usage}
    end
  end

  defp execute(phase, messages, service, attempt, opts, option_name, repair) do
    execution = Keyword.get(opts, option_name, &Execution.generate_with_metadata/4)

    context =
      opts
      |> Keyword.put(:authoring_mode, "advanced")
      |> AIUsageLedger.request_context(phase, %{
        candidate_number: attempt,
        retry_category: if(attempt > 1, do: "contract_repair"),
        finding_fingerprint:
          repair && QualityCritic.fingerprint_findings(List.wrap(repair.findings))
      })

    result =
      case Function.info(execution, :arity) do
        {:arity, 3} -> execution.(context, messages, service)
        _ -> execution.(context, messages, [], service)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, decoded} <- Jason.decode(strip_code_fence(raw)),
         true <- is_map(decoded) do
      {:ok, decoded, metadata || %{}}
    else
      false -> {:error, {:invalid_provider_response, phase}}
      {:error, reason} -> {:error, {:provider_failed, phase, reason}}
      other -> {:error, {:provider_failed, phase, other}}
    end
  end

  defp repaired_candidate(decoded, repair) when is_map(repair),
    do: StructuredPatch.apply(repair.candidate, decoded, :simulation_opportunity_designer)

  defp repaired_candidate(decoded, _repair), do: {:ok, decoded}

  defp approved?(criticism),
    do:
      criticism["approved"] == true and (criticism["confidence"] || 0.0) >= 0.9 and
        List.wrap(criticism["findings"]) == []

  defp identity(%{primary_model: model}) when is_map(model),
    do: %{"provider" => model.provider, "model" => model.model, "service" => model.name}

  defp identity(_), do: %{}

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

  defp put_duration({:ok, opportunities, metadata}, duration_ms),
    do: {:ok, opportunities, Map.put(metadata, "duration_ms", duration_ms)}

  defp put_duration(result, _duration_ms), do: result

  defp elapsed_milliseconds(started_at),
    do: max(System.monotonic_time(:millisecond) - started_at, 0)
end
