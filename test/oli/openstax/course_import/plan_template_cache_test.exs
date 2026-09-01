defmodule Oli.OpenStax.CourseImport.PlanTemplateCacheTest do
  use Oli.DataCase, async: false

  alias Oli.OpenStax.CourseImport.{
    AdvancedPipelineV7,
    BasicPipelineV7,
    PlanTemplate,
    PlanTemplateCache,
    V7Fixture
  }

  alias Oli.Repo

  test "basic guided regeneration with string-keyed repair context bypasses an approved template" do
    lesson = basic_lesson()
    cached = basic_result(lesson)
    generated = put_in(cached, [:metadata, "generation"], "guided-basic")

    assert {:ok, _stored, :generated} =
             PlanTemplateCache.fetch_or_generate(lesson, "basic", basic_services(), [], fn ->
               {:ok, cached}
             end)

    guided_lesson =
      Map.put(lesson, "repair_context", %{"author_feedback" => "Strengthen evidence."})

    assert {:ok, ^generated, :generated} =
             PlanTemplateCache.fetch_or_generate(
               guided_lesson,
               "basic",
               basic_services(),
               [],
               fn ->
                 {:ok, generated}
               end
             )

    assert Repo.aggregate(PlanTemplate, :count) == 1
  end

  test "advanced guided regeneration with atom-keyed repair context bypasses lookup and storage" do
    lesson = V7Fixture.lesson()
    cached = advanced_result(lesson)
    generated = put_in(cached, [:metadata, "generation"], "guided-advanced")

    assert {:ok, _stored, :generated} =
             PlanTemplateCache.fetch_or_generate(
               lesson,
               "advanced",
               advanced_services(),
               [],
               fn ->
                 {:ok, cached}
               end
             )

    guided_lesson = Map.put(lesson, :repair_context, %{author_feedback: "Strengthen transfer."})

    assert {:ok, ^generated, :generated} =
             PlanTemplateCache.fetch_or_generate(
               guided_lesson,
               "advanced",
               advanced_services(),
               [],
               fn ->
                 {:ok, generated}
               end
             )

    assert Repo.aggregate(PlanTemplate, :count) == 1
  end

  test "pristine requests retain content-addressed template caching" do
    lesson = basic_lesson()
    cached = basic_result(lesson)

    assert {:ok, _stored, :generated} =
             PlanTemplateCache.fetch_or_generate(lesson, "basic", basic_services(), [], fn ->
               {:ok, cached}
             end)

    assert {:ok, result, :hit} =
             PlanTemplateCache.fetch_or_generate(lesson, "basic", basic_services(), [], fn ->
               flunk("pristine request should use the approved template")
             end)

    assert result.content_payload == cached.content_payload
  end

  test "false repair context remains a pristine cache request" do
    lesson = Map.put(basic_lesson(), :repair_context, false)
    cached = basic_result(lesson)

    assert {:ok, _stored, :generated} =
             PlanTemplateCache.fetch_or_generate(lesson, "basic", basic_services(), [], fn ->
               {:ok, cached}
             end)

    assert {:ok, _result, :hit} =
             PlanTemplateCache.fetch_or_generate(lesson, "basic", basic_services(), [], fn ->
               flunk("false repair context should retain the approved template cache")
             end)
  end

  defp basic_result(lesson) do
    assert {:ok, result} =
             BasicPipelineV7.plan(lesson, 1, basic_services(),
               v7_architect_execution_fun: fn _context, _messages, _service ->
                 {:ok, %{content: Jason.encode!(basic_candidate()), metadata: %{}}}
               end,
               content_critic_fun: fn _, _, _, _ -> {:ok, approved_review()} end,
               question_agent_fun: fn _, _, _, _ ->
                 {:ok, %{questions_payload: basic_questions(), generation_metadata: %{}}}
               end,
               question_critic_fun: fn _, _, _, _, _, _ -> {:ok, approved_review()} end
             )

    result
  end

  defp advanced_result(lesson) do
    assert {:ok, result} =
             AdvancedPipelineV7.plan(lesson, 1, advanced_services(),
               v7_execution_fun: fn context, _messages, _service ->
                 candidate =
                   case context.phase do
                     :advanced_experience_architect -> V7Fixture.architecture_candidate()
                     :advanced_activity_writer -> V7Fixture.activity_candidate()
                   end

                 {:ok, %{content: Jason.encode!(candidate), metadata: %{}}}
               end,
               advanced_content_critic_fun: fn _, _, _, _ -> {:ok, approved_review()} end,
               advanced_activity_critic_fun: fn _, _, _, _ -> {:ok, approved_review()} end
             )

    result
  end

  defp basic_services,
    do: %{architect: %{}, critic: %{}, question_writer: %{}, question_critic: %{}}

  defp advanced_services,
    do: %{architect: %{}, critic: %{}, activity_writer: %{}, activity_critic: %{}}

  defp basic_lesson do
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

  defp basic_candidate do
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
      "question_slots" => [
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

  defp basic_questions do
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
