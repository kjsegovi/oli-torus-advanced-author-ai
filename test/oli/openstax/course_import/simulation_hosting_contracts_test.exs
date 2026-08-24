defmodule Oli.OpenStax.CourseImport.SimulationHostingContractsTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.S3Media
  alias Oli.OpenStax.CourseImport.Enrichment.SimulationDeliveryReadiness

  @root Path.expand("../../../..", __DIR__)

  test "turnkey Compose keeps MinIO private and puts both public hosts behind the edge" do
    compose = yaml!("docker-compose.yml")
    services = compose["services"]

    assert services["minio"]["ports"] == nil
    assert services["app"]["ports"] == nil
    assert services["edge"]["ports"] == ["80:80", "443:443"]
    assert services["minio-admin"]["profiles"] == ["minio-admin"]
    assert services["minio-admin"]["ports"] == ["127.0.0.1:9001:9001"]

    assert services["app"]["depends_on"]["minio-init"]["condition"] ==
             "service_completed_successfully"

    assert services["minio"]["depends_on"]["minio-credentials"]["condition"] ==
             "service_completed_successfully"

    assert services["app"]["environment"]["OPENSTAX_GENERATED_SIMULATION_DELIVERY_ENABLED"] ==
             "${OPENSTAX_GENERATED_SIMULATION_DELIVERY_ENABLED:-true}"

    assert services["app"]["environment"]["OPENSTAX_GENERATED_SIMULATION_KILL_SWITCH"] ==
             "${OPENSTAX_GENERATED_SIMULATION_KILL_SWITCH:-false}"

    assert "minio_data:/data" in services["minio"]["volumes"]
    assert "minio_credentials:/credentials:ro" in services["minio"]["volumes"]
    assert "minio_credentials:/minio-credentials:ro" in services["app"]["volumes"]
    assert compose["volumes"]["minio_data"] == nil
    assert compose["volumes"]["minio_credentials"] == nil
  end

  test "anonymous MinIO policy permits object reads without listing or mutation" do
    policy = json!("scripts/dev/minio/generated_simulation_read_policy.json")
    assert [statement] = policy["Statement"]
    assert statement["Effect"] == "Allow"
    assert statement["Action"] == ["s3:GetObject"]

    assert statement["Resource"] == [
             "arn:aws:s3:::__SIMULATION_BUCKET__/generated-simulations/*"
           ]

    refute inspect(policy) =~ "s3:ListBucket"
    refute inspect(policy) =~ "s3:PutObject"
    refute inspect(policy) =~ "s3:DeleteObject"
  end

  test "edge routing separates legacy and version two buckets and enforces iframe headers" do
    config = file!("scripts/dev/ha-proxy/haproxy_minio_docker.cfg")

    assert config =~ "acl simulation_method method GET HEAD"
    assert config =~ "deny_status 405 if simulation_host !simulation_method"
    assert config =~ "deny_status 404 if simulation_host !simulation_v1 !simulation_v2"
    assert config =~ "deny_status 404 if !simulation_host simulation_bucket_general_path"
    assert config =~ "backend simulation_v1"
    assert config =~ "set-path /__LEGACY_MEDIA_BUCKET__"
    assert config =~ "backend simulation_v2"
    assert config =~ "set-path /__SIMULATION_BUCKET__"
    assert config =~ "http-request del-header Authorization"
    assert config =~ "http-request del-header Cookie"
    assert config =~ "http-response del-header Set-Cookie"

    for {header, value} <- S3Media.required_response_headers(["https://torus.example.edu"]) do
      assert config =~ header_name(header)

      if header != "content-security-policy" do
        assert config =~ value
      end
    end

    assert config =~ "frame-ancestors 'self' __FRAME_ANCESTORS__"
  end

  test "the idempotent initializer publishes the exact monitored readiness object" do
    setup = file!("scripts/dev/minio/setup_generated_simulations.sh")
    body = file!("scripts/dev/minio/generated_simulation_readiness.html")

    assert setup =~ "mc mb --ignore-existing"
    assert setup =~ "mc anonymous set-json"
    assert setup =~ SimulationDeliveryReadiness.readiness_hash()

    assert setup =~
             "generated-simulations/storage-v2/readiness/sha256/${READINESS_HASH}/index.html"

    assert body == SimulationDeliveryReadiness.readiness_body()

    actual_hash =
      body
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert actual_hash == SimulationDeliveryReadiness.readiness_hash()
  end

  test "fresh Compose credentials are generated once and shared without fixed defaults" do
    setup = file!("scripts/dev/minio/setup_credentials.sh")
    compose = file!("docker-compose.yml")

    assert setup =~ "/dev/urandom"
    assert setup =~ "if [ -s \"$target\" ]"
    assert compose =~ "minio_credentials:/credentials"
    assert compose =~ "minio_credentials:/credentials:ro"
    assert compose =~ "minio_credentials:/minio-credentials:ro"
    refute compose =~ "torus-minio-change-me"
  end

  defp yaml!(path), do: @root |> Path.join(path) |> YamlElixir.read_from_file!()
  defp json!(path), do: path |> file!() |> Jason.decode!()
  defp file!(path), do: File.read!(Path.join(@root, path))

  defp header_name(header) do
    header
    |> String.split("-")
    |> Enum.map_join("-", &String.capitalize/1)
  end
end
