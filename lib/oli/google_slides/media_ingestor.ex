defmodule Oli.GoogleSlides.MediaIngestor do
  @moduledoc """
  Uploads Google Slides image bytes into the project media library.
  """

  alias Oli.Authoring.MediaLibrary
  alias Oli.GoogleDocs.SlidesClient
  alias Oli.GoogleSlides.PresentationParser.ImageRef
  alias Oli.GoogleSlides.Warnings

  @max_image_count 100
  @max_image_bytes 20 * 1024 * 1024
  @max_total_image_bytes 100 * 1024 * 1024
  @supported_image_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml)

  @spec ingest_images([ImageRef.t()], String.t(), String.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}, [map()]} | {:error, term()}
  def ingest_images(images, project_slug, access_token, opts \\ []) do
    media_library = Keyword.get(opts, :media_library, MediaLibrary)
    slides_client = Keyword.get(opts, :slides_client, SlidesClient)

    limits = %{
      image_count: Keyword.get(opts, :max_image_count, @max_image_count),
      image_bytes: Keyword.get(opts, :max_image_bytes, @max_image_bytes),
      total_bytes: Keyword.get(opts, :max_total_image_bytes, @max_total_image_bytes)
    }

    with :ok <- validate_image_count(images, limits),
         {:ok, prepared_images} <-
           prepare_images(images, access_token, slides_client, limits) do
      {urls, warnings} =
        Enum.reduce(prepared_images, {%{}, []}, fn image, {acc, warnings} ->
          case upload_image(image, project_slug, media_library) do
            {:ok, object_id, url} ->
              {Map.put(acc, object_id, url), warnings}

            {:error, reason} ->
              {acc,
               warnings ++
                 [
                   Warnings.build(:media_upload_failed, %{
                     slide_index: image.slide_index,
                     reason: inspect(reason)
                   })
                 ]}
          end
        end)

      {:ok, urls, warnings}
    end
  end

  defp validate_image_count(images, %{image_count: max_count})
       when is_integer(max_count) and max_count > 0 do
    if length(images) <= max_count do
      :ok
    else
      {:error, {:source_media_limit_exceeded, :image_count, max_count}}
    end
  end

  defp prepare_images(images, access_token, slides_client, limits) do
    Enum.reduce_while(images, {:ok, [], 0}, fn image, {:ok, prepared, total_bytes} ->
      case prepare_image(image, access_token, slides_client, limits.image_bytes) do
        {:ok, item} ->
          updated_total = total_bytes + byte_size(item.bytes)

          if updated_total <= limits.total_bytes do
            {:cont, {:ok, [item | prepared], updated_total}}
          else
            {:halt, {:error, {:source_media_limit_exceeded, :total_bytes, limits.total_bytes}}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared, _total_bytes} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_image(
         %{inline_bytes: bytes} = image,
         _access_token,
         _slides_client,
         max_image_bytes
       )
       when is_binary(bytes) and bytes != "" do
    content_type = image.inline_content_type || "image/png"

    with :ok <- validate_prepared_image(bytes, content_type, max_image_bytes) do
      {:ok, prepared_image(image, bytes, content_type)}
    end
  end

  defp prepare_image(image, access_token, slides_client, max_image_bytes) do
    with {:ok, bytes, content_type} <-
           slides_client.fetch_image_bytes(image.content_url, access_token),
         :ok <- validate_prepared_image(bytes, content_type, max_image_bytes) do
      {:ok, prepared_image(image, bytes, content_type)}
    end
  end

  defp validate_prepared_image(bytes, content_type, max_image_bytes)
       when is_binary(bytes) and is_integer(max_image_bytes) and max_image_bytes > 0 do
    cond do
      byte_size(bytes) > max_image_bytes ->
        {:error, :source_image_too_large}

      content_type not in @supported_image_types ->
        {:error, :unsupported_source_image_type}

      true ->
        :ok
    end
  end

  defp prepared_image(image, bytes, content_type) do
    %{
      object_id: image.object_id,
      slide_index: Map.get(image, :slide_index, 0),
      filename: "slides-#{image.object_id}#{image_extension(content_type)}",
      bytes: bytes
    }
  end

  defp upload_image(image, project_slug, media_library) do
    case media_library.add(project_slug, image.filename, image.bytes) do
      {:ok, media_item} ->
        {:ok, image.object_id, media_item.url}

      {:duplicate, media_item} ->
        {:ok, image.object_id, media_item.url}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Kept private and centralized so inline SVG fallbacks and remote raster
  # images receive deterministic, safe extensions.
  defp image_extension("image/svg+xml"), do: ".svg"

  defp image_extension(content_type) when is_binary(content_type) do
    case String.downcase(content_type) do
      "image/jpeg" -> ".jpg"
      "image/jpg" -> ".jpg"
      "image/gif" -> ".gif"
      "image/webp" -> ".webp"
      "image/svg+xml" -> ".svg"
      _ -> ".png"
    end
  end

  defp image_extension(_), do: ".png"
end
