defmodule Oli.OpenStax.CourseImport.Enrichment.Research.Catalog do
  @moduledoc """
  Selects reviewed resources from an institution-configured enrichment catalog.

  Catalog entries are configuration, not model output. Each entry must include
  an HTTPS URL and either authority or licensing evidence. Results remain
  annotated links; this adapter never grants iframe permission.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Research

  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @impl true
  def available?, do: valid_entries() != []

  @impl true
  def research(%EnrichmentProposal{} = proposal, _opts) do
    query_tokens = proposal_tokens(proposal)

    case best_match(valid_entries(), query_tokens) do
      nil ->
        {:error, :no_curated_resource_match}

      entry ->
        {:ok,
         %{
           evidence: %{
             "authority" => entry["authority"],
             "license" => entry["license"],
             "catalog_id" => entry["id"],
             "annotation" => entry["annotation"]
           },
           resource_title: entry["title"],
           resource_url: entry["url"],
           delivery_mode: "annotated_link"
         }}
    end
  end

  def research(_, _opts), do: {:error, :invalid_input}

  defp valid_entries do
    Application.get_env(:oli, :openstax_enrichment_resource_catalog, [])
    |> List.wrap()
    |> Enum.flat_map(&normalize_entry/1)
  end

  defp normalize_entry(entry) when is_map(entry) do
    normalized =
      entry
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    with title when is_binary(title) <- present_string(normalized["title"]),
         url when is_binary(url) <- safe_https_url(normalized["url"]),
         true <- present(normalized["authority"]) || present(normalized["license"]),
         tags when is_list(tags) <- normalized["tags"] || [] do
      [
        normalized
        |> Map.put("title", title)
        |> Map.put("url", url)
        |> Map.put("tags", Enum.filter(tags, &is_binary/1))
      ]
    else
      _ -> []
    end
  end

  defp normalize_entry(_entry), do: []

  defp best_match(entries, query_tokens) do
    entries
    |> Enum.map(fn entry -> {entry, score(entry, query_tokens)} end)
    |> Enum.filter(fn {_entry, score} -> score > 0 end)
    |> Enum.sort_by(fn {entry, score} -> {-score, entry["title"]} end)
    |> List.first()
    |> case do
      {entry, _score} -> entry
      nil -> nil
    end
  end

  defp score(entry, query_tokens) do
    entry_tokens =
      [entry["title"], entry["annotation"] | entry["tags"]]
      |> Enum.flat_map(&tokens/1)
      |> MapSet.new()

    query_tokens
    |> MapSet.intersection(entry_tokens)
    |> MapSet.size()
  end

  defp proposal_tokens(proposal) do
    [
      proposal.instructional_rationale,
      proposal.learner_task,
      get_in(proposal.metadata || %{}, ["research_query"])
      | proposal.objective_ids || []
    ]
    |> Enum.flat_map(&tokens/1)
    |> MapSet.new()
  end

  defp tokens(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(byte_size(&1) < 3))
  end

  defp tokens(_value), do: []

  defp safe_https_url(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port} = uri
      when is_binary(host) and host != "" and (is_nil(port) or port == 443) ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp safe_https_url(_value), do: nil

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil
  defp present(value) when is_binary(value), do: String.trim(value) != ""
  defp present(_value), do: false
end
