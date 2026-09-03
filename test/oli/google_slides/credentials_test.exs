defmodule Oli.GoogleSlides.CredentialsTest do
  use Oli.DataCase, async: true

  alias Oli.GoogleSlides.Credentials
  alias Oli.Seeder

  @service_account_json """
  {
    "type": "service_account",
    "project_id": "test-project",
    "private_key_id": "key-id",
    "private_key": "-----BEGIN RSA PRIVATE KEY-----\\nMIIBogIBAAJBAK5...\\n-----END RSA PRIVATE KEY-----\\n",
    "client_email": "slides@test-project.iam.gserviceaccount.com",
    "client_id": "123",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
    "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/slides"
  }
  """

  setup do
    seeder = DbSeeder.base_project_with_resource2()
    previous = System.get_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64")
    on_exit(fn -> restore_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64", previous) end)
    System.delete_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64")

    {:ok, project: seeder.project}
  end

  test "upsert and fetch credentials", %{project: project} do
    refute Credentials.configured?(project.id)

    Credentials.upsert!(project.id, @service_account_json)

    assert Credentials.configured?(project.id)
    assert Credentials.credential_source(project.id) == :project

    assert Credentials.get_client_email(project.id) ==
             "slides@test-project.iam.gserviceaccount.com"

    assert {:ok, credentials} = Credentials.get_credentials_map(project.id)
    assert credentials["client_email"] == "slides@test-project.iam.gserviceaccount.com"
  end

  test "uses global environment credentials when project override is absent", %{project: project} do
    encoded =
      @service_account_json
      |> String.trim()
      |> Base.encode64()

    previous = System.get_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64")
    on_exit(fn -> restore_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64", previous) end)
    System.put_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64", encoded)

    assert Credentials.global_configured?()
    assert Credentials.configured?(project.id)
    assert Credentials.credential_source(project.id) == :global

    assert Credentials.get_client_email(project.id) ==
             "slides@test-project.iam.gserviceaccount.com"

    assert {:ok, credentials} = Credentials.get_credentials_map(project.id)
    assert credentials["client_email"] == "slides@test-project.iam.gserviceaccount.com"
  end

  test "accepts base64 payloads with trailing shell prompt characters", %{project: project} do
    encoded =
      (@service_account_json <> "%")
      |> String.trim()
      |> Base.encode64()

    previous = System.get_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64")
    on_exit(fn -> restore_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64", previous) end)
    System.put_env("GOOGLE_SLIDES_SERVICE_ACCOUNT_JSON_B64", encoded)

    assert Credentials.global_configured?()
    assert Credentials.configured?(project.id)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
