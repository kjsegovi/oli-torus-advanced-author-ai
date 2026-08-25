defmodule Oli.OpenStax.CourseImport.Enrichment.Research.CodexWebSearch do
  @moduledoc "Local Codex live-web-search adapter for POC simulation evidence."

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Research

  alias Oli.OpenStax.CourseImport.AIBackend
  alias Oli.OpenStax.CourseImport.Enrichment.Research.ResponsesWebSearch
  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @impl true
  def available?, do: AIBackend.poc_enabled?()

  @impl true
  def available?(opts) do
    Keyword.has_key?(opts, :request_fun) or AIBackend.readiness().ready?
  end

  @impl true
  def research(%EnrichmentProposal{kind: "generated_simulation"} = proposal, opts) do
    domain = normalize_domain(get_in(proposal.metadata || %{}, ["domain"]))
    query = get_in(proposal.metadata || %{}, ["research_query"])
    allowed_domains = ResponsesWebSearch.allowed_domains(domain, opts)

    with true <- present?(query),
         true <- allowed_domains != [],
         {:ok, response} <- request(payload(proposal, domain, query, allowed_domains, opts), opts),
         {:ok, result} <-
           ResponsesWebSearch.build_evidence(
             response,
             proposal,
             domain,
             query,
             allowed_domains,
             opts
           ) do
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

  defp payload(proposal, domain, query, allowed_domains, opts) do
    %{
      "model" => Keyword.get(opts, :model, "codex-proxy/gpt-5.6-terra"),
      "allowed_domains" => allowed_domains,
      "prompt" => ResponsesWebSearch.research_prompt(proposal, domain, query)
    }
  end

  defp request(payload, opts) do
    case Keyword.get(opts, :request_fun) do
      fun when is_function(fun, 1) ->
        fun.(payload)

      _ ->
        url =
          Keyword.get(opts, :proxy_url, AIBackend.proxy_url())
          |> String.trim_trailing("/")
          |> Kernel.<>("/v1/codex/research")

        request_opts = [
          timeout: Keyword.get(opts, :timeout, 30_000),
          recv_timeout: Keyword.get(opts, :recv_timeout, 300_000),
          hackney: [pool: :genai_slow_pool]
        ]

        case HTTPoison.post(
               url,
               Jason.encode!(payload),
               [{"Content-Type", "application/json"}],
               request_opts
             ) do
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

  defp normalize_domain(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")

  defp normalize_domain(_), do: nil
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
