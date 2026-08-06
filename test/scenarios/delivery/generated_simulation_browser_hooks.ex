defmodule Oli.Scenarios.Delivery.GeneratedSimulationBrowserHooks do
  @moduledoc """
  Builds the compiler-shaped Advanced Author deck used by the generated-
  simulation browser contract.

  Proposal approval, artifact generation, and compilation are covered by their
  focused tests. This hook only joins scenario-created adaptive activities into
  the same deck structure emitted by the OpenStax authoring compiler.
  """

  alias Oli.Publishing
  alias Oli.Resources
  alias Oli.Scenarios.DirectiveTypes.ExecutionState

  @project_prefix "generated_simulation_project"
  @page_title "Observe Gas Pressure"

  @simulation_prefix "approved_gas_pressure_simulation"
  @remediation_prefix "gas_model_remediation"
  @follow_up_prefix "gas_pressure_follow_up"

  @simulation_sequence "gas-pressure-simulation-sequence"
  @remediation_sequence "gas-model-explanation-sequence"
  @follow_up_sequence "gas-pressure-follow-up-sequence"

  def build_advanced_lesson(%ExecutionState{} = state) do
    {project_name, built_project} =
      Enum.find(state.projects, fn {name, _project} ->
        String.starts_with?(name, @project_prefix)
      end) || raise "Generated-simulation browser project was not created"

    page_revision =
      Map.get(built_project.rev_by_title, @page_title) ||
        raise "Generated-simulation browser page was not created"

    simulation = activity!(state, project_name, @simulation_prefix)
    remediation = activity!(state, project_name, @remediation_prefix)
    follow_up = activity!(state, project_name, @follow_up_prefix)

    content =
      advanced_page_content([
        activity_reference(simulation, @simulation_sequence, "Explore the gas model"),
        activity_reference(remediation, @remediation_sequence, "Gas-model explanation"),
        activity_reference(follow_up, @follow_up_sequence, "Use the simulation evidence")
      ])

    case Resources.update_revision(page_revision, %{content: content, graded: false}) do
      {:ok, updated_revision} ->
        upsert_working_publication(built_project.project.slug, updated_revision)

        updated_project = %{
          built_project
          | rev_by_title: Map.put(built_project.rev_by_title, @page_title, updated_revision)
        }

        %{state | projects: Map.put(state.projects, project_name, updated_project)}

      {:error, reason} ->
        raise "Could not build generated-simulation Advanced lesson: #{inspect(reason)}"
    end
  end

  defp activity!(state, project_name, virtual_id_prefix) do
    Enum.find_value(state.activity_virtual_ids, fn
      {{^project_name, virtual_id}, revision} ->
        if String.starts_with?(virtual_id, virtual_id_prefix), do: revision

      _other ->
        nil
    end) || raise "Scenario activity #{virtual_id_prefix} was not created"
  end

  defp activity_reference(revision, sequence_id, sequence_name) do
    %{
      "type" => "activity-reference",
      "activity_id" => revision.resource_id,
      "custom" => %{
        "sequenceId" => sequence_id,
        "sequenceName" => sequence_name
      }
    }
  end

  defp advanced_page_content(children) do
    %{
      "advancedAuthoring" => true,
      "advancedDelivery" => true,
      "displayApplicationChrome" => false,
      "additionalStylesheets" => ["/css/delivery_adaptive_themes_default_light.css"],
      "customCss" => "",
      "custom" => %{
        "contentMode" => "expert",
        "defaultScreenHeight" => 540,
        "defaultScreenWidth" => 1200,
        "enableHistory" => true,
        "maxScore" => 0,
        "responsiveLayout" => true,
        "themeId" => "torus-default-light",
        "totalScore" => 0,
        "variables" => []
      },
      "model" => [
        %{
          "id" => "generated-simulation-browser-deck",
          "type" => "group",
          "layout" => "deck",
          "children" => children
        }
      ]
    }
  end

  defp upsert_working_publication(project_slug, revision) do
    case Publishing.project_working_publication(project_slug) do
      nil -> :ok
      publication -> Publishing.upsert_published_resource(publication, revision)
    end
  end
end
