defmodule Oli.OpenStax.CourseImport.ExternalMediaResolver do
  @moduledoc """
  Resolves supported linked media into an accessible native-media description.

  The importer never treats a provider page URL as a playable media file. A
  provider adapter (or an explicit pre-resolved entry) must supply the playable
  URL plus captions or a transcript. Missing accessibility data is returned as
  an author-attention finding rather than silently rendering a printed URL.
  """

  @supported_hosts MapSet.new([
                     "pbs.org",
                     "www.pbs.org",
                     "pbslearningmedia.org",
                     "www.pbslearningmedia.org",
                     "youtube.com",
                     "www.youtube.com",
                     "youtu.be"
                   ])

  @type resolution :: %{
          required(:kind) => :video,
          required(:source_url) => String.t(),
          required(:src) => String.t(),
          required(:title) => String.t(),
          required(:alt) => String.t(),
          required(:subtitles) => [map()],
          required(:transcript) => String.t() | nil,
          required(:fallback) => map()
        }

  @spec resolve(String.t(), map(), keyword()) ::
          {:ok, resolution()} | {:attention, map()} | :unsupported
  def resolve(url, metadata, opts) when is_binary(url) and is_map(metadata) and is_list(opts) do
    with {:ok, source_url} <- supported_url(url),
         {:ok, resolved} <- resolve_metadata(source_url, metadata, opts),
         {:ok, normalized} <- normalize(source_url, resolved) do
      {:ok, normalized}
    else
      :unsupported -> :unsupported
      {:attention, _finding} = attention -> attention
    end
  end

  def resolve(_url, _metadata, _opts), do: :unsupported

  @spec supported?(term()) :: boolean()
  def supported?(url), do: match?({:ok, _}, supported_url(url))

  defp supported_url(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri when is_binary(host) ->
        if MapSet.member?(@supported_hosts, String.downcase(host)),
          do: {:ok, URI.to_string(uri)},
          else: :unsupported

      _uri ->
        :unsupported
    end
  end

  defp resolve_metadata(source_url, metadata, opts) do
    supplied =
      opts
      |> Keyword.get(:external_media, %{})
      |> lookup(source_url)
      |> stringify_keys()
      |> Map.merge(stringify_keys(metadata), fn _key, supplied_value, source_value ->
        present(source_value) || supplied_value
      end)

    case Keyword.get(opts, :external_media_resolver_fun) do
      fun when is_function(fun, 2) ->
        case fun.(source_url, supplied) do
          {:ok, value} when is_map(value) ->
            {:ok, Map.merge(supplied, stringify_keys(value))}

          {:attention, finding} when is_map(finding) ->
            {:attention, finding}

          {:error, reason} ->
            {:attention, finding(source_url, "external_media_resolution_failed", reason)}

          other ->
            {:attention, finding(source_url, "invalid_external_media_resolution", other)}
        end

      _fun ->
        {:ok, supplied}
    end
  end

  defp normalize(source_url, metadata) do
    src = first_present([metadata["src"], metadata["playable_url"], metadata["content_url"]])
    title = first_present([metadata["title"], metadata["label"]])
    alt = first_present([metadata["alt"], metadata["description"], title])
    transcript = first_present([metadata["transcript"], metadata["transcript_text"]])
    subtitles = normalize_subtitles(metadata["subtitles"] || metadata["captions"])

    cond do
      not safe_media_url?(src) ->
        {:attention,
         finding(
           source_url,
           "external_media_playable_url_required",
           "Resolve the provider page to a playable HTTPS or project-media URL."
         )}

      is_nil(title) ->
        {:attention,
         finding(source_url, "external_media_title_required", "Provide a concise media title.")}

      subtitles == [] and is_nil(transcript) ->
        {:attention,
         finding(
           source_url,
           "external_media_accessibility_required",
           "Provide captions or a transcript before importing this media."
         )}

      true ->
        {:ok,
         %{
           kind: :video,
           source_url: source_url,
           src: src,
           title: title,
           alt: alt,
           subtitles: subtitles,
           transcript: transcript,
           fallback: %{
             "label" => "Open #{title} on the provider site",
             "url" => source_url,
             "transcript" => transcript
           }
         }}
    end
  end

  defp normalize_subtitles(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      value = stringify_keys(value)
      src = first_present([value["src"], value["url"]])

      if safe_media_url?(src) do
        [
          %{
            "default" => value["default"] == true,
            "label" => first_present([value["label"], "English"]),
            "language_code" => first_present([value["language_code"], value["language"], "en"]),
            "src" => src
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1["src"])
  end

  defp lookup(values, key) when is_map(values) do
    Map.get(values, key) ||
      Enum.find_value(values, %{}, fn
        {candidate, value} when is_atom(candidate) ->
          if Atom.to_string(candidate) == key, do: value

        _entry ->
          nil
      end)
  end

  defp lookup(_values, _key), do: %{}

  defp safe_media_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https", "staged"] and is_binary(host) ->
        true

      %URI{scheme: nil, host: nil, path: "/" <> _rest} ->
        true

      _uri ->
        false
    end
  end

  defp safe_media_url?(_url), do: false

  defp finding(source_url, code, detail) do
    %{
      "code" => code,
      "path" => "$.external_media[#{source_url}]",
      "severity" => "hard_blocker",
      "owner" => "author",
      "repair" => inspect(detail),
      "source_url" => source_url
    }
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp stringify_keys(_value), do: %{}

  defp first_present(values), do: Enum.find_value(values, &present/1)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp present(value) when is_list(value) and value != [], do: value
  defp present(value) when is_map(value) and map_size(value) > 0, do: value
  defp present(_value), do: nil
end
