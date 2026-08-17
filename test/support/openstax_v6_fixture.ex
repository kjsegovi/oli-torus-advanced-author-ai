defmodule Oli.OpenStax.CourseImport.V6Fixture do
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
          "stage_id" => "investigation",
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
          "source_block_ids" => ["evidence", "investigation"]
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
            "roles" =>
              ~w(orientation prediction investigation evidence interpretation transfer synthesis),
            "items" =>
              [%{"kind" => "content_group", "ref_id" => "evidence-group"}] ++
                Enum.map(
                  1..4,
                  &%{"kind" => "activity_slot", "ref_id" => "slot-#{&1}"}
                )
          }
        ],
        "activity_slots" => slots
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
