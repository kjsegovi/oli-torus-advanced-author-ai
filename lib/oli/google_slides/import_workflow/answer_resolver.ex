defmodule Oli.GoogleSlides.ImportWorkflow.AnswerResolver do
  @moduledoc """
  Applies author answers to an existing semantic draft before the AI continues.

  Confirmation bits are written here, outside the model tool surface. This
  prevents a planner from opting an author into runtime AI feedback or approving
  creation of a new objective on its own.
  """

  alias Oli.GoogleSlides.AI.{Draft, ImportPlan, LessonPlan}

  @spec apply(map() | nil, map()) :: {:ok, map() | nil} | {:error, term()}
  def apply(nil, _answers), do: {:ok, nil}

  def apply(plan, answers) when is_map(plan) and is_map(answers) do
    answers
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while({:ok, plan}, fn {key, answer}, {:ok, current_import_plan} ->
      case apply_import_answer(current_import_plan, to_string(key), answer) do
        {:ok, updated_import_plan} -> {:cont, {:ok, updated_import_plan}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def apply(plan, _answers), do: ImportPlan.validate(plan)

  defp apply_import_answer(import_plan, blocker_key, answer) do
    import_plan
    |> ImportPlan.lessons()
    |> Enum.with_index()
    |> Enum.find(fn {plan, _index} ->
      Enum.any?(plan["blockers"] || [], &(&1["key"] == blocker_key))
    end)
    |> case do
      nil ->
        {:ok, import_plan}

      {plan, index} ->
        with {:ok, updated_plan} <- apply_answer(plan, blocker_key, answer),
             {:ok, updated_import_plan} <-
               ImportPlan.replace_lesson(import_plan, index, updated_plan) do
          {:ok, updated_import_plan}
        end
    end
  end

  defp apply_answer(plan, blocker_key, answer) do
    case Enum.find(plan["blockers"] || [], &(&1["key"] == blocker_key)) do
      nil ->
        {:ok, plan}

      blocker ->
        resolve(plan, blocker, normalize_answer(answer))
    end
  end

  defp resolve(plan, %{"code" => "objective_confirmation", "target" => target}, answer) do
    with {:ok, objective_key} <- objective_key(target) do
      case yes_no(answer) do
        :yes ->
          Draft.confirm_objective(plan, objective_key)

        :no ->
          plan
          |> update_in(["objectives", "proposed"], fn objectives ->
            Enum.reject(objectives || [], &(&1["key"] == objective_key))
          end)
          |> LessonPlan.resolve_blocker("objective_confirmation:#{target}")
          |> LessonPlan.validate()

        :unknown ->
          {:ok, plan}
      end
    end
  end

  defp resolve(plan, %{"code" => "runtime_ai_opt_in", "target" => target}, answer) do
    with {:ok, screen_key, interaction_key} <- interaction_target(target) do
      case yes_no(answer) do
        :yes -> Draft.record_runtime_ai_opt_in(plan, screen_key, interaction_key, true)
        :no -> Draft.record_runtime_ai_opt_in(plan, screen_key, interaction_key, false)
        :unknown -> {:ok, plan}
      end
    end
  end

  defp resolve(plan, %{"code" => "style_profile_confirmation"} = blocker, answer) do
    case yes_no(answer) do
      :yes ->
        plan
        |> LessonPlan.resolve_blocker(blocker["key"])
        |> LessonPlan.validate()

      :no ->
        layout = get_in(plan, ["lesson", "layout"]) || %{}

        Draft.set_layout(plan, %{
          "mode" => layout["mode"],
          "canvas" => layout["canvas"],
          "styleProfile" => "torus-default"
        })

      :unknown ->
        {:ok, plan}
    end
  end

  defp resolve(plan, %{"code" => "missing_correct_response", "target" => target}, answer) do
    with {:ok, screen_key, interaction_key} <- interaction_target(target),
         false <- blank?(answer) do
      Draft.record_author_correct_response(
        plan,
        screen_key,
        interaction_key,
        decode_scalar(answer)
      )
    else
      true -> {:ok, plan}
      {:error, _reason} = error -> error
    end
  end

  defp resolve(plan, %{"code" => "missing_alt_text", "target" => target} = blocker, answer) do
    update_part_accessibility(plan, target, blocker["key"], "altText", answer)
  end

  defp resolve(plan, %{"code" => "missing_captions", "target" => target} = blocker, answer) do
    if safe_https_url?(answer) do
      update_part_accessibility(
        plan,
        target,
        blocker["key"],
        "captions",
        answer,
        "captionsSource"
      )
    else
      {:error,
       {:invalid_answer, blocker["key"],
        "Enter an absolute HTTPS URL for a reviewed WebVTT caption track."}}
    end
  end

  defp resolve(plan, %{"code" => "missing_transcript", "target" => target} = blocker, answer) do
    update_part_accessibility(plan, target, blocker["key"], "transcript", answer)
  end

  defp resolve(plan, %{"code" => "unsupported_component"} = blocker, "skip") do
    warning = %{
      "key" => "skipped:#{blocker["key"]}",
      "code" => "unsupported_component_skipped",
      "target" => blocker["target"],
      "message" => "The author chose to omit an unsupported source interaction.",
      "sourceRefs" => blocker["sourceRefs"] || []
    }

    plan
    |> LessonPlan.resolve_blocker(blocker["key"])
    |> LessonPlan.put_warning(warning)
    |> LessonPlan.validate()
  end

  defp resolve(plan, %{"code" => "source_inventory_unaccounted"} = blocker, answer) do
    normalized =
      case answer do
        value when is_binary(value) -> String.downcase(value)
        _value -> ""
      end

    case normalized do
      answer when answer in ["include", "preserve"] ->
        # Keep the blocker in place. The trusted answer is passed to the
        # planner, which must add a concrete object reference before the
        # deterministic fidelity pass will clear it.
        {:ok, plan}

      "omit" ->
        record_author_omission(plan, blocker)

      _answer ->
        {:ok, plan}
    end
  end

  defp resolve(plan, _blocker, _answer), do: {:ok, plan}

  defp record_author_omission(plan, blocker) do
    inventory_id =
      get_in(blocker, ["details", "inventoryId"]) ||
        inventory_id_from_target(blocker["target"])

    coverage = plan["sourceCoverage"] || []

    case Enum.any?(coverage, &(&1["inventoryId"] == inventory_id)) do
      true ->
        updated_coverage =
          Enum.map(coverage, fn
            %{"inventoryId" => ^inventory_id} = entry ->
              entry
              |> Map.put("status", "author_omitted")
              |> Map.put("targets", [])
              |> Map.put("decisionSource", "author_answer")

            entry ->
              entry
          end)

        warning = %{
          "key" => "source_inventory_author_omitted:inventory:#{inventory_id}",
          "code" => "source_inventory_author_omitted",
          "target" => "inventory:#{inventory_id}",
          "message" =>
            "The author explicitly chose to omit #{omission_label(blocker)} from the generated lesson.",
          "sourceRefs" => blocker["sourceRefs"] || []
        }

        plan
        |> Map.put("sourceCoverage", updated_coverage)
        |> LessonPlan.resolve_blocker(blocker["key"])
        |> LessonPlan.put_warning(warning)
        |> LessonPlan.validate()

      false ->
        {:error, :answer_target_not_found}
    end
  end

  defp inventory_id_from_target("inventory:" <> inventory_id) when inventory_id != "",
    do: inventory_id

  defp inventory_id_from_target(_target), do: nil

  defp omission_label(blocker) do
    case get_in(blocker, ["details", "summary"]) do
      summary when is_binary(summary) and summary != "" ->
        summary

      %{"text" => text} when is_binary(text) and text != "" ->
        text

      _summary ->
        "the selected source element"
    end
  end

  defp update_part_accessibility(
         plan,
         target,
         blocker_key,
         field,
         answer,
         source_field \\ nil
       ) do
    with false <- blank?(answer),
         {:ok, screen_key, part_key} <- part_target(target),
         {:ok, screen_index, part_index} <- find_part(plan, screen_key, part_key) do
      path = [
        "lesson",
        "screens",
        Access.at(screen_index),
        "parts",
        Access.at(part_index),
        "accessibility"
      ]

      updated =
        plan
        |> put_in(path ++ [field], to_string(answer))
        |> maybe_put_answer_source(path, source_field)

      updated
      |> LessonPlan.resolve_blocker(blocker_key)
      |> LessonPlan.validate()
    else
      true -> {:ok, plan}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_answer_source(plan, _path, nil), do: plan

  defp maybe_put_answer_source(plan, path, field),
    do: put_in(plan, path ++ [field], "author_answer")

  defp find_part(plan, screen_key, part_key) do
    screens = get_in(plan, ["lesson", "screens"]) || []

    with screen_index when is_integer(screen_index) <-
           Enum.find_index(screens, &(&1["key"] == screen_key)),
         screen <- Enum.at(screens, screen_index),
         part_index when is_integer(part_index) <-
           Enum.find_index(screen["parts"] || [], &(&1["key"] == part_key)) do
      {:ok, screen_index, part_index}
    else
      _ -> {:error, :answer_target_not_found}
    end
  end

  defp objective_key("objective:" <> objective_key) when objective_key != "",
    do: {:ok, objective_key}

  defp objective_key(_target), do: {:error, :invalid_objective_target}

  defp interaction_target(target) when is_binary(target) do
    case Regex.run(~r/\Ascreen:([^:]+):interaction:([^:]+)\z/, target) do
      [_, screen_key, interaction_key] -> {:ok, screen_key, interaction_key}
      _ -> {:error, :invalid_interaction_target}
    end
  end

  defp interaction_target(_target), do: {:error, :invalid_interaction_target}

  defp part_target(target) when is_binary(target) do
    case Regex.run(~r/\Ascreen:([^:]+):part:([^:]+)\z/, target) do
      [_, screen_key, part_key] -> {:ok, screen_key, part_key}
      _ -> {:error, :invalid_part_target}
    end
  end

  defp part_target(_target), do: {:error, :invalid_part_target}

  defp normalize_answer(answer) when is_binary(answer), do: String.trim(answer)
  defp normalize_answer(answer), do: answer

  defp yes_no(true), do: :yes
  defp yes_no(false), do: :no

  defp yes_no(answer) when is_binary(answer) do
    case String.downcase(answer) do
      answer when answer in ["yes", "true", "enable", "enabled", "approve", "approved"] -> :yes
      answer when answer in ["no", "false", "disable", "disabled", "reject", "rejected"] -> :no
      _ -> :unknown
    end
  end

  defp yes_no(_answer), do: :unknown

  defp blank?(answer) when is_binary(answer), do: String.trim(answer) == ""
  defp blank?(nil), do: true
  defp blank?(_answer), do: false

  defp safe_https_url?(answer) when is_binary(answer) do
    case URI.parse(String.trim(answer)) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp safe_https_url?(_answer), do: false

  defp decode_scalar(answer) when is_binary(answer) do
    case Jason.decode(answer) do
      {:ok, value} when not is_map(value) and not is_list(value) -> value
      _ -> answer
    end
  end

  defp decode_scalar(answer), do: answer
end
