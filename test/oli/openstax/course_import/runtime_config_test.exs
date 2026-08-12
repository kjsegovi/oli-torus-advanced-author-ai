defmodule Oli.OpenStax.CourseImport.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @v5_env "OPENSTAX_BASIC_PAGES_V5_ENABLED"
  @mix_env "MIX_ENV"

  setup do
    previous_v5 = System.get_env(@v5_env)
    previous_mix_env = System.get_env(@mix_env)

    on_exit(fn ->
      restore_env(@v5_env, previous_v5)
      restore_env(@mix_env, previous_mix_env)
    end)

    :ok
  end

  test "Basic v5 defaults on in local development" do
    System.delete_env(@v5_env)
    System.put_env(@mix_env, "dev")

    assert runtime_v5_enabled?(:dev)
  end

  test "an explicit environment setting overrides the development default" do
    System.put_env(@v5_env, "false")
    System.put_env(@mix_env, "dev")

    refute runtime_v5_enabled?(:dev)
  end

  test "Basic v5 defaults off outside local development" do
    System.delete_env(@v5_env)
    System.put_env(@mix_env, "test")

    refute runtime_v5_enabled?(:test)
  end

  defp runtime_v5_enabled?(env) do
    config = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    get_in(config, [:oli, :openstax_basic_pages_v5_enabled])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
