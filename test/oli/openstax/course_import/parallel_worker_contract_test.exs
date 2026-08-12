defmodule Oli.OpenStax.CourseImport.ParallelWorkerContractTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Worker.{
    LessonPlanWorker,
    LessonPlanningCoordinatorWorker
  }

  test "the coordinator runs on the orchestration queue" do
    changeset = LessonPlanningCoordinatorWorker.new(%{"run_id" => Ecto.UUID.generate()})

    assert Ecto.Changeset.get_field(changeset, :queue) == "course_import"

    assert Ecto.Changeset.get_field(changeset, :worker) ==
             inspect(LessonPlanningCoordinatorWorker)
  end

  test "each lesson is a bounded, independently retryable AI job" do
    args = %{
      "run_id" => Ecto.UUID.generate(),
      "lesson_id" => Ecto.UUID.generate(),
      "generation" => 2,
      "request_id" => Ecto.UUID.generate(),
      "position" => 4,
      "operation" => "initial",
      "base_plan_version" => 0,
      "attempt_offset" => 0
    }

    changeset = LessonPlanWorker.new(args)

    assert Ecto.Changeset.get_field(changeset, :queue) == "course_import_ai"
    assert Ecto.Changeset.get_field(changeset, :worker) == inspect(LessonPlanWorker)
    assert Ecto.Changeset.get_field(changeset, :args) == args
    assert Ecto.Changeset.get_field(changeset, :max_attempts) == 4
    assert LessonPlanWorker.timeout(%Oban.Job{}) == :timer.minutes(12)

    unique = Ecto.Changeset.get_change(changeset, :unique)

    assert MapSet.new(unique.fields) == MapSet.new([:args, :worker])
    assert unique.period == :infinity

    assert MapSet.new(unique.states) ==
             MapSet.new([:available, :scheduled, :executing, :retryable])
  end

  test "lesson retries use the bounded exponential schedule" do
    assert LessonPlanWorker.backoff(%Oban.Job{attempt: 1}) == 20
    assert LessonPlanWorker.backoff(%Oban.Job{attempt: 2}) == 40
    assert LessonPlanWorker.backoff(%Oban.Job{attempt: 3}) == 80
    assert LessonPlanWorker.backoff(%Oban.Job{attempt: 4}) == 160
  end
end
