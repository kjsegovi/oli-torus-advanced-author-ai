defmodule Oli.OpenStax.CourseImport.RuntimeConfigV7Test do
  use ExUnit.Case, async: false

  @advanced_env "OPENSTAX_ADVANCED_PAGES_ENABLED"
  @mix_env "MIX_ENV"

  setup do
    previous_advanced = System.get_env(@advanced_env)
    previous_mix_env = System.get_env(@mix_env)

    on_exit(fn ->
      restore_env(@advanced_env, previous_advanced)
      restore_env(@mix_env, previous_mix_env)
    end)

    :ok
  end

  test "the sole Advanced importer defaults on in local development" do
    System.delete_env(@advanced_env)
    System.put_env(@mix_env, "dev")

    assert runtime_advanced_enabled?(:dev)
  end

  test "an explicit environment setting overrides the development default" do
    System.put_env(@advanced_env, "false")
    System.put_env(@mix_env, "dev")

    refute runtime_advanced_enabled?(:dev)
  end

  test "the sole Advanced importer remains enabled outside local development" do
    System.delete_env(@advanced_env)
    System.put_env(@mix_env, "test")

    assert runtime_advanced_enabled?(:test)
  end

  defp runtime_advanced_enabled?(env) do
    config = Config.Reader.read!("config/runtime.exs", env: env, target: :host)
    get_in(config, [:oli, :openstax_advanced_pages_enabled])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
