defmodule Oli.OpenStax.CourseImport.AIBackendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oli.OpenStax.CourseImport.{
    AIBackend,
    EnrichmentProposal,
    EnrichmentResearchSet,
    ModelRoutingPolicy
  }

  alias Oli.OpenStax.CourseImport.Enrichment.SimulationSpecDesigner

  setup do
    original_env = Application.get_env(:oli, :env)
    original_enabled = Application.get_env(:oli, :openstax_codex_poc_enabled)
    original_url = Application.get_env(:oli, :openstax_codex_proxy_url)
    original_token = Application.get_env(:oli, :openstax_codex_proxy_token)
    original_openai_key = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      restore_env(:env, original_env)
      restore_env(:openstax_codex_poc_enabled, original_enabled)
      restore_env(:openstax_codex_proxy_url, original_url)
      restore_env(:openstax_codex_proxy_token, original_token)
      restore_system_env("OPENAI_API_KEY", original_openai_key)
    end)

    :ok
  end

  test "API is the independent default and local Codex requires dev, flag, and ChatGPT readiness" do
    Application.put_env(:oli, :env, :test)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)

    assert :ok = AIBackend.validate_start(:openai_api)
    assert {:error, :local_codex_disabled} = AIBackend.validate_start(:local_codex)

    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_proxy_token, "runtime-bridge-token")

    assert {:error, {:local_codex_unavailable, :not_authenticated}} =
             AIBackend.validate_start(:local_codex,
               request_fun: fn _url ->
                 {:ok, 503, Jason.encode!(%{ok: false, code: "not_authenticated"})}
               end
             )

    assert :ok =
             AIBackend.validate_start(:local_codex,
               request_fun: fn _url ->
                 {:ok, 200, Jason.encode!(%{ok: true, auth_method: "chatgpt"})}
               end
             )
  end

  test "local service is loopback-only and preserves Codex aliases through roles and escalation" do
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "http://127.0.0.1:4001")
    Application.put_env(:oli, :openstax_codex_proxy_token, "runtime-bridge-token")

    assert {:ok, base} = AIBackend.service_config(:local_codex)
    assert base.primary_model.model == "codex-proxy/gpt-5.6-terra"
    assert base.primary_model.max_concurrent == 1

    terra = ModelRoutingPolicy.service_config(base, :basic_content_architect)
    sol = ModelRoutingPolicy.service_config(base, :basic_content_critic)

    luna =
      ModelRoutingPolicy.service_config(base, :basic_question_writer,
        env_getter: fn
          "OPENSTAX_V7_LUNA_ROLES" -> "basic_question_writer"
          _ -> nil
        end
      )

    assert terra.primary_model.model == "codex-proxy/gpt-5.6-terra"
    assert sol.primary_model.model == "codex-proxy/gpt-5.6-sol"
    assert luna.primary_model.model == "codex-proxy/gpt-5.6-luna"

    assert ModelRoutingPolicy.escalate_to_terra(luna, :repair_patch_writer).primary_model.model ==
             "codex-proxy/gpt-5.6-terra"

    assert AIBackend.logical_provider(sol.primary_model.model, :open_ai) == "codex_cli"
    assert AIBackend.billing_source(sol.primary_model.model) == "chatgpt_plan"
  end

  test "persisted Local Codex spec generation stops before provider execution when runtime policy changes" do
    global_key = "synthetic-spec-openai-key-must-not-escape"
    bridge_token = "synthetic-spec-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    for {reason, env, enabled, url} <- invalid_runtime_policies() do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      execution = fn _context, _messages, _functions, _service ->
        flunk("invalid Local Codex runtime policy must stop before spec provider execution")
      end

      result =
        with {:ok, services} <- AIBackend.simulation_spec_services(:local_codex) do
          SimulationSpecDesigner.generate(
            %EnrichmentProposal{},
            %EnrichmentResearchSet{},
            services: services,
            spec_execution_fun: execution,
            spec_critic_fun: execution
          )
        end

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "persisted Local Codex generation stops before provider execution when runtime policy changes" do
    global_key = "synthetic-generation-openai-key-must-not-escape"
    bridge_token = "synthetic-generation-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    for {reason, env, enabled, url} <- invalid_runtime_policies() do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      result =
        with {:ok, _backend_opts} <- AIBackend.generator_options(:local_codex) do
          flunk(
            "invalid Local Codex runtime policy must stop before generation provider execution"
          )
        end

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "persisted Local Codex critic stops before provider execution when runtime policy changes" do
    global_key = "synthetic-critic-openai-key-must-not-escape"
    bridge_token = "synthetic-critic-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    for {reason, env, enabled, url} <- invalid_runtime_policies() do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      result =
        with {:ok, _backend_opts} <- AIBackend.artifact_critic_options(:local_codex) do
          flunk("invalid Local Codex runtime policy must stop before critic provider execution")
        end

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "direct Local Codex service configuration rejects invalid runtime policy" do
    global_key = "synthetic-direct-service-openai-key-must-not-escape"
    bridge_token = "synthetic-direct-service-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    for {reason, env, enabled, url} <- invalid_runtime_policies() do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      result = AIBackend.service_config(:local_codex)

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "direct Local Codex research configuration rejects invalid runtime policy" do
    global_key = "synthetic-direct-research-openai-key-must-not-escape"
    bridge_token = "synthetic-direct-research-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    for {reason, env, enabled, url} <- invalid_runtime_policies() do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      result = AIBackend.research_options(:local_codex)

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "missing or blank bridge tokens make enabled Local Codex unavailable" do
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)

    for token <- [nil, "", "   "] do
      restore_env(:openstax_codex_proxy_token, token)

      assert %{ready?: false, code: :missing_proxy_token} =
               AIBackend.readiness(
                 request_fun: fn _url, _headers ->
                   flunk("readiness must fail before contacting an unauthenticated bridge")
                 end
               )
    end
  end

  test "readiness authenticates with the runtime bridge token" do
    token = "readiness-runtime-token"
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_token, token)

    assert %{ready?: true} =
             AIBackend.readiness(
               request_fun: fn url, headers ->
                 assert url == "http://127.0.0.1:4001/health"
                 assert {"Authorization", "Bearer #{token}"} in headers
                 {:ok, 200, Jason.encode!(%{ok: true, auth_method: "chatgpt"})}
               end
             )
  end

  test "local service config uses the runtime bridge token without logging it" do
    token = "service-runtime-token"
    configure_local_codex(token)

    assert {:ok, service} = AIBackend.service_config(:local_codex)
    assert service.primary_model.api_key == token
    refute capture_log(fn -> AIBackend.service_config(:local_codex) end) =~ token
  end

  test "all Local Codex service loaders fail closed without selecting a global OpenAI key" do
    global_key = "synthetic-global-openai-key-must-not-escape"
    error = {:local_codex_configuration_error, :missing_proxy_token}
    configure_local_codex("temporary-bridge-token")
    System.put_env("OPENAI_API_KEY", global_key)

    for token <- [nil, "", "   "] do
      restore_env(:openstax_codex_proxy_token, token)

      log =
        capture_log(fn ->
          assert {:error, ^error} = AIBackend.service_config(:local_codex)
          assert {:error, ^error} = AIBackend.simulation_spec_services(:local_codex)
          assert {:error, ^error} = AIBackend.generator_options(:local_codex)
          assert {:error, ^error} = AIBackend.artifact_critic_options(:local_codex)
          assert {:error, ^error} = AIBackend.research_options(:local_codex)

          loader = AIBackend.planner_options(:local_codex)[:service_config_loader]
          assert {:error, ^error} = loader.()
        end)

      refute log =~ global_key
    end
  end

  test "non-loopback bridge URLs fail closed" do
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "https://codex.example.com")

    assert %{ready?: false, code: :non_loopback_url} = AIBackend.readiness()
  end

  defp configure_local_codex(token) do
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "http://127.0.0.1:4001")
    Application.put_env(:oli, :openstax_codex_proxy_token, token)
  end

  defp invalid_runtime_policies do
    [
      {:disabled, :dev, false, "http://127.0.0.1:4001"},
      {:non_loopback_url, :dev, true, "https://codex.example.com"}
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_env(key, value), do: Application.put_env(:oli, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
