defmodule Oli.OpenStax.CourseImport.AIBackendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oli.OpenStax.CourseImport.{AIBackend, ModelRoutingPolicy}

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
    Application.put_env(:oli, :openstax_codex_proxy_token, token)

    assert {:ok, service} = AIBackend.service_config(:local_codex)
    assert service.primary_model.api_key == token
    refute capture_log(fn -> AIBackend.service_config(:local_codex) end) =~ token
  end

  test "all Local Codex service loaders fail closed without selecting a global OpenAI key" do
    global_key = "synthetic-global-openai-key-must-not-escape"
    error = {:local_codex_configuration_error, :missing_proxy_token}
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

  defp restore_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_env(key, value), do: Application.put_env(:oli, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
