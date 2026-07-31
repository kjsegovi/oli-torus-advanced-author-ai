defmodule Oli.GoogleSlides.ImportWorkflow.PlannerTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.ServiceConfig
  alias Oli.GoogleSlides.AI.LessonPlan
  alias Oli.GoogleSlides.ImportWorkflow.Planner

  defmodule CapturingToolLoop do
    def run(messages, _service_config, _tools_module, initial_state, _opts) do
      send(self(), {:planner_messages, messages})
      {:ok, initial_state, %{steps: 1, executions: [], estimated_input_tokens: 1}}
    end
  end

  test "marks a resumed plan as an incremental update and explains that existing content is authoritative" do
    {:ok, plan} =
      LessonPlan.new(%{
        "presentationId" => "deck-123",
        "fingerprint" => "sha256:abc",
        "title" => "Existing lesson"
      })

    plan =
      LessonPlan.put_blocker(plan, %{
        "key" => "source_inventory_unaccounted:inventory:shape-1",
        "code" => "source_inventory_unaccounted",
        "target" => "inventory:shape-1",
        "message" => "Choose whether to include this source element"
      })

    assert {:ok, _review_plan, _metadata} =
             Planner.plan(
               %{
                 service_config: %ServiceConfig{id: 1},
                 source_snapshot: %{"presentation" => %{"id" => "deck-123"}},
                 lesson_plan: plan,
                 answers: %{
                   "source_inventory_unaccounted:inventory:shape-1" => "include"
                 }
               },
               tool_loop: CapturingToolLoop
             )

    assert_received {:planner_messages, messages}

    system_message = Enum.find(messages, &(&1.role == :system))
    user_message = Enum.find(messages, &(&1.role == :user))
    [_instruction, encoded_context] = String.split(user_message.content, "\n", parts: 2)
    context = Jason.decode!(encoded_context)

    assert system_message.content =~ "Treat the existing draft as authoritative"
    assert system_message.content =~ "Submit only the incremental operations"
    assert context["planningMode"] == "update_existing_draft"
    assert context["existingLessonPlan"]["lesson"]["title"] == "Existing lesson"
  end
end
