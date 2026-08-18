defmodule Oli.OpenStax.CourseImport.SimulationOpportunityPipeline do
  @moduledoc "Bounded Terra proposal and independent Sol criticism workflow."

  alias Oli.GenAI.Completions.Message
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.SimulationOpportunityV1

  @feature :openstax_course_import
  @max_candidates 3

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
    with {:ok, candidate, usage} <- generate(lesson, content, services.designer, repair, opts) do
      case SimulationOpportunityV1.build(candidate, lesson, content) do
        {:ok, opportunities} ->
          with {:ok, criticism, critic_usage} <-
                 criticize(lesson, content, opportunities, services.critic, opts) do
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
              [%{"attempt" => attempt, "usage" => stringify(usage), "findings" => findings}]

          repair_or_stop(lesson, content, services, opts, attempt, candidate, findings, history)
      end
    end
  end

  defp repair_or_stop(_lesson, _content, _services, _opts, attempt, _candidate, findings, history)
       when attempt >= @max_candidates,
       do: {:error, {:simulation_opportunity_exhausted, %{findings: findings, attempts: history}}}

  defp repair_or_stop(lesson, content, services, opts, attempt, candidate, findings, history) do
    loop(
      lesson,
      content,
      services,
      opts,
      attempt + 1,
      %{candidate: candidate, findings: findings},
      history
    )
  end

  defp generate(lesson, content, service, repair, opts) do
    contract = SimulationOpportunityV1.prompt_contract(lesson, content)

    messages = [
      Message.new(:system, """
      Identify zero to three simulation opportunities only when dynamic manipulation materially
      improves the approved Advanced experience. Ground every objective and evidence reference in
      the supplied contract. Return JSON: {"opportunities": [...]}. Do not design or code a simulation.
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
                    "Repair every finding and return the complete JSON object.",
                  "findings" => findings
                })
              )
            ]

        _ ->
          messages
      end

    execute(:simulation_opportunity_designer, messages, service, opts, :opportunity_execution_fun)
  end

  defp criticize(lesson, content, opportunities, service, opts) do
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
             service,
             opts,
             :opportunity_critic_fun
           ) do
      {:ok, criticism, usage}
    end
  end

  defp execute(phase, messages, service, opts, option_name) do
    execution = Keyword.get(opts, option_name, &Execution.generate_with_metadata/4)
    context = %{request_type: :generate, feature: @feature, phase: phase}

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
