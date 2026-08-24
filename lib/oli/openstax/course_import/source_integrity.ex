defmodule Oli.OpenStax.CourseImport.SourceIntegrity do
  @moduledoc "Preflights and performs one exact canonical OpenStax source refresh before planning."

  alias Oli.OpenStax.CourseImport.{RichSource, Source}

  @hash_pattern ~r/\A[0-9a-f]{64}\z/

  @spec ensure(Ecto.UUID.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure(run_id, snapshot, opts \\ [])

  def ensure(run_id, snapshot, opts) when is_binary(run_id) and is_map(snapshot) do
    with {:ok, corpus} <- RichSource.load_run_corpus(run_id) do
      case invalid_urls(corpus.sections) do
        [] ->
          :ok

        urls ->
          with {:ok, replacements} <- Source.ingest_urls(snapshot, urls, opts),
               refreshed = replace_sections(snapshot, replacements),
               {:ok, _counts} <- RichSource.persist_snapshot(run_id, refreshed),
               {:ok, _linked} <- RichSource.link_lessons(run_id),
               {:ok, refreshed_corpus} <- RichSource.load_run_corpus(run_id),
               [] <- invalid_urls(refreshed_corpus.sections) do
            :ok
          else
            invalid when is_list(invalid) -> {:error, {:source_integrity_failed, invalid}}
            {:error, _} = error -> error
          end
      end
    end
  end

  def ensure(_, _, _), do: {:error, :invalid_source_integrity_context}

  @doc false
  def invalid_urls(sections) when is_list(sections) do
    sections
    |> Enum.filter(fn section ->
      not valid_hash?(section["content_hash"]) or
        not canonical_openstax_url?(section["url"]) or
        not valid_blocks?(section["source_blocks"])
    end)
    |> Enum.map(& &1["url"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def invalid_urls(_), do: []

  defp valid_blocks?(blocks) when is_list(blocks) and blocks != [] do
    Enum.all?(blocks, fn block ->
      is_binary(block["id"]) and block["id"] != "" and
        is_binary(block["normalized_text"]) and String.trim(block["normalized_text"]) != "" and
        valid_hash?(block["content_hash"]) and is_map(block["source_locator"])
    end)
  end

  defp valid_blocks?(_), do: false

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(@hash_pattern, value)

  defp canonical_openstax_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in ["openstax.org", "www.openstax.org"] -> true
      _ -> false
    end
  end

  defp canonical_openstax_url?(_), do: false

  defp replace_sections(snapshot, replacements) do
    replacements = Map.new(replacements, &{&1["url"], &1})

    Map.update(snapshot, "chapters", [], fn chapters ->
      Enum.map(chapters, fn chapter ->
        Map.update(chapter, "sections", [], fn sections ->
          Enum.map(sections, fn section -> Map.get(replacements, section["url"], section) end)
        end)
      end)
    end)
  end
end
