defmodule OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLive.SlidePreviewAdapter do
  @moduledoc """
  Loads transient Google Slides thumbnails for the import review UI.

  The default implementation requests a fresh, short-lived thumbnail URL from
  Google and returns it directly to the connected LiveView. The URL is never
  persisted with the import run. Tests and deployments may replace the source
  with `:slide_preview` in `:google_slides_ai_import` configuration.
  """

  @default_source __MODULE__.GoogleSource

  def fetch(project, run, slide_id) do
    source = source()

    if Code.ensure_loaded?(source) and function_exported?(source, :fetch, 3) do
      source.fetch(project, run, slide_id)
    else
      {:error, :slide_preview_unavailable}
    end
  rescue
    _ -> {:error, :slide_preview_unavailable}
  end

  defp source do
    case Application.get_env(:oli, :google_slides_ai_import, []) do
      config when is_list(config) ->
        Keyword.get(config, :slide_preview, @default_source)

      %{} = config ->
        Map.get(config, :slide_preview) ||
          Map.get(config, "slide_preview") ||
          @default_source

      _ ->
        @default_source
    end
  end

  defmodule GoogleSource do
    @moduledoc false

    alias Oli.GoogleDocs.SlidesClient
    alias Oli.GoogleSlides.Credentials

    def fetch(project, run, slide_id) do
      project_id = value(project, :id)
      presentation_id = value(run, :presentation_id)

      with true <- is_integer(project_id),
           true <- is_binary(presentation_id) and presentation_id != "",
           true <- source_slide?(run, slide_id),
           {:ok, credentials} <- Credentials.get_credentials_map(project_id),
           {:ok, access_token} <- SlidesClient.fetch_access_token(credentials),
           {:ok, thumbnail} <-
             SlidesClient.fetch_page_thumbnail(
               presentation_id,
               slide_id,
               access_token,
               "LARGE"
             ) do
        {:ok, thumbnail}
      else
        false -> {:error, :invalid_slide_preview}
        {:error, _reason} = error -> error
        _ -> {:error, :slide_preview_unavailable}
      end
    end

    defp source_slide?(run, slide_id) when is_binary(slide_id) and slide_id != "" do
      run
      |> value(:source_snapshot, %{})
      |> value(:slides, [])
      |> Enum.any?(&(value(&1, :objectId) == slide_id))
    end

    defp source_slide?(_run, _slide_id), do: false

    defp value(map, key, default \\ nil)

    defp value(map, key, default) when is_map(map),
      do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

    defp value(_map, _key, default), do: default
  end
end
