defmodule Oli.Scenarios.Delivery.GeneratedSimulationIframeHooks do
  @moduledoc """
  Verifies that the exact approved workflow records are the source of the
  authoring iframe and remain unchanged in learner delivery.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Oli.Activities.Model
  alias Oli.OpenStax.CourseImport.{EnrichmentProposal, SimulationArtifact}
  alias Oli.Publishing.DeliveryResolver
  alias Oli.Repo
  alias Oli.Resources
  alias Oli.Scenarios.DirectiveTypes.ExecutionState
  alias Oli.Scenarios.Engine

  @project_name "generated_simulation_project"
  @section_name "generated_simulation_section"
  @activity_virtual_id "approved_gas_pressure_simulation"
  @storage_origin "https://simulations.example.edu"

  def assert_authoring_metadata(%ExecutionState{} = state) do
    governance = fetch_governance!(state)
    revision = fetch_activity_revision!(state)

    assert_generated_model!(revision.content, governance)
    state
  end

  def assert_delivery_metadata(%ExecutionState{} = state) do
    governance = fetch_governance!(state)
    authoring_revision = fetch_activity_revision!(state)
    section = fetch_section!(state)

    delivery_revision =
      DeliveryResolver.from_resource_id(section.slug, authoring_revision.resource_id) ||
        flunk(
          "No delivery revision for activity resource #{authoring_revision.resource_id} " <>
            "in section #{section.slug}"
        )

    authoring_custom = assert_generated_model!(authoring_revision.content, governance)
    delivery_custom = assert_generated_model!(delivery_revision.content, governance)

    assert delivery_custom == authoring_custom,
           "Generated simulation metadata changed between authoring and delivery"

    state
  end

  defp assert_generated_model!(model, governance) do
    assert {:ok, _parsed_model} = Model.parse(model)

    authoring_part =
      model
      |> get_in(["authoring", "parts"])
      |> find_iframe_part!("authoring parts")

    layout_part =
      model
      |> Map.get("partsLayout")
      |> find_iframe_part!("parts layout")

    assert authoring_part["id"] == layout_part["id"]
    assert authoring_part["owner"] == "aa_import_layout"
    assert authoring_part["inherited"] == false

    custom = layout_part["custom"]
    assert is_map(custom), "Generated simulation iframe is missing custom metadata"

    assert custom["securityProfile"] == "generated_simulation"
    assert custom["title"] == governance.artifact.accessibility_metadata["title"]
    assert custom["description"] == governance.artifact.accessibility_metadata["description"]
    assert custom["allowScrolling"] == false

    assert custom["artifactIdentity"] == %{
             "proposalId" => governance.proposal.id,
             "artifactId" => governance.artifact.id,
             "version" => governance.artifact.version,
             "contentHash" => governance.artifact.content_hash,
             "storageOrigin" => @storage_origin
           }

    inputs = Map.new(custom["capiInputs"], &{&1["key"], &1})

    assert Map.keys(inputs) |> Enum.sort() ==
             ~w(amount_mol temperature_k volume_l)

    assert Enum.all?(inputs, fn {_key, input} -> input["type"] == "number" end)
    assert inputs["amount_mol"]["defaultValue"] == 1.0
    assert inputs["volume_l"]["defaultValue"] == 24.465
    assert inputs["temperature_k"]["defaultValue"] == 298.15

    assert [%{"key" => "pressure_kpa", "type" => "number"}] = custom["capiOutputs"]

    assert Enum.all?(~w(amount_mol volume_l temperature_k), fn key ->
             Enum.find(custom["configData"], &(&1["key"] == key))["readonly"] == false
           end)

    assert Enum.find(custom["configData"], &(&1["key"] == "pressure_kpa"))["readonly"] ==
             true

    assert_trusted_content_addressed_source!(custom["src"], governance.artifact)

    Enum.each(
      ~w(source sourceType sourcePageSlug linkType idref resource_id dynamicLinkFallback),
      fn key ->
        refute Map.has_key?(custom, key),
               "Generated simulation iframe unexpectedly exposes author-editable #{key} metadata"
      end
    )

    custom
  end

  defp fetch_governance!(state) do
    project = Map.fetch!(state.projects, @project_name).project

    proposal =
      Repo.one!(
        from(proposal in EnrichmentProposal,
          where:
            proposal.project_id == ^project.id and
              proposal.kind == "generated_simulation",
          preload: [:research_sets, :simulation_specs, :simulation_artifacts]
        )
      )

    research = Enum.find(proposal.research_sets, &(&1.status == "approved"))
    spec = Enum.find(proposal.simulation_specs, &(&1.status == "approved"))
    artifact = Enum.find(proposal.simulation_artifacts, &(&1.status == "approved"))

    assert proposal.state == "approved"
    assert research && research.approved_by_author_id == state.current_author.id
    assert spec && spec.research_set_id == research.id
    assert spec.evidence_hash == research.content_hash
    assert artifact && artifact.simulation_spec_id == spec.id
    assert artifact.approved_by_author_id == state.current_author.id
    assert artifact.validation_status == "passed"
    assert artifact.validation_payload["status"] == "passed"
    assert artifact.storage_state == "staged"
    assert artifact.storage_origin == @storage_origin
    assert SimulationArtifact.resolvable?(artifact)

    %{proposal: proposal, research: research, spec: spec, artifact: artifact}
  end

  defp assert_trusted_content_addressed_source!(source, artifact) do
    uri = URI.parse(source)

    assert uri.scheme == "https"
    assert uri.host == "simulations.example.edu"

    assert String.contains?(
             uri.path || "",
             "/artifacts/#{artifact.id}/v#{artifact.version}/sha256/"
           )

    assert String.contains?(uri.path || "", artifact.content_hash)
    assert String.ends_with?(uri.path || "", "/index.html")
  end

  defp find_iframe_part!(parts, location) when is_list(parts) do
    Enum.find(parts, &(&1["type"] == "janus-capi-iframe")) ||
      flunk("Generated simulation iframe is missing from #{location}")
  end

  defp find_iframe_part!(_parts, location),
    do: flunk("Expected a list of #{location}")

  defp fetch_activity_revision!(%ExecutionState{} = state) do
    case Map.get(state.activity_virtual_ids, {@project_name, @activity_virtual_id}) do
      nil -> flunk("Generated simulation activity was not created")
      revision -> Resources.get_revision!(revision.id)
    end
  end

  defp fetch_section!(%ExecutionState{} = state) do
    Engine.get_section(state, @section_name) ||
      flunk("Generated simulation delivery section was not created")
  end
end
