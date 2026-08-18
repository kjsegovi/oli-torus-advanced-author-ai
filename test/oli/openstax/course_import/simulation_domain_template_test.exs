defmodule Oli.OpenStax.CourseImport.SimulationDomainTemplateTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Enrichment.Generator.Template
  alias Oli.OpenStax.CourseImport.EnrichmentProposal
  alias Oli.OpenStax.CourseImport.SimulationPilotCorpus

  test "the audited local builder creates a parameterized model for every pilot domain" do
    Enum.each(SimulationPilotCorpus.pilot_cases(), fn pilot ->
      research = SimulationPilotCorpus.research_contract(pilot)
      spec = SimulationPilotCorpus.spec_contract(pilot, research)

      proposal = %EnrichmentProposal{
        kind: "generated_simulation",
        resource_title: pilot["title"],
        instructional_rationale: pilot["lesson"]["source_blocks"] |> hd() |> Map.fetch!("text"),
        learner_task: pilot["learner_task"]
      }

      assert {:ok, bundle} = Template.generate(proposal, simulation_spec: spec)
      assert bundle.capi_manifest == spec["capi_manifest"]
      assert bundle.manifest["library_ids"] == spec["library_ids"]
      assert bundle.metadata["domain_model"] == pilot["domain"]
      assert bundle.files["app.js"] =~ "const calculate"
      refute bundle.files["app.js"] =~ "fetch("
      refute bundle.files["app.js"] =~ "postMessage"

      Enum.each(spec["parameters"], fn parameter ->
        assert bundle.files["index.html"] =~ ~s(data-model-input="#{parameter["id"]}")
      end)

      Enum.each(spec["observations"], fn observation ->
        assert bundle.files["index.html"] =~
                 ~s(data-model-output="#{observation["output_id"]}")
      end)
    end)
  end

  test "the chemistry bundle calculates the approved ideal-gas output instead of an identity canary" do
    pilot =
      SimulationPilotCorpus.pilot_cases()
      |> Enum.find(&(&1["domain"] == "chemistry"))

    research = SimulationPilotCorpus.research_contract(pilot)
    spec = SimulationPilotCorpus.spec_contract(pilot, research)

    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      instructional_rationale: "Relate bounded pressure, volume, amount, and temperature.",
      learner_task: pilot["learner_task"]
    }

    assert {:ok, bundle} = Template.generate(proposal, simulation_spec: spec)
    assert bundle.files["app.js"] =~ "8.314462618"
    assert bundle.files["app.js"] =~ "pressure_kpa"
    refute bundle.files["index.html"] =~ "generic workspace"
  end
end
