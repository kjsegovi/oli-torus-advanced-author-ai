defmodule Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage.S3Media do
  @moduledoc """
  Stores immutable simulation bundles in the configured Torus media bucket.

  Every object lives below a SHA-256 content-addressed prefix. The configured
  generated-simulation origin remains separate from planner content and is the
  only origin this adapter will resolve for learner delivery.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

  alias ExAws.S3
  alias Oli.HTTP
  alias Oli.OpenStax.CourseImport.Enrichment.Origin
  alias Oli.OpenStax.CourseImport.SimulationArtifact

  @hash_pattern ~r/\A[0-9a-f]{64}\z/
  @storage_provider "s3_media"

  @impl true
  def available? do
    present?(Application.get_env(:oli, :s3_media_bucket_name)) and
      valid_origin?(configured_origin()) and dedicated_origin?(configured_origin()) and
      delivery_csp_enforced?()
  rescue
    _ -> false
  end

  @impl true
  def cleanup_available? do
    present?(Application.get_env(:oli, :s3_media_bucket_name))
  rescue
    _ -> false
  end

  @impl true
  def stage(%SimulationArtifact{} = artifact, bundle, opts)
      when is_map(bundle) and is_list(opts) do
    with {:ok, identity} <- prepare(artifact, bundle, opts),
         {:ok, files} <- files(bundle),
         {:ok, content_hash} <- bundle_hash(bundle),
         :ok <- upload_files(files, artifact.id, artifact.version, content_hash, opts) do
      {:ok, Map.put(identity, :storage_state, "staged")}
    else
      false -> {:error, :artifact_storage_unavailable}
      {:error, _} = error -> error
    end
  rescue
    _exception -> {:error, :artifact_storage_failed}
  end

  def stage(_, _, _), do: {:error, :invalid_input}

  @impl true
  def prepare(%SimulationArtifact{} = artifact, bundle, opts)
      when is_map(bundle) and is_list(opts) do
    with true <- available?(),
         storage_origin <- origin(opts),
         true <- valid_origin?(storage_origin) and dedicated_origin?(storage_origin),
         {:ok, files} <- files(bundle),
         {:ok, content_hash} <- bundle_hash(bundle),
         true <- hash_matches_files?(content_hash, files),
         :ok <- validate_artifact_hash(artifact, content_hash),
         :ok <- validate_artifact_identity(artifact) do
      {:ok,
       %{
         storage_provider: @storage_provider,
         storage_key: storage_key(artifact.id, artifact.version, content_hash, "index.html"),
         storage_origin: storage_origin,
         storage_state: "unstaged",
         byte_size:
           Enum.reduce(files, 0, fn {_path, contents}, total -> total + byte_size(contents) end)
       }}
    else
      false -> {:error, :artifact_storage_unavailable}
      {:error, _} = error -> error
    end
  rescue
    _exception -> {:error, :artifact_storage_failed}
  end

  def prepare(_, _, _), do: {:error, :invalid_input}

  @impl true
  def resolve(%SimulationArtifact{} = artifact, opts) when is_list(opts) do
    with true <- artifact.storage_provider == @storage_provider,
         true <-
           valid_storage_key?(
             artifact.storage_key,
             artifact.id,
             artifact.version,
             artifact.content_hash
           ),
         configured_origin <- origin(opts),
         true <- same_origin?(configured_origin, artifact.storage_origin) do
      {:ok, String.trim_trailing(configured_origin, "/") <> "/" <> artifact.storage_key}
    else
      false -> {:error, :artifact_storage_identity_invalid}
    end
  end

  def resolve(_, _), do: {:error, :invalid_input}

  @impl true
  def discard(%SimulationArtifact{} = artifact, _opts) do
    with true <- artifact.storage_provider == @storage_provider,
         true <- valid_hash?(artifact.content_hash),
         paths when is_list(paths) and paths != [] <- manifest_paths(artifact.bundle_manifest),
         :ok <- delete_paths(paths, artifact.id, artifact.version, artifact.content_hash) do
      :ok
    else
      false -> {:error, :artifact_storage_identity_invalid}
      [] -> {:error, :artifact_manifest_invalid}
      {:error, _} = error -> error
    end
  rescue
    _exception -> {:error, :artifact_storage_failed}
  end

  def discard(_, _), do: {:error, :invalid_input}

  defp upload_files(files, artifact_id, version, content_hash, opts) do
    bucket = Keyword.get(opts, :bucket, Application.get_env(:oli, :s3_media_bucket_name))

    result =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {path, contents}, {:ok, uploaded} ->
        request =
          S3.put_object(bucket, storage_key(artifact_id, version, content_hash, path), contents,
            acl: :public_read,
            content_type: MIME.from_path(path),
            cache_control: "public, max-age=31536000, immutable"
          )

        case request |> HTTP.aws().request() do
          {:ok, %{status_code: status}} when status in [200, 201, 204] ->
            {:cont, {:ok, uploaded ++ [path]}}

          _response ->
            {:halt, {:error, :artifact_upload_failed, uploaded}}
        end
      end)

    case result do
      {:ok, _uploaded} ->
        :ok

      {:error, reason, uploaded} ->
        _ = delete_paths(uploaded, artifact_id, version, content_hash, bucket)
        {:error, reason}
    end
  end

  defp delete_paths(paths, artifact_id, version, content_hash),
    do:
      delete_paths(
        paths,
        artifact_id,
        version,
        content_hash,
        Application.get_env(:oli, :s3_media_bucket_name)
      )

  defp delete_paths(paths, artifact_id, version, content_hash, bucket) do
    paths
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case bucket
           |> S3.delete_object(storage_key(artifact_id, version, content_hash, path))
           |> HTTP.aws().request() do
        {:ok, %{status_code: status}} when status in [200, 202, 204] -> {:cont, :ok}
        _response -> {:halt, {:error, :artifact_discard_failed}}
      end
    end)
  end

  defp files(bundle) do
    case bundle[:files] || bundle["files"] do
      files when is_map(files) and map_size(files) > 0 ->
        if Map.has_key?(files, "index.html") and
             Enum.all?(files, fn {path, contents} ->
               is_binary(path) and is_binary(contents) and safe_path?(path)
             end) do
          {:ok, files}
        else
          {:error, :artifact_bundle_invalid}
        end

      _ ->
        {:error, :artifact_bundle_invalid}
    end
  end

  defp bundle_hash(bundle) do
    value = bundle[:content_hash] || bundle["content_hash"]
    if valid_hash?(value), do: {:ok, value}, else: {:error, :artifact_hash_invalid}
  end

  defp validate_artifact_hash(%SimulationArtifact{content_hash: nil}, _content_hash), do: :ok

  defp validate_artifact_hash(%SimulationArtifact{content_hash: hash}, hash)
       when is_binary(hash),
       do: :ok

  defp validate_artifact_hash(_artifact, _content_hash),
    do: {:error, :artifact_hash_mismatch}

  defp hash_matches_files?(hash, files), do: hash == content_hash(files)

  defp content_hash(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn {path, contents} -> path <> <<0>> <> contents <> <<0>> end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp manifest_paths(manifest) when is_map(manifest) do
    (manifest["files"] || manifest[:files] || [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and safe_path?(&1)))
    |> Enum.uniq()
  end

  defp manifest_paths(_), do: []

  defp storage_key(artifact_id, version, content_hash, path),
    do:
      "generated-simulations/artifacts/#{artifact_id}/v#{version}/sha256/#{content_hash}/#{path}"

  defp valid_storage_key?(key, artifact_id, version, content_hash)
       when is_binary(key) and is_binary(artifact_id) and artifact_id != "" and
              is_integer(version) and is_binary(content_hash),
       do: key == storage_key(artifact_id, version, content_hash, "index.html")

  defp valid_storage_key?(_, _, _, _), do: false

  defp validate_artifact_identity(%SimulationArtifact{id: id})
       when is_binary(id) and id != "",
       do: :ok

  defp validate_artifact_identity(_artifact), do: {:error, :artifact_identity_invalid}

  defp safe_path?(path) do
    normalized = path |> Path.expand("/bundle") |> Path.relative_to("/bundle")

    path != "" and Path.type(path) != :absolute and path == normalized and
      not String.contains?(path, ["\\", <<0>>])
  end

  defp origin(opts), do: Keyword.get(opts, :origin, configured_origin())

  defp configured_origin do
    Application.get_env(:oli, :openstax_generated_simulation_origin)
  end

  defp delivery_csp_enforced? do
    Application.get_env(:oli, :env) in [:dev, :test] or
      Application.get_env(:oli, :openstax_generated_simulation_csp_header_enforced, false) ==
        true
  end

  defp same_origin?(left, right) do
    normalize_origin(left) == normalize_origin(right) and not is_nil(normalize_origin(left))
  end

  defp valid_origin?(value), do: not is_nil(normalize_origin(value))

  defp dedicated_origin?(value) do
    generated = normalize_origin(value)

    general_origins =
      [
        Application.get_env(:oli, :media_url),
        configured_app_origin()
      ]
      |> Enum.map(&normalize_origin/1)
      |> Enum.reject(&is_nil/1)

    not is_nil(generated) and generated not in general_origins
  end

  defp configured_app_origin do
    endpoint_config = Application.get_env(:oli, OliWeb.Endpoint, [])
    url = Keyword.get(endpoint_config, :url, [])
    scheme = Keyword.get(url, :scheme, "http") |> to_string()
    host = Keyword.get(url, :host)
    port = Keyword.get(url, :port)

    cond do
      not is_binary(host) or host == "" -> nil
      is_integer(port) -> "#{scheme}://#{host}:#{port}"
      true -> "#{scheme}://#{host}"
    end
  end

  defp normalize_origin(value) when is_binary(value) do
    case URI.parse(String.trim_trailing(value, "/")) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if scheme == "https" or Origin.local_loopback_host?(host) do
          port =
            case {scheme, uri.port} do
              {"https", 443} -> nil
              {"http", 80} -> nil
              {_scheme, value} -> value
            end

          if is_integer(port),
            do: "#{scheme}://#{String.downcase(host)}:#{port}",
            else: "#{scheme}://#{String.downcase(host)}"
        end

      _ ->
        nil
    end
  end

  defp normalize_origin(_), do: nil
  defp valid_hash?(value), do: is_binary(value) and Regex.match?(@hash_pattern, value)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
