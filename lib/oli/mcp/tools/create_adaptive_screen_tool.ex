defmodule Oli.MCP.Tools.CreateAdaptiveScreenTool do
  @moduledoc """
  MCP tool for creating adaptive screens (`oli_adaptive` activities).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Oli.Accounts
  alias Oli.Authoring.Editing.ActivityEditor
  alias Oli.GenAI.Agent.MCPToolRegistry
  alias Oli.MCP.Auth.Authorization
  alias Oli.MCP.UsageTracker

  @tool_schema MCPToolRegistry.get_tool_schema("create_adaptive_screen")

  schema do
    field :project_slug, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "project_slug", "description"])

    field :title, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "title", "description"])

    field :screen_json, :string,
      required: true,
      description: get_in(@tool_schema, ["properties", "screen_json", "description"])
  end

  @impl true
  def execute(%{project_slug: project_slug, title: title, screen_json: screen_json}, frame) do
    UsageTracker.track_tool_usage("create_adaptive_screen", frame)

    with {:ok, %{author_id: author_id}} <-
           Authorization.validate_project_access(project_slug, frame),
         {:ok, author} <- fetch_author(author_id),
         {:ok, content} <- Jason.decode(screen_json),
         {:ok, {revision, _content}} <-
           ActivityEditor.create(
             project_slug,
             "oli_adaptive",
             author,
             content,
             %{},
             "embedded",
             title
           ) do
      text =
        Jason.encode!(%{
          activity_slug: revision.slug,
          resource_id: revision.resource_id,
          title: revision.title
        })

      {:reply, Response.text(Response.tool(), text), frame}
    else
      {:error, reason} ->
        UsageTracker.track_tool_usage("create_adaptive_screen", frame, "error")

        {:reply, Response.error(Response.tool(), "Screen creation failed: #{inspect(reason)}"),
         frame}
    end
  end

  defp fetch_author(nil), do: {:error, "author not found"}
  defp fetch_author(author_id), do: Accounts.get_author(author_id) |> wrap_author()
  defp wrap_author(nil), do: {:error, "author not found"}
  defp wrap_author(author), do: {:ok, author}
end
