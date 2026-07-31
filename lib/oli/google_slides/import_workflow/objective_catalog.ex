defmodule Oli.GoogleSlides.ImportWorkflow.ObjectiveCatalog do
  @moduledoc """
  Validates model-authored objective mappings against the current project catalog.

  The model may select an objective identifier, but it cannot introduce an
  identifier or display title. Titles are replaced with the current canonical
  project title before the plan reaches author review.
  """

  @spec canonicalize(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def canonicalize(plan, catalog) when is_map(plan) and is_list(catalog) do
    catalog_by_id =
      Map.new(catalog, fn objective ->
        id = value(objective, :objectiveId) || value(objective, :resource_id)
        {to_string(id), objective}
      end)

    mapped = get_in(plan, ["objectives", "mapped"]) || []

    mapped
    |> Enum.reduce_while({:ok, []}, fn objective, {:ok, canonical} ->
      id =
        value(objective, :objectiveId) ||
          value(objective, :resourceId) ||
          value(objective, :resource_id) ||
          value(objective, :id)

      case id && Map.get(catalog_by_id, to_string(id)) do
        nil ->
          {:halt, {:error, {:invalid_mapped_objective, id}}}

        catalog_objective ->
          canonical_objective =
            objective
            |> stringify_keys()
            |> Map.put("objectiveId", to_string(value(catalog_objective, :objectiveId)))
            |> Map.put("title", value(catalog_objective, :title))

          {:cont, {:ok, canonical ++ [canonical_objective]}}
      end
    end)
    |> case do
      {:ok, canonical} ->
        {:ok, put_in(plan, ["objectives", "mapped"], canonical)}

      {:error, _reason} = error ->
        error
    end
  end

  def canonicalize(_plan, _catalog), do: {:error, :invalid_objective_catalog}

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_map, _key), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn {key, nested} -> {to_string(key), nested} end)
  end
end
