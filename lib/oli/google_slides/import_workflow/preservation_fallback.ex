defmodule Oli.GoogleSlides.ImportWorkflow.PreservationFallback do
  @moduledoc """
  Deterministically preserves source objects the planner did not represent.

  Meaningful objects are grouped by slide into one reviewed static semantic
  fallback. They become an expandable review warning, never one include/omit
  question per source object.
  """

  alias Oli.GoogleSlides.AI.{Draft, LessonPlan}
  alias Oli.GoogleSlides.ImportWorkflow.FidelityValidator

  @spec apply(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply(plan, snapshot) when is_map(plan) and is_map(snapshot) do
    with {:ok, reconciled} <- FidelityValidator.reconcile(plan, snapshot),
         groups <- unaccounted_by_slide(reconciled),
         {:ok, preserved} <- add_groups(reconciled, snapshot, groups),
         preserved <- resolve_preserved_component_blockers(preserved),
         {:ok, final} <- FidelityValidator.reconcile(preserved, snapshot) do
      {:ok, final}
    end
  end

  def apply(_plan, _snapshot), do: {:error, :invalid_preservation_fallback_input}

  defp unaccounted_by_slide(plan) do
    plan
    |> Map.get("sourceCoverage", [])
    |> Enum.filter(&(&1["status"] == "unaccounted" and &1["sourceType"] != "group"))
    |> Enum.group_by(& &1["slideId"])
    |> Enum.sort_by(fn {slide_id, _entries} -> slide_id end)
  end

  defp add_groups(plan, snapshot, groups) do
    Enum.reduce_while(groups, {:ok, plan}, fn {slide_id, entries}, {:ok, current} ->
      case add_group(current, snapshot, slide_id, entries) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_preserved_component_blockers(plan) do
    preserved_refs =
      plan
      |> Map.get("warnings", [])
      |> Enum.filter(&(&1["code"] == "source_preservation_fallback"))
      |> Enum.flat_map(&(&1["sourceRefs"] || []))
      |> MapSet.new(&{&1["slideId"], &1["objectId"]})

    plan
    |> Map.get("blockers", [])
    |> Enum.filter(&(&1["code"] == "unsupported_component"))
    |> Enum.filter(fn blocker ->
      refs = blocker["sourceRefs"] || []

      refs != [] and
        Enum.all?(refs, fn ref ->
          MapSet.member?(preserved_refs, {ref["slideId"], ref["objectId"]})
        end)
    end)
    |> Enum.reduce(plan, fn blocker, current ->
      LessonPlan.resolve_blocker(current, blocker["key"])
    end)
  end

  defp add_group(plan, snapshot, slide_id, entries) do
    slide = Enum.find(snapshot["slides"] || [], &(&1["objectId"] == slide_id)) || %{}
    slide_index = slide["index"] || 0
    screen_key = existing_screen_key(plan, slide_id) || stable_key("preserved-slide", slide_index)
    part_key = stable_key("preserved-source", slide_index)
    source_refs = Enum.map(entries, &source_ref/1)

    with {:ok, plan} <- ensure_screen(plan, screen_key, slide, slide_id),
         {:ok, plan} <-
           ensure_fallback_part(plan, screen_key, part_key, slide, source_refs, entries) do
      warning =
        %{
          "code" => "source_preservation_fallback",
          "key" => "source-preservation-fallback:#{slide_id}",
          "target" => "screen:#{screen_key}",
          "message" =>
            "Torus preserved #{length(entries)} source #{pluralize(length(entries), "item")} from slide #{slide_index} as reviewed static content.",
          "sourceRefs" => source_refs
        }

      {:ok, LessonPlan.put_warning(plan, warning)}
    end
  end

  defp ensure_screen(plan, screen_key, slide, slide_id) do
    case existing_screen_key(plan, slide_id) do
      nil ->
        Draft.add_screen(plan, %{
          "key" => screen_key,
          "title" => present(slide["title"], "Preserved source slide #{slide["index"]}"),
          "sourceRefs" => [%{"slideId" => slide_id}]
        })

      _existing ->
        {:ok, plan}
    end
  end

  defp ensure_fallback_part(plan, screen_key, part_key, slide, source_refs, entries) do
    if part_exists?(plan, screen_key, part_key) do
      {:ok, plan}
    else
      Draft.add_content_part(plan, screen_key, %{
        "key" => part_key,
        "kind" => "text",
        "content" => %{
          "text" => fallback_text(slide, entries),
          "tag" => "p"
        },
        "sourceRefs" => source_refs
      })
    end
  end

  defp existing_screen_key(plan, slide_id) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.find_value(fn screen ->
      if Enum.any?(screen["sourceRefs"] || [], &(&1["slideId"] == slide_id)),
        do: screen["key"]
    end)
  end

  defp part_exists?(plan, screen_key, part_key) do
    plan
    |> get_in(["lesson", "screens"])
    |> List.wrap()
    |> Enum.find(fn screen -> screen["key"] == screen_key end)
    |> case do
      nil -> false
      screen -> Enum.any?(screen["parts"] || [], &(&1["key"] == part_key))
    end
  end

  defp fallback_text(slide, entries) do
    summaries =
      entries
      |> Enum.map(&summary_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case summaries do
      [] ->
        "Source content from #{present(slide["title"], "slide #{slide["index"]}")} was preserved for review."

      summaries ->
        Enum.join(summaries, " · ")
    end
  end

  defp summary_text(%{"summary" => summary}) when is_map(summary) do
    summary
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn
      {_key, value} when is_binary(value) and value != "" -> [value]
      {_key, value} when is_number(value) -> [to_string(value)]
      _entry -> []
    end)
    |> Enum.join(" — ")
  end

  defp summary_text(_entry), do: ""

  defp source_ref(entry) do
    %{
      "slideId" => entry["slideId"],
      "objectId" => entry["objectId"]
    }
  end

  defp stable_key(prefix, index) do
    suffix = if is_integer(index) and index > 0, do: Integer.to_string(index), else: "source"
    "#{prefix}-#{suffix}"
  end

  defp present(value, _fallback) when is_binary(value) and value != "", do: value
  defp present(_value, fallback), do: fallback

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
