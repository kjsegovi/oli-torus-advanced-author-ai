defmodule Oli.OpenStax.CourseImport.AIPlannerTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}
  alias Oli.OpenStax.CourseImport.{AIPlanner, Planner}

  test "Basic generation fails closed when the v5 rollout gate is disabled" do
    assert {:error, {:basic_v5_disabled, :feature_not_enabled}} =
             AIPlanner.plan(basic_lesson(), 1,
               plan_schema_version: 5,
               basic_v5_enabled: false,
               service_config_loader: fn ->
                 flunk("the provider must not be loaded while the rollout gate is closed")
               end
             )
  end

  test "legacy Basic runs cannot invoke a removed writer" do
    assert {:error, {:basic_v5_required, :start_a_new_import}} =
             AIPlanner.plan(basic_lesson(), 1,
               plan_schema_version: 4,
               basic_v5_enabled: true,
               service_config_loader: fn ->
                 flunk("legacy Basic runs must stop before provider configuration")
               end
             )
  end

  test "Basic v5 requires the deterministic source AST" do
    lesson = Map.put(basic_lesson(), "source_blocks", [])

    assert {:error, {:basic_v5_source_ast_required, :start_a_new_import}} =
             AIPlanner.plan(lesson, 1,
               plan_schema_version: 5,
               basic_v5_enabled: true,
               service_config_loader: fn ->
                 flunk("missing source AST must stop before provider configuration")
               end
             )
  end

  test "new Basic runs use only the v5 architect and critic pipeline" do
    candidate = %{
      "title" => "Algorithms",
      "orientation" => %{"overview" => "Read how precise procedures solve problems."},
      "content_groups" => [
        %{
          "id" => "algorithm-definition",
          "title" => "Precise procedures",
          "instructional_purpose" => "concept",
          "source_block_ids" => ["algorithm-definition"]
        }
      ],
      "question_slots" => [],
      "synthesis" => %{
        "summary" => "An algorithm specifies an ordered procedure.",
        "takeaways" => ["Algorithms use precise ordered steps."]
      }
    }

    assert {:ok, result} =
             AIPlanner.plan(basic_lesson(), 1,
               plan_schema_version: 5,
               basic_v5_enabled: true,
               service_config_loader: fn -> {:ok, service_config()} end,
               v5_architect_execution_fun: fn _request, messages, service ->
                 assert service.name == "openstax-v5-content-architect"
                 assert Enum.any?(messages, &(&1.role == :system))
                 {:ok, %{content: Jason.encode!(candidate), metadata: %{model: "terra"}}}
               end,
               content_critic_fun: fn _lesson, content, service, _opts ->
                 assert content["schema_version"] == 5
                 assert service.name == "openstax-v5-content-critic"
                 {:ok, approved_review()}
               end
             )

    assert result.plan_mode == "basic"
    assert result.created_by == "ai"
    assert result.payload["content_payload"]["schema_version"] == 5
    assert result.payload["content_payload"]["coverage_manifest"]["complete"]
    assert result.payload["questions_payload"] == %{"items" => []}
    assert result.metadata["pipeline"] == "openstax_basic_v5"
  end

  test "Basic v5 never falls back to deterministic content when AI is unavailable" do
    assert {:error,
            {:ai_configuration_failed, {:basic_question_agent_unavailable, :not_configured}}} =
             AIPlanner.plan(basic_lesson(), 1,
               plan_schema_version: 5,
               basic_v5_enabled: true,
               service_config_loader: fn -> {:error, :not_configured} end
             )
  end

  test "Advanced generation keeps its existing deterministic fallback" do
    assert {:ok, result} =
             AIPlanner.plan(advanced_lesson(), 1,
               plan_schema_version: 5,
               basic_v5_enabled: false,
               service_config_loader: fn -> {:error, :not_configured} end
             )

    assert result.plan_mode == "advanced"
    assert result.created_by == "system"
    assert result.metadata == %{strategy: :deterministic}
    assert result.payload["content_payload"]["schema_version"] == 4
  end

  test "Advanced provider failures remain visible" do
    assert {:error, {:ai_planning_failed, :timeout}} =
             AIPlanner.plan(advanced_lesson(), 1,
               plan_schema_version: 5,
               service_config_loader: fn -> {:ok, service_config()} end,
               execution_fun: fn _, _, _ -> {:error, :timeout} end
             )
  end

  test "Advanced response-contract failures use the visible deterministic fallback" do
    {_mode, payload} =
      Planner.build_lesson_plan(advanced_lesson(), 1, plan_schema_version: 5)

    invalid_response =
      payload
      |> Map.put("plan_mode", "advanced")
      |> put_in(["content_payload", "advanced_blueprint"], %{
        "screens" => [],
        "remediation_paths" => []
      })

    assert {:ok, result} =
             AIPlanner.plan(advanced_lesson(), 1,
               plan_schema_version: 5,
               service_config_loader: fn -> {:ok, service_config()} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(invalid_response), metadata: %{model: "test"}}}
               end
             )

    assert result.plan_mode == "advanced"
    assert result.created_by == "system"
    assert result.payload["content_payload"]["schema_version"] == 4

    assert result.metadata == %{
             strategy: :deterministic,
             fallback_from: :invalid_ai_response_contract,
             fallback_reason: :invalid_instructional_section
           }
  end

  defp basic_lesson do
    %{
      "title" => "Algorithms",
      "source_excerpt" => "Algorithms are precise procedures for solving problems.",
      "source_sections" => ["https://openstax.org/books/test/pages/algorithms"],
      "source_evidence_links" => ["https://openstax.org/books/test/pages/algorithms"],
      "source_objectives" => ["Define an algorithm"],
      "source_blocks" => [
        %{
          "id" => "algorithm-definition",
          "kind" => "paragraph",
          "text" => "An algorithm is a precise sequence of steps for solving a problem.",
          "ast" => [
            %{
              "type" => "p",
              "children" => [
                %{"text" => "An algorithm is a precise sequence of steps for solving a problem."}
              ]
            }
          ]
        }
      ],
      "source_media" => []
    }
  end

  defp advanced_lesson do
    %{
      "title" => "Choose an algorithm",
      "source_excerpt" =>
        "Compare alternative strategies for a constrained scenario and justify the tradeoff.",
      "source_sections" => ["https://openstax.org/books/test/pages/choose-an-algorithm"],
      "source_evidence_links" => [
        "https://openstax.org/books/test/pages/choose-an-algorithm"
      ],
      "source_objectives" => ["Compare algorithmic strategies and select one for a scenario"],
      "source_blocks" => [
        %{
          "id" => "algorithm-scenario",
          "kind" => "exercise",
          "text" =>
            "Choose between two strategies for this scenario and justify the decision using the stated constraint."
        }
      ]
    }
  end

  defp service_config do
    model = %RegisteredModel{
      id: 1,
      name: "test-model",
      provider: :open_ai,
      model: "test-model",
      url_template: "https://example.invalid",
      api_key: "test"
    }

    %ServiceConfig{id: 1, name: "test-service", primary_model: model}
  end

  defp approved_review do
    %{
      "approved" => true,
      "gate_passed" => true,
      "confidence" => 0.96,
      "threshold" => 0.9,
      "findings" => [],
      "hard_blocker_count" => 0,
      "repair_count" => 0,
      "advisory_count" => 0,
      "summary" => "Approved",
      "model_usage" => %{}
    }
  end
end
