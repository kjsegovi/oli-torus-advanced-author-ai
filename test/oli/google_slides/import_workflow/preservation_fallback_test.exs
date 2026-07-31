defmodule Oli.GoogleSlides.ImportWorkflow.PreservationFallbackTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.LessonPlan

  alias Oli.GoogleSlides.ImportWorkflow.{
    FidelityValidator,
    Planner,
    PreservationFallback
  }

  test "groups uncovered objects into a static slide fallback instead of questions" do
    {:ok, plan} =
      LessonPlan.new(%{
        "lessonKey" => "lesson-one",
        "title" => "Lesson one",
        "presentationId" => "presentation-1",
        "fingerprint" => "fingerprint-1",
        "layoutMode" => "responsive",
        "styleProfile" => "torus-default"
      })

    plan =
      LessonPlan.put_blocker(plan, %{
        "key" => "unsupported_component:screen:future-1",
        "code" => "unsupported_component",
        "target" => "screen:future-1",
        "message" => "Unsupported source interaction",
        "sourceRefs" => [%{"slideId" => "slide-1", "objectId" => "future-1"}]
      })

    snapshot = snapshot()

    assert {:ok, preserved} = PreservationFallback.apply(plan, snapshot)
    assert :ok = FidelityValidator.validate(preserved, snapshot)
    assert Planner.questions(preserved, snapshot) == []
    assert preserved["blockers"] == []

    assert [screen] = get_in(preserved, ["lesson", "screens"])
    assert [part] = screen["parts"]
    assert part["key"] == "preserved-source-1"
    assert length(part["sourceRefs"]) == 2

    assert Enum.any?(
             preserved["warnings"],
             &(&1["code"] == "source_preservation_fallback")
           )

    assert Enum.all?(preserved["sourceCoverage"], &(&1["status"] == "included"))
  end

  defp snapshot do
    inventory = [
      %{
        "inventoryId" => "slide-1:0:shape-1",
        "slideId" => "slide-1",
        "objectId" => "shape-1",
        "objectIdSource" => "google",
        "sourceType" => "shape",
        "meaningful" => true,
        "decorative" => false,
        "container" => false,
        "suggestedDisposition" => "native_semantic",
        "fidelity" => "semantic",
        "summary" => %{"text" => "Important source text"},
        "order" => 0,
        "path" => "0"
      },
      %{
        "inventoryId" => "slide-1:1:future-1",
        "slideId" => "slide-1",
        "objectId" => "future-1",
        "objectIdSource" => "google",
        "sourceType" => "unknown",
        "meaningful" => true,
        "decorative" => false,
        "container" => false,
        "suggestedDisposition" => "unsupported",
        "fidelity" => "unsupported",
        "summary" => %{"structuralKeys" => ["futureElement"]},
        "order" => 1,
        "path" => "1"
      }
    ]

    %{
      "schemaVersion" => 3,
      "truncated" => false,
      "presentation" => %{
        "id" => "presentation-1",
        "fingerprint" => "fingerprint-1"
      },
      "inventoryAccounting" => %{
        "discovered" => 2,
        "included" => 2,
        "omitted" => 0
      },
      "slides" => [
        %{
          "index" => 1,
          "objectId" => "slide-1",
          "title" => "Source slide",
          "paragraphs" => ["Important source text"],
          "listItems" => [],
          "contentBlocks" => [],
          "notes" => "",
          "links" => [],
          "sourceInventory" => inventory
        }
      ]
    }
  end
end
