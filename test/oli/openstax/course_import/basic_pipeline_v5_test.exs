defmodule Oli.OpenStax.CourseImport.BasicPipelineV5Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.BasicPipelineV5

  test "persists accepted content and question checkpoints with independent critic approval" do
    parent = self()

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: architect_fun(valid_candidate()),
               content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.96)}
               end,
               question_agent_fun: fn _lesson, _content, _service, _opts ->
                 {:ok,
                  %{
                    questions_payload: questions(),
                    generation_metadata: %{"model" => "terra-question-writer"}
                  }}
               end,
               question_critic_fun: fn _lesson, _content, _questions, ledger, _service, _opts ->
                 assert ledger == [%{"objective_id" => "prior-objective"}]
                 {:ok, approved_review(0.94)}
               end,
               objective_ledger: [%{"objective_id" => "prior-objective"}],
               checkpoint_fun: fn stage, payload ->
                 send(parent, {:checkpoint, stage, payload})
                 :ok
               end
             )

    assert result.content_payload["schema_version"] == 5
    assert result.questions_payload == questions()
    assert result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["confidence"] == 0.94

    assert_receive {:checkpoint, "content_approved",
                    %{"content_payload" => %{"schema_version" => 5}}}

    assert_receive {:checkpoint, "questions_approved",
                    %{"questions_payload" => %{"items" => [_]}}}
  end

  test "returns repaired content when the original architect resolves structured findings" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    execution_fun = fn _context, _messages, _service ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      candidate = if attempt == 1, do: invalid_candidate(), else: valid_candidate([])

      {:ok,
       %{
         content: Jason.encode!(candidate),
         metadata: %{attempt: attempt}
       }}
    end

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: execution_fun,
               content_critic_fun: fn _lesson, _content, _service, _opts ->
                 {:ok, approved_review(0.97)}
               end,
               checkpoint_fun: fn stage, payload ->
                 send(parent, {:checkpoint, stage, payload})
                 :ok
               end
             )

    assert_receive {:checkpoint, "content_repair_pending",
                    %{
                      "next_attempt" => 2,
                      "repair_candidate" => %{},
                      "repair_findings" => [_ | _]
                    }}

    assert length(result.metadata["repair_history"]["content"]) == 2
    assert Enum.map(result.metadata["content_reviews"], & &1["attempt"]) == [1, 2]
    assert result.questions_payload == %{"items" => []}
  end

  test "stops early when deterministic hard blockers repeat without measurable progress" do
    assert {:error, {:content_quality_stalled, failure}} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: architect_fun(invalid_candidate())
             )

    assert failure["attempts"] == 2
    assert Enum.any?(failure["findings"], &(&1["severity"] == "hard_blocker"))
    assert length(failure["review_history"]) == 2
  end

  test "resumes an accepted questions checkpoint without invoking any specialist" do
    checkpoint = %{
      "stage" => "questions_approved",
      "payload" => %{
        "content_payload" => accepted_content(),
        "content_reviews" => [approved_review(0.95)],
        "content_attempts" => [%{"attempt" => 1}],
        "questions_payload" => questions(),
        "question_reviews" => [approved_review(0.93)],
        "question_attempts" => [%{"attempt" => 1}],
        "writer_metadata" => %{"model" => "terra-question-writer"}
      }
    }

    reject = fn _context, _messages, _service -> flunk("architect should not run") end

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v5_architect_execution_fun: reject,
               question_agent_fun: fn _, _, _, _ -> flunk("question writer should not run") end,
               content_critic_fun: fn _, _, _, _ -> flunk("content critic should not run") end,
               question_critic_fun: fn _, _, _, _, _, _ ->
                 flunk("question critic should not run")
               end
             )

    assert result.metadata["resume"] == %{"content" => true, "questions" => true}
    assert result.metadata["quality_gate"]["approved"]
  end

  test "resumes a durable question-attention checkpoint without invoking specialists" do
    repair = repair_review("feedback-consistency")

    checkpoint = %{
      "stage" => "quality_attention",
      "payload" => %{
        "content_payload" => accepted_content(),
        "content_reviews" => [approved_review(0.96)],
        "content_attempts" => [%{"attempt" => 1}],
        "questions_payload" => questions(),
        "question_reviews" => [repair],
        "question_attempts" => [%{"attempt" => 4}],
        "writer_metadata" => %{"model" => "terra-question-writer"},
        "needs_attention" => true,
        "attention_reason" => "question_quality_exhausted"
      }
    }

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v5_architect_execution_fun: fn _, _, _ -> flunk("architect should not run") end,
               question_agent_fun: fn _, _, _, _ -> flunk("question writer should not run") end,
               content_critic_fun: fn _, _, _, _ -> flunk("content critic should not run") end,
               question_critic_fun: fn _, _, _, _, _, _ ->
                 flunk("question critic should not run")
               end
             )

    assert result.questions_payload == questions()
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"

    assert result.metadata["quality_gate"]["attention_reason"] ==
             "question_quality_exhausted"

    assert result.metadata["resume"] == %{"content" => true, "questions" => true}
  end

  test "resumes the original question writer from a durable repair checkpoint" do
    parent = self()

    repair_review = %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.88,
      "findings" => [
        %{
          "severity" => "repair",
          "code" => "imprecise_feedback",
          "path" => "$.items[0].incorrect_feedback",
          "message" => "Anchor the feedback to the evidence group."
        }
      ]
    }

    checkpoint = %{
      "stage" => "question_repair_pending",
      "payload" => %{
        "content_payload" => accepted_content(),
        "content_reviews" => [approved_review(0.96)],
        "content_attempts" => [%{"attempt" => 1}],
        "questions_payload" => questions(),
        "question_reviews" => [repair_review],
        "question_attempts" => [%{"attempt" => 1}],
        "writer_metadata" => %{"model" => "terra-question-writer"},
        "repair_findings" => repair_review["findings"],
        "previous_fingerprint" => "prior-review-fingerprint",
        "next_attempt" => 2
      }
    }

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               generation_checkpoint: checkpoint,
               v5_architect_execution_fun: fn _, _, _ -> flunk("architect should not run") end,
               content_critic_fun: fn _, _, _, _ -> flunk("content critic should not run") end,
               question_agent_fun: fn _lesson, _content, _service, opts ->
                 assert opts[:previous_questions_payload] == questions()
                 assert opts[:critic_findings] == repair_review["findings"]

                 {:ok,
                  %{
                    questions_payload: questions(),
                    generation_metadata: %{"model" => "same-terra-question-writer"}
                  }}
               end,
               question_critic_fun: fn _, _, _, _, _, _ ->
                 {:ok, approved_review(0.95)}
               end,
               checkpoint_fun: fn stage, payload ->
                 send(parent, {:checkpoint, stage, payload})
                 :ok
               end
             )

    assert result.metadata["resume"] == %{"content" => true, "questions" => true}
    refute_receive {:checkpoint, "content_approved", _payload}

    assert_receive {:checkpoint, "questions_approved",
                    %{"questions_payload" => %{"items" => [_]}}}
  end

  test "allows three question repair rounds after the initial candidate" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: architect_fun(valid_candidate()),
               content_critic_fun: fn _, _, _, _ -> {:ok, approved_review(0.97)} end,
               question_agent_fun: fn _lesson, _content, _service, _opts ->
                 Agent.update(counter, &(&1 + 1))

                 {:ok,
                  %{
                    questions_payload: questions(),
                    generation_metadata: %{"model" => "terra-question-writer"}
                  }}
               end,
               question_critic_fun: fn _, _, _, _, _, _ ->
                 attempt = Agent.get(counter, & &1)

                 if attempt == 4,
                   do: {:ok, approved_review(0.97)},
                   else: {:ok, repair_review("repair-#{attempt}")}
               end
             )

    assert result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "approved"
    assert length(result.metadata["repair_history"]["questions"]) == 4
    assert Agent.get(counter, & &1) == 4
  end

  test "preserves a semantically valid question plan for attention after repair exhaustion" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: architect_fun(valid_candidate()),
               content_critic_fun: fn _, _, _, _ -> {:ok, approved_review(0.97)} end,
               question_agent_fun: fn _lesson, _content, _service, _opts ->
                 Agent.update(counter, &(&1 + 1))

                 {:ok,
                  %{
                    questions_payload: questions(),
                    generation_metadata: %{"model" => "terra-question-writer"}
                  }}
               end,
               question_critic_fun: fn _, _, _, _, _, _ ->
                 {:ok, repair_review("repair-#{Agent.get(counter, & &1)}")}
               end,
               checkpoint_fun: fn stage, payload ->
                 send(parent, {:checkpoint, stage, payload})
                 :ok
               end
             )

    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"

    assert result.metadata["quality_gate"]["attention_reason"] ==
             "question_quality_exhausted"

    assert [%{"code" => "repair-4"}] = result.metadata["quality_gate"]["repairs"]
    assert result.questions_payload == questions()
    assert length(result.metadata["repair_history"]["questions"]) == 4

    assert_receive {:checkpoint, "quality_attention",
                    %{
                      "needs_attention" => true,
                      "attention_reason" => "question_quality_exhausted"
                    }}
  end

  test "preserves valid source content and defers questions when content repairs exhaust" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    assert {:ok, result} =
             BasicPipelineV5.plan(lesson(), 1, services(),
               v5_architect_execution_fun: architect_fun(valid_candidate()),
               content_critic_fun: fn _, _, _, _ ->
                 attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
                 {:ok, repair_review("content-repair-#{attempt}")}
               end,
               question_agent_fun: fn _, _, _, _ ->
                 flunk("questions must wait for content critic approval")
               end
             )

    refute result.metadata["quality_gate"]["approved"]
    assert result.metadata["quality_gate"]["outcome"] == "needs_attention"

    assert result.metadata["quality_gate"]["attention_reason"] ==
             "content_quality_exhausted"

    assert result.content_payload["coverage_manifest"]["complete"]
    assert result.questions_payload == %{"items" => []}
    assert length(result.metadata["repair_history"]["content"]) == 4
  end

  defp lesson do
    %{
      "title" => "The Nature of Science",
      "source_objectives" => ["Explain how evidence changes scientific explanations."],
      "source_evidence_links" => ["https://openstax.org/books/chemistry-2e/pages/1-2"],
      "source_blocks" => [
        %{
          "id" => "heading-1",
          "kind" => "heading",
          "text" => "The Nature of Science",
          "ast" => [%{"type" => "h2", "children" => [%{"text" => "The Nature of Science"}]}]
        },
        %{
          "id" => "paragraph-1",
          "kind" => "paragraph",
          "text" => "New evidence can change scientific explanations.",
          "ast" => [
            %{
              "type" => "p",
              "children" => [%{"text" => "New evidence can change scientific explanations."}]
            }
          ]
        }
      ],
      "source_media" => [],
      "attribution" => %{"provider" => "OpenStax", "license" => "CC BY 4.0"}
    }
  end

  defp valid_candidate(question_slots \\ nil) do
    %{
      "title" => "The Nature of Science",
      "orientation" => %{"overview" => "Examine how scientific knowledge develops."},
      "content_groups" => [
        %{
          "id" => "evidence",
          "title" => "Evidence and revision",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["heading-1", "paragraph-1"]
        }
      ],
      "question_slots" =>
        question_slots ||
          [
            %{
              "id" => "checkpoint-evidence",
              "purpose" => "check_understanding",
              "placement_after_group_id" => "evidence",
              "objective_ids" => ["objective-1"],
              "evidence_block_ids" => ["paragraph-1"],
              "recommended_types" => ["short_answer"]
            }
          ],
      "synthesis" => %{
        "summary" => "Scientific explanations remain open to revision.",
        "takeaways" => ["Evidence can change an explanation."]
      }
    }
  end

  defp invalid_candidate do
    %{
      "content_groups" => [
        %{
          "id" => "evidence",
          "title" => "Evidence",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["heading-1"]
        }
      ],
      "question_slots" => []
    }
  end

  defp accepted_content do
    {:ok, content} =
      Oli.OpenStax.CourseImport.BasicPlanV5.build(valid_candidate(), lesson(), 1)

    content
  end

  defp questions do
    %{
      "items" => [
        %{
          "type" => "short_answer",
          "prompt" => "How can new evidence affect a scientific explanation?",
          "answer_keywords" => ["change", "revise"],
          "placement_after_section_id" => "evidence",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["paragraph-1"],
          "hint" => "Review how explanations respond to evidence.",
          "correct_feedback" => "Yes. New evidence can support revising an explanation.",
          "incorrect_feedback" => "Revisit the evidence and revision content group."
        }
      ]
    }
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

  defp repair_review(code) do
    %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.96,
      "threshold" => 0.9,
      "findings" => [
        %{
          "severity" => "repair",
          "code" => code,
          "path" => "$.questions_payload.items[0]",
          "message" => "Repair the remaining consistency issue."
        }
      ],
      "hard_blocker_count" => 0,
      "repair_count" => 1,
      "advisory_count" => 0,
      "summary" => "One repair remains.",
      "model_usage" => %{}
    }
  end

  defp architect_fun(candidate) do
    fn _context, _messages, _service ->
      {:ok, %{content: Jason.encode!(candidate), metadata: %{model: "terra-architect"}}}
    end
  end

  defp services do
    %{architect: %{}, critic: %{}, question_writer: %{}, question_critic: %{}}
  end
end
