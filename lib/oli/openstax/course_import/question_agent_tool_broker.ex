defmodule Oli.OpenStax.CourseImport.QuestionAgentToolBroker do
  @moduledoc """
  Scoped broker for OpenStax Basic question generation.

  It deliberately exposes no general authoring or mutation tools. The only
  mutation is persistence of a deterministically accepted whole-set draft.
  """

  @behaviour Oli.GenAI.Agent.Tool

  alias Oli.GenAI.Agent.Persistence
  alias Oli.OpenStax.CourseImport.QuestionAgentValidator

  @validate_and_submit_tool "validate_and_submit_openstax_questions"

  @spec describe() :: [map()]
  def describe do
    [
      %{
        name: @validate_and_submit_tool,
        desc:
          "Validate one complete Basic lesson question set and atomically persist it when valid. Invalid sets return bounded deterministic repair findings."
      }
    ]
  end

  @spec tools_for_completion() :: [map()]
  def tools_for_completion do
    Enum.map(describe(), fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.desc,
          parameters: candidate_schema()
        }
      }
    end)
  end

  @impl true
  def call(@validate_and_submit_tool, args, context) do
    validation = QuestionAgentValidator.validate(args, context)

    case validation.valid do
      false ->
        {:ok,
         %{
           content: validation |> review_content() |> Map.put(:accepted, false),
           token_cost: 0
         }}

      true ->
        metadata = %{
          "count_rationale" => validation.count_rationale,
          "question_count" => length(validation.questions_payload["items"]),
          "candidate_hash" => validation.candidate_hash
        }

        attrs = %{
          run_id: context.run_id,
          object_type: "openstax_question_set",
          object_ref: to_string(context[:lesson_id] || context["lesson_id"] || "unknown"),
          patch: %{"questions_payload" => validation.questions_payload},
          status: :accepted,
          metadata: metadata
        }

        case Persistence.create_draft(attrs) do
          {:ok, draft} ->
            {:ok,
             %{
               content: %{
                 accepted: true,
                 valid: true,
                 findings: [],
                 candidate_hash: validation.candidate_hash,
                 draft_id: draft.id
               },
               token_cost: 0
             }}

          {:error, changeset} ->
            {:error, {:draft_persistence_failed, changeset.errors}}
        end
    end
  end

  def call(name, _args, _context), do: {:error, {:tool_not_allowed, name}}

  defp review_content(validation) do
    %{
      valid: validation.valid,
      findings: validation.findings,
      candidate_hash: validation.candidate_hash,
      question_count: length(validation.questions_payload["items"])
    }
  end

  defp candidate_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["questions_payload", "count_rationale"],
      "properties" => %{
        "count_rationale" => %{
          "type" => "string",
          "description" =>
            "Why the selected count fits the objectives, concept density, instructional sections, and expected learning value."
        },
        "questions_payload" => %{
          "type" => "object",
          "required" => ["items"],
          "properties" => %{
            "items" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => 10,
              "items" => question_schema()
            }
          }
        }
      }
    }
  end

  defp question_schema do
    %{
      "type" => "object",
      "required" => [
        "prompt",
        "type",
        "placement_after_section_id",
        "objective_ids",
        "evidence_block_ids"
      ],
      "properties" => %{
        "prompt" => %{"type" => "string"},
        "type" => %{"type" => "string", "enum" => ["multiple_choice", "short_answer"]},
        "placement_after_section_id" => %{"type" => "string"},
        "objective_ids" => %{
          "type" => "array",
          "description" =>
            "One or more stable IDs copied exactly from the supplied objective_catalog.",
          "items" => %{"type" => "string"}
        },
        "evidence_block_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
        "choices" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["text", "correct", "feedback"],
            "properties" => %{
              "text" => %{"type" => "string"},
              "correct" => %{"type" => "boolean"},
              "feedback" => %{"type" => "string"}
            }
          }
        },
        "response_kind" => %{"type" => "string", "enum" => ["reflection", "application"]},
        "answer_guidance" => %{"type" => "string"},
        "answer_keywords" => %{"type" => "array", "items" => %{"type" => "string"}},
        "hint" => %{"type" => "string"},
        "correct_feedback" => %{"type" => "string"},
        "incorrect_feedback" => %{"type" => "string"},
        "remediation" => %{"type" => "string"},
        "media_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
        "allow_not_sure" => %{"type" => "boolean"}
      }
    }
  end
end
