defmodule Oli.GoogleSlides.AI.DraftToolsTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.DraftTools

  test "publishes schemas for the bounded draft-only tool set" do
    names = Enum.map(DraftTools.definitions(), & &1.name)

    assert "create_lesson_draft" in names
    assert "add_interaction" in names
    assert "apply_draft_operations" in names
    assert "finalize_lesson_plan" in names
    refute "confirm_objective" in names
    refute "create_activity" in names
    refute "apply_lesson_plan" in names

    assert %{schema: %{"type" => "object"}} = DraftTools.definition("add_screen")
  end

  test "applies an ordered batch without exposing author-confirmation operations" do
    operations = [
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

    assert {:ok, plan} =
             DraftTools.call("apply_draft_operations", nil, %{"operations" => operations})

    assert get_in(plan, ["lesson", "screens", Access.at(0), "key"]) == "screen-one"

    assert {:error, [%{"code" => "invalid_batch_operation"}]} =
             DraftTools.call("apply_draft_operations", plan, %{
               "operations" => [
                 %{"name" => "confirm_objective", "arguments" => %{"objectiveKey" => "x"}}
               ]
             })
  end

  test "dispatches pure operations over a caller-owned plan" do
    assert {:ok, plan} =
             DraftTools.call("create_lesson_draft", nil, %{
               "presentationId" => "deck-123",
               "fingerprint" => "sha256:abc",
               "title" => "Test lesson"
             })

    assert {:ok, plan} =
             DraftTools.call("add_screen", plan, %{
               "key" => "screen-one",
               "title" => "Screen one",
               "sourceRefs" => [%{"slideId" => "slide-1"}]
             })

    assert plan["lesson"]["screens"] |> hd() |> Map.fetch!("key") == "screen-one"
  end

  test "returns a structured error for unknown tools" do
    assert {:error, [%{"code" => "unknown_tool"}]} =
             DraftTools.call("delete_project", %{}, %{})
  end
end
