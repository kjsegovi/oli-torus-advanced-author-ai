defmodule Oli.GoogleSlides.AI.ImportPlanTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.{Draft, ImportPlan, LessonPlan}

  test "keeps legacy single plans readable" do
    plan = lesson_plan!("lesson-one", "Lesson one")

    assert ImportPlan.lessons(plan) == [plan]
    assert {:ok, ^plan} = ImportPlan.validate(plan)
    refute ImportPlan.multi?(plan)
  end

  test "validates a two-to-ten lesson envelope with globally stable keys" do
    first = lesson_plan!("lesson-one", "Lesson one") |> add_screen!("shared-screen", "First")
    second = lesson_plan!("lesson-two", "Lesson two") |> add_screen!("second-screen", "Second")

    assert {:ok, envelope} = ImportPlan.new_set([first, second])
    assert ImportPlan.multi?(envelope)
    assert length(ImportPlan.lessons(envelope)) == 2

    duplicate =
      lesson_plan!("lesson-three", "Lesson three") |> add_screen!("shared-screen", "Third")

    assert {:error, errors} = ImportPlan.new_set([first, duplicate])
    assert Enum.any?(errors, &(&1["path"] == "lessons.screens"))

    {:ok, first_with_variable} =
      Draft.declare_variable(first, %{
        "key" => "shared-variable",
        "type" => "integer",
        "initialValue" => 0,
        "purpose" => "Track attempts",
        "sourceRefs" => [%{"slideId" => "slide-1"}]
      })

    {:ok, second_with_variable} =
      Draft.declare_variable(second, %{
        "key" => "shared-variable",
        "type" => "integer",
        "initialValue" => 0,
        "purpose" => "Track attempts",
        "sourceRefs" => [%{"slideId" => "slide-2"}]
      })

    assert {:error, errors} =
             ImportPlan.new_set([first_with_variable, second_with_variable])

    assert Enum.any?(errors, &(&1["path"] == "lessons.variables"))
  end

  test "rejects one-lesson and over-ten split envelopes" do
    plan = lesson_plan!("lesson-one", "Lesson one")
    assert {:error, _errors} = ImportPlan.new_set([plan])

    plans =
      Enum.map(1..11, fn index ->
        lesson_plan!("lesson-#{index}", "Lesson #{index}")
      end)

    assert {:error, _errors} = ImportPlan.new_set(plans)
  end

  defp lesson_plan!(key, title) do
    {:ok, plan} =
      LessonPlan.new(%{
        "lessonKey" => key,
        "title" => title,
        "presentationId" => "presentation-1",
        "fingerprint" => "fingerprint-1",
        "layoutMode" => "responsive",
        "styleProfile" => "torus-default"
      })

    plan
  end

  defp add_screen!(plan, key, title) do
    {:ok, plan} =
      Draft.add_screen(plan, %{
        "key" => key,
        "title" => title,
        "sourceRefs" => [%{"slideId" => "slide-1"}]
      })

    plan
  end
end
