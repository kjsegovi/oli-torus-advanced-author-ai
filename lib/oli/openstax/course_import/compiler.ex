defmodule Oli.OpenStax.CourseImport.Compiler do
  @moduledoc """
  Provider-neutral dry-run compiler for OpenStax lesson and unit plans.

  The compiler validates every approved plan before persistence and emits a
  normalized artifact map used by the apply worker for both Basic and Advanced
  Author pages.
  """

  alias Oli.OpenStax.CourseImport.AuthoringCompiler

  @spec dry_run(map()) :: {:ok, map()} | {:error, term()}
  def dry_run(run), do: dry_run(run, [])

  @spec dry_run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(%{units: units} = run, opts) when is_list(units) and is_list(opts) do
    with false <- Enum.empty?(units),
         {:ok, compiled_units} <- compile_units(units, opts) do
      {:ok,
       %{
         "run_id" => run.id,
         "units" => compiled_units,
         "lesson_count" => Enum.reduce(compiled_units, 0, &(&2 + length(&1["lessons"]))),
         "compiled_at" => DateTime.to_iso8601(DateTime.utc_now())
       }}
    else
      true -> {:error, :no_units_to_compile}
      {:error, _} = error -> error
    end
  end

  def dry_run(_, _), do: {:error, :invalid_run}

  defp compile_units(units, opts) do
    units
    |> Enum.sort_by(& &1.order)
    |> Enum.reduce_while({:ok, []}, fn unit, {:ok, acc} ->
      with true <- unit.selected,
           {:ok, lessons} <- compile_lessons(unit.lessons, opts),
           {:ok, assessment} <- compile_assessment(unit, opts) do
        compiled = %{
          "unit_id" => unit.id,
          "title" => unit.unit_name,
          "assessment" => assessment,
          "lessons" => lessons
        }

        {:cont, {:ok, acc ++ [compiled]}}
      else
        false -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:unit_compile_failed, unit.id, reason}}}
      end
    end)
  end

  defp compile_lessons(lessons, opts) do
    lessons
    |> Enum.filter(& &1.selected)
    |> Enum.sort_by(& &1.order)
    |> Enum.reduce_while({:ok, []}, fn lesson, {:ok, acc} ->
      case compile_lesson(lesson, opts) do
        {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_lesson(%{status: "approved", plans: plans} = lesson, opts) do
    plan = Enum.max_by(plans, & &1.version, fn -> nil end)

    with false <- is_nil(plan),
         true <- plan.approved_by_user,
         {:ok, artifact} <-
           AuthoringCompiler.compile(
             lesson.plan_mode,
             lesson.title,
             plan.content_payload,
             plan.questions_payload,
             lesson.id,
             opts
           ) do
      {:ok,
       Map.merge(
         %{
           "lesson_id" => lesson.id,
           "title" => lesson.title,
           "mode" => lesson.plan_mode,
           "content_payload" => plan.content_payload,
           "questions_payload" => plan.questions_payload,
           "source_evidence_links" => lesson.source_evidence_links
         },
         artifact
       )}
    else
      true -> {:error, {:lesson_not_compilable, lesson.id}}
      false -> {:error, {:lesson_not_compilable, lesson.id}}
      {:error, reason} -> {:error, {:lesson_artifact_invalid, lesson.id, reason}}
      _ -> {:error, {:lesson_not_compilable, lesson.id}}
    end
  end

  defp compile_lesson(lesson, _opts), do: {:error, {:lesson_not_approved, lesson.id}}

  defp compile_assessment(unit, opts) do
    assessment = unit.assessment_payload || %{}
    title = assessment["title"] || "#{unit.unit_name} assessment"
    mode = assessment["authoring_mode"] || "basic"
    questions = assessment["questions"] || []

    content = %{
      "title" => title,
      "objective" => "Demonstrate mastery of #{unit.unit_name}",
      "learning_objectives" => ["Demonstrate mastery of #{unit.unit_name}"],
      "narrative" => "Complete this unit assessment after reviewing the lessons.",
      "source_evidence_links" => assessment["source_evidence_links"] || [],
      "authoring_mode" => mode
    }

    with true <- questions != [],
         {:ok, artifact} <-
           AuthoringCompiler.compile(
             mode,
             title,
             content,
             %{"items" => questions},
             "#{unit.id}:assessment",
             opts
           ) do
      {:ok,
       Map.merge(
         %{
           "title" => title,
           "mode" => mode,
           "questions_payload" => %{"items" => questions},
           "content_payload" => content,
           "source_evidence_links" => assessment["source_evidence_links"] || []
         },
         artifact
       )}
    else
      false -> {:error, :missing_unit_assessment}
      {:error, reason} -> {:error, {:unit_assessment_invalid, reason}}
    end
  end
end
