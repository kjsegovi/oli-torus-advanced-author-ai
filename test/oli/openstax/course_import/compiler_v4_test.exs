defmodule Oli.OpenStax.CourseImport.CompilerV4Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Compiler, Lesson, LessonPlan, Unit}

  test "legacy plans compile without enrichment payload mutations" do
    {legacy_content, run} = legacy_run()

    assert {:ok, compiled} = Compiler.dry_run(run)

    [compiled_unit] = compiled["units"]
    [compiled_lesson] = compiled_unit["lessons"]

    assert compiled_lesson["content_payload"] == legacy_content
    refute Map.has_key?(compiled_lesson["content_payload"], "curated_enrichments")
  end

  test "v4 compilation rejects persisted content schema downgrade or type mutation" do
    {_legacy_content, run} = legacy_run()

    for invalid_version <- [3, "4"] do
      run =
        run
        |> Map.put(:plan_schema_version, 4)
        |> update_in(
          [:units, Access.at(0), Access.key(:lessons), Access.at(0), Access.key(:plans)],
          fn [
               plan
             ] ->
            [
              %{
                plan
                | content_payload:
                    Map.put(plan.content_payload, "schema_version", invalid_version)
              }
            ]
          end
        )

      assert {:error,
              {:unit_compile_failed, "legacy-unit",
               {:lesson_artifact_invalid, "legacy-lesson", :plan_schema_version_mismatch}}} =
               Compiler.dry_run(run)
    end
  end

  defp legacy_run do
    legacy_content = %{
      "schema_version" => 3,
      "objective" => "Apply the source concept",
      "learning_objectives" => ["Apply the source concept"],
      "narrative" => "A source-grounded narrative.",
      "source_evidence_links" => [
        "https://openstax.org/books/sample/pages/1-1-topic"
      ]
    }

    questions = [
      %{"prompt" => "Explain the concept.", "type" => "short_answer"},
      %{"prompt" => "Apply the concept.", "type" => "short_answer"}
    ]

    plan = %LessonPlan{
      version: 1,
      content_payload: legacy_content,
      questions_payload: %{"items" => questions},
      approved_by_user: true
    }

    lesson = %Lesson{
      id: "legacy-lesson",
      run_id: "legacy-run",
      unit_id: "legacy-unit",
      order: 1,
      title: "Legacy lesson",
      plan_mode: "basic",
      status: "approved",
      selected: true,
      source_evidence_links: [],
      plans: [plan]
    }

    unit = %Unit{
      id: "legacy-unit",
      run_id: "legacy-run",
      order: 1,
      unit_name: "Legacy unit",
      selected: true,
      lessons: [lesson],
      assessment_payload: %{
        "title" => "Legacy assessment",
        "authoring_mode" => "basic",
        "questions" => questions,
        "source_evidence_links" => []
      }
    }

    {legacy_content,
     %{
       id: "legacy-run",
       plan_schema_version: 3,
       units: [unit],
       enrichment_proposals: []
     }}
  end
end
