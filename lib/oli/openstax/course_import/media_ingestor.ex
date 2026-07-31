defmodule Oli.OpenStax.CourseImport.MediaIngestor do
  @moduledoc """
  Safely stages remote OpenStax images in a project's media library.

  Every redirect target is revalidated against an HTTPS host allowlist.
  Response headers and bytes are bounded before upload, and declared MIME
  types must agree with a supported file signature. Staging state is durable,
  so retries reuse completed assets and MediaLibrary-level duplicates.
  """

  import Ecto.Query
  import Bitwise

  alias Oli.Authoring.MediaLibrary
  alias Oli.OpenStax.CourseImport.{Media, Run, SourceAsset}
  alias Oli.Repo

  @default_allowed_hosts ~w(openstax.org assets.openstax.org)
  @supported_mime_types ~w(image/png image/jpeg image/gif image/webp)
  @max_asset_count 240
  @max_asset_bytes 10 * 1024 * 1024
  @max_total_bytes 100 * 1024 * 1024
  @max_image_width 12_000
  @max_image_height 12_000
  @max_image_pixels 40_000_000
  @max_redirects 3
  @connect_timeout 5_000
  @receive_timeout 15_000
  @user_agent "OLI-Torus-OpenStax-Media-Importer/1.0"

  defmodule Result do
    @moduledoc false

    defstruct total: 0,
              staged: 0,
              reused: 0,
              skipped: 0,
              bytes_staged: 0,
              media: [],
              unavailable: []

    @type t :: %__MODULE__{
            total: non_neg_integer(),
            staged: non_neg_integer(),
            reused: non_neg_integer(),
            skipped: non_neg_integer(),
            bytes_staged: non_neg_integer(),
            media: [Oli.OpenStax.CourseImport.Media.t()],
            unavailable: [map()]
          }
  end

  @spec stage_run(Ecto.UUID.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def stage_run(run_id, opts \\ [])

  def stage_run(run_id, opts) when is_binary(run_id) do
    with %Run{} = run <- Repo.get(Run, run_id),
         run <- Repo.preload(run, :project),
         true <- not is_nil(run.project),
         assets <- run_assets(run.id),
         :ok <- validate_asset_count(assets, opts) do
      stage_assets(run, assets, opts, false)
    else
      nil -> {:error, :not_found}
      false -> {:error, :project_not_found}
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, {:media_staging_exception, Exception.message(exception)}}
  end

  def stage_run(_, _), do: {:error, :invalid_input}

  @spec select_required_assets(Ecto.UUID.t(), [String.t()]) ::
          {:ok, [SourceAsset.t()]} | {:error, term()}
  def select_required_assets(run_id, source_keys)
      when is_binary(run_id) and is_list(source_keys) do
    source_keys =
      source_keys
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    Repo.transaction(fn ->
      Repo.get(Run, run_id) || Repo.rollback(:not_found)

      Repo.update_all(
        from(asset in SourceAsset, where: asset.run_id == ^run_id),
        set: [required: false]
      )

      selected =
        SourceAsset
        |> where([asset], asset.run_id == ^run_id and asset.source_key in ^source_keys)
        |> order_by([asset], asc: asset.source_key)
        |> Repo.all()

      selected_keys = Enum.map(selected, & &1.source_key)

      if selected_keys == source_keys do
        Repo.update_all(
          from(asset in SourceAsset, where: asset.id in ^Enum.map(selected, & &1.id)),
          set: [required: true]
        )

        Enum.map(selected, &%{&1 | required: true})
      else
        Repo.rollback({:unknown_required_media_ids, source_keys -- selected_keys})
      end
    end)
  end

  def select_required_assets(_, _), do: {:error, :invalid_input}

  @spec stage_required_run(Ecto.UUID.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def stage_required_run(run_id, opts \\ [])

  def stage_required_run(run_id, opts) when is_binary(run_id) do
    with %Run{} = run <- Repo.get(Run, run_id),
         run <- Repo.preload(run, :project),
         true <- not is_nil(run.project),
         assets <- required_run_assets(run.id),
         :ok <- validate_asset_count(assets, opts),
         {:ok, result} <- stage_assets(run, assets, opts, true) do
      case result.unavailable do
        [] -> {:ok, result}
        unavailable -> {:error, {:required_media_unavailable, unavailable}}
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :project_not_found}
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, {:media_staging_exception, Exception.message(exception)}}
  end

  def stage_required_run(_, _), do: {:error, :invalid_input}

  @spec required_media_ids(map()) :: [String.t()]
  def required_media_ids(compiled) when is_map(compiled) do
    compiled
    |> collect_required_media_ids([])
    |> Enum.uniq()
    |> Enum.sort()
  end

  def required_media_ids(_), do: []

  @spec discovery_media_urls(Ecto.UUID.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def discovery_media_urls(run_id, source_keys)
      when is_binary(run_id) and is_list(source_keys) do
    assets =
      SourceAsset
      |> where([asset], asset.run_id == ^run_id and asset.source_key in ^source_keys)
      |> order_by([asset], asc: asset.source_key)
      |> Repo.all()

    selected_keys = Enum.map(assets, & &1.source_key)
    expected_keys = source_keys |> Enum.uniq() |> Enum.sort()

    if selected_keys == expected_keys do
      {:ok,
       Map.new(assets, fn asset ->
         semantic = semantic_asset_metadata(asset)

         {asset.source_key,
          %{
            "url" => "staged://#{asset.source_key}",
            "alt" => asset.alt_text || semantic["alt"],
            "caption" => asset.caption || semantic["caption"],
            "credit" => semantic["credit"],
            "rights_status" => semantic["rights_status"]
          }}
       end)}
    else
      {:error, {:unknown_required_media_ids, expected_keys -- selected_keys}}
    end
  end

  def discovery_media_urls(_, _), do: {:error, :invalid_input}

  @spec required_media_urls(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def required_media_urls(run_id) when is_binary(run_id) do
    assets = required_run_assets(run_id)

    assets
    |> Enum.reduce_while({:ok, %{}}, fn asset, {:ok, urls} ->
      case required_media_override(asset) do
        {:ok, override} ->
          {:cont, {:ok, Map.put(urls, asset.source_key, override)}}

        {:error, reason} ->
          {:halt, {:error, {:required_media_not_ready, asset.source_key, reason}}}
      end
    end)
  end

  def required_media_urls(_), do: {:error, :invalid_input}

  @doc """
  Soft-deletes only unreferenced MediaLibrary items that this run created.

  Reused items, another project's items, items shared by another import row,
  and items predating the run are never selected. While a run is awaiting
  lesson review, selected items are also retained. Failed or cancelled runs may
  clean selected items because course import apply is atomic and cannot publish
  a partial curriculum. This is intentionally explicit and is not invoked by
  retry paths.
  """
  @spec cleanup_run_created_media(Ecto.UUID.t(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), media_item_ids: [integer()]}} | {:error, term()}
  def cleanup_run_created_media(run_id, opts \\ [])

  def cleanup_run_created_media(run_id, opts) when is_binary(run_id) do
    with %Run{} = run <- Repo.get(Run, run_id),
         true <-
           run.status in [
             :awaiting_lesson_approval,
             :failed,
             :cancelled
           ],
         run <- Repo.preload(run, :project),
         true <- not is_nil(run.project) do
      started_at =
        (run.started_at || run.inserted_at)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      candidates =
        SourceAsset
        |> join(:inner, [asset], media in Media,
          on:
            media.source_asset_id == asset.id and media.run_id == asset.run_id and
              media.project_id == ^run.project_id
        )
        |> join(:inner, [asset, media], item in assoc(media, :media_item))
        |> maybe_limit_cleanup_to_unselected(run.status)
        |> where(
          [asset, media, item],
          asset.run_id == ^run.id and media.status == "staged" and
            item.project_id == ^run.project_id and item.deleted == false and
            item.inserted_at >= ^started_at
        )
        |> select([_asset, media, item], {media.id, item.id})
        |> Repo.all()
        |> Enum.reject(fn {media_id, item_id} ->
          Repo.exists?(
            from(other in Media,
              where: other.media_item_id == ^item_id and other.id != ^media_id
            )
          )
        end)

      media_item_ids = candidates |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      media_library = Keyword.get(opts, :media_library, MediaLibrary)

      case media_item_ids do
        [] ->
          {:ok, %{deleted: 0, media_item_ids: []}}

        ids ->
          case media_library.delete_media_items(run.project.slug, ids) do
            {:ok, deleted} when is_integer(deleted) ->
              {:ok, %{deleted: deleted, media_item_ids: ids}}

            {:error, reason} ->
              {:error, {:media_cleanup_failed, reason}}

            other ->
              {:error, {:invalid_media_cleanup_response, inspect(other)}}
          end
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :media_cleanup_not_allowed}
    end
  end

  def cleanup_run_created_media(_, _), do: {:error, :invalid_input}

  defp maybe_limit_cleanup_to_unselected(query, :awaiting_lesson_approval),
    do: where(query, [asset, _media, _item], asset.required == false)

  defp maybe_limit_cleanup_to_unselected(query, _terminal_status), do: query

  @doc false
  def trusted_source_url?(url, opts \\ []) do
    allowed_hosts = allowed_hosts(opts)

    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        userinfo: nil
      }
      when is_binary(host) and port in [nil, 443] ->
        normalize_host(host) in allowed_hosts and byte_size(url) <= 2_048

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp run_assets(run_id) do
    SourceAsset
    |> where([asset], asset.run_id == ^run_id)
    |> order_by([asset], asc: asset.source_section_id, asc: asset.order)
    |> preload([:media])
    |> Repo.all()
  end

  defp required_run_assets(run_id) do
    SourceAsset
    |> where([asset], asset.run_id == ^run_id and asset.required == true)
    |> order_by([asset], asc: asset.source_key)
    |> preload(media: [:media_item])
    |> Repo.all()
  end

  defp stage_assets(run, assets, opts, strict?) do
    initial = %Result{
      total: length(assets),
      bytes_staged: already_staged_bytes(assets)
    }

    assets
    |> Enum.reduce_while({:ok, initial}, fn asset, {:ok, result} ->
      case stage_asset(asset, run, result.bytes_staged, opts) do
        {:ok, media, :staged, bytes} ->
          result = %{
            result
            | staged: result.staged + 1,
              bytes_staged: result.bytes_staged + bytes,
              media: [media | result.media]
          }

          continue_with_progress(result, opts)

        {:ok, media, :reused, bytes} ->
          result = %{
            result
            | reused: result.reused + 1,
              bytes_staged: result.bytes_staged + bytes,
              media: [media | result.media]
          }

          continue_with_progress(result, opts)

        {:ok, media, :already_staged, _bytes} ->
          result = %{
            result
            | reused: result.reused + 1,
              media: [media | result.media]
          }

          continue_with_progress(result, opts)

        {:ok, media, :skipped, _bytes} ->
          unavailable =
            if strict? do
              [
                %{
                  "source_media_id" => asset.source_key,
                  "reason" => media.failure_reason || %{"reason" => "skipped"}
                }
                | result.unavailable
              ]
            else
              result.unavailable
            end

          result = %{
            result
            | skipped: result.skipped + 1,
              media: [media | result.media],
              unavailable: unavailable
          }

          continue_with_progress(result, opts)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok,
         %{
           result
           | media: Enum.reverse(result.media),
             unavailable: Enum.reverse(result.unavailable)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp continue_with_progress(result, opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 1) ->
        case callback.(result) do
          :ok -> {:cont, {:ok, result}}
          {:ok, _value} -> {:cont, {:ok, result}}
          {:error, reason} -> {:halt, {:error, {:progress_checkpoint_failed, reason}}}
          other -> {:halt, {:error, {:invalid_progress_callback_response, other}}}
        end

      _ ->
        {:cont, {:ok, result}}
    end
  rescue
    exception ->
      {:halt, {:error, {:progress_callback_exception, Exception.message(exception)}}}
  end

  defp required_media_override(
         %SourceAsset{
           run_id: run_id,
           media: %Media{
             run_id: run_id,
             project_id: project_id,
             status: status,
             media_url: media_url,
             media_item: %{project_id: project_id, deleted: false, url: item_url}
           }
         } = asset
       )
       when status in ["staged", "reused"] do
    url = item_url || media_url

    if is_binary(url) and url != "" do
      semantic = semantic_asset_metadata(asset)

      {:ok,
       %{
         "url" => url,
         "alt" => asset.alt_text || semantic["alt"],
         "caption" => asset.caption || semantic["caption"],
         "credit" => semantic["credit"],
         "rights_status" => semantic["rights_status"]
       }}
    else
      {:error, :missing_media_url}
    end
  end

  # The association can still be preloaded when the Media Library row has
  # subsequently been soft-deleted. Only the fully validated clause above is
  # allowed to return a URL; every other staged/reused shape is unavailable.
  defp required_media_override(%SourceAsset{media: %Media{status: status}})
       when status in ["staged", "reused"],
       do: {:error, :missing_media_record}

  defp required_media_override(%SourceAsset{media: %Media{status: status}}),
    do: {:error, {:invalid_media_status, status}}

  defp required_media_override(_), do: {:error, :missing_media_record}

  defp semantic_asset_metadata(asset) do
    case get_in(asset.metadata || %{}, ["semantic_payload"]) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp collect_required_media_ids(%{"required_media_ids" => ids} = value, acc)
       when is_list(ids) do
    value
    |> Map.delete("required_media_ids")
    |> collect_required_media_ids(ids ++ acc)
  end

  defp collect_required_media_ids(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {_key, nested}, nested_acc ->
      collect_required_media_ids(nested, nested_acc)
    end)
  end

  defp collect_required_media_ids(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_required_media_ids/2)
  end

  defp collect_required_media_ids(_value, acc),
    do: Enum.filter(acc, &(is_binary(&1) and &1 != ""))

  defp validate_asset_count(assets, opts) do
    max_count = positive_limit(opts[:max_asset_count], @max_asset_count)

    if length(assets) <= max_count,
      do: :ok,
      else: {:error, {:source_media_limit_exceeded, :asset_count, max_count}}
  end

  defp already_staged_bytes(assets) do
    Enum.reduce(assets, 0, fn
      %SourceAsset{media: %Media{status: status, byte_size: size}}, total
      when status in ["staged", "reused"] and is_integer(size) ->
        total + size

      _, total ->
        total
    end)
  end

  defp stage_asset(
         %SourceAsset{media: %Media{status: status} = media},
         _run,
         _total_bytes,
         _opts
       )
       when status in ["staged", "reused"] do
    {:ok, media, :already_staged, media.byte_size || 0}
  end

  defp stage_asset(
         %SourceAsset{media: %Media{status: "skipped"} = media},
         _run,
         _total_bytes,
         _opts
       ),
       do: {:ok, media, :skipped, 0}

  defp stage_asset(asset, run, total_bytes, opts) do
    with true <- trusted_source_url?(asset.source_url, opts),
         {:ok, staging} <- mark_staging(asset, run),
         {:ok, bytes, mime_type, final_url} <- fetch_remote(asset.source_url, opts),
         :ok <- validate_declared_mime(asset.declared_mime_type, mime_type),
         :ok <- validate_total_bytes(total_bytes, byte_size(bytes), opts),
         {:ok, upload_status, media_item} <-
           upload(asset, run.project.slug, bytes, mime_type, opts),
         {:ok, media} <-
           mark_staged(
             asset,
             staging,
             media_item,
             upload_status,
             final_url,
             bytes,
             mime_type
           ) do
      {:ok, media, upload_status, byte_size(bytes)}
    else
      false ->
        skip(asset, run, :untrusted_source_url)

      {:error, reason} ->
        if permanent_failure?(reason) do
          skip(asset, run, reason)
        else
          fail(asset, run, reason)
        end
    end
  end

  defp mark_staging(asset, run) do
    media = asset.media || %Media{}

    result =
      media
      |> Media.changeset(%{
        run_id: run.id,
        source_asset_id: asset.id,
        project_id: run.project_id,
        status: "staging",
        source_url: asset.source_url,
        attempts: (media.attempts || 0) + 1,
        failure_reason: nil
      })
      |> Repo.insert_or_update()

    with {:ok, persisted} <- result,
         {:ok, _asset} <- update_asset_status(asset, "staging") do
      {:ok, persisted}
    end
  end

  defp mark_staged(
         asset,
         media,
         media_item,
         upload_status,
         final_url,
         bytes,
         mime_type
       ) do
    status = if(upload_status == :reused, do: "reused", else: "staged")
    sha256 = sha256(bytes)
    file_name = staged_filename(asset.id, sha256, mime_type)

    with {:ok, persisted} <-
           media
           |> Media.changeset(%{
             media_item_id: map_value(media_item, :id),
             status: status,
             final_source_url: final_url,
             media_url: map_value(media_item, :url),
             file_name: file_name,
             mime_type: mime_type,
             byte_size: byte_size(bytes),
             sha256: sha256,
             failure_reason: nil,
             staged_at: DateTime.utc_now()
           })
           |> Repo.update(),
         {:ok, _asset} <- update_asset_status(asset, status) do
      {:ok, persisted}
    end
  end

  defp skip(asset, run, reason) do
    with {:ok, media} <- mark_terminal(asset, run, "skipped", reason),
         {:ok, _asset} <- update_asset_status(asset, "skipped") do
      {:ok, media, :skipped, 0}
    end
  end

  defp fail(asset, run, reason) do
    with {:ok, _media} <- mark_terminal(asset, run, "failed", reason),
         {:ok, _asset} <- update_asset_status(asset, "failed") do
      {:error, {:source_media_staging_failed, asset.id, reason}}
    end
  end

  defp mark_terminal(asset, run, status, reason) do
    media =
      case asset.media do
        %Media{} = media ->
          Repo.get(Media, media.id) || media

        _ ->
          Repo.get_by(Media, source_asset_id: asset.id) || %Media{}
      end

    media
    |> Media.changeset(%{
      run_id: run.id,
      source_asset_id: asset.id,
      project_id: run.project_id,
      status: status,
      source_url: asset.source_url,
      attempts: max(media.attempts || 0, 1),
      failure_reason: %{"reason" => inspect(reason)}
    })
    |> Repo.insert_or_update()
  end

  defp update_asset_status(asset, status) do
    asset
    |> SourceAsset.changeset(%{status: status})
    |> Repo.update()
  end

  defp upload(asset, project_slug, bytes, mime_type, opts) do
    media_library = Keyword.get(opts, :media_library, MediaLibrary)
    sha256 = sha256(bytes)
    file_name = staged_filename(asset.id, sha256, mime_type)

    case media_library.add(project_slug, file_name, bytes) do
      {:ok, media_item} -> {:ok, :staged, media_item}
      {:duplicate, media_item} -> {:ok, :reused, media_item}
      {:error, reason} -> {:error, {:media_library_upload_failed, reason}}
      other -> {:error, {:invalid_media_library_response, inspect(other)}}
    end
  end

  defp fetch_remote(url, opts), do: fetch_remote(url, opts, 0)

  defp fetch_remote(url, opts, redirect_count) do
    max_redirects = positive_limit(opts[:max_redirects], @max_redirects)

    with true <- trusted_source_url?(url, opts),
         {:ok, response} <- request(url, opts) do
      case response.status_code do
        status when status in 200..299 ->
          with {:ok, mime_type} <- response_mime_type(response.headers),
               :ok <- validate_body_size(response.body, opts),
               :ok <- validate_file_signature(response.body, mime_type),
               :ok <- validate_image_dimensions(response.body, mime_type, opts) do
            {:ok, response.body, mime_type, url}
          end

        status when status in [301, 302, 303, 307, 308] ->
          with true <- redirect_count < max_redirects,
               {:ok, location} <- redirect_location(response.headers),
               {:ok, redirected_url} <- resolve_redirect(url, location),
               true <- trusted_source_url?(redirected_url, opts) do
            fetch_remote(redirected_url, opts, redirect_count + 1)
          else
            false -> {:error, :untrusted_or_excessive_redirect}
            {:error, _} = error -> error
          end

        status ->
          {:error, {:unexpected_status, status}}
      end
    else
      false -> {:error, :untrusted_source_url}
      {:error, _} = error -> error
    end
  end

  defp request(url, opts) do
    client = Keyword.get(opts, :http_client, HTTPoison)
    max_bytes = positive_limit(opts[:max_asset_bytes], @max_asset_bytes)
    receive_timeout = positive_limit(opts[:receive_timeout], @receive_timeout)

    headers = [
      {"accept", Enum.join(@supported_mime_types, ",")},
      {"user-agent", @user_agent}
    ]

    request_opts = [
      timeout: positive_limit(opts[:connect_timeout], @connect_timeout),
      recv_timeout: receive_timeout,
      max_body_length: max_bytes,
      hackney: [follow_redirect: false]
    ]

    if client == HTTPoison do
      request_streaming(url, headers, request_opts, max_bytes, receive_timeout)
    else
      request_buffered(client, url, headers, request_opts, max_bytes)
    end
  rescue
    exception -> {:error, {:http_exception, Exception.message(exception)}}
  end

  defp request_buffered(client, url, headers, request_opts, max_bytes) do
    case call_client(client, url, headers, request_opts) do
      {:ok, %{status_code: status, headers: response_headers} = response} ->
        body = Map.get(response, :body, "")

        with true <- is_binary(body),
             :ok <- validate_content_length(response_headers, max_bytes),
             :ok <- validate_body_size(body, max_bytes) do
          {:ok, %{status_code: status, headers: response_headers, body: body}}
        else
          false -> {:error, :invalid_http_body}
          {:error, _} = error -> error
        end

      {:ok, %{status_code: status} = response} ->
        {:ok,
         %{
           status_code: status,
           headers: Map.get(response, :headers, []),
           body: Map.get(response, :body, "")
         }}

      {:error, reason} ->
        {:error, {:http_error, reason}}

      other ->
        {:error, {:invalid_http_response, inspect(other)}}
    end
  end

  defp call_client(client, url, headers, request_opts) when is_function(client, 3),
    do: client.(url, headers, request_opts)

  defp call_client(client, url, headers, request_opts),
    do: client.get(url, headers, request_opts)

  defp request_streaming(url, headers, request_opts, max_bytes, receive_timeout) do
    stream_opts = request_opts ++ [stream_to: self(), async: :once]

    case HTTPoison.get(url, headers, stream_opts) do
      {:ok, %HTTPoison.AsyncResponse{} = response} ->
        HTTPoison.stream_next(response)
        collect_stream(response, max_bytes, receive_timeout, nil, [], [], 0)

      {:error, reason} ->
        {:error, {:http_error, reason}}

      other ->
        {:error, {:invalid_http_response, inspect(other)}}
    end
  end

  defp collect_stream(response, max_bytes, timeout, status, headers, chunks, size) do
    receive do
      %HTTPoison.AsyncStatus{id: id, code: code} when id == response.id ->
        HTTPoison.stream_next(response)
        collect_stream(response, max_bytes, timeout, code, headers, chunks, size)

      %HTTPoison.AsyncHeaders{id: id, headers: response_headers} when id == response.id ->
        with :ok <- validate_content_length(response_headers, max_bytes) do
          if status in [301, 302, 303, 307, 308] do
            stop_stream(response)
            {:ok, %{status_code: status, headers: response_headers, body: ""}}
          else
            HTTPoison.stream_next(response)

            collect_stream(
              response,
              max_bytes,
              timeout,
              status,
              response_headers,
              chunks,
              size
            )
          end
        else
          {:error, _} = error ->
            stop_stream(response)
            error
        end

      %HTTPoison.AsyncChunk{id: id, chunk: chunk} when id == response.id ->
        next_size = size + byte_size(chunk)

        if next_size <= max_bytes do
          HTTPoison.stream_next(response)

          collect_stream(
            response,
            max_bytes,
            timeout,
            status,
            headers,
            [chunk | chunks],
            next_size
          )
        else
          stop_stream(response)
          {:error, {:response_too_large, next_size, max_bytes}}
        end

      %HTTPoison.AsyncEnd{id: id} when id == response.id ->
        {:ok,
         %{
           status_code: status,
           headers: headers,
           body: chunks |> Enum.reverse() |> IO.iodata_to_binary()
         }}
    after
      timeout ->
        stop_stream(response)
        {:error, :http_receive_timeout}
    end
  end

  defp stop_stream(%HTTPoison.AsyncResponse{id: id}) do
    :hackney.stop_async(id)
    :ok
  rescue
    _ -> :ok
  end

  defp response_mime_type(headers) do
    case header_value(headers, "content-type") do
      nil ->
        {:error, :missing_content_type}

      value ->
        mime_type =
          value
          |> String.split(";", parts: 2)
          |> List.first()
          |> String.trim()
          |> String.downcase()
          |> normalize_mime_type()

        if mime_type in @supported_mime_types,
          do: {:ok, mime_type},
          else: {:error, {:unsupported_mime_type, mime_type}}
    end
  end

  defp normalize_mime_type("image/jpg"), do: "image/jpeg"
  defp normalize_mime_type(value), do: value

  defp validate_declared_mime(nil, _actual), do: :ok
  defp validate_declared_mime("", _actual), do: :ok

  defp validate_declared_mime(declared, actual) do
    declared =
      declared
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()
      |> normalize_mime_type()

    if declared == actual,
      do: :ok,
      else: {:error, {:declared_mime_mismatch, declared, actual}}
  end

  defp validate_file_signature(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, "image/png"),
    do: :ok

  defp validate_file_signature(<<0xFF, 0xD8, 0xFF, _::binary>>, "image/jpeg"), do: :ok
  defp validate_file_signature(<<"GIF87a", _::binary>>, "image/gif"), do: :ok
  defp validate_file_signature(<<"GIF89a", _::binary>>, "image/gif"), do: :ok

  defp validate_file_signature(
         <<"RIFF", _size::binary-size(4), "WEBP", _::binary>>,
         "image/webp"
       ),
       do: :ok

  defp validate_file_signature(_bytes, mime_type),
    do: {:error, {:mime_signature_mismatch, mime_type}}

  defp validate_image_dimensions(bytes, mime_type, opts) do
    max_width = positive_limit(opts[:max_image_width], @max_image_width)
    max_height = positive_limit(opts[:max_image_height], @max_image_height)
    max_pixels = positive_limit(opts[:max_image_pixels], @max_image_pixels)

    with {:ok, {width, height}} <- image_dimensions(bytes, mime_type),
         true <- width > 0 and height > 0,
         true <- width <= max_width and height <= max_height,
         true <- width * height <= max_pixels do
      :ok
    else
      false ->
        {:error, {:image_dimensions_exceeded, max_width, max_height, max_pixels}}

      {:error, _} = error ->
        error
    end
  end

  defp image_dimensions(
         <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", width::32, height::32,
           _rest::binary>>,
         "image/png"
       ),
       do: {:ok, {width, height}}

  defp image_dimensions(
         <<"GIF87a", width::little-16, height::little-16, _rest::binary>>,
         "image/gif"
       ),
       do: {:ok, {width, height}}

  defp image_dimensions(
         <<"GIF89a", width::little-16, height::little-16, _rest::binary>>,
         "image/gif"
       ),
       do: {:ok, {width, height}}

  defp image_dimensions(<<0xFF, 0xD8, rest::binary>>, "image/jpeg"),
    do: jpeg_dimensions(rest)

  defp image_dimensions(
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8X", _chunk_size::little-32, _flags::8,
           _reserved::24, width_minus_one::little-24, height_minus_one::little-24,
           _rest::binary>>,
         "image/webp"
       ),
       do: {:ok, {width_minus_one + 1, height_minus_one + 1}}

  defp image_dimensions(
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8L", _chunk_size::little-32, 0x2F, b0::8,
           b1::8, b2::8, b3::8, _rest::binary>>,
         "image/webp"
       ) do
    width = 1 + b0 + ((b1 &&& 0x3F) <<< 8)
    height = 1 + (b1 >>> 6) + (b2 <<< 2) + ((b3 &&& 0x0F) <<< 10)
    {:ok, {width, height}}
  end

  defp image_dimensions(
         <<"RIFF", _riff_size::little-32, "WEBP", "VP8 ", _chunk_size::little-32,
           _frame_tag::binary-size(3), 0x9D, 0x01, 0x2A, raw_width::little-16,
           raw_height::little-16, _rest::binary>>,
         "image/webp"
       ),
       do: {:ok, {raw_width &&& 0x3FFF, raw_height &&& 0x3FFF}}

  defp image_dimensions(_bytes, mime_type),
    do: {:error, {:image_dimensions_unavailable, mime_type}}

  @jpeg_sof_markers [
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF
  ]

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>) when marker in @jpeg_sof_markers do
    case rest do
      <<_segment_size::16, _precision::8, height::16, width::16, _rest::binary>> ->
        {:ok, {width, height}}

      _ ->
        {:error, {:image_dimensions_unavailable, "image/jpeg"}}
    end
  end

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>)
       when marker in [0x01, 0xD8, 0xD9] or marker in 0xD0..0xD7,
       do: jpeg_dimensions(rest)

  defp jpeg_dimensions(<<0xFF, _marker, segment_size::16, rest::binary>>)
       when segment_size >= 2 and byte_size(rest) >= segment_size - 2 do
    <<_segment::binary-size(segment_size - 2), remaining::binary>> = rest
    jpeg_dimensions(remaining)
  end

  defp jpeg_dimensions(<<_byte, rest::binary>>), do: jpeg_dimensions(rest)

  defp jpeg_dimensions(_),
    do: {:error, {:image_dimensions_unavailable, "image/jpeg"}}

  defp validate_body_size(body, opts) when is_list(opts) do
    validate_body_size(body, positive_limit(opts[:max_asset_bytes], @max_asset_bytes))
  end

  defp validate_body_size(body, max_bytes) when is_binary(body) and is_integer(max_bytes) do
    if byte_size(body) <= max_bytes,
      do: :ok,
      else: {:error, {:response_too_large, byte_size(body), max_bytes}}
  end

  defp validate_total_bytes(total, incoming, opts) do
    max_total = positive_limit(opts[:max_total_bytes], @max_total_bytes)

    if total + incoming <= max_total,
      do: :ok,
      else: {:error, {:source_media_limit_exceeded, :total_bytes, max_total}}
  end

  defp validate_content_length(headers, max_bytes) do
    case header_value(headers, "content-length") do
      nil ->
        :ok

      value ->
        case Integer.parse(String.trim(value)) do
          {size, ""} when size <= max_bytes -> :ok
          {size, ""} when size > max_bytes -> {:error, {:response_too_large, size, max_bytes}}
          _ -> :ok
        end
    end
  end

  defp redirect_location(headers) do
    case header_value(headers, "location") do
      nil -> {:error, :redirect_without_location}
      "" -> {:error, :redirect_without_location}
      location -> {:ok, location}
    end
  end

  defp resolve_redirect(current_url, location) do
    {:ok,
     current_url
     |> URI.parse()
     |> URI.merge(location)
     |> Map.put(:fragment, nil)
     |> URI.to_string()}
  rescue
    _ -> {:error, :invalid_redirect_location}
  end

  defp header_value(headers, requested_name) do
    Enum.find_value(List.wrap(headers), fn
      {name, value} ->
        if String.downcase(to_string(name)) == requested_name, do: to_string(value)

      _ ->
        nil
    end)
  end

  defp permanent_failure?(reason) do
    case reason do
      :untrusted_source_url -> true
      :untrusted_or_excessive_redirect -> true
      :redirect_without_location -> true
      :invalid_redirect_location -> true
      :missing_content_type -> true
      :invalid_http_body -> true
      {:unsupported_mime_type, _} -> true
      {:declared_mime_mismatch, _, _} -> true
      {:mime_signature_mismatch, _} -> true
      {:image_dimensions_unavailable, _} -> true
      {:image_dimensions_exceeded, _, _, _} -> true
      {:response_too_large, _, _} -> true
      {:unexpected_status, status} when status in 400..499 and status not in [408, 429] -> true
      _ -> false
    end
  end

  defp staged_filename(asset_id, sha256, mime_type) do
    "openstax-#{asset_id}-#{String.slice(sha256, 0, 16)}#{extension(mime_type)}"
  end

  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/gif"), do: ".gif"
  defp extension("image/webp"), do: ".webp"
  defp extension(_), do: ".png"

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  defp allowed_hosts(opts) do
    opts
    |> Keyword.get(:allowed_hosts, @default_allowed_hosts)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_host/1)
    |> Enum.uniq()
  end

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_, _), do: nil
end
