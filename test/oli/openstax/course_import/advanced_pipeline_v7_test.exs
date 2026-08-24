defmodule Oli.OpenStax.CourseImport.AdvancedPipelineV7Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AdvancedPipelineV7
  alias Oli.OpenStax.CourseImport.V7Fixture, as: Fixture

  test "runs reviewed architecture then reviewed activities and persists checkpoints" do
    parent = self()

    execution = fn context, messages, _service -> provider_response(context, messages) end

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
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

    assert result.content_payload["schema_version"] == 7
    assert result.questions_payload == %{"items" => []}
    assert result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["confidence"] == 0.95
    assert_receive {:checkpoint, "advanced_content_approved", _}
    assert_receive {:checkpoint, "advanced_approved", _}
  end

  test "architect receives the rich connective-material contract without renderer authority" do
    parent = self()

    execution = fn context, messages, _service ->
      if context.phase == :advanced_experience_architect do
        send(parent, {:architect_system_prompt, hd(messages).content})
        send(parent, {:architect_contract, messages |> Enum.at(1) |> Map.fetch!(:content)})
      end

      provider_response(context, messages)
    end

    assert {:ok, _result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.97)}
               end,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end
             )

    assert_receive {:architect_system_prompt, prompt}
    assert prompt =~ "compact connective instruction"
    assert prompt =~ "source-grounded prediction"
    assert prompt =~ "native_follow_up_slot_id"
    assert prompt =~ "Do not emit rules"

    assert_receive {:architect_contract, encoded_contract}
    contract = Jason.decode!(encoded_contract)

    assert contract["required_guidance_kinds"] ==
             ~w(prediction observation interpretation transfer synthesis)

    assert "predict_observe_explain" in contract["allowed_presentation_patterns"]

    [slot_schema] = contract["experience_blueprint_schema"]["activity_slots"]
    assert Map.has_key?(slot_schema, "stage_id")
    assert Map.has_key?(slot_schema, "purpose")
    assert Map.has_key?(slot_schema, "recommended_types")
  end

  test "never falls back when the provider fails" do
    assert {:error, {:provider_failed, :advanced_experience_architect, :timeout}} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: fn _context, _messages, _service -> {:error, :timeout} end
             )
  end

  test "repairs a rejected architecture with the same role and converges" do
    Process.put(:content_review_count, 0)
    Process.put(:architect_count, 0)

    execution = fn context, messages, _service ->
      if architecture_request?(context, messages) do
        Process.put(:architect_count, Process.get(:architect_count, 0) + 1)
      end

      provider_response(context, messages)
    end

    content_critic = fn _lesson, _content, _service, _opts ->
      count = Process.get(:content_review_count, 0) + 1
      Process.put(:content_review_count, count)

      if count == 1,
        do: {:ok, rejected_review("weak_stage_transition")},
        else: {:ok, approved_review(0.96)}
    end

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: content_critic,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end
             )

    assert Process.get(:architect_count) == 2
    assert result.metadata["quality_gate"]["approved"]
    assert length(result.metadata["repair_history"]["experience"]) == 2
  end

  test "uses every repair round before repeated critic findings mark the lesson stalled" do
    Process.put(:activity_writer_called, false)
    Process.put(:architect_count, 0)

    execution = fn context, messages, _service ->
      if architecture_request?(context, messages) do
        Process.put(:architect_count, Process.get(:architect_count, 0) + 1)
      else
        Process.put(:activity_writer_called, true)
      end

      provider_response(context, messages)
    end

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, rejected_review("same_finding")}
               end
             )

    refute Process.get(:activity_writer_called)
    assert Process.get(:architect_count) == 2
    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"

    assert result.metadata["quality_gate"]["attention_reason"] ==
             "content_quality_re_review_failed"
  end

  test "guided regeneration edits the persisted architecture and activities" do
    parent = self()

    guided_lesson =
      Map.put(Fixture.lesson(), "repair_context", %{
        "previous_candidates" => %{
          "experience" => Fixture.architecture_candidate(),
          "activities" => Fixture.activity_candidate()
        },
        "phase_findings" => %{
          "experience" => [
            %{
              "severity" => "repair",
              "code" => "weak_transfer_stage",
              "path" => "$.experience_blueprint.stages[0]",
              "message" => "Strengthen the transfer stage."
            }
          ],
          "activities" => [
            %{
              "severity" => "repair",
              "code" => "duplicative_transfer_activity",
              "path" => "$.experience_blueprint.activities[2]",
              "message" => "Use a genuinely new transfer scenario."
            }
          ]
        }
      })

    execution = fn context, messages, _service ->
      previous_candidate = messages |> Enum.at(2) |> Map.fetch!(:content) |> Jason.decode!()
      repair_request = messages |> Enum.at(3) |> Map.fetch!(:content) |> Jason.decode!()

      if Map.has_key?(previous_candidate, "experience_blueprint") do
        assert previous_candidate == Fixture.architecture_candidate()
        assert [%{"code" => "weak_transfer_stage"}] = repair_request["critic_findings"]
        send(parent, :guided_experience_candidate_received)
      else
        assert previous_candidate == Fixture.activity_candidate()

        assert [%{"code" => "duplicative_transfer_activity"}] =
                 repair_request["critic_findings"]

        send(parent, :guided_activity_candidate_received)
      end

      provider_response(context, messages)
    end

    assert {:ok, result} =
             AdvancedPipelineV7.plan(guided_lesson, 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _, _, _, _ ->
                 {:ok, approved_review(0.97)}
               end,
               advanced_activity_critic_fun: fn _, _, _, _ ->
                 {:ok, approved_review(0.95)}
               end
             )

    assert result.metadata["quality_gate"]["approved"]
    assert_receive :guided_experience_candidate_received
    assert_receive :guided_activity_candidate_received
  end

  test "allows one full critic re-review after a bounded repair" do
    Process.put(:critic_attempt, 0)

    execution = fn context, messages, _service -> provider_response(context, messages) end

    critic = fn _lesson, _content, _service, _opts ->
      attempt = Process.get(:critic_attempt, 0) + 1
      Process.put(:critic_attempt, attempt)
      {:ok, rejected_review("finding_#{attempt}")}
    end

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: critic
             )

    assert Process.get(:critic_attempt) == 2

    assert result.metadata["quality_gate"]["attention_reason"] ==
             "content_quality_re_review_failed"
  end

  test "preserves server-owned source AST findings as advisories and continues activities" do
    Process.put(:architect_count, 0)
    Process.put(:activity_writer_called, false)

    execution = fn context, messages, _service ->
      case context.phase do
        :advanced_experience_architect ->
          Process.put(:architect_count, Process.get(:architect_count, 0) + 1)

        :advanced_activity_writer ->
          Process.put(:activity_writer_called, true)
      end

      provider_response(context, messages)
    end

    source_review =
      rejected_review("invalid_source_formula")
      |> put_in(
        ["findings", Access.at(0), "path"],
        "content_plan.content_groups[0].source_blocks[0].ast[0].src"
      )

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _, _, _, _ -> {:ok, source_review} end,
               advanced_activity_critic_fun: fn _, _, _, _ ->
                 {:ok, approved_review(0.95)}
               end
             )

    assert Process.get(:architect_count) == 1
    assert Process.get(:activity_writer_called)
    assert result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["attention_reason"] == nil

    assert [%{"code" => "invalid_source_formula", "source_owned" => true}] =
             result.metadata["quality_gate"]["advisories"]
  end

  test "low critic confidence cannot approve an otherwise valid candidate" do
    execution = fn context, messages, _service -> provider_response(context, messages) end

    low_confidence = %{approved_review(0.62) | "approved" => true, "gate_passed" => false}

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, low_confidence}
               end
             )

    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"
  end

  test "resumes from an accepted content checkpoint without rerunning architecture" do
    {:ok, content} =
      Oli.OpenStax.CourseImport.AdvancedPlanV7.build_architecture(
        Fixture.architecture_candidate(),
        Fixture.lesson(),
        1
      )

    Process.put(:architect_called, false)

    execution = fn context, messages, _service ->
      case context.phase do
        :advanced_experience_architect ->
          Process.put(:architect_called, true)
          {:ok, %{content: Jason.encode!(Fixture.architecture_candidate()), metadata: %{}}}

        :advanced_activity_writer ->
          :ok
      end

      provider_response(context, messages)
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
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v7_execution_fun: execution,
               advanced_activity_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.95)}
               end
             )

    refute Process.get(:architect_called)
    assert result.metadata["resume"]["experience"]
    assert result.metadata["quality_gate"]["approved"]
  end

  test "revalidates a repair checkpoint before spending another architect call" do
    Process.put(:architect_called, false)

    execution = fn context, messages, _service ->
      case context.phase do
        :advanced_experience_architect ->
          Process.put(:architect_called, true)
          flunk("a now-valid repair candidate should be reused")

        :advanced_activity_writer ->
          :ok
      end

      provider_response(context, messages)
    end

    checkpoint = %{
      "stage" => "advanced_content_repair_pending",
      "payload" => %{
        "repair_candidate" => Fixture.architecture_candidate(),
        "repair_findings" => [
          %{
            "code" => "contract_updated",
            "severity" => "hard_blocker",
            "message" => "Revalidate with the current deterministic contract."
          }
        ],
        "content_reviews" => [],
        "content_attempts" => [%{"attempt" => 1}],
        "next_attempt" => 2
      }
    }

    assert {:ok, result} =
             AdvancedPipelineV7.plan(Fixture.lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v7_execution_fun: execution,
               advanced_content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.96)}
               end,
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

  defp provider_response(context, messages) do
    candidate =
      case context.phase do
        :advanced_experience_architect ->
          Fixture.architecture_candidate()

        :advanced_activity_writer ->
          Fixture.activity_candidate()

        :repair_patch_writer ->
          previous = messages |> Enum.at(2) |> Map.fetch!(:content) |> Jason.decode!()

          if Map.has_key?(previous, "activities") do
            %{
              "patch" => [
                %{
                  "op" => "replace",
                  "path" => "/activities/0/context",
                  "value" => get_in(previous, ["activities", Access.at(0), "context"])
                }
              ]
            }
          else
            %{
              "patch" => [
                %{
                  "op" => "replace",
                  "path" => "/orientation/overview",
                  "value" => get_in(previous, ["orientation", "overview"])
                }
              ]
            }
          end
      end

    {:ok, %{content: Jason.encode!(candidate), metadata: %{phase: context.phase}}}
  end

  defp architecture_request?(%{phase: :advanced_experience_architect}, _messages), do: true

  defp architecture_request?(%{phase: :repair_patch_writer}, messages) do
    previous = messages |> Enum.at(2) |> Map.fetch!(:content) |> Jason.decode!()
    Map.has_key?(previous, "experience_blueprint")
  end

  defp architecture_request?(_context, _messages), do: false

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
