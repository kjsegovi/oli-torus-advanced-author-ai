defmodule Oli.GoogleSlides.Adaptive.PartBuildersTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.Adaptive.PartBuilders

  test "ordinary iframe parts retain the third-party model path" do
    part =
      PartBuilders.iframe_part(%{
        "src" => "https://example.edu/lab",
        "allowScrolling" => true,
        "configData" => [%{"key" => "temperature", "type" => 1, "value" => 20}]
      })

    assert part["type"] == "janus-capi-iframe"
    assert part["custom"]["src"] == "https://example.edu/lab"
    assert part["custom"]["allowScrolling"]
    assert part["custom"]["title"] == "Embedded content"
    assert [%{"key" => "temperature"}] = part["custom"]["configData"]
    refute Map.has_key?(part["custom"], "securityProfile")
    refute Map.has_key?(part["custom"], "artifactIdentity")
  end

  test "generated simulation parts require and preserve trusted artifact metadata" do
    hash = String.duplicate("a", 64)

    part =
      PartBuilders.generated_simulation_part(
        %{
          "src" => "https://media.example.edu/bundles/#{hash}/index.html",
          "title" => "Gas pressure model",
          "description" => "Change volume and observe pressure.",
          "securityProfile" => "generated_simulation",
          "artifactIdentity" => %{
            "proposalId" => "proposal-1",
            "artifactId" => "artifact-1",
            "version" => 2,
            "contentHash" => hash,
            "storageOrigin" => "https://media.example.edu"
          },
          "capiInputs" => [%{"key" => "volume", "type" => "number"}],
          "capiOutputs" => [%{"key" => "pressure", "type" => "number"}],
          "configData" => [
            %{"key" => "volume", "type" => 1, "value" => 1, "readonly" => false},
            %{"key" => "pressure", "type" => 1, "value" => 0, "readonly" => true}
          ]
        },
        y: 180,
        height: 360
      )

    custom = part["custom"]
    assert custom["securityProfile"] == "generated_simulation"
    assert custom["artifactIdentity"]["contentHash"] == hash
    assert custom["title"] == "Gas pressure model"
    assert custom["description"] == "Change volume and observe pressure."
    assert custom["capiInputs"] == [%{"key" => "volume", "type" => "number"}]
    assert custom["capiOutputs"] == [%{"key" => "pressure", "type" => "number"}]
    assert custom["y"] == 180
    assert custom["height"] == 360
  end

  test "ordinary iframe builder cannot opt itself into the generated security profile" do
    assert_raise ArgumentError, ~r/generated simulations must be built/, fn ->
      PartBuilders.iframe_part(%{
        "src" => "https://model-authored.example/simulation",
        "securityProfile" => "generated_simulation"
      })
    end
  end
end
