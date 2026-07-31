defmodule Oli.MCP.Tools.ImportGoogleSlidesTool do
  @moduledoc """
  MCP tool to import a public Google Slides presentation into an adaptive page.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Oli.Accounts
  alias Oli.GenAI.Agent.MCPToolRegistry
  alias Oli.GoogleSlides.SlidesImport
  alias Oli.MCP.Auth.Authorization
  alias Oli.MCP.UsageTracker

  @tool_schema MCPToolRegistry.get_tool_schema("import_google_slides")

  schema do
    field :project_slug, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "project_slug", "description"])

    field :page_slug, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "page_slug", "description"])

    field :presentation_url, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "presentation_url", "description"])
  end

  @impl true
  def execute(%{project_slug: project_slug, page_slug: page_slug, presentation_url: url}, frame) do
    UsageTracker.track_tool_usage("import_google_slides", frame)

    with {:ok, %{author_id: author_id}} <-
           Authorization.validate_project_access(project_slug, frame),
         {:ok, author} <- Accounts.get_author(author_id) |> wrap_author(),
         {:ok, result, warnings} <- SlidesImport.import(project_slug, page_slug, url, author) do
      text =
        Jason.encode!(%{
          revision_slug: result.revision_slug,
          screen_count: result.screen_count,
          warnings: warnings
        })

      {:reply, Response.text(Response.tool(), text), frame}
    else
      {:error, reason, warnings} ->
        UsageTracker.track_tool_usage("import_google_slides", frame, "error")

        {:reply,
         Response.error(
           Response.tool(),
           "Import failed: #{inspect(reason)} warnings=#{inspect(warnings)}"
         ), frame}

      {:error, reason} ->
        UsageTracker.track_tool_usage("import_google_slides", frame, "error")
        {:reply, Response.error(Response.tool(), "Import failed: #{inspect(reason)}"), frame}
    end
  end

  defp wrap_author(nil), do: {:error, "author not found"}
  defp wrap_author(author), do: {:ok, author}
end
