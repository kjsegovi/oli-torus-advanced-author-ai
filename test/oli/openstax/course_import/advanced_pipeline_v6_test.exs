defmodule Oli.OpenStax.CourseImport.AdvancedPipelineV6Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AdvancedPipelineV6
  alias Oli.OpenStax.CourseImport.V6Fixture, as: Fixture

  test "runs reviewed architecture then reviewed activities and persists checkpoints" do
    parent = self()

    execution = fn context, _messages, _service ->
      candidate =
        case context.phase do
          :v6_experience_architect -> Fixture.architecture_candidate()
          :v6_activity_writer -> Fixture.activity_candidate()
        end

      {:ok, %{content: Jason.encode!(candidate), metadata: %{phase: context.phase}}}
    end

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.97)}
               end,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end,
               checkpoint_fun: fn stage, payload ->
                 send(parent, {:checkpoint, stage, payload})
                 :ok
               end
             )

    assert result.content_payload["schema_version"] == 6
    assert result.questions_payload == %{"items" => []}
    assert result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["confidence"] == 0.95
    assert_receive {:checkpoint, "advanced_content_approved", _}
    assert_receive {:checkpoint, "advanced_approved", _}
  end

  test "never falls back when the provider fails" do
    assert {:error, {:provider_failed, :v6_experience_architect, :timeout}} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: fn _context, _messages, _service -> {:error, :timeout} end
             )
  end

  test "repairs a rejected architecture with the same role and converges" do
    Process.put(:content_review_count, 0)
    Process.put(:architect_count, 0)

    execution = fn context, _messages, _service ->
      if context.phase == :v6_experience_architect do
        Process.put(:architect_count, Process.get(:architect_count, 0) + 1)
      end

      candidate =
        if context.phase == :v6_experience_architect,
          do: Fixture.architecture_candidate(),
          else: Fixture.activity_candidate()

      {:ok, %{content: Jason.encode!(candidate), metadata: %{phase: context.phase}}}
    end

    content_critic = fn _lesson, _content, _service, _opts ->
      count = Process.get(:content_review_count, 0) + 1
      Process.put(:content_review_count, count)

      if count == 1,
        do: {:ok, rejected_review("weak_stage_transition")},
        else: {:ok, approved_review(0.96)}
    end

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: execution,
               advanced_content_critic_fun: content_critic,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end
             )

    assert Process.get(:architect_count) == 2
    assert result.metadata["quality_gate"]["approved"]
    assert length(result.metadata["repair_history"]["experience"]) == 2
  end

  test "stops on repeated critic findings and marks the lesson needs attention" do
    Process.put(:activity_writer_called, false)

    execution = fn context, _messages, _service ->
      case context.phase do
        :v6_experience_architect ->
          {:ok, %{content: Jason.encode!(Fixture.architecture_candidate()), metadata: %{}}}

        :v6_activity_writer ->
          Process.put(:activity_writer_called, true)
          {:ok, %{content: Jason.encode!(Fixture.activity_candidate()), metadata: %{}}}
      end
    end

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, rejected_review("same_finding")}
               end
             )

    refute Process.get(:activity_writer_called)
    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"
    assert result.metadata["quality_gate"]["attention_reason"] == "content_quality_stalled"
  end

  test "allows the initial candidate plus three repairs before attention" do
    Process.put(:critic_attempt, 0)

    execution = fn context, _messages, _service ->
      candidate =
        if context.phase == :v6_experience_architect,
          do: Fixture.architecture_candidate(),
          else: Fixture.activity_candidate()

      {:ok, %{content: Jason.encode!(candidate), metadata: %{}}}
    end

    critic = fn _lesson, _content, _service, _opts ->
      attempt = Process.get(:critic_attempt, 0) + 1
      Process.put(:critic_attempt, attempt)
      {:ok, rejected_review("finding_#{attempt}")}
    end

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: execution,
               advanced_content_critic_fun: critic
             )

    assert Process.get(:critic_attempt) == 4
    assert result.metadata["quality_gate"]["attention_reason"] == "content_quality_exhausted"
  end

  test "low critic confidence cannot approve an otherwise valid candidate" do
    execution = fn context, _messages, _service ->
      candidate =
        if context.phase == :v6_experience_architect,
          do: Fixture.architecture_candidate(),
          else: Fixture.activity_candidate()

      {:ok, %{content: Jason.encode!(candidate), metadata: %{}}}
    end

    low_confidence = %{approved_review(0.62) | "approved" => true, "gate_passed" => false}

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               v6_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, low_confidence}
               end
             )

    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"
  end

  test "resumes from an accepted content checkpoint without rerunning architecture" do
    {:ok, content} =
      Oli.OpenStax.CourseImport.AdvancedPlanV6.build_architecture(
        Fixture.architecture_candidate(),
        Fixture.lesson(),
        1
      )

    Process.put(:architect_called, false)

    execution = fn context, _messages, _service ->
      case context.phase do
        :v6_experience_architect ->
          Process.put(:architect_called, true)
          {:ok, %{content: Jason.encode!(Fixture.architecture_candidate()), metadata: %{}}}

        :v6_activity_writer ->
          {:ok, %{content: Jason.encode!(Fixture.activity_candidate()), metadata: %{}}}
      end
    end

    checkpoint = %{
      "stage" => "advanced_content_approved",
      "payload" => %{
        "content_payload" => content,
        "content_reviews" => [approved_review(0.96)],
        "content_attempts" => [%{"attempt" => 1}]
      }
    }

    assert {:ok, result} =
             AdvancedPipelineV6.plan(Fixture.lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v6_execution_fun: execution,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end
             )

    refute Process.get(:architect_called)
    assert result.metadata["resume"]["experience"]
    assert result.metadata["quality_gate"]["approved"]
  end

  defp services do
    %{architect: %{}, critic: %{}, activity_writer: %{}, activity_critic: %{}}
  end

  defp approved_review(confidence) do
    %{
      "approved" => true,
      "gate_passed" => true,
      "confidence" => confidence,
      "threshold" => 0.9,
      "findings" => [],
      "hard_blocker_count" => 0,
      "repair_count" => 0,
      "advisory_count" => 0,
      "summary" => "Approved",
      "model_usage" => %{}
    }
  end

  defp rejected_review(code) do
    %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.92,
      "threshold" => 0.9,
      "findings" => [
        %{
          "severity" => "repair",
          "code" => code,
          "path" => "$.experience_blueprint.stages",
          "message" => "Repair this finding."
        }
      ],
      "hard_blocker_count" => 0,
      "repair_count" => 1,
      "advisory_count" => 0,
      "summary" => "Repair required",
      "model_usage" => %{}
    }
  end
end
