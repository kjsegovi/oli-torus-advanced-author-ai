defmodule Oli.GoogleSlides.GenAITest do
  use Oli.DataCase, async: false

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}
  alias Oli.GenAI.FeatureConfig
  alias Oli.GoogleSlides.GenAI

  setup do
    Repo.delete_all(FeatureConfig)
    Repo.delete_all(ServiceConfig)
    Repo.delete_all(RegisteredModel)

    original_key = System.get_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn -> restore_env("OPENAI_API_KEY", original_key) end)
  end

  describe "configured?/0" do
    test "returns true when OPENAI_API_KEY is set" do
      original_key = System.get_env("OPENAI_API_KEY")

      on_exit(fn -> restore_env("OPENAI_API_KEY", original_key) end)

      System.put_env("OPENAI_API_KEY", "test-openai-key")

      assert GenAI.configured?()
    end

    test "returns false when OPENAI_API_KEY is blank and no service config is available" do
      original_key = System.get_env("OPENAI_API_KEY")

      on_exit(fn -> restore_env("OPENAI_API_KEY", original_key) end)

      System.delete_env("OPENAI_API_KEY")

      refute GenAI.configured?()
    end
  end

  describe "resolve_service_config/0 provider requirements" do
    for slot <- [:primary, :secondary, :backup],
        provider <- [:null, :claude] do
      @slot slot
      @provider provider

      test "rejects #{@provider} in the #{@slot} routing slot" do
        invalid_model = insert_model(@provider, "#{@slot}-#{@provider}")

        {primary, secondary, backup} =
          case @slot do
            :primary ->
              {invalid_model, nil, nil}

            :secondary ->
              {insert_model(:open_ai, "primary"), invalid_model, nil}

            :backup ->
              {insert_model(:open_ai, "primary"), nil, invalid_model}
          end

        configure_feature(primary, secondary, backup)

        assert {:error, :not_configured} = GenAI.resolve_service_config()
        refute GenAI.configured?()
      end
    end

    test "accepts an OpenAI primary with no fallback models" do
      primary = insert_model(:open_ai, "primary-only")
      service_config = configure_feature(primary)

      assert {:ok, resolved} = GenAI.resolve_service_config()
      assert resolved.id == service_config.id
      assert resolved.primary_model.provider == :open_ai
      assert is_nil(resolved.secondary_model)
      assert is_nil(resolved.backup_model)
    end

    test "accepts a service config when every populated routing slot is OpenAI" do
      primary = insert_model(:open_ai, "primary")
      secondary = insert_model(:open_ai, "secondary")
      backup = insert_model(:open_ai, "backup")
      service_config = configure_feature(primary, secondary, backup)

      assert {:ok, resolved} = GenAI.resolve_service_config()
      assert resolved.id == service_config.id
      assert resolved.primary_model.provider == :open_ai
      assert resolved.secondary_model.provider == :open_ai
      assert resolved.backup_model.provider == :open_ai
    end

    test "prefers the documented environment route over a generic seeded fallback" do
      original_model = System.get_env("GOOGLE_SLIDES_IMPORT_OPENAI_MODEL")
      fallback = insert_model(:open_ai, "generic-fallback")

      Repo.insert!(%ServiceConfig{
        name: "standard-no-backup",
        primary_model_id: fallback.id
      })

      System.put_env("OPENAI_API_KEY", "feature-env-key")
      System.put_env("GOOGLE_SLIDES_IMPORT_OPENAI_MODEL", "feature-env-model")

      on_exit(fn ->
        restore_env("GOOGLE_SLIDES_IMPORT_OPENAI_MODEL", original_model)
      end)

      assert {:ok, resolved} = GenAI.resolve_service_config()
      assert resolved.primary_model.name == "google-slides-import-env"
      assert resolved.primary_model.model == "feature-env-model"
      assert resolved.primary_model.api_key == "feature-env-key"
    end

    test "uses a longer receive timeout for slide planning and supports a feature override" do
      original_timeout = System.get_env("OPENAI_RECV_TIMEOUT")
      original_feature_timeout = System.get_env("GOOGLE_SLIDES_IMPORT_OPENAI_RECV_TIMEOUT")

      on_exit(fn ->
        restore_env("OPENAI_RECV_TIMEOUT", original_timeout)
        restore_env("GOOGLE_SLIDES_IMPORT_OPENAI_RECV_TIMEOUT", original_feature_timeout)
      end)

      System.put_env("OPENAI_API_KEY", "feature-env-key")
      System.delete_env("OPENAI_RECV_TIMEOUT")
      System.delete_env("GOOGLE_SLIDES_IMPORT_OPENAI_RECV_TIMEOUT")

      assert {:ok, default_route} = GenAI.resolve_service_config()
      assert default_route.primary_model.recv_timeout == 120_000
      assert default_route.primary_model.routing_breaker_error_rate_threshold == 0.0
      assert default_route.primary_model.routing_breaker_429_threshold == 0.0
      assert default_route.primary_model.routing_breaker_latency_p95_ms == 0

      System.put_env("GOOGLE_SLIDES_IMPORT_OPENAI_RECV_TIMEOUT", "180000")

      assert {:ok, overridden_route} = GenAI.resolve_service_config()
      assert overridden_route.primary_model.recv_timeout == 180_000
    end

    test "does not route course content through an arbitrary persisted model" do
      insert_model(:open_ai, "unassigned")

      assert {:error, :not_configured} = GenAI.resolve_service_config()
    end
  end

  describe "strip_code_fence/1" do
    test "removes json fences" do
      assert GenAI.strip_code_fence("```json\n{\"a\": 1}\n```") == "{\"a\": 1}"
    end
  end

  defp insert_model(provider, suffix) do
    Repo.insert!(%RegisteredModel{
      name: "google-slides-#{suffix}",
      provider: provider,
      model: "test-model",
      url_template: "https://example.test",
      api_key: "test-key"
    })
  end

  defp configure_feature(primary, secondary \\ nil, backup \\ nil) do
    service_config =
      Repo.insert!(%ServiceConfig{
        name: "google-slides-provider-test",
        primary_model_id: primary.id,
        secondary_model_id: secondary && secondary.id,
        backup_model_id: backup && backup.id
      })

    Repo.insert!(%FeatureConfig{
      feature: :google_slides_import,
      service_config_id: service_config.id
    })

    service_config
  end

  defp restore_env(name, value) do
    case value do
      nil -> System.delete_env(name)
      val -> System.put_env(name, val)
    end
  end
end
