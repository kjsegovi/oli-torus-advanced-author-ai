defmodule Oli.OpenStax.CourseImport.V7Fixture do
  def lesson do
    evidence =
      "Analyze quantitative data, compare competing models, calculate a ratio, and interpret the figure. " <>
        String.duplicate(
          "Record the measurement and evaluate the prediction against the evidence. ",
          110
        )

    %{
      "title" => "Quantitative evidence and competing models",
      "source_objectives" => ["Use quantitative evidence to compare two models."],
      "source_blocks" => [
        block("evidence", "paragraph", evidence),
        block(
          "investigation",
          "exercise",
          "First calculate the predicted value, then compare it with the observed data and justify a decision."
        )
      ],
      "source_media" => [
        media("figure-1", "evidence"),
        media("figure-2", "evidence"),
        media("figure-3", "evidence")
      ],
      "source_sections" => ["https://openstax.org/books/chemistry-2e/pages/1-4"],
      "source_evidence_links" => ["https://openstax.org/books/chemistry-2e/pages/1-4"]
    }
  end

  def architecture_candidate do
    slots =
      Enum.map(1..4, fn index ->
        %{
          "id" => "slot-#{index}",
          "stage_id" => if(index == 4, do: "synthesis-stage", else: "investigation"),
          "purpose" => "Use source evidence in investigation step #{index}.",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["evidence", "investigation"],
          "recommended_types" => ["multiple_choice"],
          "remediation_content_group_id" => "evidence-group",
          "estimated_minutes" => 10
        }
      end)

    %{
      "title" => "Quantitative evidence and competing models",
      "orientation" => %{
        "overview" => "Use measurements to decide which model better explains the evidence."
      },
      "content_groups" => [
        %{
          "id" => "evidence-group",
          "title" => "Evidence for the model decision",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["evidence"]
        },
        %{
          "id" => "investigation-group",
          "title" => "Apply the evidence to the decision",
          "instructional_purpose" => "application",
          "source_block_ids" => ["investigation"]
        }
      ],
      "question_slots" => [],
      "generated_alt_text" => [],
      "synthesis" => %{
        "heading" => "Synthesize the evidence",
        "summary" => "Use the data to revisit the driving question.",
        "takeaways" => ["Evidence distinguishes models."]
      },
      "experience_blueprint" => %{
        "driving_question" => "Which model is most consistent with the measured evidence?",
        "stages" => [
          %{
            "id" => "investigation",
            "title" => "Investigate and decide",
            "purpose" => "Move from prediction through transfer and synthesis.",
            "presentation_pattern" => "predict_observe_explain",
            "roles" =>
              ~w(orientation prediction investigation observation evidence interpretation transfer synthesis),
            "introduction" => %{
              "heading" => "Turn the model into a testable claim",
              "body" =>
                "Connect the source relationship to a prediction, then use the recorded measurements to decide which model is better supported.",
              "evidence_block_ids" => ["evidence", "investigation"]
            },
            "guidance" => rich_guidance(),
            "native_follow_up_slot_id" => "slot-3",
            "items" => [
              %{"kind" => "activity_slot", "ref_id" => "slot-1"},
              %{"kind" => "content_group", "ref_id" => "evidence-group"},
              %{"kind" => "content_group", "ref_id" => "investigation-group"},
              %{"kind" => "activity_slot", "ref_id" => "slot-2"},
              %{"kind" => "activity_slot", "ref_id" => "slot-3"}
            ]
          },
          %{
            "id" => "synthesis-stage",
            "title" => "Rejoin and synthesize",
            "purpose" => "Bring every evidence pathway back to a shared assessment.",
            "presentation_pattern" => "guided_reading",
            "roles" => ["synthesis"],
            "introduction" => %{
              "heading" => "Compare the pathways",
              "body" =>
                "Use the evidence from your selected pathway to answer the shared model question.",
              "evidence_block_ids" => ["evidence", "investigation"]
            },
            "guidance" => [],
            "native_follow_up_slot_id" => "slot-4",
            "items" => [%{"kind" => "activity_slot", "ref_id" => "slot-4"}]
          }
        ],
        "activity_slots" => slots,
        "branch_sets" => [
          %{
            "id" => "model-evidence-path",
            "decision_activity_slot_id" => "slot-1",
            "objective_ids" => ["objective-1"],
            "rejoin_stage_id" => "synthesis-stage",
            "pathways" => [
              %{
                "choice_id" => "supported",
                "label" => "Follow the matching-evidence path",
                "target_content_group_id" => "evidence-group",
                "feedback" => "Inspect where prediction and measurement agree.",
                "evidence_block_ids" => ["evidence"]
              },
              %{
                "choice_id" => "unsupported",
                "label" => "Investigate the conflicting-evidence path",
                "target_content_group_id" => "investigation-group",
                "feedback" => "Test why the measurements challenge the original model.",
                "evidence_block_ids" => ["investigation"]
              }
            ]
          }
        ]
      }
    }
  end

  def activity_candidate do
    %{
      "activities" =>
        Enum.map(1..4, fn index ->
          %{
            "id" => "activity-#{index}",
            "slot_id" => "slot-#{index}",
            "context" =>
              "The source table and figure compare a prediction with measured evidence.",
            "prompt" => "Which conclusion is supported in investigation step #{index}?",
            "interaction_type" => "multiple_choice",
            "choices" => [
              %{
                "id" => "supported",
                "text" => "Prefer the model whose prediction agrees with the measurements.",
                "correct" => true
              },
              %{
                "id" => "unsupported",
                "text" => "Ignore the measurements and keep the original model.",
                "correct" => false,
                "feedback" => "The decision must use the observed evidence."
              }
            ],
            "correct_feedback" => "The response connects the prediction to the measurement.",
            "incorrect_feedback" =>
              "Revisit the evidence group and compare predicted with observed values.",
            "allow_not_sure" => true,
            "hint" => "Look for agreement between the prediction and measurement.",
            "remediation_content_group_id" => "evidence-group",
            "objective_ids" => ["objective-1"],
            "evidence_block_ids" => ["evidence", "investigation"]
          }
        end)
    }
  end

  def rich_guidance do
    [
      %{
        "kind" => "prediction",
        "heading" => "Commit to a prediction",
        "body" =>
          "State which model should agree more closely with the measurement before comparing the values.",
        "evidence_block_ids" => ["evidence"]
      },
      %{
        "kind" => "observation",
        "heading" => "Record what the evidence shows",
        "body" =>
          "Record the predicted and observed values with their units, including any discrepancy.",
        "evidence_block_ids" => ["evidence", "investigation"]
      },
      %{
        "kind" => "interpretation",
        "heading" => "Explain the discrepancy",
        "body" =>
          "Use the direction and size of the discrepancy to explain which model is better supported.",
        "evidence_block_ids" => ["evidence", "investigation"]
      },
      %{
        "kind" => "transfer",
        "heading" => "Test a changed condition",
        "body" =>
          "Apply the same comparison when one measured condition changes and identify what remains invariant.",
        "evidence_block_ids" => ["evidence", "investigation"]
      },
      %{
        "kind" => "synthesis",
        "heading" => "Answer the driving question",
        "body" =>
          "Combine the calculation and measurement into a concise evidence-based model decision.",
        "evidence_block_ids" => ["evidence", "investigation"]
      }
    ]
  end

  defp block(id, kind, text),
    do: %{
      "id" => id,
      "kind" => kind,
      "text" => text,
      "ast" => [%{"type" => "p", "children" => [%{"text" => text}]}]
    }

  defp media(id, block_id),
    do: %{
      "id" => id,
      "source_block_id" => block_id,
      "alt" => "A source figure showing measured evidence.",
      "status" => "ready",
      "rights_status" => "approved",
      "required" => false
    }
end
