defmodule Oli.OpenStax.CourseImport.Enrichment.Origin do
  @moduledoc false

  @doc "Returns true only for a normalized loopback host allowed to use HTTP in development."
  @spec local_loopback_host?(term()) :: boolean()
  def local_loopback_host?(host) when is_binary(host) do
    normalized =
      host
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    normalized in ["localhost", "127.0.0.1", "::1"] or localhost_subdomain?(normalized)
  end

  def local_loopback_host?(_host), do: false

  defp localhost_subdomain?(host) do
    suffix = ".localhost"
    byte_size(host) > byte_size(suffix) and String.ends_with?(host, suffix)
  end
end
