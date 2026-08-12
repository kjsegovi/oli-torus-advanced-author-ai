defmodule OliWeb.Api.CourseImportController do
  @moduledoc """
  JSON endpoints for durable OpenStax course import runs.

  The endpoints intentionally return the complete persisted checkpoint after
  every mutation. A client can therefore reconnect after a browser close and
  continue polling the same run without reconstructing local state.
  """

  use OliWeb, :controller

  alias Oli.Authoring.Course.Project
  alias Oli.OpenStax.CourseImport
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias OliWeb.Api.CourseImportJSON
  alias OliWeb.Api.CourseImportParams

  def create(conn, %{"project_id" => project_id} = params) do
    author = conn.assigns.current_author

    with {:ok, project} <- project_from_id(project_id),
         {:ok, root_container} <- root_container(project),
         {:ok, run} <-
           CourseImport.start_import(project, root_container, author, source_url(params)) do
      render_run(conn, :created, run.id, author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def show(conn, %{"project_id" => project_id, "run_id" => run_id}) do
    author = conn.assigns.current_author

    with {:ok, project} <- project_from_id(project_id),
         {:ok, run} <- CourseImport.get_run(project, author, run_id) do
      json(conn, %{result: "success", run: CourseImportJSON.run(run)})
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def update_scope(conn, %{"run_id" => run_id} = params) do
    selected_chapter_ids = CourseImportParams.selected_chapter_ids(params)

    case CourseImport.update_scope(run_id, conn.assigns.current_author, selected_chapter_ids) do
      {:ok, run} -> render_run(conn, :ok, run.id, conn.assigns.current_author)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def approve_outline(conn, %{"run_id" => run_id}) do
    case CourseImport.approve_outline(run_id, conn.assigns.current_author) do
      {:ok, run} -> render_run(conn, :ok, run.id, conn.assigns.current_author)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def approve_lesson(conn, %{"run_id" => run_id, "lesson_id" => lesson_id}) do
    mutate_lesson(conn, run_id, lesson_id, :approve, %{})
  end

  def update_lesson_plan(conn, %{"run_id" => run_id, "lesson_id" => lesson_id} = params) do
    with :ok <- ensure_lesson_in_run(run_id, lesson_id, conn.assigns.current_author),
         {:ok, _lesson} <-
           CourseImport.update_lesson_plan(
             lesson_id,
             conn.assigns.current_author,
             CourseImportParams.lesson_plan_payload(params),
             Map.get(params, "plan_mode")
           ) do
      render_run(conn, :ok, run_id, conn.assigns.current_author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def reject_lesson(conn, %{"run_id" => run_id, "lesson_id" => lesson_id} = params) do
    mutate_lesson(conn, run_id, lesson_id, :reject, params)
  end

  def regenerate_lesson(conn, %{"run_id" => run_id, "lesson_id" => lesson_id}) do
    mutate_lesson(conn, run_id, lesson_id, :regenerate, %{})
  end

  def apply(conn, %{"run_id" => run_id}) do
    author = conn.assigns.current_author

    with {:ok, run} <- CourseImport.load_run_details(run_id, author),
         {:ok, project} <- project_from_id(run.project_id),
         {:ok, updated_run} <- CourseImport.start_apply(project, run.id, author) do
      render_run(conn, :accepted, updated_run.id, author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def cancel(conn, %{"run_id" => run_id}) do
    case CourseImport.cancel_run(run_id, conn.assigns.current_author) do
      {:ok, run} -> render_run(conn, :ok, run.id, conn.assigns.current_author)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def retry(conn, %{"run_id" => run_id}) do
    case CourseImport.retry_run(run_id, conn.assigns.current_author) do
      {:ok, run} -> render_run(conn, :accepted, run.id, conn.assigns.current_author)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp mutate_lesson(conn, run_id, lesson_id, :approve, _params) do
    with :ok <- ensure_lesson_in_run(run_id, lesson_id, conn.assigns.current_author),
         {:ok, _lesson} <-
           CourseImport.approve_lesson(run_id, lesson_id, conn.assigns.current_author) do
      render_run(conn, :ok, run_id, conn.assigns.current_author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp mutate_lesson(conn, run_id, lesson_id, :reject, params) do
    reason = Map.get(params, "reason") || Map.get(params, "rejection_reason")

    with :ok <- ensure_lesson_in_run(run_id, lesson_id, conn.assigns.current_author),
         {:ok, _lesson} <-
           CourseImport.reject_lesson(run_id, lesson_id, conn.assigns.current_author, reason) do
      render_run(conn, :ok, run_id, conn.assigns.current_author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp mutate_lesson(conn, run_id, lesson_id, :regenerate, _params) do
    with :ok <- ensure_lesson_in_run(run_id, lesson_id, conn.assigns.current_author),
         {:ok, _lesson} <-
           CourseImport.regenerate_lesson(run_id, lesson_id, conn.assigns.current_author) do
      render_run(conn, :accepted, run_id, conn.assigns.current_author)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp render_run(conn, status, run_id, author) do
    case CourseImport.load_run_details(run_id, author) do
      {:ok, run} ->
        conn
        |> put_status(status)
        |> json(%{result: "success", run: CourseImportJSON.run(run)})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  defp ensure_lesson_in_run(run_id, lesson_id, author) do
    with {:ok, run} <- CourseImport.load_run_details(run_id, author) do
      if Enum.any?(run.units, &Enum.any?(&1.lessons, fn lesson -> lesson.id == lesson_id end)) do
        :ok
      else
        {:error, :not_found}
      end
    end
  end

  defp project_from_id(id) when is_integer(id), do: lookup_project(id)

  defp project_from_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {project_id, ""} -> lookup_project(project_id)
      _ -> {:error, :not_found}
    end
  end

  defp project_from_id(_), do: {:error, :not_found}

  defp lookup_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp root_container(project) do
    case AuthoringResolver.root_container(project.slug) do
      nil -> {:error, :invalid_target}
      container -> {:ok, container}
    end
  end

  defp source_url(params) do
    params["source_url"] || get_in(params, ["course_import", "source_url"])
  end

  defp error_response(conn, reason) do
    {status, code, detail} = error_details(reason)

    conn
    |> put_status(status)
    |> json(%{result: "error", error: %{code: code, detail: detail}})
  end

  defp error_details(:not_found),
    do: {:not_found, "not_found", "Course import run was not found."}

  defp error_details(:not_authorized), do: {:forbidden, "not_authorized", "Not authorized."}

  defp error_details(:feature_disabled),
    do:
      {:forbidden, "feature_disabled",
       "OpenStax course import is not available for this project."}

  defp error_details(:invalid_openstax_url),
    do: {:unprocessable_entity, "invalid_openstax_url", "Use an OpenStax book details URL."}

  defp error_details(:invalid_target),
    do: {:unprocessable_entity, "invalid_target", "The project root container is unavailable."}

  defp error_details(:project_root_not_empty),
    do:
      {:conflict, "project_root_not_empty",
       "Create the course in a project whose root curriculum is empty."}

  defp error_details(:target_must_be_project_root),
    do:
      {:unprocessable_entity, "target_must_be_project_root",
       "An OpenStax course import can only be applied to the project root."}

  defp error_details(:invalid_input),
    do: {:unprocessable_entity, "invalid_input", "The request payload is invalid."}

  defp error_details(:run_in_progress),
    do: {:conflict, "run_in_progress", "An import is already running for this project."}

  defp error_details(:lessons_pending_approval),
    do: {:conflict, "lessons_pending_approval", "Every lesson must be approved before applying."}

  defp error_details(:lesson_plan_busy),
    do:
      {:conflict, "lesson_plan_busy",
       "This lesson is currently being generated. Wait for it to finish before editing or approving it."}

  defp error_details(:no_lessons_to_approve),
    do: {:unprocessable_entity, "no_lessons_to_approve", "The plan has no lessons to approve."}

  defp error_details(:no_chapters_selected),
    do:
      {:unprocessable_entity, "no_chapters_selected",
       "Select at least one OpenStax chapter before continuing."}

  defp error_details(:no_chapters_discovered),
    do:
      {:unprocessable_entity, "no_chapters_discovered",
       "No chapters were found at that OpenStax book URL. Verify the book is publicly available and try again."}

  defp error_details(:selected_chapter_has_no_sections),
    do:
      {:unprocessable_entity, "selected_chapter_has_no_sections",
       "One of the selected chapters has no readable sections. Choose a different chapter selection."}

  defp error_details(:invalid_chapter_selection),
    do:
      {:unprocessable_entity, "invalid_chapter_selection",
       "The selected chapters are not part of this OpenStax book. Refresh the chapter list and try again."}

  defp error_details(:empty_outline),
    do:
      {:unprocessable_entity, "empty_outline",
       "The selected chapters did not produce any lessons. Adjust the chapter selection and try again."}

  defp error_details(:lesson_plan_rejected),
    do:
      {:conflict, "lesson_plan_rejected",
       "This lesson plan was rejected. Edit or regenerate it before approving the course."}

  defp error_details(:rejection_reason_required),
    do:
      {:unprocessable_entity, "rejection_reason_required",
       "Include a reason when rejecting a lesson plan."}

  defp error_details(:not_cancellable),
    do: {:conflict, "not_cancellable", "This course import can no longer be cancelled."}

  defp error_details(:not_recoverable),
    do:
      {:conflict, "not_recoverable",
       "This failure is not safe to retry. Start a new import instead."}

  defp error_details(:retry_job_already_active),
    do:
      {:conflict, "retry_job_already_active",
       "A background worker is still handling this import. Refresh its status before retrying."}

  defp error_details(:project_publication_changed),
    do:
      {:conflict, "project_publication_changed",
       "The project changed while the import was starting. Refresh the curriculum and try again."}

  defp error_details({:invalid_status, current, expected}),
    do: {:conflict, "invalid_status", "Expected #{expected}, but the run is #{current}."}

  defp error_details({:invalid_transition, current, next}),
    do: {:conflict, "invalid_transition", "Cannot transition from #{current} to #{next}."}

  defp error_details({:compile_failed, _reason}),
    do:
      {:unprocessable_entity, "compile_failed",
       "One or more approved lesson plans could not be compiled. Edit or regenerate the affected plan and try again."}

  defp error_details(%Ecto.Changeset{}),
    do: {:unprocessable_entity, "validation_failed", "The request could not be saved."}

  defp error_details(_),
    do:
      {:unprocessable_entity, "course_import_error",
       "The course import request could not be completed."}
end
