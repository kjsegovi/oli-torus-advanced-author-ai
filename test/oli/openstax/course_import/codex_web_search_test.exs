defmodule Oli.OpenStax.CourseImport.CodexWebSearchTest do
  use ExUnit.Case, async: false

  alias Oli.OpenStax.CourseImport.Enrichment.Research.CodexWebSearch
  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  setup do
    original_env = Application.get_env(:oli, :env)
    original_enabled = Application.get_env(:oli, :openstax_codex_poc_enabled)
    original_url = Application.get_env(:oli, :openstax_codex_proxy_url)
    original_token = Application.get_env(:oli, :openstax_codex_proxy_token)
    original_openai_key = System.get_env("OPENAI_API_KEY")
    Application.put_env(:oli, :env, :dev)
    Application.put_env(:oli, :openstax_codex_poc_enabled, true)
    Application.put_env(:oli, :openstax_codex_proxy_url, "http://127.0.0.1:4001")
    Application.put_env(:oli, :openstax_codex_proxy_token, "research-test-bridge-token")

    on_exit(fn ->
      restore_application_env(:env, original_env)
      restore_application_env(:openstax_codex_poc_enabled, original_enabled)
      restore_application_env(:openstax_codex_proxy_url, original_url)
      restore_application_env(:openstax_codex_proxy_token, original_token)
      restore_system_env("OPENAI_API_KEY", original_openai_key)
    end)
  end

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

  test "sends the runtime bridge bearer token through the injected request seam" do
    token = "research-runtime-token"
    Application.put_env(:oli, :openstax_codex_proxy_token, token)

    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare pressure.",
      instructional_rationale: "Use evidence.",
      source_evidence: %{"block-1" => %{"summary" => "Evidence"}},
      metadata: %{"domain" => "chemistry", "research_query" => "pressure"}
    }

    request_fun = fn payload, headers ->
      assert payload["model"] == "codex-proxy/gpt-5.6-terra"
      assert {"Authorization", "Bearer #{token}"} in headers

      {:ok,
       %{
         "retrieved_sources" => [
           %{"url" => "https://www.nist.gov/a", "title" => "NIST A"},
           %{"url" => "https://pubchem.ncbi.nlm.nih.gov/b", "title" => "PubChem B"}
         ],
         "claims" => [
           %{
             "paraphrase" => "Pressure changes with volume.",
             "citation_urls" => ["https://www.nist.gov/a"]
           },
           %{
             "paraphrase" => "The relationship assumes a fixed amount of gas.",
             "citation_urls" => ["https://pubchem.ncbi.nlm.nih.gov/b"]
           }
         ],
         "search_count" => 2
       }}
    end

    assert {:ok, _result} = CodexWebSearch.research(proposal, request_fun: request_fun)
  end

  test "resumed Local Codex research stops before HTTP execution when runtime policy changes" do
    global_key = "synthetic-research-policy-openai-key-must-not-escape"
    bridge_token = "synthetic-research-policy-bridge-token-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)
    Application.put_env(:oli, :openstax_codex_proxy_token, bridge_token)

    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare pressure.",
      instructional_rationale: "Use evidence.",
      source_evidence: %{"block-1" => %{"summary" => "Evidence"}},
      metadata: %{"domain" => "chemistry", "research_query" => "pressure"}
    }

    invalid_policies = [
      {:disabled, :dev, false, "http://127.0.0.1:4001"},
      {:non_loopback_url, :dev, true, "https://codex.example.com"}
    ]

    for {reason, env, enabled, url} <- invalid_policies do
      Application.put_env(:oli, :env, env)
      Application.put_env(:oli, :openstax_codex_poc_enabled, enabled)
      Application.put_env(:oli, :openstax_codex_proxy_url, url)

      result =
        CodexWebSearch.research(proposal,
          request_fun: fn _payload, _headers ->
            flunk("invalid Local Codex runtime policy must stop before research HTTP execution")
          end
        )

      assert {:error, {:local_codex_configuration_error, ^reason}} = result
      refute inspect(result) =~ global_key
      refute inspect(result) =~ bridge_token
    end
  end

  test "missing bridge token fails before research provider requests or global key fallback" do
    global_key = "synthetic-research-openai-key-must-not-escape"
    System.put_env("OPENAI_API_KEY", global_key)

    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare pressure.",
      instructional_rationale: "Use evidence.",
      source_evidence: %{"block-1" => %{"summary" => "Evidence"}},
      metadata: %{"domain" => "chemistry", "research_query" => "pressure"}
    }

    for token <- [nil, "", "   "] do
      restore_application_env(:openstax_codex_proxy_token, token)

      assert {:error, {:local_codex_configuration_error, :missing_proxy_token}} =
               CodexWebSearch.research(proposal,
                 request_fun: fn _payload, _headers ->
                   flunk("missing bridge tokens must fail before a research provider request")
                 end
               )
    end
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

  defp restore_application_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_application_env(key, value), do: Application.put_env(:oli, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
