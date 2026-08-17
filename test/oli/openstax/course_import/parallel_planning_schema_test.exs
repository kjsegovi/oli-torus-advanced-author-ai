defmodule Oli.OpenStax.CourseImport.ParallelPlanningSchemaTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.{Lesson, Run}

  test "new runs and lessons default to bounded parallel planning" do
    assert %Run{
             lesson_planning_strategy: :parallel_v1,
             lesson_planning_generation: 0,
             lesson_planning_parallelism: 3
           } = %Run{}

    assert %Lesson{
             planning_state: "pending",
             planning_operation: "initial",
             planning_generation: 0,
             planning_attempts: 0,
             planning_base_plan_version: 0
           } = %Lesson{}
  end

  test "run changesets accept only the current parallel strategy and clamp per-run parallelism" do
    attrs = %{
      project_id: 1,
      author_id: 1,
      source_url: "https://openstax.org/details/books/example",
      book_slug: "example",
      lesson_planning_strategy: :parallel_v1,
      lesson_planning_generation: 2,
      lesson_planning_parallelism: 8
    }

    assert Run.create_changeset(%Run{}, attrs).valid?

    refute Run.create_changeset(%Run{}, %{attrs | lesson_planning_strategy: :serial_v1}).valid?
    refute Run.create_changeset(%Run{}, %{attrs | lesson_planning_parallelism: 0}).valid?
    refute Run.create_changeset(%Run{}, %{attrs | lesson_planning_parallelism: 9}).valid?
    refute Run.create_changeset(%Run{}, %{attrs | lesson_planning_strategy: :unknown}).valid?
  end

  test "lesson changesets validate durable job identity and lifecycle values" do
    attrs = %{
      run_id: Ecto.UUID.generate(),
      unit_id: Ecto.UUID.generate(),
      order: 1,
      title: "A parallel lesson",
      planning_state: "running",
      planning_operation: "regenerate",
      planning_generation: 3,
      planning_request_id: Ecto.UUID.generate(),
      planning_position: 4,
      planning_oban_job_id: 42,
      planning_attempts: 2,
      planning_base_plan_version: 5
    }

    assert Lesson.changeset(%Lesson{}, attrs).valid?

    refute Lesson.changeset(%Lesson{}, %{attrs | planning_state: "unknown"}).valid?
    refute Lesson.changeset(%Lesson{}, %{attrs | planning_operation: "unknown"}).valid?
    refute Lesson.changeset(%Lesson{}, %{attrs | planning_position: 0}).valid?
    refute Lesson.changeset(%Lesson{}, %{attrs | planning_oban_job_id: 0}).valid?
    refute Lesson.changeset(%Lesson{}, %{attrs | planning_attempts: -1}).valid?
  end
end
