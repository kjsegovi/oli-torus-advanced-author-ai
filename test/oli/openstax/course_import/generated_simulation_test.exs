defmodule Oli.OpenStax.CourseImport.GeneratedSimulationTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.GeneratedSimulation

  @proposal_id "00000000-0000-4000-8000-000000000001"
  @hash String.duplicate("b", 64)

  test "resolves an approved content-addressed artifact and normalizes typed CAPI declarations" do
    assert {:ok, spec} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn @proposal_id -> {:ok, artifact()} end,
               simulation_artifact_url_resolver: fn _artifact ->
                 {:ok, "https://media.example.edu/bundles/#{@hash}/index.html"}
               end,
               generated_simulation_origins: ["https://media.example.edu"],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )

    assert spec["securityProfile"] == "generated_simulation"
    assert spec["src"] == "https://media.example.edu/bundles/#{@hash}/index.html"
    assert spec["title"] == "Gas pressure model"
    assert spec["artifactIdentity"]["proposalId"] == @proposal_id
    assert spec["artifactIdentity"]["artifactId"] == "artifact-1"
    assert spec["artifactIdentity"]["version"] == 3

    assert spec["capiInputs"] == [
             %{"defaultValue" => 1.0, "key" => "volume", "type" => "number"}
           ]

    assert spec["capiOutputs"] == [
             %{
               "defaultValue" => 0,
               "key" => "pressure",
               "type" => "number",
               "branching" => %{
                 "operator" => "greaterThanInclusive",
                 "value" => 80,
                 "remediation_section_id" => "gas-law",
                 "feedback" => "Review how volume and pressure are related."
               }
             },
             %{
               "allowedValues" => ["stable", "changing"],
               "defaultValue" => "stable",
               "key" => "state",
               "type" => "enum"
             }
           ]

    assert [input, pressure, state] = spec["configData"]

    assert input == %{
             "key" => "volume",
             "readonly" => false,
             "type" => 1,
             "value" => 1.0,
             "writeonly" => false
           }

    assert pressure["readonly"]
    assert pressure["type"] == 1
    assert state["readonly"]
    assert state["type"] == 5
  end

  test "rejects artifact records that are not approved and validated" do
    pending = Map.put(artifact(), :status, "preview_ready")

    assert {:error, :simulation_artifact_not_approved} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, pending} end,
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )

    failed_validation = Map.put(artifact(), :validation_payload, %{"status" => "failed"})

    assert {:error, :simulation_artifact_validation_failed} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, failed_validation} end,
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )
  end

  test "rejects URLs outside the recorded and configured media origin" do
    assert {:error, :simulation_artifact_url_origin_mismatch} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, artifact()} end,
               simulation_artifact_url_resolver: fn _ ->
                 {:ok, "https://attacker.example/bundles/#{@hash}/index.html"}
               end,
               generated_simulation_origins: ["https://media.example.edu"],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )

    assert {:error, :simulation_artifact_origin_untrusted} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, artifact()} end,
               simulation_artifact_url_resolver: fn _ ->
                 {:ok, "https://media.example.edu/bundles/#{@hash}/index.html"}
               end,
               generated_simulation_origins: ["https://different-media.example.edu"],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )

    assert {:error, :simulation_artifact_origin_untrusted} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, artifact()} end,
               simulation_artifact_url_resolver: fn _ ->
                 {:ok, "https://media.example.edu/bundles/#{@hash}/index.html"}
               end,
               generated_simulation_origins: [],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )
  end

  test "rejects invalid and duplicate CAPI declarations" do
    invalid_capi =
      put_in(artifact(), [:capi_manifest], %{
        "inputs" => [%{"key" => "shared", "type" => "number"}],
        "outputs" => [%{"key" => "shared", "type" => "string"}]
      })

    assert {:error, :duplicate_simulation_capi_key} =
             GeneratedSimulation.resolve(@proposal_id,
               simulation_artifact_resolver: fn _ -> {:ok, invalid_capi} end,
               simulation_artifact_url_resolver: fn _ ->
                 {:ok, "https://media.example.edu/bundles/#{@hash}/index.html"}
               end,
               generated_simulation_origins: ["https://media.example.edu"],
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false
             )
  end

  test "rejects prototype keys and excessive CAPI declarations" do
    prototype_key =
      put_in(artifact(), [:capi_manifest], %{
        "inputs" => [],
        "outputs" => [%{"key" => "__proto__", "type" => "string"}]
      })

    assert {:error, {:simulation_capi_declaration_invalid, 1, :invalid_key_or_type}} =
             resolve(prototype_key)

    too_many =
      put_in(artifact(), [:capi_manifest], %{
        "inputs" => [],
        "outputs" =>
          Enum.map(1..33, fn index ->
            %{"key" => "output_#{index}", "type" => "number"}
          end)
      })

    assert {:error, :simulation_capi_declaration_limit_exceeded} = resolve(too_many)
  end

  defp resolve(artifact) do
    GeneratedSimulation.resolve(@proposal_id,
      simulation_artifact_resolver: fn _ -> {:ok, artifact} end,
      simulation_artifact_url_resolver: fn _ ->
        {:ok, "https://media.example.edu/bundles/#{@hash}/index.html"}
      end,
      generated_simulation_origins: ["https://media.example.edu"],
      generated_simulation_delivery_enabled: true,
      generated_simulation_kill_switch: false
    )
  end

  defp artifact do
    %{
      id: "artifact-1",
      proposal_id: @proposal_id,
      status: "approved",
      version: 3,
      content_hash: @hash,
      storage_provider: "local",
      storage_state: "promoted",
      storage_key: "bundles/#{@hash}/index.html",
      storage_origin: "https://media.example.edu",
      manifest: %{"entrypoint" => "index.html"},
      capi_manifest: %{
        "inputs" => [%{"key" => "volume", "type" => "number", "default" => 1.0}],
        "outputs" => [
          %{
            "key" => "pressure",
            "type" => "number",
            "branching" => %{
              "operator" => "greater_than_or_equal",
              "value" => 80,
              "remediation_section_id" => "gas-law",
              "feedback" => "Review how volume and pressure are related."
            }
          },
          %{
            "key" => "state",
            "type" => "enum",
            "allowed_values" => ["stable", "changing"]
          }
        ]
      },
      accessibility_metadata: %{
        "title" => "Gas pressure model",
        "description" => "Change volume and observe pressure."
      },
      validation_payload: %{"status" => "passed"}
    }
  end
end
