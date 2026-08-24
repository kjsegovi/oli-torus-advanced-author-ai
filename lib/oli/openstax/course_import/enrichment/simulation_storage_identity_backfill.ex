defmodule Oli.OpenStax.CourseImport.Enrichment.SimulationStorageIdentityBackfill do
  @moduledoc """
  Verifies and versions legacy S3-compatible simulation storage identities.

  Existing origins and keys are never rewritten. A legacy identity is stamped
  only after the recorded entrypoint is confirmed in the legacy bucket.
  """

  import Ecto.Query

  require Logger

  alias ExAws.S3
  alias Oli.HTTP
  alias Oli.OpenStax.CourseImport.SimulationArtifact
  alias Oli.Repo

  @legacy_identity_version 1

  @spec run(keyword()) ::
          {:ok,
           %{
             backfilled: non_neg_integer(),
             missing: non_neg_integer(),
             skipped: non_neg_integer()
           }}
  def run(opts \\ []) do
    bucket = Keyword.get(opts, :legacy_bucket, Application.get_env(:oli, :s3_media_bucket_name))
    object_exists? = Keyword.get(opts, :object_exists?, &object_exists?/2)

    if present?(bucket) do
      SimulationArtifact
      |> where(
        [artifact],
        artifact.storage_provider == "s3_media" and
          is_nil(artifact.storage_bucket) and
          is_nil(artifact.storage_identity_version) and
          not is_nil(artifact.storage_key)
      )
      |> Repo.all()
      |> Enum.reduce(%{backfilled: 0, missing: 0, skipped: 0}, fn artifact, counts ->
        backfill_artifact(artifact, bucket, object_exists?, counts)
      end)
      |> tap(&emit_telemetry/1)
      |> then(&{:ok, &1})
    else
      {:ok, %{backfilled: 0, missing: 0, skipped: 0}}
    end
  rescue
    exception ->
      Logger.error(
        "Generated simulation storage identity backfill failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :simulation_storage_identity_backfill_failed}
  end

  defp backfill_artifact(artifact, bucket, object_exists?, counts) do
    if legacy_identity_candidate?(artifact) do
      verify_and_backfill(artifact, bucket, object_exists?, counts)
    else
      Logger.warning(
        "Generated simulation legacy identity is invalid; preserving native fallback",
        artifact_id: artifact.id,
        storage_bucket: bucket
      )

      %{counts | skipped: counts.skipped + 1}
    end
  end

  defp verify_and_backfill(artifact, bucket, object_exists?, counts) do
    case object_exists?.(bucket, artifact.storage_key) do
      true ->
        now = DateTime.utc_now()

        {updated, _} =
          SimulationArtifact
          |> where(
            [current],
            current.id == ^artifact.id and is_nil(current.storage_bucket) and
              is_nil(current.storage_identity_version)
          )
          |> Repo.update_all(
            set: [
              storage_bucket: bucket,
              storage_identity_version: @legacy_identity_version,
              updated_at: now
            ]
          )

        if updated == 1,
          do: %{counts | backfilled: counts.backfilled + 1},
          else: %{counts | skipped: counts.skipped + 1}

      false ->
        Logger.warning(
          "Generated simulation legacy object is unavailable; preserving native fallback",
          artifact_id: artifact.id,
          storage_bucket: bucket
        )

        %{counts | missing: counts.missing + 1}

      {:error, reason} ->
        Logger.warning(
          "Generated simulation legacy object could not be verified; preserving native fallback",
          artifact_id: artifact.id,
          storage_bucket: bucket,
          reason: inspect(reason)
        )

        %{counts | missing: counts.missing + 1}
    end
  end

  defp legacy_identity_candidate?(artifact) do
    expected_key =
      "generated-simulations/artifacts/#{artifact.id}/v#{artifact.version}/sha256/#{artifact.content_hash}/index.html"

    artifact.storage_key == expected_key and present?(artifact.storage_origin) and
      is_binary(artifact.content_hash) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact.content_hash)
  end

  defp object_exists?(bucket, key) do
    case bucket |> S3.head_object(key) |> HTTP.aws().request() do
      {:ok, %{status_code: status}} when status in 200..299 -> true
      {:ok, %{status_code: 404}} -> false
      {:error, {:http_error, 404, _}} -> false
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp emit_telemetry(counts) do
    :telemetry.execute(
      [:oli, :openstax, :course_import, :simulation_storage_backfill],
      counts,
      %{}
    )
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
