defmodule Oli.OpenStax.CourseImport.AIPlanner do
  @moduledoc """
  Hard-cutover OpenStax planner. Every run uses plan schema 6 and every lesson
  is emitted as either source-faithful Basic schema 5 or reviewed Advanced
  schema 6. No legacy schema reader, downgrade, or Advanced filler is available.
  """

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}
  alias Oli.GenAI.FeatureConfig

  alias Oli.OpenStax.CourseImport.{
    AdvancedPipelineV6,
    AdvancedSuitabilityV6,
    BasicPipelineV5,
    SimulationOpportunityPipeline
  }

  @feature :openstax_course_import
  @run_schema_version 6
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
      suitability = AdvancedSuitabilityV6.assess(lesson)

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

    with {:ok, result} <- BasicPipelineV5.plan(lesson, index, services, opts) do
      {:ok, planning_result("basic", result, suitability, [], %{})}
    else
      {:error, reason} -> {:error, {:ai_planning_failed, reason}}
    end
  end

  defp plan_advanced(lesson, index, service_config, suitability, opts) do
    services = advanced_services(service_config, opts)
    opts = Keyword.put(opts, :advanced_suitability, suitability)

    with {:ok, result} <- AdvancedPipelineV6.plan(lesson, index, services, opts) do
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
      :advanced_v6_enabled,
      Application.get_env(:oli, :openstax_advanced_pages_v6_enabled, false)
    )
  end

  defp basic_services(%ServiceConfig{} = base, opts) do
    env = Keyword.get(opts, :env_getter, &System.get_env/1)

    %{
      architect:
        role_service_config(
          base,
          "basic-content-architect",
          env.("OPENSTAX_CONTENT_ARCHITECT_MODEL") || "gpt-5.6-terra"
        ),
      critic:
        role_service_config(
          base,
          "basic-content-critic",
          env.("OPENSTAX_CONTENT_CRITIC_MODEL") || "gpt-5.6-sol"
        ),
      question_writer:
        role_service_config(
          base,
          "basic-question-writer",
          env.("OPENSTAX_QUESTION_WRITER_MODEL") || "gpt-5.6-terra"
        ),
      question_critic:
        role_service_config(
          base,
          "basic-question-critic",
          env.("OPENSTAX_QUESTION_CRITIC_MODEL") || "gpt-5.6-sol"
        )
    }
  end

  defp advanced_services(%ServiceConfig{} = base, opts) do
    env = Keyword.get(opts, :env_getter, &System.get_env/1)

    %{
      architect:
        role_service_config(
          base,
          "advanced-experience-architect",
          env.("OPENSTAX_ADVANCED_ARCHITECT_MODEL") || "gpt-5.6-terra"
        ),
      critic:
        role_service_config(
          base,
          "advanced-experience-critic",
          env.("OPENSTAX_ADVANCED_CRITIC_MODEL") || "gpt-5.6-sol"
        ),
      activity_writer:
        role_service_config(
          base,
          "advanced-activity-writer",
          env.("OPENSTAX_ADVANCED_ACTIVITY_WRITER_MODEL") || "gpt-5.6-terra"
        ),
      activity_critic:
        role_service_config(
          base,
          "advanced-activity-critic",
          env.("OPENSTAX_ADVANCED_ACTIVITY_CRITIC_MODEL") || "gpt-5.6-sol"
        ),
      designer:
        role_service_config(
          base,
          "simulation-opportunity-designer",
          env.("OPENSTAX_SIMULATION_OPPORTUNITY_MODEL") || "gpt-5.6-terra"
        ),
      opportunity_critic:
        role_service_config(
          base,
          "simulation-opportunity-critic",
          env.("OPENSTAX_SIMULATION_OPPORTUNITY_CRITIC_MODEL") || "gpt-5.6-sol"
        )
    }
  end

  defp role_service_config(%ServiceConfig{} = service_config, role, model_name) do
    role_model = %{service_config.primary_model | name: "openstax-#{role}", model: model_name}

    %{
      service_config
      | name: "openstax-#{role}",
        primary_model: role_model,
        secondary_model: nil,
        backup_model: nil
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
