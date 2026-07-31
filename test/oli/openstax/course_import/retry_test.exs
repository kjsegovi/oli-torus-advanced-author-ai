defmodule Oli.OpenStax.CourseImport.RetryTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.Authoring.Course
  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.Run
  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax retry project")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/retry-book"
      )

    {:ok, author: author, project: project, root: root, run: run}
  end

  test "a retry job conflict leaves the failed run failed", %{author: author, run: run} do
    assert {:ok, %Run{status: :failed}} =
             CourseImport.mark_failed(run.id, :preflight, :timeout)

    # The original unique preflight job is still available. Treating Oban's
    # conflict result as a successful retry would reactivate the run without a
    # new worker to advance it.
    assert {:error, :retry_job_already_active} =
             CourseImport.retry_run(run.id, author)

    assert {:ok, %Run{status: :failed}} = CourseImport.fetch_run(run.id)
  end

  test "an oversized source is an actionable non-recoverable failure", %{
    author: author,
    run: run
  } do
    assert {:ok, %Run{status: :failed} = failed} =
             CourseImport.mark_failed(
               run.id,
               :preflight,
               {:source_scope_too_large, 240, 120}
             )

    refute failed.error["recoverable"]
    assert failed.error["message"] =~ "240 course sections"
    assert failed.error["message"] =~ "limit of 120"
    assert {:error, :not_recoverable} = CourseImport.retry_run(run.id, author)
  end

  test "retry revalidates the locked current project root before reactivating", %{
    author: author,
    project: project,
    run: run
  } do
    assert {:ok, %Run{status: :failed}} =
             CourseImport.mark_failed(run.id, :preflight, :timeout)

    {:ok, %{resource: page, revision: page_revision}} =
      Course.create_and_attach_resource(project, %{
        title: "Authored after import failure",
        author_id: author.id,
        resource_type_id: Oli.Resources.ResourceType.id_for_page()
      })

    assert {:ok, _} = ChangeTracker.track_revision(project.slug, page_revision)

    current_root = AuthoringResolver.root_container(project.slug)

    assert {:ok, _} =
             ChangeTracker.track_revision(project.slug, current_root, %{
               children: [page.id],
               author_id: author.id
             })

    assert {:error, :project_root_not_empty} =
             CourseImport.retry_run(run.id, author)

    assert {:ok, %Run{status: :failed}} = CourseImport.fetch_run(run.id)
    assert AuthoringResolver.root_container(project.slug).children == [page.id]
  end
end
