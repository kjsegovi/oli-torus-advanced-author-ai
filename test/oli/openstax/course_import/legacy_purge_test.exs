defmodule Oli.OpenStax.CourseImport.LegacyPurgeTest do
  use Oli.DataCase, async: false

  alias Oli.Authoring.Course
  alias Oli.OpenStax.CourseImport.{LegacyPurge, Run}
  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.Resources.ResourceType

  test "purges a completed mixed legacy import while preserving unrelated curriculum and shared activities" do
    allow_legacy_runs!()
    author = author_fixture()
    %{project: project, resource_revision: root} = project_fixture(author, "Legacy mixed import")

    orphan_activity = create_resource!(project, author, "Run-only activity", :activity)
    shared_activity = create_resource!(project, author, "Shared activity", :activity)

    basic_page =
      create_resource!(project, author, "Basic schema 5 page", :page,
        content: page_content([orphan_activity.resource.id, shared_activity.resource.id])
      )

    advanced_page =
      create_resource!(project, author, "Advanced schema 4 page", :page,
        content: page_content([])
      )

    unrelated_page =
      create_resource!(project, author, "Unrelated page", :page,
        content: page_content([shared_activity.resource.id])
      )

    unit =
      create_resource!(project, author, "Imported unit", :container,
        children: [basic_page.resource.id, advanced_page.resource.id]
      )

    root =
      revise!(project, root, author, children: [unit.resource.id, unrelated_page.resource.id])

    run =
      insert_legacy_run!(project, root, author, :completed, %{
        "unit_resource_ids" => [unit.resource.id],
        "lesson_resource_ids" => [basic_page.resource.id, advanced_page.resource.id],
        "assessment_resource_ids" => [],
        "root_revision_id" => root.id
      })

    job =
      %{"run_id" => run.id}
      |> Oban.Job.new(worker: "Oli.LegacyOpenStaxWorker", queue: :course_import)
      |> Repo.insert!()

    assert {:ok, summary} = LegacyPurge.purge_all(environment: :test)
    assert summary == %{projects: 1, runs: 1, resources: 3, activities: 1}
    refute Repo.get(Run, run.id)
    refute Repo.get(Oban.Job, job.id)

    assert deleted?(project, unit.resource.id)
    assert deleted?(project, basic_page.resource.id)
    assert deleted?(project, advanced_page.resource.id)
    assert deleted?(project, orphan_activity.resource.id)

    refute deleted?(project, unrelated_page.resource.id)
    refute deleted?(project, shared_activity.resource.id)

    assert AuthoringResolver.root_container(project.slug).children == [unrelated_page.resource.id]

    assert {:ok, %{projects: 0, runs: 0, resources: 0, activities: 0}} =
             LegacyPurge.purge_all(environment: :test)
  end

  test "purges a failed pre-application run without touching project curriculum" do
    allow_legacy_runs!()
    author = author_fixture()
    %{project: project, resource_revision: root} = project_fixture(author, "Failed legacy import")
    unrelated = create_resource!(project, author, "Existing page", :page)
    root = revise!(project, root, author, children: [unrelated.resource.id])
    run = insert_legacy_run!(project, root, author, :failed, %{})

    assert {:ok, %{projects: 1, runs: 1, resources: 0, activities: 0}} =
             LegacyPurge.purge_all(environment: :test)

    refute Repo.get(Run, run.id)
    refute deleted?(project, unrelated.resource.id)
    assert AuthoringResolver.root_container(project.slug).children == [unrelated.resource.id]
  end

  test "fences and purges a partially applied active run" do
    allow_legacy_runs!()
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "Partial legacy import")

    page = create_resource!(project, author, "Partially applied page", :page)

    unit =
      create_resource!(project, author, "Partially applied unit", :container,
        children: [page.resource.id]
      )

    root = revise!(project, root, author, children: [unit.resource.id])

    run =
      insert_legacy_run!(project, root, author, :applying, %{
        "unit_resource_ids" => [unit.resource.id],
        "lesson_resource_ids" => [page.resource.id],
        "root_revision_id" => root.id
      })

    assert {:ok, %{projects: 1, runs: 1, resources: 2, activities: 0}} =
             LegacyPurge.purge_all(environment: :test)

    refute Repo.get(Run, run.id)
    assert deleted?(project, unit.resource.id)
    assert deleted?(project, page.resource.id)
    assert AuthoringResolver.root_container(project.slug).children == []
  end

  test "is idempotent when the local database contains no legacy runs" do
    assert {:ok, first} = LegacyPurge.purge_all(environment: :test)
    assert first == %{projects: 0, runs: 0, resources: 0, activities: 0}
    assert {:ok, second} = LegacyPurge.purge_all(environment: :test)
    assert second == first
  end

  test "refuses to inspect or mutate production data" do
    assert {:error, :legacy_purge_forbidden} = LegacyPurge.purge_all(environment: :prod)
  end

  defp allow_legacy_runs! do
    Repo.query!(
      "ALTER TABLE course_import_runs DROP CONSTRAINT course_import_runs_schema_versions"
    )
  end

  defp insert_legacy_run!(project, root, author, status, result) do
    Repo.insert!(%Run{
      project_id: project.id,
      author_id: author.id,
      target_root_container_resource_id: root.resource_id,
      status: status,
      source_url: "https://openstax.org/details/books/legacy-test",
      book_slug: "legacy-test",
      source_schema_version: 3,
      plan_schema_version: 4,
      lesson_planning_strategy: :parallel_v1,
      result: result
    })
  end

  defp create_resource!(project, author, title, type, changes \\ []) do
    resource_type_id =
      case type do
        :activity -> ResourceType.id_for_activity()
        :container -> ResourceType.id_for_container()
        :page -> ResourceType.id_for_page()
      end

    {:ok, %{resource: resource, revision: revision}} =
      Course.create_and_attach_resource(project, %{
        title: title,
        author_id: author.id,
        resource_type_id: resource_type_id
      })

    revision = revise!(project, revision, author, changes)
    %{resource: resource, revision: revision}
  end

  defp revise!(project, revision, author, changes) do
    changes = changes |> Map.new() |> Map.put(:author_id, author.id)
    {:ok, revision} = ChangeTracker.track_revision(project.slug, revision, changes)
    revision
  end

  defp page_content(activity_ids) do
    %{
      "version" => "0.1.0",
      "model" =>
        Enum.map(activity_ids, fn activity_id ->
          %{
            "type" => "activity-reference",
            "id" => "ref-#{activity_id}",
            "activity_id" => activity_id
          }
        end)
    }
  end

  defp deleted?(project, resource_id) do
    case AuthoringResolver.from_resource_id(project.slug, resource_id) do
      %{deleted: true} -> true
      _ -> false
    end
  end
end
