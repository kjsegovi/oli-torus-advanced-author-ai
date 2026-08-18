defmodule Oli.OpenStax.CourseImport.SimulationGovernanceContractsTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{
    EnrichmentProposal,
    EnrichmentResearchSet,
    SimulationOpportunityPipeline,
    SimulationOpportunityV1,
    SimulationDomainReferences,
    SimulationPilotCorpus,
    SimulationSpec,
    SimulationSpecV1
  }

  alias Oli.OpenStax.CourseImport.Enrichment.{
    ArtifactCritic,
    Generator.UntrustedGenerated,
    LibraryRegistry,
    Research.ResponsesWebSearch,
    SimulationSpecDesigner
  }

  alias Oli.GenAI.Completions.{RegisteredModel, ServiceConfig}

  @domains ~w(chemistry physics biology mathematics astronomy computer_science)
  @hash String.duplicate("a", 64)
  @root Path.expand("../../../..", __DIR__)

  test "normalizes stable, source-grounded opportunities in all six pilot domains" do
    lesson = %{
      "source_blocks" => [%{"id" => "block-1", "kind" => "paragraph", "text" => "Evidence"}]
    }

    content = %{
      "objective_catalog" => [%{"id" => "objective-1"}],
      "experience_blueprint" => %{"stages" => [%{"id" => "stage-1"}]}
    }

    for domain <- @domains do
      candidate = %{
        "domain" => domain,
        "objective_ids" => ["objective-1"],
        "source_evidence" => %{"block_ids" => ["block-1"]},
        "instructional_rationale" => "Make the source relationship observable.",
        "learner_task" => "Predict, change one bounded parameter, and explain the result.",
        "misconception_target" => "A common causal misconception",
        "placement" => %{"stage_id" => "stage-1"},
        "research_query" => "Authoritative evidence for the bounded model",
        "expected_instructional_value" => "Connect prediction, observation, and explanation."
      }

      assert {:ok, [first]} = SimulationOpportunityV1.build([candidate], lesson, content)
      assert {:ok, [second]} = SimulationOpportunityV1.build([candidate], lesson, content)
      assert first["id"] == second["id"]
      assert first["domain"] == domain
      assert first["source_evidence"] == %{"block_ids" => ["block-1"]}
    end
  end

  test "source-backed pilot contracts cover one distinct simulation in every domain" do
    pilot_cases = SimulationPilotCorpus.pilot_cases()

    assert MapSet.new(pilot_cases, & &1["domain"]) == MapSet.new(@domains)

    for pilot <- pilot_cases do
      lesson = pilot["lesson"]
      evidence_ids = lesson["expected_evidence_block_ids"]

      content = %{
        "objective_catalog" => [%{"id" => "objective-1"}],
        "experience_blueprint" => %{"stages" => [%{"id" => "investigation"}]}
      }

      candidate = %{
        "domain" => pilot["domain"],
        "objective_ids" => ["objective-1"],
        "source_evidence" => %{"block_ids" => evidence_ids},
        "instructional_rationale" =>
          "Make the cited source relationship observable before the native follow-up.",
        "learner_task" => pilot["learner_task"],
        "misconception_target" => pilot["misconception"],
        "placement" => %{"stage_id" => "investigation"},
        "research_query" => "Authoritative evidence for #{pilot["title"]}",
        "expected_instructional_value" =>
          "Connect a prediction, bounded observation, and source-grounded explanation."
      }

      assert {:ok, [opportunity]} = SimulationOpportunityV1.build([candidate], lesson, content)
      assert opportunity["domain"] == pilot["domain"]
      assert opportunity["source_evidence"] == %{"block_ids" => evidence_ids}

      research = SimulationPilotCorpus.research_contract(pilot)
      spec = SimulationPilotCorpus.spec_contract(pilot, research)
      opts = [three_d_enabled: pilot["rendering_mode"] == "3d"]

      validation_opts =
        opts ++
          [
            expected_domain: pilot["domain"],
            allowed_objective_ids: ["objective-1"]
          ]

      assert {:ok, normalized, validation} =
               SimulationSpecV1.validate(spec, research, validation_opts)

      assert normalized["domain"] == pilot["domain"]
      assert validation["status"] == "passed"
      assert validation["rendering_mode"] == pilot["rendering_mode"]
      assert validation["sample_case_count"] >= 3
      assert normalized["contract_profile"] == "domain_reference_v1"
      assert is_map(normalized["model"])
      assert is_map(normalized["misconception_handling"])
      assert is_binary(get_in(normalized, ["native_follow_up", "activity_id"]))
      assert is_binary(get_in(normalized, ["remediation", "content_group_id"]))

      parameter_ids = MapSet.new(normalized["parameters"], & &1["id"])
      control_ids = MapSet.new(normalized["controls"], & &1["parameter_id"])
      capi_input_ids = MapSet.new(normalized["capi_manifest"]["inputs"], & &1["key"])
      output_ids = MapSet.new(normalized["observations"], & &1["output_id"])
      capi_output_ids = MapSet.new(normalized["capi_manifest"]["outputs"], & &1["key"])

      assert parameter_ids == control_ids
      assert parameter_ids == capi_input_ids
      assert output_ids == capi_output_ids

      for sample <- normalized["sample_cases"] do
        assert {:ok, expected} =
                 SimulationDomainReferences.evaluate(pilot["domain"], sample["inputs"])

        assert_reference_outputs(expected, sample["expected_outputs"], sample["tolerance"])
      end

      if pilot["domain"] == "astronomy" do
        assert normalized["library_ids"] == ["three-0.185.1"]
        assert is_binary(get_in(normalized, ["accessibility", "webgl_fallback"]))
      end

      if pilot["domain"] == "computer_science" do
        assert get_in(normalized, ["algorithm", "max_steps"]) <= 10_000
        refute get_in(normalized, ["algorithm", "accepts_learner_code"])
        assert get_in(normalized, ["model", "algorithm_id"]) == "insertion_sort"

        assert Enum.any?(normalized["sample_cases"], fn sample ->
                 is_binary(get_in(sample, ["expected_outputs", "state"]))
               end)
      end
    end
  end

  test "six domain references compute substantive expected observations" do
    research_by_domain =
      SimulationPilotCorpus.pilot_cases()
      |> Map.new(fn pilot ->
        {pilot["domain"], SimulationPilotCorpus.research_contract(pilot)}
      end)

    for domain <- SimulationDomainReferences.domains() do
      spec = SimulationDomainReferences.build!(domain, Map.fetch!(research_by_domain, domain))
      outputs = Enum.map(spec["sample_cases"], & &1["expected_outputs"])

      assert length(outputs) >= 3
      assert length(Enum.uniq(outputs)) > 1
      refute Enum.any?(outputs, fn output -> output == %{"y" => 30} end)
    end

    chemistry = reference_spec("chemistry")
    assert get_in(chemistry, ["model", "equations", Access.at(0), "expression"]) =~ "volume_l"

    physics = reference_spec("physics")

    assert MapSet.new(physics["observations"], & &1["output_id"]) ==
             MapSet.new(~w(final_velocity_m_s displacement_m))

    biology = reference_spec("biology")
    assert get_in(biology, ["model", "equations", Access.at(0), "expression"]) =~ "exp(-r * t)"

    mathematics = reference_spec("mathematics")

    assert MapSet.new(mathematics["observations"], & &1["output_id"]) ==
             MapSet.new(~w(derivative_estimate exact_derivative absolute_error))

    astronomy = reference_spec("astronomy")
    assert astronomy["rendering_mode"] == "3d"
    assert astronomy["library_ids"] == ["three-0.185.1"]
    assert get_in(astronomy, ["accessibility", "webgl_fallback"]) =~ "table"

    computer_science = reference_spec("computer_science")
    assert get_in(computer_science, ["algorithm", "max_items"]) == 5
    refute get_in(computer_science, ["algorithm", "accepts_learner_code"])
    refute computer_science["learner_code_execution"]
  end

  test "reference evaluators reproduce known domain cases" do
    assert {:ok, %{"pressure_kpa" => pressure}} =
             SimulationDomainReferences.evaluate("chemistry", %{
               "amount_mol" => 1.0,
               "volume_l" => 24.465,
               "temperature_k" => 298.15
             })

    assert_in_delta pressure, 101.325, 0.01

    assert {:ok, %{"final_velocity_m_s" => 10.0, "displacement_m" => 25.0}} =
             SimulationDomainReferences.evaluate("physics", %{
               "initial_velocity_m_s" => 0.0,
               "acceleration_m_s2" => 2.0,
               "time_s" => 5.0
             })

    assert {:ok, %{"population" => initial_population}} =
             SimulationDomainReferences.evaluate("biology", %{
               "initial_population" => 100.0,
               "growth_rate_per_step" => 0.2,
               "carrying_capacity" => 1_000.0,
               "elapsed_steps" => 0.0
             })

    assert_in_delta initial_population, 100.0, 1.0e-9

    assert {:ok,
            %{
              "derivative_estimate" => derivative_estimate,
              "exact_derivative" => 12.0,
              "absolute_error" => derivative_error
            }} =
             SimulationDomainReferences.evaluate("mathematics", %{"x" => 2.0, "h" => 0.5})

    assert_in_delta derivative_estimate, 12.25, 1.0e-9
    assert_in_delta derivative_error, 0.25, 1.0e-9

    assert {:ok, %{"period_years" => 8.0}} =
             SimulationDomainReferences.evaluate("astronomy", %{
               "semi_major_axis_au" => 4.0,
               "eccentricity" => 0.5,
               "true_anomaly_deg" => 180.0
             })

    assert {:ok, %{"state" => "1,3,4,2", "sorted" => false}} =
             SimulationDomainReferences.evaluate("computer_science", %{
               "case_id" => 1,
               "step_index" => 2
             })
  end

  test "spec design prompt receives the substantive reference for its selected domain" do
    research = reference_research("chemistry")

    prompt =
      SimulationSpecV1.prompt_contract(research, %{
        "id" => "gas-opportunity",
        "domain" => "chemistry",
        "objective_ids" => ["objective-1"]
      })

    reference = prompt["domain_reference"]
    assert reference["contract_profile"] == "domain_reference_v1"
    assert length(reference["sample_cases"]) >= 3

    assert get_in(reference, ["model", "equations", Access.at(0), "expression"]) =~
             "ideal_gas_constant"
  end

  test "strict reference validation rejects cross-domain, unmapped, trivial, and unroutable specs" do
    research = reference_research("physics")

    invalid =
      reference_spec("physics")
      |> Map.put("domain", "chemistry")
      |> put_in(["controls", Access.at(0), "parameter_id"], "invented_parameter")
      |> put_in(
        ["sample_cases", Access.at(1), "expected_outputs"],
        get_in(reference_spec("physics"), ["sample_cases", Access.at(0), "expected_outputs"])
      )
      |> put_in(
        ["sample_cases", Access.at(2), "expected_outputs"],
        get_in(reference_spec("physics"), ["sample_cases", Access.at(0), "expected_outputs"])
      )
      |> put_in(["native_follow_up", "activity_id"], "not a valid id")

    assert {:error, findings} =
             SimulationSpecV1.validate(invalid, research,
               expected_domain: "physics",
               allowed_objective_ids: ["objective-1"]
             )

    codes = MapSet.new(findings, & &1["code"])
    assert MapSet.member?(codes, "simulation_domain_mismatch")
    assert MapSet.member?(codes, "parameter_control_mapping_mismatch")
    assert MapSet.member?(codes, "trivial_sample_outputs")
    assert MapSet.member?(codes, "invalid_native_follow_up_id")
  end

  test "rejects unknown evidence, unsupported domains, and more than three opportunities" do
    lesson = %{"source_blocks" => [%{"id" => "block-1"}]}

    content = %{
      "objective_catalog" => [%{"id" => "objective-1"}],
      "experience_blueprint" => %{"stages" => [%{"id" => "stage-1"}]}
    }

    invalid = opportunity("geology") |> put_in(["source_evidence", "block_ids"], ["invented"])

    assert {:error, findings} = SimulationOpportunityV1.build([invalid], lesson, content)
    codes = MapSet.new(findings, & &1["code"])
    assert MapSet.member?(codes, "unsupported_simulation_domain")
    assert MapSet.member?(codes, "unknown_simulation_evidence")

    assert {:error, [%{"code" => "too_many_simulation_opportunities"}]} =
             SimulationOpportunityV1.build(
               List.duplicate(opportunity("physics"), 4),
               lesson,
               content
             )
  end

  test "opportunity planning repairs a contract finding before independent approval" do
    lesson = %{
      "source_blocks" => [%{"id" => "block-1", "kind" => "exercise", "text" => "Evidence"}]
    }

    content = %{
      "objective_catalog" => [%{"id" => "objective-1"}],
      "experience_blueprint" => %{"stages" => [%{"id" => "stage-1"}]}
    }

    Process.put(:opportunity_attempt, 0)

    designer = fn context, messages, _functions, _service ->
      assert context.phase == :simulation_opportunity_designer
      attempt = Process.get(:opportunity_attempt, 0) + 1
      Process.put(:opportunity_attempt, attempt)

      if attempt == 2 do
        assert Enum.any?(messages, fn message ->
                 is_binary(message.content) and message.content =~ "unknown_simulation_evidence"
               end)
      end

      candidate =
        if attempt == 1 do
          put_in(opportunity("physics"), ["source_evidence", "block_ids"], ["invented"])
        else
          opportunity("physics")
        end

      {:ok,
       %{
         content: Jason.encode!(%{"opportunities" => [candidate]}),
         metadata: %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end

    critic = fn context, _messages, _functions, _service ->
      assert context.phase == :simulation_opportunity_critic

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "approved" => true,
             "confidence" => 0.98,
             "findings" => [],
             "summary" => "Source-grounded and instructionally useful."
           }),
         metadata: %{"input_tokens" => 8, "output_tokens" => 4}
       }}
    end

    services = %{
      designer: service_config("gpt-5.6-terra"),
      critic: service_config("gpt-5.6-sol")
    }

    assert {:ok, [planned], metadata} =
             SimulationOpportunityPipeline.plan(lesson, content, services,
               opportunity_execution_fun: designer,
               opportunity_critic_fun: critic
             )

    assert planned["domain"] == "physics"
    assert Process.get(:opportunity_attempt) == 2
    assert length(metadata["attempts"]) == 2
    assert metadata["repair_count"] == 1
    assert is_integer(metadata["duration_ms"])
    assert get_in(metadata, ["attempts", Access.at(1), "critic_usage", "input_tokens"]) == 8
    assert get_in(metadata, ["designer", "model"]) == "gpt-5.6-terra"
    assert get_in(metadata, ["critic", "model"]) == "gpt-5.6-sol"
  end

  test "accepts complete deterministic specs and rejects uncited or unbounded contracts" do
    research = research()

    for domain <- @domains do
      candidate = valid_spec(domain)
      assert {:ok, normalized, validation} = SimulationSpecV1.validate(candidate, research)
      assert normalized["domain"] == domain
      assert validation["status"] == "passed"
    end

    invalid =
      valid_spec("computer_science")
      |> put_in(["constants", Access.at(0), "citation_urls"], ["https://invented.example/value"])
      |> put_in(["algorithm", "max_steps"], 10_001)
      |> Map.put("learner_code_execution", true)

    assert {:error, findings} = SimulationSpecV1.validate(invalid, research)
    codes = MapSet.new(findings, & &1["code"])
    assert MapSet.member?(codes, "invented_constant_citation")
    assert MapSet.member?(codes, "unbounded_algorithm_steps")
    assert MapSet.member?(codes, "learner_code_execution_forbidden")
  end

  test "spec design repairs a deterministic finding before Sol criticism" do
    proposal = %EnrichmentProposal{
      id: Ecto.UUID.generate(),
      kind: "generated_simulation",
      objective_ids: ["objective-1"],
      source_evidence: %{"block_ids" => ["block-1"]},
      placement: %{"stage_id" => "stage-1"},
      learner_task: "Predict and explain.",
      instructional_rationale: "Make the relationship observable.",
      metadata: %{
        "planner_id" => "pilot-physics",
        "domain" => "physics",
        "misconception_target" => "Constant acceleration means constant velocity",
        "expected_instructional_value" => "Connect prediction and observation."
      }
    }

    research = %EnrichmentResearchSet{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      status: "approved",
      content_hash: @hash,
      source_hash: String.duplicate("b", 64),
      source_evidence: proposal.source_evidence,
      proposed_sources: research()["proposed_sources"],
      retrieved_sources: research()["proposed_sources"],
      claims: [
        %{
          "paraphrase" => "The model states bounded variables and limitations.",
          "citation_urls" => Enum.map(research()["proposed_sources"], & &1["url"])
        }
      ]
    }

    Process.put(:spec_attempt, 0)

    designer = fn context, messages, _functions, _service ->
      assert context.phase == :simulation_spec_designer
      attempt = Process.get(:spec_attempt, 0) + 1
      Process.put(:spec_attempt, attempt)

      if attempt == 2 do
        assert Enum.any?(messages, fn message ->
                 is_binary(message.content) and
                   message.content =~ "learner_code_execution_forbidden"
               end)
      end

      candidate =
        if attempt == 1,
          do: Map.put(valid_spec("physics"), "learner_code_execution", true),
          else: valid_spec("physics")

      {:ok,
       %{
         content: Jason.encode!(candidate),
         metadata: %{"input_tokens" => 20, "output_tokens" => 10}
       }}
    end

    critic = fn context, _messages, _functions, _service ->
      assert context.phase == :simulation_spec_critic

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "approved" => true,
             "confidence" => 0.97,
             "findings" => [],
             "summary" => "The bounded contract is approved."
           }),
         metadata: %{"input_tokens" => 12, "output_tokens" => 6}
       }}
    end

    services = %{
      designer: service_config("gpt-5.6-terra"),
      critic: service_config("gpt-5.6-sol")
    }

    assert {:ok, result} =
             SimulationSpecDesigner.generate(proposal, research,
               services: services,
               spec_execution_fun: designer,
               spec_critic_fun: critic
             )

    assert result.spec["domain"] == "physics"
    assert result.repair_count == 1
    assert length(result.history) == 2
    assert Process.get(:spec_attempt) == 2
  end

  test "web research requests complete source metadata and stores paraphrases without page bodies" do
    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      learner_task: "Compare predicted and observed pressure.",
      instructional_rationale: "Make the inverse relationship visible.",
      source_evidence: %{"block_ids" => ["openstax-block-1"]},
      metadata: %{
        "domain" => "chemistry",
        "research_query" => "authoritative gas relationship evidence"
      }
    }

    request_fun = fn payload ->
      send(self(), {:research_payload, payload})

      {:ok,
       %{
         "model" => "gpt-5.6-terra",
         "usage" => %{"input_tokens" => 120, "output_tokens" => 40},
         "output" => [
           %{
             "type" => "web_search_call",
             "action" => %{
               "type" => "search",
               "sources" => [
                 %{"url" => "https://physics.nist.gov/cuu/Constants/", "title" => "NIST"},
                 %{"url" => "https://pubchem.ncbi.nlm.nih.gov/", "title" => "PubChem"},
                 %{"url" => "https://attacker.example/copied", "title" => "Rejected"}
               ]
             }
           },
           %{
             "type" => "message",
             "content" => [
               %{
                 "type" => "output_text",
                 "text" =>
                   Jason.encode!(%{
                     "claims" => [
                       %{
                         "paraphrase" =>
                           "A bounded gas model must state its units and assumptions.",
                         "citation_urls" => [
                           "https://physics.nist.gov/cuu/Constants/",
                           "https://pubchem.ncbi.nlm.nih.gov/"
                         ]
                       }
                     ]
                   })
               }
             ]
           }
         ]
       }}
    end

    now = ~U[2026-08-17 12:00:00Z]

    assert {:ok, %{evidence: evidence}} =
             ResponsesWebSearch.research(proposal, request_fun: request_fun, now: now)

    assert_received {:research_payload, payload}
    assert get_in(payload, ["tools", Access.at(0), "type"]) == "web_search"
    assert "web_search_call.action.sources" in payload["include"]
    assert "nist.gov" in get_in(payload, ["tools", Access.at(0), "filters", "allowed_domains"])
    assert evidence["source_count"] == 2
    assert evidence["provider_usage"] == %{"input_tokens" => 120, "output_tokens" => 40}
    assert [%{"paraphrase" => _, "citation_urls" => citations}] = evidence["claims"]
    assert length(citations) == 2
    refute inspect(evidence) =~ "copied"
    assert evidence["accessed_at"] == "2026-08-17T12:00:00Z"
  end

  test "library registry rejects unknown and disabled 3D IDs and injects audited files" do
    assert {:error, {:unknown_simulation_libraries, ["remote-library"]}} =
             LibraryRegistry.validate_ids(["remote-library"])

    assert {:error, :three_d_generation_disabled} =
             LibraryRegistry.validate_ids(["three-0.185.1"])

    bundle = %{
      files: %{"index.html" => "<!doctype html><title>test</title>"},
      manifest: %{"entrypoint" => "index.html", "library_ids" => ["chartjs-4.4.0"]},
      capi_manifest: %{"inputs" => [], "outputs" => []}
    }

    assert {:ok, assembled} =
             LibraryRegistry.assemble(bundle,
               library_root: Path.join(@root, "priv/openstax_simulation_libraries")
             )

    chart = assembled.files["vendor/chartjs-4.4.0.js"]
    identity = assembled.system_library_manifest["vendor/chartjs-4.4.0.js"]
    assert is_binary(chart)

    assert LibraryRegistry.trusted_file?(
             "vendor/chartjs-4.4.0.js",
             chart,
             assembled.system_library_manifest
           )

    assert identity["system_owned"]
    assert assembled.manifest["runtime_network"] == "none"

    d3_bundle =
      put_in(bundle, [:manifest, "library_ids"], ["d3-scale-4.0.2"])

    assert {:ok, d3_assembled} =
             LibraryRegistry.assemble(d3_bundle,
               library_root: Path.join(@root, "priv/openstax_simulation_libraries")
             )

    assert is_binary(d3_assembled.files["vendor/d3-array-3.2.4.js"])
    assert is_binary(d3_assembled.files["vendor/d3-interpolate-3.0.1.js"])
    assert is_binary(d3_assembled.files["vendor/d3-scale-4.0.2.js"])
    refute Enum.any?(Map.keys(d3_assembled.files), &String.contains?(&1, "d3-fetch"))

    d3_contract = LibraryRegistry.contract()["d3-scale-4.0.2"]

    assert List.last(d3_contract["load_order"]) == %{
             "artifact_path" => "vendor/d3-scale-4.0.2.js",
             "loading" => "classic_script"
           }

    assert Enum.any?(d3_contract["load_order"], fn dependency ->
             dependency["artifact_path"] == "vendor/d3-array-3.2.4.js"
           end)

    assert LibraryRegistry.contract()["three-0.185.1"]["loading"] ==
             "static_module_import"
  end

  test "untrusted source generation repairs an invalid library contract before acceptance" do
    proposal = %EnrichmentProposal{id: Ecto.UUID.generate(), kind: "generated_simulation"}

    research = %EnrichmentResearchSet{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      status: "approved",
      content_hash: @hash,
      claims: [],
      proposed_sources: []
    }

    spec = %SimulationSpec{
      id: Ecto.UUID.generate(),
      proposal_id: proposal.id,
      research_set_id: research.id,
      status: "approved",
      evidence_hash: @hash,
      content_hash: String.duplicate("b", 64),
      spec_payload: %{
        "capi_manifest" => %{"inputs" => [], "outputs" => []},
        "library_ids" => []
      }
    }

    Process.put(:source_generation_attempt, 0)

    execution = fn _context, messages, _functions, _service ->
      attempt = Process.get(:source_generation_attempt, 0) + 1
      Process.put(:source_generation_attempt, attempt)

      if attempt == 2 do
        assert Enum.any?(messages, fn message ->
                 is_binary(message.content) and
                   message.content =~ "invalid_generated_bundle_contract"
               end)
      end

      library_ids = if attempt == 1, do: ["remote-library"], else: []

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "files" => %{"index.html" => "<!doctype html><title>Simulation</title>"},
             "manifest" => %{"entrypoint" => "index.html", "library_ids" => library_ids},
             "capi_manifest" => %{"inputs" => [], "outputs" => []}
           }),
         metadata: %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end

    assert {:ok, generated} =
             UntrustedGenerated.generate(proposal,
               simulation_spec: spec,
               research_set: research,
               service: service_config("gpt-5.6-sol"),
               execution_fun: execution
             )

    assert generated.metadata["source_repair_count"] == 1
    assert length(generated.metadata["source_generation_history"]) == 2
    assert Process.get(:source_generation_attempt) == 2
  end

  test "audited seeded artifacts retain a deterministic critic boundary" do
    spec = %SimulationSpec{spec_payload: %{}, content_hash: String.duplicate("b", 64)}
    research = %EnrichmentResearchSet{content_hash: @hash, claims: []}

    generated = %{
      metadata: %{"runtime_profile" => "audited_static"},
      files: %{"index.html" => "fixture"}
    }

    assert {:ok, criticism} = ArtifactCritic.review(spec, research, generated, %{})
    assert criticism["approved"]
    assert criticism["model"] == "audited-static"
  end

  defp opportunity(domain) do
    %{
      "domain" => domain,
      "objective_ids" => ["objective-1"],
      "source_evidence" => %{"block_ids" => ["block-1"]},
      "instructional_rationale" => "Make the relationship observable.",
      "learner_task" => "Predict and explain.",
      "misconception_target" => "A common misconception",
      "placement" => %{"stage_id" => "stage-1"},
      "research_query" => "Authoritative evidence",
      "expected_instructional_value" => "Connect prediction to evidence."
    }
  end

  defp research do
    %{
      "content_hash" => @hash,
      "proposed_sources" => [
        %{"url" => "https://physics.nist.gov/cuu/Constants/", "title" => "NIST"},
        %{"url" => "https://pubchem.ncbi.nlm.nih.gov/", "title" => "PubChem"}
      ]
    }
  end

  defp valid_spec(domain) do
    %{
      "domain" => domain,
      "objective_ids" => ["objective-1"],
      "evidence_hash" => @hash,
      "research_hash" => @hash,
      "assumptions" => ["The learner varies only bounded parameters."],
      "limitations" => ["The display is an instructional model."],
      "parameters" => [
        %{"id" => "x", "min" => 0, "max" => 10, "default" => 2, "step" => 1, "unitless" => true}
      ],
      "constants" => [
        %{
          "id" => "scale",
          "value" => 2,
          "unit" => "1",
          "citation_urls" => ["https://physics.nist.gov/cuu/Constants/"]
        }
      ],
      "sample_cases" => [
        %{
          "inputs" => %{"x" => 2},
          "expected_outputs" => %{"y" => 4},
          "tolerance" => 0,
          "deterministic" => true
        }
      ],
      "controls" => [%{"parameter_id" => "x", "control" => "slider"}],
      "observations" => [%{"output_id" => "y", "display" => "number"}],
      "guided_tasks" => [%{"prompt" => "Predict and test."}],
      "misconception_handling" => "Contrast prediction with the deterministic result.",
      "native_follow_up" => "Explain why the result changed.",
      "remediation" => "Review the cited source evidence and retry.",
      "capi_manifest" => %{
        "inputs" => [%{"key" => "x", "type" => "number"}],
        "outputs" => [%{"key" => "y", "type" => "number"}]
      },
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" => %{
        "keyboard" => %{"completion" => "Tab to each control and activate with arrow keys."},
        "text_or_table_alternative" => "A table lists every input and output pair.",
        "reduced_motion" => "Disable transitions and show the final state immediately.",
        "color_independent_encoding" => "Use labels and line patterns in addition to color."
      },
      "algorithm" => %{"max_steps" => 100, "max_items" => 100, "accepts_learner_code" => false},
      "learner_code_execution" => false
    }
  end

  defp reference_spec(domain) do
    SimulationDomainReferences.build!(domain, reference_research(domain))
  end

  defp reference_research(domain) do
    pilot = Enum.find(SimulationPilotCorpus.pilot_cases(), &(&1["domain"] == domain))
    SimulationPilotCorpus.research_contract(pilot)
  end

  defp assert_reference_outputs(expected, actual, tolerance) do
    assert MapSet.new(Map.keys(expected)) == MapSet.new(Map.keys(actual))

    Enum.each(expected, fn {key, expected_value} ->
      actual_value = Map.fetch!(actual, key)

      if is_number(expected_value) do
        assert_in_delta actual_value, expected_value, max(tolerance, 1.0e-12)
      else
        assert actual_value == expected_value
      end
    end)
  end

  defp service_config(model_name) do
    model = %RegisteredModel{
      id: -1,
      name: "test-model",
      provider: :open_ai,
      model: model_name,
      url_template: "https://api.openai.test",
      api_key: "test",
      timeout: 1_000,
      recv_timeout: 1_000,
      pool_class: :slow,
      routing_breaker_error_rate_threshold: 0.0,
      routing_breaker_429_threshold: 0.0,
      routing_breaker_latency_p95_ms: 0
    }

    %ServiceConfig{id: -1, name: "test-service", primary_model: model}
  end
end
