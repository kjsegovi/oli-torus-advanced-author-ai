defmodule Oli.OpenStax.CourseImport.RuntimeConfigV6Test do
  use ExUnit.Case, async: false

  @v6_env "OPENSTAX_ADVANCED_PAGES_V6_ENABLED"
  @mix_env "MIX_ENV"

  setup do
    previous_v6 = System.get_env(@v6_env)
    previous_mix_env = System.get_env(@mix_env)

    on_exit(fn ->
      restore_env(@v6_env, previous_v6)
      restore_env(@mix_env, previous_mix_env)
    end)

    :ok
  end

  test "Advanced v6 defaults on in local development" do
    System.delete_env(@v6_env)
    System.put_env(@mix_env, "dev")

    assert runtime_v6_enabled?(:dev)
  end

  test "an explicit environment setting overrides the development default" do
    System.put_env(@v6_env, "false")
    System.put_env(@mix_env, "dev")

    refute runtime_v6_enabled?(:dev)
  end

  test "Advanced v6 defaults off outside local development" do
    System.delete_env(@v6_env)
    System.put_env(@mix_env, "test")

    refute runtime_v6_enabled?(:test)
  end

  defp runtime_v6_enabled?(env) do
    config = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    get_in(config, [:oli, :openstax_advanced_pages_v6_enabled])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
