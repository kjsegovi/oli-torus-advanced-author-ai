defmodule Oli.OpenStax.CourseImport.Enrichment.Research.ResponsesWebSearch do
  @moduledoc """
  OpenAI Responses API web-search adapter for author-reviewed simulation evidence.

  It stores the complete consulted source list and claim-level paraphrases, but
  never persists fetched page bodies. Domain filters and strict post-response
  validation provide a second boundary around the hosted search tool.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Research

  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @default_model "gpt-5.6-terra"
  @prompt_version "simulation-research-v1"
  @max_searches 4
  @max_retrieved_sources 12
  @min_proposed_sources 2
  @max_proposed_sources 8

  @domain_allowlists %{
    "chemistry" => ~w(nist.gov iupac.org pubchem.ncbi.nlm.nih.gov),
    "physics" => ~w(nist.gov),
    "biology" => ~w(nih.gov ncbi.nlm.nih.gov cdc.gov),
    "mathematics" => ~w(dlmf.nist.gov ams.org),
    "astronomy" => ~w(nasa.gov esa.int noirlab.edu),
    "computer_science" => ~w(acm.org ieee.org rfc-editor.org)
  }

  @impl true
  def available? do
    Application.get_env(:oli, :openstax_web_research_enabled, false) == true and
      present?(System.get_env("OPENAI_API_KEY"))
  end

  @impl true
  def research(%EnrichmentProposal{kind: "generated_simulation"} = proposal, opts) do
    domain = proposal_domain(proposal)
    query = get_in(proposal.metadata || %{}, ["research_query"])
    allowed_domains = allowed_domains(domain, opts)

    with true <- present?(query),
         true <- allowed_domains != [],
         {:ok, response} <- request(payload(proposal, domain, query, allowed_domains, opts), opts),
         {:ok, result} <- parse_response(response, proposal, domain, query, allowed_domains, opts) do
      {:ok, result}
    else
      false -> {:error, :invalid_research_request}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :research_provider_failed}
  end

  def research(%EnrichmentProposal{}, _opts), do: {:error, :not_generated_simulation}
  def research(_, _opts), do: {:error, :invalid_input}

  def allowed_domains(domain, opts \\ []) do
    configured_edu =
      Keyword.get(opts, :approved_edu_domains) ||
        Application.get_env(:oli, :openstax_research_approved_edu_domains, [])

    (@domain_allowlists[normalize_domain(domain)] || [])
    |> Kernel.++(List.wrap(configured_edu))
    |> Enum.flat_map(&normalize_domain_filter/1)
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp payload(proposal, domain, query, allowed_domains, opts) do
    model =
      Keyword.get(opts, :model) || System.get_env("OPENSTAX_SIMULATION_RESEARCH_MODEL") ||
        @default_model

    %{
      "model" => model,
      "reasoning" => %{"effort" => "medium"},
      "tools" => [
        %{
          "type" => "web_search",
          "filters" => %{"allowed_domains" => allowed_domains}
        }
      ],
      "tool_choice" => "auto",
      "include" => ["web_search_call.action.sources"],
      "input" => research_prompt(proposal, domain, query)
    }
  end

  defp research_prompt(proposal, domain, query) do
    Jason.encode!(%{
      "role" => "simulation evidence researcher",
      "domain" => domain,
      "query" => query,
      "learner_task" => proposal.learner_task,
      "instructional_rationale" => proposal.instructional_rationale,
      "limits" => %{
        "maximum_search_actions" => @max_searches,
        "maximum_consulted_sources" => @max_retrieved_sources,
        "proposed_source_count" => [@min_proposed_sources, @max_proposed_sources]
      },
      "required_output" => %{
        "claims" => [
          %{
            "paraphrase" => "a concise claim paraphrase grounded by the cited URLs",
            "citation_urls" => ["https://authoritative.example/source"]
          }
        ]
      },
      "instructions" => [
        "Use no more than four search actions.",
        "Consult no more than twelve sources.",
        "Return only JSON and never copy source passages.",
        "Every claim must cite one or more consulted source URLs."
      ]
    })
  end

  defp request(payload, opts) do
    case Keyword.get(opts, :request_fun) do
      fun when is_function(fun, 1) ->
        fun.(payload)

      _ ->
        url =
          (System.get_env("OPENAI_API_URL") || "https://api.openai.com")
          |> String.trim_trailing("/")
          |> Kernel.<>("/v1/responses")

        headers = [
          {"Authorization", "Bearer #{System.fetch_env!("OPENAI_API_KEY")}"},
          {"Content-Type", "application/json"}
        ]

        request_opts = [
          timeout: Keyword.get(opts, :timeout, 30_000),
          recv_timeout: Keyword.get(opts, :recv_timeout, 120_000),
          hackney: [pool: :genai_slow_pool]
        ]

        case HTTPoison.post(url, Jason.encode!(payload), headers, request_opts) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            Jason.decode(body)

          {:ok, %HTTPoison.Response{status_code: 429}} ->
            {:error, :rate_limited}

          {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
            {:error, :provider_unavailable}

          {:ok, %HTTPoison.Response{}} ->
            {:error, :research_provider_rejected}

          {:error, %HTTPoison.Error{reason: :timeout}} ->
            {:error, :provider_timeout}

          {:error, %HTTPoison.Error{}} ->
            {:error, :provider_unavailable}
        end
    end
  end

  defp parse_response(response, proposal, domain, query, allowed_domains, opts) do
    response = stringify(response)
    output = List.wrap(response["output"])
    search_calls = Enum.filter(output, &(&1["type"] == "web_search_call"))
    search_count = Enum.count(search_calls, &(get_in(&1, ["action", "type"]) == "search"))

    retrieved =
      search_calls
      |> Enum.flat_map(&List.wrap(get_in(&1, ["action", "sources"])))
      |> Enum.flat_map(&normalize_source(&1, allowed_domains))
      |> Enum.uniq_by(& &1["url"])

    with true <- search_count in 1..@max_searches,
         true <- length(retrieved) in @min_proposed_sources..@max_retrieved_sources,
         {:ok, claims} <- decode_claims(output_text(output)),
         :ok <- validate_claims(claims, retrieved),
         proposed <- proposed_sources(claims, retrieved),
         true <- length(proposed) in @min_proposed_sources..@max_proposed_sources,
         true <- is_map(proposal.source_evidence) and map_size(proposal.source_evidence) > 0 do
      accessed_at = Keyword.get(opts, :now, DateTime.utc_now())
      source_hash = hash(%{"source_evidence" => proposal.source_evidence})

      evidence = %{
        "schema_version" => 1,
        "domain" => domain,
        "query" => query,
        "source_evidence" => proposal.source_evidence,
        "retrieved_sources" => retrieved,
        "proposed_sources" => proposed,
        "claims" => claims,
        "search_count" => search_count,
        "source_count" => length(retrieved),
        "provider" => "open_ai",
        "model" => response["model"],
        "provider_usage" => response["usage"] || %{},
        "prompt_version" => @prompt_version,
        "source_hash" => source_hash,
        "accessed_at" => DateTime.to_iso8601(accessed_at)
      }

      evidence = Map.put(evidence, "content_hash", hash(evidence))

      {:ok,
       %{
         evidence: evidence,
         resource_title: "Reviewed evidence for #{humanize_domain(domain)} simulation",
         delivery_mode: "generated_simulation"
       }}
    else
      false -> {:error, :research_contract_failed}
      {:error, _} = error -> error
    end
  end

  defp output_text(output) do
    output
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(&List.wrap(&1["content"]))
    |> Enum.filter(&(&1["type"] == "output_text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp decode_claims(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(strip_code_fence(raw)),
         claims when is_list(claims) <- decoded["claims"],
         normalized <- Enum.flat_map(claims, &normalize_claim/1),
         true <- normalized != [] do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_research_claims}
    end
  end

  defp decode_claims(_), do: {:error, :invalid_research_claims}

  defp normalize_claim(%{} = claim) do
    claim = stringify(claim)
    paraphrase = claim["paraphrase"] || claim["claim"]

    urls =
      (claim["citation_urls"] || claim["source_urls"])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if present?(paraphrase) and urls != [] do
      [%{"paraphrase" => String.trim(paraphrase), "citation_urls" => urls}]
    else
      []
    end
  end

  defp normalize_claim(_), do: []

  defp validate_claims(claims, sources) do
    urls = MapSet.new(sources, & &1["url"])

    if Enum.all?(claims, fn claim ->
         claim["citation_urls"] != [] and
           Enum.all?(claim["citation_urls"], &MapSet.member?(urls, &1))
       end) do
      :ok
    else
      {:error, :uncited_research_claim}
    end
  end

  defp proposed_sources(claims, sources) do
    cited = claims |> Enum.flat_map(& &1["citation_urls"]) |> MapSet.new()

    sources
    |> Enum.filter(&MapSet.member?(cited, &1["url"]))
    |> Enum.take(@max_proposed_sources)
  end

  defp normalize_source(source, allowed_domains) when is_map(source) do
    source = stringify(source)

    case safe_allowed_url(source["url"], allowed_domains) do
      {:ok, url} -> [%{"url" => url, "title" => present_string(source["title"]) || url}]
      :error -> []
    end
  end

  defp normalize_source(_, _), do: []

  defp safe_allowed_url(value, allowed_domains) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port} = uri
      when is_binary(host) and (is_nil(port) or port == 443) ->
        host = String.downcase(host)

        if Enum.any?(allowed_domains, &(host == &1 or String.ends_with?(host, ".#{&1}"))),
          do: {:ok, URI.to_string(uri)},
          else: :error

      _ ->
        :error
    end
  end

  defp safe_allowed_url(_, _), do: :error

  defp normalize_domain_filter(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase() |> String.trim_leading("https://")

    if value != "" and not String.contains?(value, ["/", "?", "#", "@"]),
      do: [value],
      else: []
  end

  defp normalize_domain_filter(_), do: []

  defp proposal_domain(proposal),
    do: normalize_domain(get_in(proposal.metadata || %{}, ["domain"]))

  defp normalize_domain(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")

  defp normalize_domain(_), do: nil

  defp humanize_domain(domain), do: domain |> to_string() |> String.replace("_", " ")
  defp hash(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  defp strip_code_fence(content),
    do:
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp present_string(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp present_string(_), do: nil
  defp present?(value), do: not is_nil(present_string(value))
end
