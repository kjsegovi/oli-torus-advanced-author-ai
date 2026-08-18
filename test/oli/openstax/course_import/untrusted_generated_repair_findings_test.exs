defmodule Oli.OpenStax.CourseImport.UntrustedGeneratedRepairFindingsTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    EnrichmentResearchSet,
    SimulationSpec
  }

  alias Oli.OpenStax.CourseImport.Enrichment.Generator.UntrustedGenerated

  test "forwards exact bounded validator finding details into the Sol repair request" do
    proposal = %EnrichmentProposal{id: Ecto.UUID.generate(), kind: "generated_simulation"}

    research = %EnrichmentResearchSet{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      status: "approved",
      content_hash: String.duplicate("a", 64),
      claims: [],
      proposed_sources: []
    }

    spec = %SimulationSpec{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      research_set_id: research.id,
      status: "approved",
      evidence_hash: research.content_hash,
      content_hash: String.duplicate("b", 64),
      spec_payload: %{
        "capi_manifest" => %{"inputs" => [], "outputs" => []},
        "library_ids" => []
      }
    }

    execution = fn _context, messages, _functions, _service ->
      repair_message = List.last(messages).content
      assert repair_message =~ "capi_sample_failed"
      assert repair_message =~ "sample_index"
      assert repair_message =~ "expected"
      assert repair_message =~ "actual"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "files" => %{"index.html" => "<!doctype html><title>Simulation</title>"},
             "manifest" => %{"entrypoint" => "index.html", "library_ids" => []},
             "capi_manifest" => %{"inputs" => [], "outputs" => []}
           }),
         metadata: %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end

    repair = %{
      candidate: %{
        files: %{"index.html" => "<!doctype html><title>Old</title>"},
        manifest: %{"entrypoint" => "index.html", "library_ids" => []},
        capi_manifest: %{"inputs" => [], "outputs" => []}
      },
      findings: [
        %{
          "category" => "sample",
          "code" => "capi_sample_failed",
          "message" => "CAPI sample did not match.",
          "details" => %{
            "sample_index" => 1,
            "expected" => %{"pressure" => 2},
            "actual" => %{"pressure" => 3}
          }
        }
      ]
    }

    assert {:ok, _bundle} =
             UntrustedGenerated.generate(proposal,
               simulation_spec: spec,
               research_set: research,
               repair: repair,
               service: service_config(),
               execution_fun: execution
             )
  end

  test "forwards bounded author guidance without changing the approved contracts" do
    proposal = %EnrichmentProposal{id: Ecto.UUID.generate(), kind: "generated_simulation"}

    research = %EnrichmentResearchSet{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      status: "approved",
      content_hash: String.duplicate("a", 64),
      claims: [],
      proposed_sources: []
    }

    spec = %SimulationSpec{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      research_set_id: research.id,
      status: "approved",
      evidence_hash: research.content_hash,
      content_hash: String.duplicate("b", 64),
      spec_payload: %{
        "capi_manifest" => %{"inputs" => [], "outputs" => []},
        "library_ids" => []
      }
    }

    execution = fn _context, messages, _functions, _service ->
      contract = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()

      assert get_in(contract, ["author_guidance", "instruction"]) ==
               "Make the comparison table visible before the chart."

      assert contract["approved_spec_hash"] == spec.content_hash
      assert contract["approved_research"]["content_hash"] == research.content_hash
      assert contract["author_guidance"]["authority"] =~ "specification"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "files" => %{"index.html" => "<!doctype html><title>Simulation</title>"},
             "manifest" => %{"entrypoint" => "index.html", "library_ids" => []},
             "capi_manifest" => %{"inputs" => [], "outputs" => []}
           }),
         metadata: %{}
       }}
    end

    assert {:ok, _bundle} =
             UntrustedGenerated.generate(proposal,
               simulation_spec: spec,
               research_set: research,
               author_feedback: "Make the comparison table visible before the chart.",
               service: service_config(),
               execution_fun: execution
             )
  end

  defp service_config do
    model = %RegisteredModel{
      id: -1,
      name: "test-model",
      provider: :open_ai,
      model: "gpt-5.6-sol",
      url_template: "https://api.openai.test",
      api_key: "test",
      timeout: 1_000,
      recv_timeout: 1_000,
      pool_class: :slow,
      routing_breaker_error_rate_threshold: 0.0,
      routing_breaker_429_threshold: 0.0,
      routing_breaker_latency_p95_ms: 0
    }

    %ServiceConfig{id: -1, name: "test", primary_model: model}
  end
end
