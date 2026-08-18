defmodule Oli.OpenStax.CourseImport.SimulationOpportunityV1 do
  @moduledoc """
  Deterministic contract for optional, source-grounded simulation opportunities.

  The model proposes pedagogy; this module owns identifiers, supported domains,
  source/objective references, placement, and the zero-to-three bound.
  """

  @domains ~w(chemistry physics biology mathematics astronomy computer_science)
  @max_opportunities 3

  @required_text_fields ~w(
    instructional_rationale learner_task misconception_target research_query
    expected_instructional_value
  )

  @spec build(term(), map(), map()) :: {:ok, [map()]} | {:error, [map()]}
  def build(candidate, lesson, advanced_content)
      when is_map(lesson) and is_map(advanced_content) do
    values =
      case candidate do
        %{"opportunities" => opportunities} -> List.wrap(opportunities)
        %{opportunities: opportunities} -> List.wrap(opportunities)
        opportunities when is_list(opportunities) -> opportunities
        _ -> []
      end

    cond do
      length(values) > @max_opportunities ->
        {:error, [finding("too_many_simulation_opportunities", "$", "Return at most three.")]}

      true ->
        values
        |> Enum.with_index(1)
        |> Enum.map(&normalize(&1, lesson, advanced_content))
        |> collect()
    end
  end

  def build(_candidate, _lesson, _advanced_content),
    do: {:error, [finding("invalid_simulation_opportunities", "$", "Return a JSON list.")]}

  def domains, do: @domains
  def max_opportunities, do: @max_opportunities

  def prompt_contract(lesson, content) do
    blueprint = content["experience_blueprint"] || %{}

    %{
      "supported_domains" => @domains,
      "maximum_opportunities" => @max_opportunities,
      "objective_ids" =>
        content |> Map.get("objective_catalog", []) |> Enum.map(&map_value(&1, "id")),
      "source_blocks" =>
        lesson
        |> Map.get("source_blocks", [])
        |> List.wrap()
        |> Enum.map(&Map.take(&1, ["id", "kind", "text"])),
      "stage_ids" =>
        blueprint |> Map.get("stages", []) |> List.wrap() |> Enum.map(&map_value(&1, "id")),
      "required_fields" =>
        ~w(domain objective_ids source_evidence instructional_rationale learner_task misconception_target placement research_query expected_instructional_value)
    }
  end

  defp normalize({raw, rank}, lesson, content) when is_map(raw) do
    raw = stringify_keys(raw)
    domain = normalize_domain(raw["domain"])
    objective_ids = normalize_strings(raw["objective_ids"])
    evidence_ids = evidence_ids(raw["source_evidence"])
    placement = stringify_keys(raw["placement"] || %{})
    stage_id = placement["stage_id"]
    objective_catalog = ids(content["objective_catalog"])
    source_catalog = ids(lesson["source_blocks"])
    stage_catalog = ids(get_in(content, ["experience_blueprint", "stages"]))

    findings =
      []
      |> maybe_finding(domain not in @domains, "unsupported_simulation_domain", "$.domain")
      |> maybe_finding(objective_ids == [], "missing_simulation_objectives", "$.objective_ids")
      |> maybe_finding(
        not subset?(objective_ids, objective_catalog),
        "unknown_simulation_objective",
        "$.objective_ids"
      )
      |> maybe_finding(evidence_ids == [], "missing_simulation_evidence", "$.source_evidence")
      |> maybe_finding(
        not subset?(evidence_ids, source_catalog),
        "unknown_simulation_evidence",
        "$.source_evidence"
      )
      |> maybe_finding(
        not is_binary(stage_id) or stage_id not in stage_catalog,
        "invalid_simulation_placement",
        "$.placement.stage_id"
      )
      |> Kernel.++(
        Enum.flat_map(@required_text_fields, fn field ->
          if present?(raw[field]), do: [], else: [finding("missing_#{field}", "$.#{field}")]
        end)
      )

    case findings do
      [] ->
        stable_material =
          Jason.encode!(%{
            domain: domain,
            objective_ids: Enum.sort(objective_ids),
            evidence_ids: Enum.sort(evidence_ids),
            stage_id: stage_id,
            rank: rank
          })

        planner_id =
          :crypto.hash(:sha256, stable_material)
          |> Base.encode16(case: :lower)
          |> binary_part(0, 20)
          |> then(&"simulation-opportunity-#{&1}")

        {:ok,
         %{
           "id" => planner_id,
           "kind" => "generated_simulation",
           "domain" => domain,
           "objective_ids" => objective_ids,
           "source_evidence" => %{"block_ids" => evidence_ids},
           "instructional_rationale" => String.trim(raw["instructional_rationale"]),
           "learner_task" => String.trim(raw["learner_task"]),
           "misconception_target" => String.trim(raw["misconception_target"]),
           "placement" => placement,
           "research_query" => String.trim(raw["research_query"]),
           "expected_instructional_value" => String.trim(raw["expected_instructional_value"]),
           "metadata" => %{
             "planner_id" => planner_id,
             "domain" => domain,
             "misconception_target" => String.trim(raw["misconception_target"]),
             "expected_instructional_value" => String.trim(raw["expected_instructional_value"])
           }
         }}

      findings ->
        {:error, findings}
    end
  end

  defp normalize({_raw, _rank}, _lesson, _content),
    do: {:error, [finding("invalid_simulation_opportunity", "$", "Return one object.")]}

  defp collect(results) do
    findings =
      Enum.flat_map(results, fn
        {:error, values} -> values
        _ -> []
      end)

    if findings == [] do
      {:ok, Enum.map(results, fn {:ok, value} -> value end)}
    else
      {:error, findings}
    end
  end

  defp evidence_ids(%{} = evidence),
    do: normalize_strings(evidence["block_ids"] || evidence[:block_ids])

  defp evidence_ids(values), do: normalize_strings(values)

  defp ids(values),
    do: values |> List.wrap() |> Enum.map(&map_value(&1, "id")) |> Enum.filter(&is_binary/1)

  defp subset?(values, allowed), do: MapSet.subset?(MapSet.new(values), MapSet.new(allowed))

  defp normalize_domain(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalize_domain(_), do: nil

  defp normalize_strings(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp stringify_keys(_), do: %{}

  defp map_value(value, key) when is_map(value), do: value[key] || value[String.to_atom(key)]
  defp map_value(_value, _key), do: nil

  defp maybe_finding(findings, false, _code, _path), do: findings
  defp maybe_finding(findings, true, code, path), do: findings ++ [finding(code, path)]

  defp finding(code, path, repair \\ "Repair the simulation opportunity contract."),
    do: %{"code" => code, "path" => path, "severity" => "repair", "repair" => repair}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
