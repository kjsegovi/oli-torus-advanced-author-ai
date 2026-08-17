defmodule Oli.OpenStax.CourseImport.AdvancedSuitabilityV6 do
  @moduledoc """
  Deterministic, source-only suitability assessment for schema 6 Advanced
  Explorations.

  The assessment is intentionally conservative. A source-grounded knowledge
  check by itself is not enough: the lesson must contain evidence for a central
  investigation and enough learner work to support a 45–75 minute experience.
  """

  @quantitative_terms ~w(
    calculate change equation estimate graph measure measurement model numeric
    percent predict probability rate ratio scale table uncertainty variable
  )
  @evidence_terms ~w(
    analyze compare contrast data decision evidence evaluate explanation
    hypothesis infer interpret model observation pattern prediction tradeoff
  )
  @investigation_kinds ~w(
    exercise exercises problem problems table equation figure
  )
  @minimum_minutes 45
  @maximum_minutes 75

  @type assessment :: %{required(String.t()) => term()}

  @spec assess(map()) :: assessment()
  def assess(lesson) when is_map(lesson) do
    blocks = source_blocks(lesson)
    title = present(lesson["title"] || lesson[:title]) || "Untitled lesson"
    words = source_word_count(lesson, blocks)
    media = lesson |> Map.get("source_media", []) |> List.wrap()
    kinds = blocks |> Enum.map(&to_string(&1["kind"] || &1[:kind])) |> MapSet.new()
    tokens = source_tokens(lesson, blocks)

    quantitative? = contains_any?(tokens, @quantitative_terms)
    evidence_reasoning? = contains_any?(tokens, @evidence_terms)
    structured_investigation? = Enum.any?(@investigation_kinds, &MapSet.member?(kinds, &1))
    multi_step? = multi_step_source?(blocks)

    affordances =
      []
      |> maybe_add(quantitative? and structured_investigation?, "quantitative_investigation")
      |> maybe_add(evidence_reasoning? and structured_investigation?, "evidence_analysis")
      |> maybe_add(multi_step?, "multi_step_problem")
      |> maybe_add(media != [] and evidence_reasoning?, "figure_or_data_analysis")

    depth = depth_estimate(words, blocks, media, affordances)
    excluded_title? = title_excluded?(title)

    candidate? =
      not excluded_title? and affordances != [] and
        depth >= @minimum_minutes and depth <= @maximum_minutes

    %{
      "mode" => if(candidate?, do: "advanced", else: "basic"),
      "candidate" => candidate?,
      "affordances" => affordances,
      "evidence_block_ids" => evidence_block_ids(blocks, affordances),
      "source_word_count" => words,
      "source_media_count" => length(media),
      "expected_depth_minutes" => depth,
      "maximum_supported_minutes" => depth,
      "reasons" => reasons(candidate?, excluded_title?, affordances, depth)
    }
  end

  def assess(_lesson), do: basic_assessment("The lesson source is unavailable.")

  @spec advanced?(map()) :: boolean()
  def advanced?(lesson), do: assess(lesson)["candidate"] == true

  defp basic_assessment(reason) do
    %{
      "mode" => "basic",
      "candidate" => false,
      "affordances" => [],
      "evidence_block_ids" => [],
      "source_word_count" => 0,
      "source_media_count" => 0,
      "expected_depth_minutes" => 0,
      "maximum_supported_minutes" => 0,
      "reasons" => [reason]
    }
  end

  defp source_blocks(lesson) do
    lesson
    |> Map.get("source_blocks", [])
    |> List.wrap()
    |> flatten_blocks()
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&(&1["id"] || &1[:id]))
  end

  defp flatten_blocks(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = block ->
        [block] ++
          flatten_blocks(block["blocks"] || block[:blocks]) ++
          flatten_blocks(block["children"] || block[:children])

      _ ->
        []
    end)
  end

  defp source_word_count(lesson, blocks) do
    case lesson["source_word_count"] || lesson[:source_word_count] do
      value when is_integer(value) and value > 0 -> value
      _ -> blocks |> Enum.map_join(" ", &to_string(&1["text"] || &1[:text] || "")) |> words()
    end
  end

  defp source_tokens(lesson, blocks) do
    [
      lesson["title"] || lesson[:title],
      Enum.join(List.wrap(lesson["source_objectives"] || lesson[:source_objectives]), " "),
      Enum.map_join(blocks, " ", fn block ->
        [block["title"], block["text"], block["callout_body"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
      end)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> MapSet.new()
  end

  defp contains_any?(tokens, terms), do: Enum.any?(terms, &MapSet.member?(tokens, &1))

  defp multi_step_source?(blocks) do
    Enum.any?(blocks, fn block ->
      kind = to_string(block["kind"] || block[:kind] || "")
      text = to_string(block["text"] || block[:text] || "")

      kind in ~w(exercise exercises problem problems) or
        Regex.match?(~r/(?:^|\s)(?:step\s+\d+|first.+then|procedure|investigat)/iu, text)
    end)
  end

  defp depth_estimate(words, blocks, media, affordances) do
    reading = ceil_div(words, 180)
    substantive = Enum.count(blocks, &substantive?/1)
    investigation = length(affordances) * 10
    media_analysis = min(length(media) * 4, 16)
    structured_work = min(substantive, 12)
    reading + investigation + media_analysis + structured_work + 8
  end

  defp substantive?(block) do
    kind = to_string(block["kind"] || block[:kind] || "")

    present(block["text"] || block[:text]) != nil and
      kind not in ~w(heading title footnote footnotes)
  end

  defp evidence_block_ids(blocks, affordances) do
    if affordances == [] do
      []
    else
      blocks
      |> Enum.filter(fn block ->
        kind = to_string(block["kind"] || block[:kind] || "")
        kind in @investigation_kinds or substantive?(block)
      end)
      |> Enum.map(&(&1["id"] || &1[:id]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
    end
  end

  defp title_excluded?(title) do
    Regex.match?(~r/^\s*(?:chapter\s+)?(?:outline|introduction|summary)\s*$/iu, title) or
      Regex.match?(~r/^\s*chapter\s+outline\s*$/iu, title)
  end

  defp reasons(true, _excluded, affordances, depth) do
    [
      "The source supports a central #{affordances |> List.first() |> String.replace("_", " ")}.",
      "The deterministic depth estimate supports approximately #{depth} minutes."
    ]
  end

  defp reasons(false, true, _affordances, _depth),
    do: ["Structural chapter pages are kept as source-faithful Basic lessons."]

  defp reasons(false, _excluded, [], _depth),
    do: ["The source does not contain a genuine investigation affordance."]

  defp reasons(false, _excluded, _affordances, depth) when depth < @minimum_minutes,
    do: ["The source supports only about #{depth} minutes without padding, so it remains Basic."]

  defp reasons(false, _excluded, _affordances, depth),
    do: [
      "The source requires about #{depth} minutes, outside the 45–75 minute Advanced range, so it remains Basic."
    ]

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp words(text) when is_binary(text),
    do: text |> String.split(~r/\s+/u, trim: true) |> length()

  defp ceil_div(value, divisor), do: div(max(value, 0) + divisor - 1, divisor)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil
end
