defmodule Oli.Scenarios.Delivery.GeneratedSimulationIframeHooks do
  @moduledoc """
  Read-only assertions for generated-simulation iframe scenario coverage.

  The scenario creates all project, activity, publication, section, enrollment,
  and attempt state through Oli.Scenarios directives. These hooks only inspect
  the resulting authoring and delivery revisions.
  """

  import ExUnit.Assertions

  alias Oli.Activities.Model
  alias Oli.Publishing.DeliveryResolver
  alias Oli.Resources
  alias Oli.Scenarios.DirectiveTypes.ExecutionState
  alias Oli.Scenarios.Engine

  @project_name "generated_simulation_project"
  @section_name "generated_simulation_section"
  @activity_virtual_id "approved_gas_pressure_simulation"
  @part_id "generated_simulation_iframe"
  @proposal_id "proposal-gas-pressure"
  @artifact_id "artifact-gas-pressure-v1"
  @content_hash String.duplicate("a", 64)
  @storage_origin "https://simulations.example.edu"

  def assert_authoring_metadata(%ExecutionState{} = state) do
    revision = fetch_activity_revision!(state)

    assert_generated_model!(revision.content)

    state
  end

  def assert_delivery_metadata(%ExecutionState{} = state) do
    authoring_revision = fetch_activity_revision!(state)
    section = fetch_section!(state)

    delivery_revision =
      DeliveryResolver.from_resource_id(section.slug, authoring_revision.resource_id) ||
        flunk(
          "No delivery revision for activity resource #{authoring_revision.resource_id} " <>
            "in section #{section.slug}"
        )

    authoring_custom = assert_generated_model!(authoring_revision.content)
    delivery_custom = assert_generated_model!(delivery_revision.content)

    assert delivery_custom == authoring_custom,
           "Generated simulation metadata changed between authoring and delivery"

    state
  end

  defp assert_generated_model!(model) do
    assert {:ok, _parsed_model} = Model.parse(model)

    authoring_part =
      model
      |> get_in(["authoring", "parts"])
      |> find_iframe_part!("authoring parts")

    layout_part =
      model
      |> Map.get("partsLayout")
      |> find_iframe_part!("parts layout")

    assert authoring_part["id"] == @part_id
    assert authoring_part["owner"] == "aa_import_layout"
    assert authoring_part["inherited"] == false
    assert layout_part["id"] == @part_id

    custom = layout_part["custom"]
    assert is_map(custom), "Generated simulation iframe is missing custom metadata"

    assert custom["securityProfile"] == "generated_simulation"
    assert custom["title"] == "Gas pressure model"
    assert custom["description"] == "Change volume and observe the resulting pressure."
    assert custom["allowScrolling"] == false

    assert custom["artifactIdentity"] == %{
             "proposalId" => @proposal_id,
             "artifactId" => @artifact_id,
             "version" => 1,
             "contentHash" => @content_hash,
             "storageOrigin" => @storage_origin
           }

    assert custom["capiInputs"] == [
             %{"key" => "volume", "type" => "number", "defaultValue" => 1}
           ]

    assert custom["capiOutputs"] == [
             %{"key" => "pressure", "type" => "number", "defaultValue" => 0}
           ]

    assert Enum.find(custom["configData"], &(&1["key"] == "volume"))["readonly"] == false
    assert Enum.find(custom["configData"], &(&1["key"] == "pressure"))["readonly"] == true

    assert_trusted_content_addressed_source!(custom["src"])

    Enum.each(
      ~w(source sourceType sourcePageSlug linkType idref resource_id dynamicLinkFallback),
      fn key ->
        refute Map.has_key?(custom, key),
               "Generated simulation iframe unexpectedly exposes author-editable #{key} metadata"
      end
    )

    custom
  end

  defp assert_trusted_content_addressed_source!(source) do
    uri = URI.parse(source)

    assert uri.scheme == "https"
    assert uri.host == "simulations.example.edu"
    assert String.contains?(uri.path || "", "/artifacts/#{@artifact_id}/v1/sha256/")
    assert String.contains?(uri.path || "", @content_hash)
    assert String.ends_with?(uri.path || "", "/index.html")
  end

  defp find_iframe_part!(parts, location) when is_list(parts) do
    Enum.find(parts, fn part ->
      part["id"] == @part_id and part["type"] == "janus-capi-iframe"
    end) || flunk("Generated simulation iframe is missing from #{location}")
  end

  defp find_iframe_part!(_parts, location),
    do: flunk("Expected a list of #{location}")

  defp fetch_activity_revision!(%ExecutionState{} = state) do
    case Map.get(state.activity_virtual_ids, {@project_name, @activity_virtual_id}) do
      nil ->
        flunk("Generated simulation activity was not created")

      revision ->
        Resources.get_revision!(revision.id)
    end
  end

  defp fetch_section!(%ExecutionState{} = state) do
    Engine.get_section(state, @section_name) ||
      flunk("Generated simulation delivery section was not created")
  end
end
