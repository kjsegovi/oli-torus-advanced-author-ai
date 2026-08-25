defmodule Oli.OpenStax.CourseImport.AIBackendTest do
  use ExUnit.Case, async: false

  alias Oli.OpenStax.CourseImport.{AIBackend, ModelRoutingPolicy}

  setup do
    original_env = Application.get_env(:oli, :env)
    original_enabled = Application.get_env(:oli, :openstax_codex_poc_enabled)
    original_url = Application.get_env(:oli, :openstax_codex_proxy_url)

    on_exit(fn ->
      restore_env(:env, original_env)
      restore_env(:openstax_codex_poc_enabled, original_enabled)
      restore_env(:openstax_codex_proxy_url, original_url)
    end)

    :ok
  end

  test "API is the independent default and local Codex requires dev, flag, and ChatGPT readiness" do
    Application.put_env(:oli, :env, :test)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)

    assert :ok = AIBackend.validate_start(:openai_api)
    assert {:error, :local_codex_disabled} = AIBackend.validate_start(:local_codex)

    Application.put_env(:oli, :env, :dev)

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

    base = AIBackend.service_config(:local_codex)
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

  test "non-loopback bridge URLs fail closed" do
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "https://codex.example.com")

    assert %{ready?: false, code: :non_loopback_url} = AIBackend.readiness()
  end

  defp restore_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_env(key, value), do: Application.put_env(:oli, key, value)
end
