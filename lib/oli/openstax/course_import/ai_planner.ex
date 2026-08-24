defmodule Oli.OpenStax.CourseImport.AIPlanner do
  @moduledoc """
  Hard-cutover OpenStax planner. Every run uses source schema 4 and plan schema 7,
  and every lesson is emitted through the shared Basic/Advanced content schema 7.
  No legacy schema reader, downgrade, or Advanced filler is available.
  """

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}
  alias Oli.GenAI.FeatureConfig

  alias Oli.OpenStax.CourseImport.{
    AdvancedPipelineV7,
    AdvancedSuitabilityV7,
    BasicPipelineV7,
    ImportContract,
    ModelRoutingPolicy,
    PlanTemplateCache,
    SimulationOpportunityPipeline
  }

  @feature :openstax_course_import
  @run_schema_version ImportContract.plan_schema_version()
  @default_openai_url "https://api.openai.com"
  @default_openai_model "gpt-5.6-luna"
  @default_openai_timeout 8_000
  @default_openai_receive_timeout 120_000

  @spec plan(map(), pos_integer(), keyword()) ::
          {:ok, %{plan_mode: String.t(), payload: map(), created_by: String.t(), metadata: map()}}
          | {:error, term()}
  def plan(lesson, index, opts \\ [])

  def plan(lesson, index, opts) when is_map(lesson) and is_integer(index) and index > 0 do
    with :ok <- require_current_run_schema(opts),
         :ok <- require_source_ast(lesson),
         {:ok, service_config} <- service_config(opts) do
      suitability = AdvancedSuitabilityV7.assess(lesson)

      if advanced_enabled?(opts) and suitability["candidate"] == true do
        plan_advanced(lesson, index, service_config, suitability, opts)
      else
        plan_basic(lesson, index, service_config, suitability, opts)
      end
    else
      {:error, {:missing_feature_config, _message} = reason} ->
        {:error, {:ai_configuration_failed, reason}}

      {:error, :not_configured} ->
        {:error, {:ai_configuration_failed, :not_configured}}

      {:error, _reason} = error ->
        error
    end
  end

  def plan(_, _, _), do: {:error, :invalid_lesson}

  defp plan_basic(lesson, index, service_config, suitability, opts) do
    services = basic_services(service_config, opts)

    with {:ok, result, _cache_status} <-
           PlanTemplateCache.fetch_or_generate(lesson, "basic", services, opts, fn ->
             BasicPipelineV7.plan(lesson, index, services, opts)
           end) do
      {:ok, planning_result("basic", result, suitability, [], %{})}
    else
      {:error, reason} -> {:error, {:ai_planning_failed, reason}}
    end
  end

  defp plan_advanced(lesson, index, service_config, suitability, opts) do
    services = advanced_services(service_config, opts)
    opts = Keyword.put(opts, :advanced_suitability, suitability)

    with {:ok, result, _cache_status} <-
           PlanTemplateCache.fetch_or_generate(lesson, "advanced", services, opts, fn ->
             AdvancedPipelineV7.plan(lesson, index, services, opts)
           end) do
      {opportunities, opportunity_metadata} =
        maybe_plan_simulation_opportunities(lesson, result, services, opts)

      {:ok,
       planning_result(
         "advanced",
         result,
         suitability,
         opportunities,
         opportunity_metadata
       )}
    else
      {:error, reason} -> {:error, {:ai_planning_failed, reason}}
    end
  end

  defp planning_result(mode, result, suitability, enrichment_proposals, opportunity_metadata) do
    %{
      plan_mode: mode,
      payload: %{
        "content_payload" => result.content_payload,
        "questions_payload" => result.questions_payload
      },
      enrichment_proposals: enrichment_proposals,
      created_by: "ai",
      metadata:
        result.metadata
        |> Map.put("suitability", suitability)
        |> Map.put("simulation_opportunities", opportunity_metadata)
    }
  end

  defp maybe_plan_simulation_opportunities(lesson, result, services, opts) do
    approved = get_in(result.metadata, ["quality_gate", "approved"]) == true

    enabled =
      Keyword.get(
        opts,
        :simulation_opportunities_enabled,
        Application.get_env(:oli, :openstax_generated_enrichment_enabled, false)
      )

    if approved and enabled do
      opportunity_services = %{designer: services.designer, critic: services.opportunity_critic}

      case SimulationOpportunityPipeline.plan(
             lesson,
             result.content_payload,
             opportunity_services,
             opts
           ) do
        {:ok, opportunities, metadata} -> {opportunities, Map.put(metadata, "status", "approved")}
        {:error, reason} -> {[], %{"status" => "omitted", "reason" => inspect(reason)}}
      end
    else
      {[], %{"status" => "not_requested"}}
    end
  end

  defp require_current_run_schema(opts) do
    case Keyword.get(opts, :plan_schema_version, @run_schema_version) do
      @run_schema_version -> :ok
      version -> {:error, {:unsupported_openstax_plan_schema, version}}
    end
  end

  defp require_source_ast(lesson) do
    blocks = source_blocks(lesson)

    if blocks != [] and
         Enum.all?(blocks, fn
           %{"id" => id, "ast" => ast} when is_binary(id) and is_list(ast) -> ast != []
           _block -> false
         end) do
      :ok
    else
      {:error, {:current_source_ast_required, :start_a_new_import}}
    end
  end

  defp source_blocks(lesson), do: lesson |> Map.get("source_blocks", []) |> List.wrap()

  defp advanced_enabled?(opts) do
    Keyword.get(
      opts,
      :advanced_enabled,
      Application.get_env(:oli, :openstax_advanced_pages_enabled, true)
    )
  end

  defp basic_services(%ServiceConfig{} = base, opts) do
    %{
      architect: ModelRoutingPolicy.service_config(base, :basic_content_architect, opts),
      critic: ModelRoutingPolicy.service_config(base, :basic_content_critic, opts),
      question_writer: ModelRoutingPolicy.service_config(base, :basic_question_writer, opts),
      question_critic: ModelRoutingPolicy.service_config(base, :basic_question_critic, opts)
    }
  end

  defp advanced_services(%ServiceConfig{} = base, opts) do
    %{
      architect: ModelRoutingPolicy.service_config(base, :advanced_experience_architect, opts),
      critic: ModelRoutingPolicy.service_config(base, :advanced_experience_critic, opts),
      activity_writer: ModelRoutingPolicy.service_config(base, :advanced_activity_writer, opts),
      activity_critic: ModelRoutingPolicy.service_config(base, :advanced_activity_critic, opts),
      designer: ModelRoutingPolicy.service_config(base, :simulation_opportunity_designer, opts),
      opportunity_critic:
        ModelRoutingPolicy.service_config(base, :simulation_opportunity_critic, opts)
    }
  end

  defp service_config(opts) do
    case Keyword.fetch(opts, :service_config_loader) do
      {:ok, loader} when is_function(loader, 0) ->
        loader.()

      :error ->
        loader =
          Keyword.get(opts, :feature_config_loader, fn ->
            FeatureConfig.load_for(nil, @feature)
          end)

        case loader.() do
          {:ok, %ServiceConfig{} = service_config} -> {:ok, service_config}
          {:error, {:missing_feature_config, _}} -> env_service_config(opts)
          {:error, :not_configured} -> env_service_config(opts)
          {:error, _} = error -> error
        end
    end
  end

  defp env_service_config(opts) do
    env = Keyword.get(opts, :env_getter, &System.get_env/1)

    case env.("OPENAI_API_KEY") |> blank_to_nil() do
      nil ->
        {:error, :not_configured}

      api_key ->
        model = %RegisteredModel{
          id: -1,
          name: "openstax-course-import-env",
          provider: :open_ai,
          model:
            env.("OPENSTAX_COURSE_IMPORT_OPENAI_MODEL") || env.("OPENAI_MODEL") ||
              @default_openai_model,
          url_template: env.("OPENAI_API_URL") || @default_openai_url,
          api_key: api_key,
          secondary_api_key: env.("OPENAI_ORG_KEY"),
          timeout:
            env_integer(
              env,
              "OPENSTAX_COURSE_IMPORT_OPENAI_TIMEOUT",
              env_integer(env, "OPENAI_TIMEOUT", @default_openai_timeout)
            ),
          recv_timeout:
            env_integer(
              env,
              "OPENSTAX_COURSE_IMPORT_OPENAI_RECV_TIMEOUT",
              env_integer(env, "OPENAI_RECV_TIMEOUT", @default_openai_receive_timeout)
            ),
          pool_class: :slow,
          routing_breaker_error_rate_threshold: 0.0,
          routing_breaker_429_threshold: 0.0,
          routing_breaker_latency_p95_ms: 0
        }

        {:ok,
         %ServiceConfig{
           id: -1,
           name: "openstax-course-import-env",
           primary_model: model,
           secondary_model: nil,
           backup_model: nil
         }}
    end
  end

  defp env_integer(env, name, default) do
    case env.(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil
end
