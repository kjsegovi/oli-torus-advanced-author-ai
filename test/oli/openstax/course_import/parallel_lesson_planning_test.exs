defmodule Oli.OpenStax.CourseImport.ParallelLessonPlanningTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    Lesson,
    LessonPlan,
    LessonSource,
    Notification,
    Outbox,
    Planner,
    Run,
    SourceBlock,
    SourceSection,
    Unit
  }

  alias Oli.OpenStax.CourseImport.Worker.{
    LessonPlanWorker,
    LessonPlanningCoordinatorWorker,
    RunHealthWorker
  }

  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "Parallel OpenStax planning")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/parallel-planning"
      )

    run = advance_to_outline_review(run)
    lessons = insert_lessons(run, 5)

    {:ok, author: author, run: run, lessons: lessons}
  end

  test "the coordinator fills only the configured window and is idempotent", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    coordinator_args = %{"run_id" => run.id, "generation" => generation}

    assert_enqueued(worker: LessonPlanningCoordinatorWorker, args: coordinator_args)
    assert :ok = perform_job(LessonPlanningCoordinatorWorker, coordinator_args)

    persisted = ordered_lessons(run.id)

    assert Enum.map(persisted, & &1.planning_position) == [1, 2, 3, 4, 5]
    assert Enum.map(persisted, & &1.planning_generation) == List.duplicate(generation, 5)
    assert Enum.count(persisted, &(&1.planning_state == "queued")) == 3
    assert Enum.count(persisted, &(&1.planning_state == "pending")) == 2
    assert length(child_jobs(run.id, generation)) == 3

    assert :ok = perform_job(LessonPlanningCoordinatorWorker, coordinator_args)
    assert length(child_jobs(run.id, generation)) == 3
  end

  test "a child enqueue failure rolls back the entire coordinator window", %{
    author: author,
    run: run
  } do
    config_key = :openstax_course_import_lesson_job_inserter
    previous_inserter = Application.get_env(:oli, config_key)
    counter_key = {__MODULE__, make_ref()}

    on_exit(fn -> restore_application_env(config_key, previous_inserter) end)

    Application.put_env(:oli, config_key, fn changeset ->
      insertion = Process.get(counter_key, 0) + 1
      Process.put(counter_key, insertion)

      if insertion == 2,
        do: {:error, :forced_enqueue_failure},
        else: Oban.insert(changeset)
    end)

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert {:error, {:lesson_job_enqueue_failed, failed_lesson_id, :forced_enqueue_failure}} =
             CourseImport.initialize_parallel_lesson_planning(run.id, generation)

    assert is_binary(failed_lesson_id)
    assert child_jobs(run.id, generation) == []

    assert Enum.all?(ordered_lessons(run.id), fn lesson ->
             lesson.planning_state == "pending" and lesson.planning_generation == 0 and
               is_nil(lesson.planning_oban_job_id)
           end)
  end

  test "cancellation fences a queued child before it can generate a plan", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)

    coordinator_args = %{
      "run_id" => run.id,
      "generation" => planning.lesson_planning_generation
    }

    assert :ok = perform_job(LessonPlanningCoordinatorWorker, coordinator_args)
    [queued_job | _] = child_jobs(run.id, planning.lesson_planning_generation)

    assert {:ok, cancelled} = CourseImport.cancel_run(run.id, author)
    assert cancelled.lesson_planning_generation > planning.lesson_planning_generation

    assert {:discard, :stale_lesson_planning_job} =
             perform_job(LessonPlanWorker, queued_job.args)

    assert Repo.aggregate(
             from(plan in LessonPlan,
               join: lesson in Lesson,
               on: lesson.id == plan.lesson_id,
               where: lesson.run_id == ^run.id
             ),
             :count
           ) == 0

    assert Enum.all?(ordered_lessons(run.id), &(&1.planning_state == "cancelled"))
  end

  test "a terminal lesson failure refills the window and the run fails only after siblings finish",
       %{
         author: author,
         run: run
       } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    assert {:ok, _lesson, still_planning} = fail_next_queued_lesson(run.id, generation)
    assert still_planning.status == :planning_lessons

    after_first_failure = ordered_lessons(run.id)
    assert Enum.count(after_first_failure, &(&1.planning_state == "failed")) == 1
    assert Enum.count(after_first_failure, &(&1.planning_state == "queued")) == 3
    assert Enum.count(after_first_failure, &(&1.planning_state == "pending")) == 1

    Enum.each(1..4, fn _ ->
      assert {:ok, _lesson, _run} = fail_next_queued_lesson(run.id, generation)
    end)

    assert {:ok, failed_run} = CourseImport.fetch_run(run.id)
    assert failed_run.status == :failed
    assert failed_run.error["phase"] == "lesson_planning"
    assert failed_run.error["failed_count"] == 5
    assert failed_run.error["recoverable"]
    assert Enum.all?(ordered_lessons(run.id), &(&1.planning_state == "failed"))

    assert :ok = Outbox.persist(failed_run)
    assert :ok = Outbox.persist(failed_run)

    dedupe_key = "#{run.id}:import_failed:lesson_planning:#{generation}"

    assert Repo.aggregate(
             from(notification in Notification,
               where:
                 notification.run_id == ^run.id and notification.event == "import_failed" and
                   notification.dedupe_key == ^dedupe_key
             ),
             :count
           ) == 1

    next_generation = %{failed_run | lesson_planning_generation: generation + 1}
    assert :ok = Outbox.persist(next_generation)

    assert Repo.aggregate(
             from(notification in Notification,
               where: notification.run_id == ^run.id and notification.event == "import_failed"
             ),
             :count
           ) == 2
  end

  test "whole-run retry preserves successful plans and queues only failed lessons", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    assert {:ok, first, _run} = complete_position(run.id, generation, 1)
    assert {:ok, second, _run} = complete_position(run.id, generation, 2)

    successful_versions = %{
      first.id => first.last_plan_version,
      second.id => second.last_plan_version
    }

    Enum.each(1..3, fn _ ->
      assert {:ok, _lesson, _run} = fail_next_queued_lesson(run.id, generation)
    end)

    assert {:ok, failed_run} = CourseImport.fetch_run(run.id)
    assert failed_run.status == :failed

    assert {:ok, retried} = CourseImport.retry_run(run.id, author)
    assert retried.status == :planning_lessons
    assert retried.lesson_planning_generation == generation + 1

    retry_generation = retried.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => retry_generation
             })

    lessons = ordered_lessons(run.id)
    successful_ids = Map.keys(successful_versions)
    successful = Enum.filter(lessons, &(&1.id in successful_ids))
    retrying = Enum.reject(lessons, &(&1.id in successful_ids))

    assert Enum.all?(successful, fn lesson ->
             lesson.planning_state == "completed" and
               lesson.last_plan_version == successful_versions[lesson.id]
           end)

    assert Enum.all?(retrying, &(&1.planning_state == "queued"))
    assert length(child_jobs(run.id, retry_generation)) == 3
  end

  test "health recovery detects one orphan while sibling jobs remain active", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    [orphaned_job | active_siblings] = child_jobs(run.id, generation)
    assert length(active_siblings) == 2

    orphaned_job
    |> Ecto.Changeset.change(state: "discarded")
    |> Repo.update!()

    assert :ok = perform_job(RunHealthWorker, %{})

    assert {:ok, recovered_run} = CourseImport.fetch_run(run.id)
    assert recovered_run.status == :planning_lessons

    lessons = ordered_lessons(run.id)
    assert Enum.count(lessons, &(&1.planning_state == "failed")) == 1
    assert Enum.count(lessons, &(&1.planning_state == "queued")) == 3
    assert Enum.count(lessons, &(&1.planning_state == "pending")) == 1
  end

  test "health recovery emits sanitized telemetry for every terminal job state", %{
    author: author,
    run: run
  } do
    handler_id = attach_lesson_failure_telemetry()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    planning
    |> Run.update_changeset(%{lesson_planning_parallelism: 4})
    |> Repo.update!()

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    [discarded_job, cancelled_job, exhausted_job, missing_job] =
      child_jobs(run.id, generation)

    discarded_job
    |> Ecto.Changeset.change(state: "discarded", attempt: 2)
    |> Repo.update!()

    cancelled_job
    |> Ecto.Changeset.change(state: "cancelled", attempt: 1)
    |> Repo.update!()

    exhausted_job
    |> Ecto.Changeset.change(state: "completed", attempt: 4)
    |> Repo.update!()

    missing_lesson = Repo.get!(Lesson, missing_job.args["lesson_id"])

    missing_lesson
    |> Lesson.changeset(%{planning_attempts: 4})
    |> Repo.update!()

    Repo.delete!(missing_job)

    assert :ok = perform_job(RunHealthWorker, %{})

    events =
      Enum.map(1..4, fn _index ->
        assert_receive {:lesson_failure_telemetry, measurements, metadata}, 1_000
        {measurements, metadata}
      end)

    assert events
           |> Enum.map(fn {_measurements, metadata} -> metadata.reason end)
           |> MapSet.new() ==
             MapSet.new([
               :background_job_discarded,
               :background_job_cancelled,
               :background_job_exhausted,
               :background_job_missing_exhausted
             ])

    assert Enum.all?(events, fn {measurements, metadata} ->
             Enum.sort(Map.keys(measurements)) == [:attempt, :count] and
               Enum.sort(Map.keys(metadata)) == [:lesson_id, :reason, :run_id] and
               metadata.run_id == run.id and measurements.count == 1
           end)

    refute_receive {:lesson_failure_telemetry, _measurements, _metadata}, 50
  end

  test "health recovery ignores a healthy serial run awaiting lesson approval", %{run: run} do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    review
    |> Run.update_changeset(%{lesson_planning_strategy: :serial_v1})
    |> Repo.update!()

    assert :ok = perform_job(RunHealthWorker, %{})

    assert {:ok, persisted} = CourseImport.fetch_run(run.id)
    assert persisted.status == :awaiting_lesson_approval
    assert persisted.lesson_planning_strategy == :serial_v1
    assert persisted.error == nil
  end

  test "stale generations and request ids cannot claim or persist", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    job = job_for_position!(run.id, generation, 1)
    lesson = Repo.get!(Lesson, job.args["lesson_id"])
    result = generated_result(lesson)

    stale_generation = Map.put(job.args, "generation", generation + 1)

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.claim_lesson_plan_job(stale_generation, 1, job.id)

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.complete_lesson_plan_job(stale_generation, result)

    stale_request = Map.put(job.args, "request_id", Ecto.UUID.generate())

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.claim_lesson_plan_job(stale_request, 1, job.id)

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.complete_lesson_plan_job(stale_request, result)

    assert lesson_plan_count(run.id) == 0
    assert Repo.reload!(lesson).planning_state == "queued"
  end

  test "source schema v2 fails permanently before calling the planner when normalized evidence is missing",
       %{
         author: author,
         run: run
       } do
    previous_planner = Application.get_env(:oli, :openstax_course_import_lesson_planner)
    test_pid = self()

    on_exit(fn -> restore_lesson_planner(previous_planner) end)

    Application.put_env(
      :oli,
      :openstax_course_import_lesson_planner,
      fn _source, _position, _opts ->
        send(test_pid, :lesson_planner_called)
        {:error, :should_not_run}
      end
    )

    assert run.source_schema_version >= 2
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    job = job_for_position!(run.id, generation, 1)

    assert {:discard, :missing_lesson_source} =
             LessonPlanWorker.perform(%{job | attempt: 1, max_attempts: 4, state: "executing"})

    refute_received :lesson_planner_called
    assert Repo.get!(Lesson, job.args["lesson_id"]).planning_state == "failed"
    assert lesson_plan_count(run.id) == 0
  end

  test "source schema v1 preserves legacy excerpt-only lesson planning", %{
    author: author,
    run: run
  } do
    run =
      run
      |> Run.update_changeset(%{source_schema_version: 1})
      |> Repo.update!()

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    job = job_for_position!(run.id, generation, 1)

    assert {:ok, claim} = CourseImport.claim_lesson_plan_job(job.args, 1, job.id)
    assert claim.source["source_blocks"] == []
    assert claim.source["source_excerpt"] =~ "Evidence and observations"
  end

  test "transient provider errors retry while authentication errors fail permanently", %{
    author: author,
    run: run
  } do
    previous_planner =
      Application.get_env(:oli, :openstax_course_import_lesson_planner)

    on_exit(fn -> restore_lesson_planner(previous_planner) end)

    run.id
    |> ordered_lessons()
    |> Enum.take(2)
    |> Enum.each(&insert_normalized_source!(run, &1, &1.order))

    Application.put_env(
      :oli,
      :openstax_course_import_lesson_planner,
      fn _source, position, _opts ->
        case position do
          1 -> {:error, {:ai_planning_failed, :timeout}}
          2 -> {:error, {:ai_planning_failed, %{status: 401}}}
        end
      end
    )

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    transient_job = job_for_position!(run.id, generation, 1)
    permanent_job = job_for_position!(run.id, generation, 2)

    assert {:error, :provider_timeout} =
             LessonPlanWorker.perform(%{
               transient_job
               | attempt: 1,
                 max_attempts: 4,
                 state: "executing"
             })

    assert {:discard, :provider_unauthorized} =
             LessonPlanWorker.perform(%{
               permanent_job
               | attempt: 1,
                 max_attempts: 4,
                 state: "executing"
             })

    transient = Repo.get!(Lesson, transient_job.args["lesson_id"])
    permanent = Repo.get!(Lesson, permanent_job.args["lesson_id"])

    assert transient.planning_state == "retrying"
    assert transient.planning_error["retryable"]
    assert permanent.planning_state == "failed"
    refute permanent.planning_error["retryable"]
    assert lesson_plan_count(run.id) == 0
  end

  test "out-of-order completions refill one slot and the last child transitions once", %{
    author: author,
    run: run
  } do
    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    assert {:ok, _lesson, after_third} = complete_position(run.id, generation, 3)
    assert after_third.status == :planning_lessons
    assert queued_positions(run.id) == [1, 2, 4]

    assert {:ok, _lesson, after_first} = complete_position(run.id, generation, 1)
    assert after_first.status == :planning_lessons
    assert queued_positions(run.id) == [2, 4, 5]

    assert {:ok, _lesson, after_second} = complete_position(run.id, generation, 2)
    assert after_second.status == :planning_lessons
    assert queued_positions(run.id) == [4, 5]

    assert {:ok, _lesson, after_fifth} = complete_position(run.id, generation, 5)
    assert after_fifth.status == :planning_lessons
    assert queued_positions(run.id) == [4]

    last_job = job_for_position!(run.id, generation, 4)
    last_lesson = Repo.get!(Lesson, last_job.args["lesson_id"])

    assert {:ok, _lesson, review_run} =
             CourseImport.complete_lesson_plan_job(last_job.args, generated_result(last_lesson))

    assert review_run.status == :awaiting_lesson_approval
    assert queued_positions(run.id) == []
    assert Enum.all?(ordered_lessons(run.id), &(&1.planning_state == "completed"))

    version_count = lesson_plan_count(run.id)

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.complete_lesson_plan_job(last_job.args, generated_result(last_lesson))

    assert lesson_plan_count(run.id) == version_count

    assert Repo.aggregate(
             from(notification in Notification,
               where:
                 notification.run_id == ^run.id and
                   notification.event == "lesson_plans_ready"
             ),
             :count
           ) == 1
  end

  test "three lesson workers can execute the planner concurrently", %{
    author: author,
    run: run
  } do
    previous_planner =
      Application.get_env(:oli, :openstax_course_import_lesson_planner)

    on_exit(fn ->
      if is_nil(previous_planner) do
        Application.delete_env(:oli, :openstax_course_import_lesson_planner)
      else
        Application.put_env(
          :oli,
          :openstax_course_import_lesson_planner,
          previous_planner
        )
      end
    end)

    test_pid = self()

    Application.put_env(
      :oli,
      :openstax_course_import_lesson_planner,
      fn source, position, _opts ->
        send(test_pid, {:lesson_planner_entered, self(), position})

        receive do
          :release_lesson_planner ->
            {_mode, payload} = Planner.build_lesson_plan(source, position)
            payload = put_in(payload, ["content_payload", "authoring_mode"], "basic")

            {:ok,
             %{
               plan_mode: "basic",
               payload: payload,
               created_by: "system",
               metadata: %{strategy: :test_barrier}
             }}
        after
          5_000 -> {:error, :planner_barrier_timeout}
        end
      end
    )

    run.id
    |> ordered_lessons()
    |> Enum.each(&insert_normalized_source!(run, &1, &1.order))

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    jobs = child_jobs(run.id, generation)
    assert length(jobs) == 3

    tasks =
      Enum.map(jobs, fn job ->
        Task.async(fn ->
          LessonPlanWorker.perform(%{job | attempt: 1, max_attempts: 4, state: "executing"})
        end)
      end)

    entered =
      Enum.map(1..3, fn _index ->
        assert_receive {:lesson_planner_entered, worker_pid, position}, 2_000
        {worker_pid, position}
      end)

    assert entered |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 3
    assert entered |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [1, 2, 3]

    Enum.each(entered, fn {worker_pid, _position} ->
      send(worker_pid, :release_lesson_planner)
    end)

    assert Enum.all?(tasks, &(Task.await(&1, 30_000) == :ok))
  end

  test "cancellation during an AI call fences the late result", %{
    author: author,
    run: run
  } do
    previous_planner =
      Application.get_env(:oli, :openstax_course_import_lesson_planner)

    on_exit(fn -> restore_lesson_planner(previous_planner) end)

    test_pid = self()

    Application.put_env(
      :oli,
      :openstax_course_import_lesson_planner,
      fn source, position, _opts ->
        send(test_pid, {:cancellable_planner_entered, self()})

        receive do
          :release_cancellable_planner ->
            {_mode, payload} = Planner.build_lesson_plan(source, position)
            payload = put_in(payload, ["content_payload", "authoring_mode"], "basic")

            {:ok,
             %{
               plan_mode: "basic",
               payload: payload,
               created_by: "system",
               metadata: %{strategy: :cancellation_barrier}
             }}
        after
          5_000 -> {:error, :planner_barrier_timeout}
        end
      end
    )

    [first_lesson | _] = ordered_lessons(run.id)
    insert_normalized_source!(run, first_lesson, 1)

    assert {:ok, planning} = CourseImport.approve_outline(run.id, author)
    generation = planning.lesson_planning_generation

    assert :ok =
             perform_job(LessonPlanningCoordinatorWorker, %{
               "run_id" => run.id,
               "generation" => generation
             })

    job = job_for_position!(run.id, generation, 1)

    task =
      Task.async(fn ->
        LessonPlanWorker.perform(%{job | attempt: 1, max_attempts: 4, state: "executing"})
      end)

    assert_receive {:cancellable_planner_entered, planner_pid}, 2_000
    assert {:ok, cancelled} = CourseImport.cancel_run(run.id, author)
    assert cancelled.lesson_planning_generation == generation + 1

    send(planner_pid, :release_cancellable_planner)

    assert Task.await(task, 30_000) == {:discard, :stale_lesson_planning_job}
    assert lesson_plan_count(run.id) == 0
    assert Repo.get!(Lesson, first_lesson.id).planning_state == "cancelled"
  end

  test "regeneration is queued asynchronously and locks only that lesson", %{
    author: author,
    run: run,
    lessons: [lesson | _]
  } do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, _review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    approved_at = DateTime.utc_now()

    lesson =
      lesson
      |> Lesson.changeset(%{
        status: "approved",
        last_plan_version: 1,
        planning_state: "completed",
        planning_position: 1,
        approved_by_author_id: author.id,
        approved_at: approved_at
      })
      |> Repo.update!()

    plan =
      %LessonPlan{}
      |> LessonPlan.changeset(%{
        lesson_id: lesson.id,
        version: 1,
        content_payload: %{"objective" => "Explain the evidence."},
        questions_payload: %{"items" => []},
        checks_snapshot: %{"status" => "passed"},
        approved_by_user: true,
        approved_at: approved_at
      })
      |> Repo.insert!()

    assert {:ok, queued} = CourseImport.regenerate_lesson(run.id, lesson.id, author)
    assert queued.planning_state == "queued"
    assert queued.planning_operation == "regenerate"
    assert queued.planning_base_plan_version == 1
    assert is_binary(queued.planning_request_id)
    assert queued.approved_by_author_id == nil
    assert queued.approved_at == nil

    refute Repo.reload!(plan).approved_by_user
    assert length(child_jobs(run.id, queued.planning_generation)) == 1

    assert {:error, :lesson_plan_busy} =
             CourseImport.regenerate_lesson(run.id, lesson.id, author)

    assert {:error, :lesson_plan_busy} =
             CourseImport.approve_lesson(run.id, lesson.id, author)

    assert {:error, :lesson_plan_busy} =
             CourseImport.update_lesson_plan(
               lesson.id,
               author,
               %{"content_payload" => %{"objective" => "A conflicting edit"}},
               "basic"
             )

    assert {:error, :lesson_plan_busy} =
             CourseImport.reject_lesson(run.id, lesson.id, author, "Try another approach")
  end

  test "regeneration uses the stable position and creates one next version", %{
    author: author,
    run: run,
    lessons: [lesson | _]
  } do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, _review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    lesson =
      lesson
      |> Lesson.changeset(%{
        status: "ready_for_review",
        last_plan_version: 7,
        planning_state: "completed",
        planning_position: 4
      })
      |> Repo.update!()

    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 7,
      content_payload: %{"objective" => "Explain the prior plan."},
      questions_payload: %{"items" => []},
      checks_snapshot: %{"status" => "passed"}
    })
    |> Repo.insert!()

    assert {:ok, queued} = CourseImport.regenerate_lesson(run.id, lesson.id, author)
    job = Repo.get!(Oban.Job, queued.planning_oban_job_id)

    assert job.args["position"] == 4
    assert job.args["base_plan_version"] == 7

    insert_normalized_source!(run, queued, 4)

    assert {:ok, claim} = CourseImport.claim_lesson_plan_job(job.args, 1, job.id)
    assert claim.planning_position == 4
    Repo.delete_all(from(source in LessonSource, where: source.lesson_id == ^queued.id))

    telemetry_handler =
      "parallel-duplicate-completion-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        telemetry_handler,
        [
          [:oli, :openstax, :course_import, :plan_checked],
          [:oli, :openstax, :course_import, :lesson_job_completed]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:parallel_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    assert {:ok, completed, review_run} =
             CourseImport.complete_lesson_plan_job(job.args, generated_result(queued))

    assert review_run.status == :awaiting_lesson_approval
    assert completed.planning_state == "completed"
    assert completed.last_plan_version == 8

    assert Repo.aggregate(from(plan in LessonPlan, where: plan.lesson_id == ^lesson.id), :count) ==
             2

    assert_receive {:parallel_telemetry, [:oli, :openstax, :course_import, :plan_checked], _,
                    %{lesson_id: lesson_id}}

    assert lesson_id == lesson.id

    assert_receive {:parallel_telemetry, [:oli, :openstax, :course_import, :lesson_job_completed],
                    _, %{lesson_id: ^lesson_id}}

    assert {:ok, duplicate, _run} =
             CourseImport.complete_lesson_plan_job(job.args, generated_result(queued))

    assert duplicate.last_plan_version == 8

    assert Repo.aggregate(from(plan in LessonPlan, where: plan.lesson_id == ^lesson.id), :count) ==
             2

    refute_receive {:parallel_telemetry, _, _, %{lesson_id: ^lesson_id}}
  end

  test "a regeneration result is rejected when its base plan changes during the AI call", %{
    author: author,
    run: run,
    lessons: [lesson | _]
  } do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, _review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    lesson =
      lesson
      |> Lesson.changeset(%{
        status: "ready_for_review",
        last_plan_version: 1,
        planning_state: "completed",
        planning_position: 1
      })
      |> Repo.update!()

    original = generated_result(lesson).payload

    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 1,
      content_payload: original["content_payload"],
      questions_payload: original["questions_payload"],
      checks_snapshot: %{"status" => "passed"}
    })
    |> Repo.insert!()

    assert {:ok, queued} = CourseImport.regenerate_lesson(run.id, lesson.id, author)
    job = Repo.get!(Oban.Job, queued.planning_oban_job_id)
    insert_normalized_source!(run, queued, 1)

    assert {:ok, _claim} = CourseImport.claim_lesson_plan_job(job.args, 1, job.id)

    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 2,
      content_payload: Map.put(original["content_payload"], "title", "Newer author plan"),
      questions_payload: original["questions_payload"],
      checks_snapshot: %{"status" => "passed"},
      created_by: "author"
    })
    |> Repo.insert!()

    queued
    |> Lesson.changeset(%{last_plan_version: 2})
    |> Repo.update!()

    assert {:error, :stale_lesson_planning_job} =
             CourseImport.complete_lesson_plan_job(job.args, generated_result(queued))

    persisted = Repo.get!(Lesson, lesson.id)
    assert persisted.last_plan_version == 2
    assert persisted.planning_state == "running"

    assert Repo.aggregate(from(plan in LessonPlan, where: plan.lesson_id == ^lesson.id), :count) ==
             2
  end

  test "a fourth regeneration remains pending and all reviewer mutations stay busy", %{
    author: author,
    run: run,
    lessons: lessons
  } do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, _review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    review_lessons =
      lessons
      |> Enum.take(4)
      |> Enum.with_index(1)
      |> Enum.map(fn {lesson, position} ->
        lesson =
          lesson
          |> Lesson.changeset(%{
            status: "ready_for_review",
            last_plan_version: 1,
            planning_state: "completed",
            planning_position: position
          })
          |> Repo.update!()

        %LessonPlan{}
        |> LessonPlan.changeset(%{
          lesson_id: lesson.id,
          version: 1,
          content_payload: %{"objective" => "Explain lesson #{position}."},
          questions_payload: %{"items" => []},
          checks_snapshot: %{"status" => "passed"}
        })
        |> Repo.insert!()

        lesson
      end)

    queued_lessons =
      Enum.map(review_lessons, fn lesson ->
        assert {:ok, queued} = CourseImport.regenerate_lesson(run.id, lesson.id, author)
        queued
      end)

    generation = queued_lessons |> List.first() |> Map.fetch!(:planning_generation)
    fourth = List.last(queued_lessons)

    assert length(child_jobs(run.id, generation)) == 3
    assert fourth.planning_state == "pending"
    assert fourth.planning_operation == "regenerate"
    assert is_binary(fourth.planning_request_id)
    assert fourth.planning_oban_job_id == nil

    assert {:error, :lesson_plan_busy} =
             CourseImport.regenerate_lesson(run.id, fourth.id, author)

    assert {:error, :lesson_plan_busy} =
             CourseImport.approve_lesson(run.id, fourth.id, author)

    assert {:error, :lesson_plan_busy} =
             CourseImport.update_lesson_plan(
               fourth.id,
               author,
               %{"content_payload" => %{"objective" => "A conflicting edit"}},
               "basic"
             )

    assert {:error, :lesson_plan_busy} =
             CourseImport.reject_lesson(run.id, fourth.id, author, "Try another approach")
  end

  test "an author edit clears failed regeneration progress", %{
    author: author,
    run: run,
    lessons: [lesson | _]
  } do
    assert {:ok, planning} = CourseImport.transition_run(run.id, :planning_lessons)
    assert {:ok, _review} = CourseImport.transition_run(planning.id, :awaiting_lesson_approval)

    lesson =
      lesson
      |> Lesson.changeset(%{
        status: "ready_for_review",
        last_plan_version: 1,
        planning_state: "completed",
        planning_position: 1
      })
      |> Repo.update!()

    initial = generated_result(lesson).payload

    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 1,
      content_payload: initial["content_payload"],
      questions_payload: initial["questions_payload"],
      checks_snapshot: initial["checks_snapshot"]
    })
    |> Repo.insert!()

    assert {:ok, queued} = CourseImport.regenerate_lesson(run.id, lesson.id, author)
    job = Repo.get!(Oban.Job, queued.planning_oban_job_id)

    assert {:ok, failed, review_run} =
             CourseImport.fail_lesson_plan_job(job.args, 4, :provider_unauthorized)

    assert failed.planning_state == "failed"
    assert review_run.status == :awaiting_lesson_approval
    assert get_in(review_run.progress, ["lesson_planning", "failed"]) == 1

    assert {:ok, edited} =
             CourseImport.update_lesson_plan(
               lesson.id,
               author,
               %{
                 "content_payload" => %{
                   "narrative" =>
                     initial["content_payload"]["narrative"] <> "\n\nInstructor revision."
                 }
               },
               "basic"
             )

    assert edited.planning_state == "completed"
    assert edited.planning_error == nil

    assert {:ok, reconciled} = CourseImport.fetch_run(run.id)
    assert get_in(reconciled.progress, ["lesson_planning", "failed"]) == 0
    assert get_in(reconciled.progress, ["lesson_planning", "completed"]) == 1
  end

  defp advance_to_outline_review(run) do
    Enum.reduce(
      [:awaiting_scope, :ingesting, :planning_outline, :awaiting_outline_approval],
      run,
      fn status, current ->
        assert {:ok, updated} = CourseImport.transition_run(current.id, status)
        updated
      end
    )
  end

  defp insert_lessons(run, count) do
    unit =
      %Unit{}
      |> Unit.changeset(%{
        run_id: run.id,
        unit_name: "Unit 1",
        order: 1,
        status: "ready_for_review"
      })
      |> Repo.insert!()

    Enum.map(1..count, fn position ->
      source_url =
        "https://openstax.org/books/parallel-planning/pages/1-#{position}-lesson"

      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        order: position,
        title: "Lesson #{position}",
        source_sections: [source_url],
        source_evidence_links: [source_url],
        source_objectives: ["Explain the evidence and model in lesson #{position}"],
        source_excerpt: rich_source_excerpt(position),
        selected: true
      })
      |> Repo.insert!()
    end)
  end

  defp ordered_lessons(run_id) do
    Repo.all(
      from(lesson in Lesson,
        where: lesson.run_id == ^run_id,
        order_by: [asc: lesson.planning_position, asc: lesson.order]
      )
    )
  end

  defp child_jobs(run_id, generation) do
    worker = Oban.Worker.to_string(LessonPlanWorker)

    Repo.all(
      from(job in Oban.Job,
        where:
          job.worker == ^worker and
            fragment("?->>'run_id' = ?", job.args, ^run_id) and
            fragment("(?->>'generation')::integer = ?", job.args, ^generation),
        order_by: [asc: job.id]
      )
    )
  end

  defp job_for_position!(run_id, generation, position) do
    run_id
    |> child_jobs(generation)
    |> Enum.find(&(&1.args["position"] == position))
    |> case do
      %Oban.Job{} = job -> job
      nil -> raise "no lesson job for position #{position}"
    end
  end

  defp complete_position(run_id, generation, position) do
    job = job_for_position!(run_id, generation, position)
    lesson = Repo.get!(Lesson, job.args["lesson_id"])
    CourseImport.complete_lesson_plan_job(job.args, generated_result(lesson))
  end

  defp generated_result(%Lesson{} = lesson) do
    source = %{
      "title" => lesson.title,
      "source_excerpt" => lesson.source_excerpt,
      "source_sections" => lesson.source_sections,
      "source_evidence_links" => lesson.source_evidence_links,
      "source_objectives" => lesson.source_objectives
    }

    {_recommended_mode, payload} =
      Planner.build_lesson_plan(source, lesson.planning_position || lesson.order)

    payload = put_in(payload, ["content_payload", "authoring_mode"], "basic")

    %{plan_mode: "basic", payload: payload, created_by: "system"}
  end

  defp queued_positions(run_id) do
    run_id
    |> ordered_lessons()
    |> Enum.filter(&(&1.planning_state == "queued"))
    |> Enum.map(& &1.planning_position)
  end

  defp lesson_plan_count(run_id) do
    Repo.aggregate(
      from(plan in LessonPlan,
        join: lesson in Lesson,
        on: lesson.id == plan.lesson_id,
        where: lesson.run_id == ^run_id
      ),
      :count
    )
  end

  defp insert_normalized_source!(run, lesson, position) do
    text = lesson.source_excerpt
    digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    source_url = List.first(lesson.source_sections)

    section =
      %SourceSection{}
      |> SourceSection.changeset(%{
        run_id: run.id,
        canonical_url: source_url,
        section_slug: "lesson-#{position}",
        title: lesson.title,
        order: position,
        normalized_word_count: text |> String.split() |> length(),
        content_hash: digest,
        retrieved_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    block =
      %SourceBlock{}
      |> SourceBlock.changeset(%{
        run_id: run.id,
        source_section_id: section.id,
        source_key: "test-source-#{lesson.id}",
        order: 1,
        heading_path: [lesson.title],
        block_kind: "paragraph",
        normalized_text: text,
        token_estimate: max(div(String.length(text), 4), 1),
        content_hash: digest
      })
      |> Repo.insert!()

    %LessonSource{}
    |> LessonSource.changeset(%{
      run_id: run.id,
      lesson_id: lesson.id,
      source_block_id: block.id,
      order: 1,
      purpose: "instruction"
    })
    |> Repo.insert!()
  end

  defp restore_lesson_planner(nil),
    do: Application.delete_env(:oli, :openstax_course_import_lesson_planner)

  defp restore_lesson_planner(planner),
    do: Application.put_env(:oli, :openstax_course_import_lesson_planner, planner)

  defp restore_application_env(key, nil), do: Application.delete_env(:oli, key)
  defp restore_application_env(key, value), do: Application.put_env(:oli, key, value)

  defp rich_source_excerpt(position) do
    """
    ## Evidence and observations
    Lesson #{position} develops evidence through observations, models, constraints, and examples.
    Learners distinguish observations from assumptions, identify relevant conditions, and explain
    how a change in context can alter a result. A careful analysis connects each conclusion to the
    evidence that supports it and checks whether the reasoning addresses the original problem.

    ## Models and applications
    A model represents the parts of a problem that matter for a particular decision. Learners trace
    how inputs are transformed, compare alternative explanations, test edge cases, and evaluate
    whether an approach is correct and efficient enough for its context. Worked examples make the
    reasoning visible before learners apply the same model to a new situation.
    """
  end

  defp fail_next_queued_lesson(run_id, generation) do
    lesson =
      Repo.one!(
        from(lesson in Lesson,
          where:
            lesson.run_id == ^run_id and lesson.planning_generation == ^generation and
              lesson.planning_state == "queued",
          order_by: [asc: lesson.planning_position],
          limit: 1
        )
      )

    job = Repo.get!(Oban.Job, lesson.planning_oban_job_id)
    CourseImport.fail_lesson_plan_job(job.args, 4, :provider_unauthorized)
  end

  defp attach_lesson_failure_telemetry do
    handler_id = "parallel-health-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:oli, :openstax, :course_import, :lesson_job_failed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:lesson_failure_telemetry, measurements, metadata})
        end,
        nil
      )

    handler_id
  end
end
