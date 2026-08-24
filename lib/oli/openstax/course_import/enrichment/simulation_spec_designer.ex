defmodule Oli.OpenStax.CourseImport.Enrichment.SimulationSpecDesigner do
  @moduledoc "Terra design and independent Sol criticism for SimulationSpecV1."

  alias Oli.GenAI.Completions.{Message, RegisteredModel, ServiceConfig}
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    AIUsageLedger,
    EnrichmentProposal,
    EnrichmentResearchSet,
    ModelRoutingPolicy,
    SimulationSpecV1
  }

  @max_candidates 2
  @prompt_version "simulation-spec-v1"

  @spec generate(EnrichmentProposal.t(), EnrichmentResearchSet.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate(proposal, research, opts \\ [])

  def generate(%EnrichmentProposal{} = proposal, %EnrichmentResearchSet{} = research, opts) do
    with {:ok, services} <- services(opts) do
      loop(proposal, research, services, opts, 1, nil, [])
    end
  end

  def generate(_, _, _), do: {:error, :invalid_simulation_spec_context}

  defp loop(proposal, research, services, opts, attempt, repair, history) do
    attempt_opts = Keyword.put(opts, :candidate_number, attempt)

    with {:ok, candidate, usage} <-
           design(proposal, research, services.designer, repair, attempt_opts) do
      research_payload = research_payload(research)

      case SimulationSpecV1.validate(
             candidate,
             research_payload,
             validation_opts(opts, proposal)
           ) do
        {:ok, spec, validation} ->
          with {:ok, criticism, critic_usage} <-
                 criticize(spec, research_payload, services.critic, attempt_opts) do
            history =
              history ++
                [
                  %{
                    "attempt" => attempt,
                    "designer_usage" => stringify(usage),
                    "critic_usage" => stringify(critic_usage),
                    "criticism" => criticism
                  }
                ]

            if approved?(criticism) do
              content_hash = hash(spec)

              {:ok,
               %{
                 spec: spec,
                 validation: Map.put(validation, "content_hash", content_hash),
                 criticism: criticism,
                 repair_count: attempt - 1,
                 provider: "open_ai",
                 model: model_name(services.designer),
                 prompt_version: @prompt_version,
                 content_hash: content_hash,
                 history: history
               }}
            else
              repair_or_stop(
                proposal,
                research,
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
              [%{"attempt" => attempt, "findings" => findings, "usage" => stringify(usage)}]

          repair_or_stop(
            proposal,
            research,
            services,
            opts,
            attempt,
            candidate,
            findings,
            history
          )
      end
    end
  end

  defp repair_or_stop(
         _proposal,
         _research,
         _services,
         _opts,
         attempt,
         _candidate,
         findings,
         history
       )
       when attempt >= @max_candidates,
       do: {:error, {:simulation_spec_exhausted, %{findings: findings, attempts: history}}}

  defp repair_or_stop(proposal, research, services, opts, attempt, candidate, findings, history) do
    loop(
      proposal,
      research,
      services,
      opts,
      attempt + 1,
      %{candidate: candidate, findings: findings},
      history
    )
  end

  defp design(proposal, research, service, repair, opts) do
    opportunity = opportunity_payload(proposal)

    messages = [
      Message.new(:system, """
      Design a bounded, scientifically grounded simulation specification. Use only approved claim
      paraphrases and cited URLs. Include all SimulationSpecV1 scientific, deterministic sample,
      CAPI, native follow-up, remediation, rendering, and accessibility fields. Reference only
      supplied library registry IDs. Never include executable code. Return one JSON object.
      """),
      Message.new(
        :user,
        Jason.encode!(
          SimulationSpecV1.prompt_contract(
            research_payload(research),
            opportunity,
            validation_opts(opts, proposal)
          )
        )
      )
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
                    "Repair every finding and return the complete specification.",
                  "findings" => findings
                })
              )
            ]

        _ ->
          messages
      end

    execute(:simulation_spec_designer, messages, service, opts, :spec_execution_fun)
  end

  defp criticize(spec, research, service, opts) do
    messages = [
      Message.new(:system, """
      Independently audit this simulation specification for scientific correctness, evidence
      grounding, units, bounded algorithms, deterministic sample cases, CAPI consistency, and
      accessibility. Return JSON with approved, confidence, findings, and summary. Approval needs
      confidence at least 0.90 and no findings.
      """),
      Message.new(:user, Jason.encode!(%{"research" => research, "spec" => spec}))
    ]

    execute(:simulation_spec_critic, messages, service, opts, :spec_critic_fun)
  end

  defp execute(phase, messages, service, opts, option_name) do
    execution = Keyword.get(opts, option_name, &Execution.generate_with_metadata/4)

    service =
      ModelRoutingPolicy.service_config(service, phase,
        first_pass: Keyword.get(opts, :candidate_number, 1) == 1
      )

    context =
      AIUsageLedger.request_context(opts, phase, %{
        candidate_number: Keyword.get(opts, :candidate_number, 1),
        operation_id: Keyword.get(opts, :operation_id),
        cost_scope: :simulation
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

  defp services(opts) do
    case Keyword.get(opts, :services) do
      %{designer: %ServiceConfig{}, critic: %ServiceConfig{}} = services ->
        {:ok, services}

      _ ->
        with key when is_binary(key) <- System.get_env("OPENAI_API_KEY"),
             true <- String.trim(key) != "" do
          {:ok,
           %{
             designer:
               service(
                 "simulation-spec-designer",
                 "OPENSTAX_SIMULATION_SPEC_MODEL",
                 "gpt-5.6-terra",
                 key
               ),
             critic:
               service(
                 "simulation-spec-critic",
                 "OPENSTAX_SIMULATION_SPEC_CRITIC_MODEL",
                 "gpt-5.6-sol",
                 key
               )
           }}
        else
          _ -> {:error, :not_configured}
        end
    end
  end

  defp service(name, env_name, default_model, api_key) do
    model = %RegisteredModel{
      id: -1,
      name: "openstax-#{name}",
      provider: :open_ai,
      model: System.get_env(env_name) || default_model,
      url_template: System.get_env("OPENAI_API_URL") || "https://api.openai.com",
      api_key: api_key,
      secondary_api_key: System.get_env("OPENAI_ORG_KEY"),
      timeout: 30_000,
      recv_timeout: 120_000,
      pool_class: :slow,
      routing_breaker_error_rate_threshold: 0.0,
      routing_breaker_429_threshold: 0.0,
      routing_breaker_latency_p95_ms: 0
    }

    %ServiceConfig{id: -1, name: "openstax-#{name}", primary_model: model}
  end

  defp opportunity_payload(proposal) do
    %{
      "id" => get_in(proposal.metadata || %{}, ["planner_id"]),
      "domain" => get_in(proposal.metadata || %{}, ["domain"]),
      "objective_ids" => proposal.objective_ids,
      "source_evidence" => proposal.source_evidence,
      "instructional_rationale" => proposal.instructional_rationale,
      "learner_task" => proposal.learner_task,
      "misconception_target" => get_in(proposal.metadata || %{}, ["misconception_target"]),
      "placement" => proposal.placement,
      "expected_instructional_value" =>
        get_in(proposal.metadata || %{}, ["expected_instructional_value"])
    }
  end

  defp research_payload(research) do
    %{
      "content_hash" => research.content_hash,
      "source_hash" => research.source_hash,
      "source_evidence" => research.source_evidence,
      "retrieved_sources" => research.retrieved_sources,
      "proposed_sources" => research.proposed_sources,
      "claims" => research.claims
    }
  end

  defp validation_opts(opts, proposal),
    do: [
      three_d_enabled:
        Keyword.get(
          opts,
          :three_d_enabled,
          Application.get_env(:oli, :openstax_three_d_generation_enabled, false)
        ),
      opportunity: opportunity_payload(proposal)
    ]

  defp approved?(criticism),
    do:
      criticism["approved"] == true and (criticism["confidence"] || 0.0) >= 0.9 and
        List.wrap(criticism["findings"]) == []

  defp model_name(%ServiceConfig{primary_model: model}), do: model.model
  defp hash(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

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
end
