defmodule OliWeb.Components.ScopedFeatureToggleComponentTest do
  use OliWeb.ConnCase, async: true

  import LiveComponentTests
  import Phoenix.LiveViewTest
  import Oli.Factory

  alias OliWeb.Components.ScopedFeatureToggleComponent
  alias Oli.ScopedFeatureFlags

  describe "scoped feature toggle component" do
    setup do
      author = insert(:author)
      project = insert(:project)
      section = insert(:section)

      %{author: author, project: project, section: section}
    end

    test "renders empty state when no features match scope", %{
      conn: conn,
      author: author,
      project: project
    } do
      attrs = %{
        id: "toggle_component",
        scopes: [:nonexistent],
        source_id: project.id,
        source_type: :project,
        source: project,
        current_author: author
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      assert has_element?(lcd, "div.scoped-feature-toggle-component")
      assert has_element?(lcd, "div", "No scoped features available")
    end

    test "lists authoring features for a project", %{conn: conn, author: author, project: project} do
      attrs = %{
        id: "toggle_component",
        scopes: [:authoring, :both],
        source_id: project.id,
        source_type: :project,
        source: project,
        current_author: author
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      assert has_element?(lcd, "h3", "Feature Flags")
      assert has_element?(lcd, "h4", "Mcp authoring")
      refute has_element?(lcd, "h4", "Adaptive duplication")
      assert has_element?(lcd, "span", "Authoring")
      assert has_element?(lcd, "span", "Disabled")
    end

    test "enables editing when checkbox toggled", %{conn: conn, author: author, project: project} do
      attrs = %{
        id: "toggle_component",
        scopes: [:authoring],
        source_id: project.id,
        source_type: :project,
        source: project,
        current_author: author
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      lcd
      |> element("input[type='checkbox']")
      |> render_click()

      assert has_element?(lcd, "button", "Enable")
    end

    test "enables a feature when toggled", %{conn: conn, author: author, project: project} do
      attrs = %{
        id: "toggle_component",
        scopes: [:authoring],
        source_id: project.id,
        source_type: :project,
        source: project,
        current_author: author,
        edits_enabled: true
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      lcd
      |> element("button[phx-value-feature='mcp_authoring'][phx-value-enabled='true']")
      |> render_click()

      assert ScopedFeatureFlags.enabled?(:mcp_authoring, project)
    end

    test "renders a forced local feature as enabled without a persisted flag or toggle", %{
      conn: conn,
      author: author,
      project: project
    } do
      attrs = %{
        id: "toggle_component",
        scopes: [:authoring, :both],
        source_id: project.id,
        source_type: :project,
        source: project,
        current_author: author,
        edits_enabled: true,
        forced_enabled_features: [:openstax_course_import]
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      assert has_element?(lcd, "h4", "Openstax course import")
      assert has_element?(lcd, "span", "Enabled for local testing")
      assert has_element?(lcd, "span", "Local development default")

      refute has_element?(
               lcd,
               "button[phx-value-feature='openstax_course_import']"
             )

      refute ScopedFeatureFlags.enabled?(:openstax_course_import, project)
      assert ScopedFeatureFlags.list_project_features(project) == []

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          edits_enabled: true,
          forced_enabled_features: [:openstax_course_import],
          source: project,
          source_type: :project,
          current_author: author
        }
      }

      assert {:noreply, ^socket} =
               ScopedFeatureToggleComponent.handle_event(
                 "toggle_feature",
                 %{"feature" => "openstax_course_import", "enabled" => "false"},
                 socket
               )

      refute ScopedFeatureFlags.enabled?(:openstax_course_import, project)
      assert ScopedFeatureFlags.list_project_features(project) == []
    end

    test "renders delivery features for a section", %{
      conn: conn,
      author: author,
      section: section
    } do
      attrs = %{
        id: "toggle_component",
        scopes: [:delivery, :both],
        source_id: section.id,
        source_type: :section,
        source: section,
        current_author: author
      }

      {:ok, lcd, _html} = live_component_isolated(conn, ScopedFeatureToggleComponent, attrs)

      assert has_element?(lcd, "div.scoped-feature-toggle-component")
    end
  end
end
