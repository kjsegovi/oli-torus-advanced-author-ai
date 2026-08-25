defmodule Oli.OpenStax.CourseImport.CodexWebSearchTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Enrichment.Research.CodexWebSearch
  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  test "returns the existing evidence contract with Codex billing metadata and allowlisted citations" do
    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare pressure as volume changes.",
      instructional_rationale: "Ground a gas-law simulation in authoritative evidence.",
      source_evidence: %{"block-1" => %{"summary" => "Pressure-volume relationship"}},
      metadata: %{
        "domain" => "chemistry",
        "research_query" => "pressure volume gas law"
      }
    }

    request_fun = fn payload ->
      assert "nist.gov" in payload["allowed_domains"]
      assert payload["model"] == "codex-proxy/gpt-5.6-terra"

      {:ok,
       %{
         "retrieved_sources" => [
           %{"url" => "https://www.nist.gov/a", "title" => "NIST A"},
           %{"url" => "https://pubchem.ncbi.nlm.nih.gov/b", "title" => "PubChem B"}
         ],
         "claims" => [
           %{
             "paraphrase" => "Pressure changes inversely with volume under bounded conditions.",
             "citation_urls" => ["https://www.nist.gov/a"]
           },
           %{
             "paraphrase" => "The relationship assumes a fixed amount of gas.",
             "citation_urls" => ["https://pubchem.ncbi.nlm.nih.gov/b"]
           }
         ],
         "search_count" => 2,
         "provider" => "codex_cli",
         "billing_source" => "chatgpt_plan",
         "model" => "gpt-5.6-terra",
         "usage" => %{"input_tokens" => 200, "output_tokens" => 80}
       }}
    end

    assert {:ok, result} =
             CodexWebSearch.research(proposal,
               request_fun: request_fun,
               model: "codex-proxy/gpt-5.6-terra"
             )

    assert result.evidence["provider"] == "codex_cli"
    assert result.evidence["billing_source"] == "chatgpt_plan"
    assert result.evidence["source_count"] == 2
    assert length(result.evidence["claims"]) == 2
    assert result.delivery_mode == "generated_simulation"
  end

  test "rejects citations returned outside the server allowlist" do
    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare pressure.",
      instructional_rationale: "Use evidence.",
      source_evidence: %{"block-1" => %{"summary" => "Evidence"}},
      metadata: %{"domain" => "chemistry", "research_query" => "pressure"}
    }

    assert {:error, :research_contract_failed} =
             CodexWebSearch.research(proposal,
               request_fun: fn _payload ->
                 {:ok,
                  %{
                    "retrieved_sources" => [
                      %{"url" => "https://evil.example/a", "title" => "Bad"},
                      %{"url" => "https://www.nist.gov/a", "title" => "Good"}
                    ],
                    "claims" => [
                      %{
                        "paraphrase" => "Unsupported claim.",
                        "citation_urls" => ["https://evil.example/a"]
                      }
                    ],
                    "search_count" => 1
                  }}
               end
             )
  end
end
