defmodule Oli.OpenStax.CourseImport.AIPlannerV7Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oli.OpenStax.CourseImport.{AIBackend, AIPlanner}
  alias Oli.OpenStax.CourseImport.V7Fixture, as: Fixture

  setup do
    original_env = Application.get_env(:oli, :env)
    original_enabled = Application.get_env(:oli, :openstax_codex_poc_enabled)
    original_url = Application.get_env(:oli, :openstax_codex_proxy_url)
    original_token = Application.get_env(:oli, :openstax_codex_proxy_token)
    original_openai_key = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      restore_application_env(:env, original_env)
      restore_application_env(:openstax_codex_poc_enabled, original_enabled)
      restore_application_env(:openstax_codex_proxy_url, original_url)
      restore_application_env(:openstax_codex_proxy_token, original_token)
      restore_system_env("OPENAI_API_KEY", original_openai_key)
    end)
  end

  test "rejects every pre-v7 run before loading a provider" do
    assert {:error, {:unsupported_openstax_plan_schema, 4}} =
             AIPlanner.plan(Fixture.lesson(), 1,
               plan_schema_version: 4,
               service_config_loader: fn ->
                 flunk("legacy runs must stop before provider loading")
               end
             )
  end

  test "requires the deterministic current source AST" do
    assert {:error, {:current_source_ast_required, :start_a_new_import}} =
             AIPlanner.plan(%{"title" => "Missing AST", "source_blocks" => []}, 1,
               plan_schema_version: 7,
               service_config_loader: fn ->
                 flunk("missing source must stop before provider loading")
               end
             )

    assert {:error, {:current_source_ast_required, :start_a_new_import}} =
             AIPlanner.plan(
               %{"title" => "Old source", "source_blocks" => [%{"id" => "old", "text" => "x"}]},
               1,
               plan_schema_version: 7,
               service_config_loader: fn ->
                 flunk("legacy-shaped source must stop before provider loading")
               end
             )
  end

  test "resumed Local Codex planning fails before provider execution when runtime policy changes" do
    global_key = "synthetic-resume-openai-key-must-not-escape"
    bridge_token = "synthetic-resume-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    provider_request = fn _context, _messages, _functions, _service ->
      flunk("invalid Local Codex runtime policy must fail before any provider request")
    end

    invalid_policies = [
      {:disabled, :dev, false, "http://127.0.0.1:4001"},
      {:non_loopback_url, :dev, true, "https://codex.example.com"}
    ]

    for {reason, env, enabled, url} <- invalid_policies do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      log =
        capture_log(fn ->
          assert {:error, {:local_codex_configuration_error, ^reason}} =
                   AIPlanner.plan(
                     Fixture.lesson(),
                     1,
                     [
                       plan_schema_version: 7,
                       v7_execution_fun: provider_request,
                       v7_architect_execution_fun: provider_request
                     ] ++ AIBackend.planner_options(:local_codex)
                   )
        end)

      refute log =~ global_key
      refute log =~ bridge_token
    end
  end

  test "resumed Local Codex planning fails before provider execution when its token is gone" do
    global_key = "synthetic-resume-openai-key-must-not-escape"
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "http://127.0.0.1:4001")
    Application.put_env(:oli, :openstax_codex_proxy_token, "   ")
    System.put_env("OPENAI_API_KEY", global_key)

    provider_request = fn _context, _messages, _functions, _service ->
      flunk("missing bridge tokens must fail before any provider request")
    end

    log =
      capture_log(fn ->
        assert {:error, {:local_codex_configuration_error, :missing_proxy_token}} =
                 AIPlanner.plan(
                   Fixture.lesson(),
                   1,
                   [
                     plan_schema_version: 7,
                     v7_execution_fun: provider_request,
                     v7_architect_execution_fun: provider_request
                   ] ++ AIBackend.planner_options(:local_codex)
                 )
      end)

    refute log =~ global_key
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_application_env(key, value), do: Application.put_env(:oli, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
