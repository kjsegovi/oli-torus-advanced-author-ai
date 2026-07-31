defmodule Oli.GoogleSlides.ImportWorkflow.PlannerToolsTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.{Message, ServiceConfig}
  alias Oli.GoogleSlides.ImportWorkflow.{PlannerTools, ToolLoop}

  test "exposes one complete-batch tool with operation-specific schemas" do
    assert [batch] = PlannerTools.functions()
    assert batch.name == "apply_draft_operations"

    variants =
      get_in(batch.parameters, ["properties", "operations", "items", "oneOf"])

    names =
      Enum.map(variants, fn variant ->
        get_in(variant, ["properties", "name", "enum", Access.at(0)])
      end)

    assert "create_lesson_draft" in names
    assert "add_screen" in names
    assert "add_interaction" in names
    refute "apply_draft_operations" in names
    refute "finalize_lesson_plan" in names

    add_screen =
      Enum.find(variants, fn variant ->
        get_in(variant, ["properties", "name", "enum"]) == ["add_screen"]
      end)

    assert get_in(add_screen, ["properties", "arguments", "required"]) == [
             "key",
             "title",
             "sourceRefs"
           ]
  end

  test "a successful complete batch ends the tool loop for local validation" do
    arguments = complete_batch_arguments()

    assert {:done, plan, %{"ok" => true}} =
             PlannerTools.call("apply_draft_operations", arguments, nil)

    assert get_in(plan, ["lesson", "screens", Access.at(0), "key"]) == "screen-one"
  end

  test "resume schema cannot recreate the existing lesson draft" do
    [batch] = PlannerTools.functions(%{"lesson" => %{"screens" => []}})

    names =
      batch.parameters
      |> get_in(["properties", "operations", "items", "oneOf"])
      |> Enum.map(&get_in(&1, ["properties", "name", "enum", Access.at(0)]))

    refute "create_lesson_draft" in names
    assert "add_content_part" in names
    assert batch.description =~ "Update the supplied draft in place"
  end

  test "returns a replaceable retry when a batch is invalid" do
    assert {:retry, nil, %{"ok" => false, "errors" => [_error]}} =
             PlannerTools.call("apply_draft_operations", %{"operations" => []}, nil)
  end

  test "returns a replaceable retry when a screen title is blank" do
    arguments =
      put_in(
        complete_batch_arguments(),
        ["operations", Access.at(1), "arguments", "title"],
        " "
      )

    assert {:retry, nil, %{"ok" => false, "errors" => errors}} =
             PlannerTools.call("apply_draft_operations", arguments, nil)

    assert Enum.any?(
             errors,
             &(&1 == %{
                 "path" => "operations[1].lesson.screens[0].title",
                 "code" => "required",
                 "message" => "must be a non-empty string"
               })
           )
  end

  test "a valid batch completes planning after one provider request" do
    parent = self()

    completion_fun = fn _ctx, _messages, functions, _service_config ->
      send(parent, :completion_requested)
      assert [batch] = functions
      assert batch.name == "apply_draft_operations"

      {:ok,
       %{
         content: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_complete_batch",
                     "function" => %{
                       "name" => "apply_draft_operations",
                       "arguments" => Jason.encode!(complete_batch_arguments())
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:ok, plan, %{steps: 1}} =
             ToolLoop.run(
               [Message.new(:user, "Build the complete lesson")],
               %ServiceConfig{id: 1},
               PlannerTools,
               nil,
               completion_fun: completion_fun
             )

    assert get_in(plan, ["lesson", "screens", Access.at(0), "key"]) == "screen-one"
    assert_received :completion_requested
    refute_received :completion_requested
  end

  defp complete_batch_arguments do
    %{
      "operations" => [
        %{
          "name" => "create_lesson_draft",
          "arguments" => %{
            "presentationId" => "deck-123",
            "fingerprint" => "sha256:abc",
            "title" => "Batched lesson"
          }
        },
        %{
          "name" => "add_screen",
          "arguments" => %{
            "key" => "screen-one",
            "title" => "Screen one",
            "sourceRefs" => [%{"slideId" => "slide-1"}]
          }
        }
      ]
    }
  end
end
