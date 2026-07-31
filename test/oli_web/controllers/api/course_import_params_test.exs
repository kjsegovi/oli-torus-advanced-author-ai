defmodule OliWeb.Api.CourseImportParamsTest do
  use ExUnit.Case, async: true

  alias OliWeb.Api.CourseImportParams

  test "accepts top-level chapter ids as the public scope payload" do
    assert CourseImportParams.selected_chapter_ids(%{"chapters" => ["1", " 2 ", "1"]}) == [
             "1",
             "2"
           ]

    assert CourseImportParams.selected_chapter_ids(%{
             "chapters" => ["chapter-1"],
             "selected_unit_ids" => []
           }) == ["chapter-1"]
  end

  test "accepts selected chapter cards and ignores deselected cards" do
    assert CourseImportParams.selected_chapter_ids(%{
             "chapters" => [
               %{"id" => "chapter-1", "selected" => true},
               %{"chapter_id" => "chapter-2", "selected" => false},
               %{"id" => "chapter-3"}
             ]
           }) == ["chapter-1", "chapter-3"]
  end

  test "accepts a checkbox map and the legacy id aliases" do
    assert CourseImportParams.selected_chapter_ids(%{
             "chapters" => %{"chapter-1" => "true", "chapter-2" => "false", "chapter-3" => true}
           }) == ["chapter-1", "chapter-3"]

    assert CourseImportParams.selected_chapter_ids(%{
             "scope" => %{"selected_unit_ids" => ["chapter-4"]}
           }) == ["chapter-4"]
  end

  test "returns an empty selection for missing or malformed scope input" do
    assert CourseImportParams.selected_chapter_ids(%{}) == []
    assert CourseImportParams.selected_chapter_ids(%{"chapters" => [nil, " ", 1]}) == []
  end

  test "keeps top-level lesson content and questions together" do
    content = %{"learning_objectives" => ["Explain recursion"]}
    questions = %{"items" => [%{"id" => "q-1", "prompt" => "What is a base case?"}]}

    assert CourseImportParams.lesson_plan_payload(%{
             "content_payload" => content,
             "questions_payload" => questions
           }) == %{
             "content_payload" => content,
             "questions_payload" => questions
           }
  end

  test "preserves absent siblings in partial lesson plan edits" do
    content = %{"narrative" => "A revised explanation."}
    questions = %{"items" => [%{"id" => "q-1", "prompt" => "What changed?"}]}

    assert CourseImportParams.lesson_plan_payload(%{"content_payload" => content}) == %{
             "content_payload" => content
           }

    assert CourseImportParams.lesson_plan_payload(%{"questions_payload" => questions}) == %{
             "questions_payload" => questions
           }
  end

  test "accepts the wrapped plan edit shape" do
    plan = %{
      "content_payload" => %{"narrative" => "A complete explanation."},
      "questions_payload" => %{"items" => []}
    }

    assert CourseImportParams.lesson_plan_payload(%{"plan" => plan}) == plan
  end
end
