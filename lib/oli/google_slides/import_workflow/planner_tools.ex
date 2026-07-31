defmodule Oli.GoogleSlides.ImportWorkflow.PlannerTools do
  @moduledoc false

  @behaviour Oli.GoogleSlides.ImportWorkflow.ToolLoop

  alias Oli.GenAI.Completions.Function
  alias Oli.GoogleSlides.AI.DraftTools

  @non_batch_tools ~w(apply_draft_operations validate_lesson_draft finalize_lesson_plan)

  @impl true
  def functions, do: functions(nil)

  @impl true
  def functions(plan) do
    definitions = DraftTools.definitions()
    batch_definition = Enum.find(definitions, &(&1.name == "apply_draft_operations"))

    operation_variants =
      definitions
      |> Enum.reject(&(&1.name in @non_batch_tools))
      |> maybe_reject_draft_creation(plan)
      |> Enum.map(&batch_operation_variant/1)

    schema =
      put_in(
        batch_definition.schema,
        ["properties", "operations", "items"],
        %{"oneOf" => operation_variants}
      )

    [
      Function.new(
        batch_definition.name,
        batch_description(batch_definition.desc, plan),
        schema
      )
    ]
  end

  @impl true
  def call(name, arguments, plan) do
    case DraftTools.call(name, plan, arguments) do
      {:ok, updated_plan} ->
        result = %{"ok" => true, "draft" => summary(updated_plan)}

        if name in ["apply_draft_operations", "finalize_lesson_plan"] do
          {:done, updated_plan, result}
        else
          {:ok, updated_plan, result}
        end

      {:error, errors} when is_list(errors) ->
        {:retry, plan, %{"ok" => false, "errors" => errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summary(nil), do: %{"status" => "not_created"}

  defp summary(plan) do
    lesson = plan["lesson"] || %{}

    %{
      "status" => plan["status"],
      "title" => lesson["title"],
      "screenCount" => length(lesson["screens"] || []),
      "blockerCount" => length(plan["blockers"] || []),
      "warningCount" => length(plan["warnings"] || [])
    }
  end

  defp maybe_reject_draft_creation(definitions, nil), do: definitions

  defp maybe_reject_draft_creation(definitions, _plan),
    do: Enum.reject(definitions, &(&1.name == "create_lesson_draft"))

  defp batch_description(description, nil) do
    description <>
      ". Submit the complete lesson draft as one ordered batch; Torus validates and finalizes it after the batch succeeds."
  end

  defp batch_description(description, _plan) do
    description <>
      ". Update the supplied draft in place for the current source scope. Submit only new or corrective operations; do not recreate existing screens or parts."
  end

  defp batch_operation_variant(definition) do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "enum" => [definition.name]},
        "arguments" => definition.schema
      },
      "required" => ["name", "arguments"],
      "additionalProperties" => false
    }
  end
end
