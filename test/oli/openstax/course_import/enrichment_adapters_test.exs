defmodule Oli.OpenStax.CourseImport.EnrichmentAdaptersTest do
  use ExUnit.Case, async: false

  alias Oli.OpenStax.CourseImport.Enrichment
  alias Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.S3Media
  alias Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage
  alias Oli.OpenStax.CourseImport.Enrichment.Generator.Template
  alias Oli.OpenStax.CourseImport.Enrichment.Research.Catalog
  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.CapiBridge
  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.LocalContainer
  alias Oli.OpenStax.CourseImport.GeneratedSimulation
  alias Oli.OpenStax.CourseImport.EnrichmentProposal
  alias Oli.OpenStax.CourseImport.SimulationArtifact

  @hash String.duplicate("d", 64)
  @dev_generated_origin "http://generated-simulations.localhost:9000/torus-media-dev"

  defmodule CleanupOnlyStorage do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

    @impl true
    def available?, do: false

    @impl true
    def cleanup_available?, do: true

    @impl true
    def prepare(_artifact, _bundle, _opts), do: {:error, :delivery_disabled}

    @impl true
    def stage(_artifact, _bundle, _opts), do: {:error, :delivery_disabled}

    @impl true
    def resolve(_artifact, _opts), do: {:error, :delivery_disabled}

    @impl true
    def discard(artifact, opts) do
      send(opts[:test_pid], {:cleanup_called, artifact.id})
      :ok
    end
  end

  defmodule ResolvingStorage do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

    @impl true
    def available?, do: true

    @impl true
    def prepare(_artifact, _bundle, _opts), do: {:error, :not_used}

    @impl true
    def stage(_artifact, _bundle, _opts), do: {:error, :not_used}

    @impl true
    def resolve(artifact, _opts) do
      {:ok, String.trim_trailing(artifact.storage_origin, "/") <> "/" <> artifact.storage_key}
    end

    @impl true
    def discard(_artifact, _opts), do: :ok
  end

  setup do
    original_catalog = Application.get_env(:oli, :openstax_enrichment_resource_catalog, [])
    original_origin = Application.get_env(:oli, :openstax_generated_simulation_origin)
    original_media_url = Application.get_env(:oli, :media_url)
    original_bucket = Application.get_env(:oli, :s3_media_bucket_name)
    original_env = Application.get_env(:oli, :env)

    original_csp_header =
      Application.get_env(:oli, :openstax_generated_simulation_csp_header_enforced)

    on_exit(fn ->
      Application.put_env(:oli, :openstax_enrichment_resource_catalog, original_catalog)
      Application.put_env(:oli, :openstax_generated_simulation_origin, original_origin)
      Application.put_env(:oli, :media_url, original_media_url)
      Application.put_env(:oli, :s3_media_bucket_name, original_bucket)
      Application.put_env(:oli, :env, original_env)

      Application.put_env(
        :oli,
        :openstax_generated_simulation_csp_header_enforced,
        original_csp_header
      )
    end)

    :ok
  end

  test "local template generator creates a dependency-free native-followup exploration" do
    proposal = %EnrichmentProposal{
      kind: "generated_simulation",
      resource_title: "Pressure < volume",
      instructional_rationale: "Test how a bounded setting changes the visible response.",
      learner_task: "Make a prediction and explain the evidence."
    }

    assert {:ok, bundle} = Template.generate(proposal, [])
    assert Map.keys(bundle.files) |> Enum.sort() == ["app.js", "index.html", "styles.css"]
    assert bundle.capi_manifest == %{"inputs" => [], "outputs" => []}
    assert bundle.metadata["assessment_mode"] == "native_torus_followup"
    assert bundle.files["index.html"] =~ "Pressure &lt; volume"
    refute bundle.files["app.js"] =~ "postMessage"
    refute bundle.files["app.js"] =~ "fetch("

    sandbox_result = LocalContainer.build_and_validate(bundle, [])

    assert match?({:ok, _validated}, sandbox_result) or
             sandbox_result == {:error, :sandbox_unavailable}
  end

  test "configured research catalog returns only reviewed HTTPS annotated links" do
    Application.put_env(:oli, :openstax_enrichment_resource_catalog, [
      %{
        "id" => "pressure-evidence",
        "title" => "Open pressure evidence",
        "url" => "https://example.edu/open-pressure",
        "authority" => "Example University chemistry program",
        "license" => "CC BY 4.0",
        "annotation" => "A reviewed pressure and volume investigation.",
        "tags" => ["pressure", "volume", "chemistry"]
      }
    ])

    proposal = %EnrichmentProposal{
      instructional_rationale: "Connect pressure and volume evidence.",
      learner_task: "Compare the pressure pattern.",
      objective_ids: ["explain-pressure"],
      metadata: %{"research_query" => "chemistry pressure volume"}
    }

    assert Catalog.available?()
    assert {:ok, result} = Catalog.research(proposal, [])
    assert result.resource_url == "https://example.edu/open-pressure"
    assert result.delivery_mode == "annotated_link"
    assert result.evidence["license"] == "CC BY 4.0"
  end

  test "local sandbox rejects prohibited browser APIs before invoking a container runtime" do
    bundle = %{
      files: %{
        "index.html" => valid_html(~s(<script src="app.js"></script>)),
        "app.js" => "fetch('/secret')"
      }
    }

    assert {:error, :prohibited_browser_api} =
             LocalContainer.build_and_validate(bundle, [])
  end

  test "the sandbox injects only its typed CAPI bridge and keeps direct postMessage prohibited" do
    manifest = %{
      "inputs" => [%{"key" => "volume", "type" => "number", "defaultValue" => 50}],
      "outputs" => [
        %{
          "key" => "pressure",
          "type" => "number",
          "defaultValue" => 50,
          "branching" => %{
            "operator" => "greater_than_or_equal",
            "value" => 80,
            "remediation_section_id" => "gas-model"
          }
        }
      ]
    }

    files = %{
      "index.html" =>
        valid_html(
          ~s(<script src="torus-capi-bridge.js"></script><script src="app.js"></script><button id="emit">Record state</button>)
        ),
      "app.js" =>
        "document.getElementById('emit').addEventListener('click', () => window.TorusCapi.emit('pressure', 81));"
    }

    assert {:ok, prepared, normalized_manifest} = CapiBridge.prepare(files, manifest)
    bridge = prepared[CapiBridge.bridge_path()]

    assert is_binary(bridge)
    assert bridge =~ "parent.postMessage"
    assert bridge =~ "Object.defineProperty(window, 'TorusCapi'"
    assert CapiBridge.trusted_file?(CapiBridge.bridge_path(), bridge, normalized_manifest)
    assert get_in(normalized_manifest, ["outputs", Access.at(0), "key"]) == "pressure"

    sandbox_result =
      LocalContainer.build_and_validate(%{files: files, capi_manifest: manifest}, [])

    assert match?({:ok, _validated}, sandbox_result) or
             sandbox_result == {:error, :sandbox_unavailable}

    assert {:error, :trusted_capi_bridge_missing} =
             CapiBridge.prepare(
               Map.put(files, "index.html", valid_html(~s(<script src="app.js"></script>))),
               manifest
             )

    for unsafe_bridge <- [
          ~s(<script type="text/plain" src="torus-capi-bridge.js"></script><script src="app.js"></script>),
          ~s(<script async src="torus-capi-bridge.js"></script><script src="app.js"></script>),
          ~s(<script defer src="torus-capi-bridge.js"></script><script src="app.js"></script>),
          ~s(<script type="module" src="torus-capi-bridge.js"></script><script src="app.js"></script>),
          ~s(<script src="app.js"></script><script src="torus-capi-bridge.js"></script>),
          ~s(<template><script src="torus-capi-bridge.js"></script></template><script src="app.js"></script>)
        ] do
      assert {:error, :trusted_capi_bridge_missing} =
               CapiBridge.prepare(
                 Map.put(files, "index.html", valid_html(unsafe_bridge)),
                 manifest
               )
    end

    assert {:error, :reserved_capi_bridge_file} =
             CapiBridge.prepare(Map.put(files, CapiBridge.bridge_path(), "untrusted"), manifest)

    direct_post_message = %{
      files: %{
        "index.html" => valid_html(~s(<script src="app.js"></script>)),
        "app.js" => "parent.postMessage(JSON.stringify({type: 4}), '*')"
      }
    }

    assert {:error, :prohibited_browser_api} =
             LocalContainer.build_and_validate(direct_post_message, [])
  end

  test "local sandbox rejects CSP directives that append a network source after none" do
    unsafe_csp =
      required_csp()
      |> String.replace("connect-src 'none'", "connect-src 'none' https://evil.example")

    bundle = %{
      files: %{
        "index.html" => valid_html("<p>Unsafe policy</p>", unsafe_csp)
      }
    }

    assert {:error, :unsafe_content_security_policy} =
             LocalContainer.build_and_validate(bundle, [])
  end

  test "local sandbox requires one CSP before active head content" do
    late_policy = %{
      files: %{
        "index.html" => """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="description" content="Observe a bounded model.">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script src="app.js"></script>
            <meta http-equiv="Content-Security-Policy" content="#{required_csp()}">
            <title>Late policy</title>
          </head>
          <body><p>Unsafe ordering</p></body>
        </html>
        """,
        "app.js" => "console.log('already active')"
      }
    }

    assert {:error, :unsafe_content_security_policy} =
             LocalContainer.build_and_validate(late_policy, [])
  end

  test "local sandbox rejects external dependencies, inaccessible controls, and unsafe paths" do
    external_dependency = %{
      files: %{
        "index.html" =>
          valid_html(~s(<script src="https://cdn.example.edu/simulation.js"></script>))
      }
    }

    assert {:error, :external_resource_reference} =
             LocalContainer.build_and_validate(external_dependency, [])

    missing_script = %{
      files: %{
        "index.html" => valid_html(~s(<script src="missing.js"></script>))
      }
    }

    assert {:error, :inline_script_forbidden} =
             LocalContainer.build_and_validate(missing_script, [])

    data_script = %{
      files: %{
        "index.html" => valid_html(~s|<script src="data:text/javascript,alert(1)"></script>|)
      }
    }

    assert {:error, :external_resource_reference} =
             LocalContainer.build_and_validate(data_script, [])

    navigation_script = %{
      files: %{
        "index.html" => valid_html(~s(<script src="app.js"></script>)),
        "app.js" => "window.location.assign('https://outside.example')"
      }
    }

    assert {:error, :prohibited_browser_api} =
             LocalContainer.build_and_validate(navigation_script, [])

    unnamed_control = %{
      files: %{
        "index.html" => valid_html("<input id=\"volume\">")
      }
    }

    assert {:error, :control_name_missing} =
             LocalContainer.build_and_validate(unnamed_control, [])

    unsafe_path = %{
      files: %{
        "index.html" => valid_html("<p>Safe entrypoint</p>"),
        "../escape.js" => "console.log('escape')"
      }
    }

    assert {:error, :invalid_bundle_file} =
             LocalContainer.build_and_validate(unsafe_path, [])
  end

  test "S3 media resolution accepts only the exact content-addressed key and recorded origin" do
    artifact = %SimulationArtifact{
      id: "artifact-one",
      version: 2,
      content_hash: @hash,
      storage_provider: "s3_media",
      storage_key: "generated-simulations/artifacts/artifact-one/v2/sha256/#{@hash}/index.html",
      storage_origin: "https://media.example.edu"
    }

    assert {:ok,
            "https://media.example.edu/generated-simulations/artifacts/artifact-one/v2/sha256/#{@hash}/index.html"} =
             S3Media.resolve(artifact, origin: "https://media.example.edu")

    assert {:error, :artifact_storage_identity_invalid} =
             artifact
             |> Map.put(:storage_key, "generated-simulations/latest/index.html")
             |> S3Media.resolve(origin: "https://media.example.edu")

    assert {:error, :artifact_storage_identity_invalid} =
             S3Media.resolve(artifact, origin: "https://other-media.example.edu")

    second_artifact = %{
      artifact
      | id: "artifact-two",
        storage_key: "generated-simulations/artifacts/artifact-two/v2/sha256/#{@hash}/index.html"
    }

    assert {:ok, second_url} =
             S3Media.resolve(second_artifact, origin: "https://media.example.edu")

    refute second_url =~ "/artifacts/artifact-one/"
  end

  test "S3 media availability requires a dedicated generated-simulation origin" do
    Application.put_env(:oli, :s3_media_bucket_name, "media-bucket")
    Application.put_env(:oli, :media_url, "https://general-media.example.edu")
    Application.delete_env(:oli, :openstax_generated_simulation_origin)

    refute S3Media.available?()

    Application.put_env(:oli, :openstax_generated_simulation_origin, "https://localhost")
    refute S3Media.available?()

    Application.put_env(
      :oli,
      :openstax_generated_simulation_origin,
      "https://simulations.example.edu"
    )

    assert S3Media.available?()

    Application.put_env(
      :oli,
      :openstax_generated_simulation_origin,
      "https://general-media.example.edu/generated"
    )

    refute S3Media.available?()

    Application.put_env(
      :oli,
      :openstax_generated_simulation_origin,
      "https://simulations.example.edu"
    )

    Application.put_env(:oli, :env, :prod)
    Application.put_env(:oli, :openstax_generated_simulation_csp_header_enforced, false)
    refute S3Media.available?()

    Application.put_env(:oli, :openstax_generated_simulation_csp_header_enforced, true)
    assert S3Media.available?()
  end

  test "the dedicated local MinIO dev origin is accepted consistently" do
    Application.put_env(:oli, :s3_media_bucket_name, "torus-media-dev")
    Application.put_env(:oli, :media_url, "http://localhost:9000/torus-media-dev")
    Application.put_env(:oli, :openstax_generated_simulation_origin, @dev_generated_origin)
    Application.put_env(:oli, :env, :dev)

    storage_key =
      "generated-simulations/artifacts/artifact-dev/v1/sha256/#{@hash}/index.html"

    artifact = %SimulationArtifact{
      id: "artifact-dev",
      proposal_id: "proposal-dev",
      version: 1,
      status: "approved",
      validation_status: "passed",
      validation_version: 1,
      validation_payload: %{"status" => "passed"},
      content_hash: @hash,
      byte_size: 512,
      storage_provider: "s3_media",
      storage_state: "staged",
      storage_key: storage_key,
      storage_origin: @dev_generated_origin,
      bundle_manifest: %{"entrypoint" => "index.html", "files" => ["index.html"]},
      accessibility_metadata: %{
        "title" => "Local generated simulation",
        "description" => "A generated simulation served from local MinIO."
      }
    }

    expected_url = @dev_generated_origin <> "/" <> storage_key

    assert S3Media.available?()
    assert {:ok, ^expected_url} = S3Media.resolve(artifact, origin: @dev_generated_origin)

    assert {:ok, ^expected_url} =
             Enrichment.artifact_url(artifact,
               artifact_storage: ResolvingStorage,
               trusted_origin: @dev_generated_origin,
               allow_local_http: true
             )

    assert {:ok, spec} =
             GeneratedSimulation.resolve("proposal-dev",
               simulation_artifact_resolver: fn "proposal-dev" -> {:ok, artifact} end,
               simulation_artifact_url_resolver: fn ^artifact -> {:ok, expected_url} end,
               generated_simulation_origins: [@dev_generated_origin]
             )

    assert spec["src"] == expected_url

    assert spec["artifactIdentity"]["storageOrigin"] ==
             "http://generated-simulations.localhost:9000"
  end

  test "artifact cleanup remains callable when delivery readiness is disabled" do
    artifact = %SimulationArtifact{id: "cleanup-artifact"}

    assert :ok =
             ArtifactStorage.discard(artifact,
               artifact_storage: CleanupOnlyStorage,
               test_pid: self()
             )

    assert_received {:cleanup_called, "cleanup-artifact"}
  end

  defp valid_html(body, csp \\ required_csp()) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="description" content="Observe a bounded model.">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="#{csp}">
        <title>Bounded model</title>
      </head>
      <body>#{body}</body>
    </html>
    """
  end

  defp required_csp do
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'"
  end
end
