defmodule Oli.OpenStax.CourseImport.RunHealthWorkerTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  import Ecto.Query

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Lesson, Run, Unit}
  alias Oli.OpenStax.CourseImport.Worker.RunHealthWorker
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax health-check project")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/health-check-book"
      )

    {:ok, run: run, author: author, project: project}
  end

  test "leaves a run alone while its background job is active", %{run: run} do
    assert :ok = perform_job(RunHealthWorker, %{})
    assert {:ok, %Run{status: :preflighting}} = CourseImport.fetch_run(run.id)
  end

  test "marks an execution-stage run failed when no resumable job remains", %{run: run} do
    Repo.update_all(
      from(job in Oban.Job,
        where: fragment("?->>'run_id' = ?", job.args, ^run.id)
      ),
      set: [state: "discarded"]
    )

    assert :ok = perform_job(RunHealthWorker, %{})
    assert {:ok, failed} = CourseImport.fetch_run(run.id)
    assert failed.status == :failed
    assert failed.error["phase"] == "preflight"
    assert failed.error["reason"] =~ "background_job_missing"
    assert failed.error["recoverable"]
  end

  test "ignores unfinished legacy rows and reports them without mutation", %{
    author: author,
    project: project
  } do
    now = DateTime.utc_now()
    legacy_id = Ecto.UUID.generate()

    {1, _} =
      Repo.insert_all(Run, [
        %{
          id: legacy_id,
          project_id: project.id,
          author_id: author.id,
          status: :preflighting,
          source_url: "https://openstax.org/details/books/legacy-preserved",
          book_slug: "legacy-preserved",
          source_schema_version: 2,
          plan_schema_version: 4,
          lesson_planning_strategy: :parallel_v1,
          lesson_planning_generation: 0,
          lesson_planning_parallelism: 1,
          scope_manifest: %{},
          progress: %{"legacy" => true},
          latest_plan_version: 0,
          failure_count: 0,
          inserted_at: now,
          updated_at: now
        }
      ])

    before = Repo.get!(Run, legacy_id)
    assert CourseImport.unfinished_legacy_run?(project, author)
    assert :ok = perform_job(RunHealthWorker, %{})
    after_health_check = Repo.get!(Run, legacy_id)

    assert Map.take(after_health_check, [
             :status,
             :source_schema_version,
             :plan_schema_version,
             :progress,
             :updated_at
           ]) ==
             Map.take(before, [
               :status,
               :source_schema_version,
               :plan_schema_version,
               :progress,
               :updated_at
             ])
  end

  test "reviews the oldest unfinished parallel runs across the batch boundary", %{run: run} do
    review_work =
      Enum.map(1..26, fn index ->
        review_run =
          %Run{}
          |> Run.create_changeset(%{
            project_id: run.project_id,
            author_id: run.author_id,
            status: :awaiting_lesson_approval,
            source_url: "https://openstax.org/details/books/health-review-#{index}",
            book_slug: "health-review-#{index}",
            lesson_planning_strategy: :parallel_v1,
            lesson_planning_generation: 1,
            lesson_planning_parallelism: 1
          })
          |> Repo.insert!()

        unit =
          %Unit{}
          |> Unit.changeset(%{
            run_id: review_run.id,
            unit_name: "Unit #{index}",
            order: 1,
            status: "ready_for_review"
          })
          |> Repo.insert!()

        lesson =
          %Lesson{}
          |> Lesson.changeset(%{
            run_id: review_run.id,
            unit_id: unit.id,
            order: 1,
            title: "Lesson #{index}",
            status: "ready_for_review",
            planning_state: "pending",
            planning_operation: "regenerate",
            planning_generation: 1,
            planning_request_id: Ecto.UUID.generate(),
            planning_position: 1,
            planning_base_plan_version: 1
          })
          |> Repo.insert!()

        {review_run, lesson}
      end)

    {oldest_run, oldest_lesson} =
      Enum.max_by(review_work, fn {review_run, _lesson} -> review_run.id end)

    now = DateTime.utc_now()

    Repo.update_all(
      from(review_run in Run, where: review_run.id in ^Enum.map(review_work, &elem(&1, 0).id)),
      set: [updated_at: now]
    )

    Repo.update_all(
      from(review_run in Run, where: review_run.id == ^oldest_run.id),
      set: [updated_at: DateTime.add(now, -3_600, :second)]
    )

    assert :ok = perform_job(RunHealthWorker, %{})

    recovered = Repo.reload!(oldest_lesson)
    assert recovered.planning_state == "queued"
    assert is_integer(recovered.planning_oban_job_id)
  end
end
