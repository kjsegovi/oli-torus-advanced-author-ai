defmodule OliWeb.Workspaces.CourseAuthor.OpenStaxCourseImportLive do
  @moduledoc """
  Author review surface for an asynchronous OpenStax course import.

  The run lives in the database and workers publish its progress there, so this
  page can safely be closed and reopened without losing an in-flight import.
  """

  use OliWeb, :live_view

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Enrichment, Estimator, PubSub}
  alias Oli.Publishing.AuthoringResolver
  alias Phoenix.Component

  @form_name :openstax_course_import
  @poll_interval_ms 5_000
  @pubsub_refresh_debounce_ms 250
  @polling_statuses [
    :preflighting,
    :ingesting,
    :planning_outline,
    :planning_lessons,
    :staging_media,
    :applying
  ]

  @processing_statuses [
    :preflighting,
    :awaiting_scope,
    :ingesting,
    :planning_outline,
    :planning_lessons,
    :compiling,
    :staging_media,
    :applying
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    project = socket.assigns.project
    author = socket.assigns.current_author
    target_container = AuthoringResolver.root_container(project.slug)

    {:ok,
     assign(socket,
       active: :curriculum,
       resource_slug: project.slug,
       resource_title: project.title,
       page_title: gettext("Create course from OpenStax | %{project}", project: project.title),
       project: project,
       author: author,
       target_container: target_container,
       return_path: ~p"/workspaces/course_author/#{project.slug}/curriculum",
       available?: CourseImport.available?(project, author),
       unfinished_legacy_run?: CourseImport.unfinished_legacy_run?(project, author),
       approve_all_enabled: CourseImport.approve_all_lessons_enabled?(),
       test_conveniences_enabled: CourseImport.test_conveniences_enabled?(),
       enrichment_capabilities: CourseImport.enrichment_capabilities(project),
       form: import_form(),
       run: nil,
       run_estimate: nil,
       error_message: nil,
       poll_timer: nil,
       pubsub_refresh_timer: nil,
       subscribed_run_id: nil,
       editing_lesson_id: nil,
       rejecting_lesson_id: nil,
       scope_selected_ids: []
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"run_id" => run_id}, _uri, socket) do
    case CourseImport.get_run(socket.assigns.project, socket.assigns.author, run_id) do
      {:ok, run} ->
        {:noreply, socket |> assign(error_message: nil) |> assign_run(run)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(error_message: gettext("That course import could not be found."))
         |> cancel_poll()}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: course_import_error(reason))}
    end
  end

  def handle_params(_params, _uri, socket) do
    case CourseImport.get_active_run(
           socket.assigns.project,
           socket.assigns.author,
           socket.assigns.target_container
         ) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign_run(run)
         |> maybe_patch_run_path(run)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> cancel_poll()
         |> assign(run: nil, run_estimate: nil, error_message: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: course_import_error(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"openstax_course_import" => attrs}, socket) do
    {:noreply, assign(socket, form: form_with_errors(attrs))}
  end

  def handle_event("start", %{"openstax_course_import" => attrs}, socket) do
    source_url = String.trim(Map.get(attrs, "source_url", ""))

    with false <- socket.assigns.unfinished_legacy_run?,
         true <- socket.assigns.available?,
         true <- source_url != "",
         {:ok, run} <-
           CourseImport.start_import(
             socket.assigns.project,
             socket.assigns.target_container,
             socket.assigns.author,
             source_url
           ) do
      {:noreply,
       socket
       |> assign(form: import_form(), error_message: nil)
       |> assign_run(run)
       |> push_patch(to: run_path(socket.assigns.project.slug, run.id))}
    else
      true ->
        {:noreply,
         assign(
           socket,
           error_message:
             gettext(
               "This project contains an unfinished legacy import. It remains unchanged; start a new v6 import in a new project."
             )
         )}

      false ->
        {:noreply, assign(socket, error_message: gettext("Enter a valid OpenStax book URL."))}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: course_import_error(reason))}
    end
  end

  def handle_event("approve_outline", _params, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <- CourseImport.approve_outline(run.id, socket.assigns.author) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_scope", %{"chapters" => chapter_ids}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <- CourseImport.update_scope(run.id, socket.assigns.author, chapter_ids) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("change_scope", params, socket) do
    selected_ids =
      params
      |> Map.get("chapters", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    {:noreply, assign(socket, scope_selected_ids: selected_ids, error_message: nil)}
  end

  def handle_event("save_scope", _params, socket) do
    {:noreply,
     assign(socket,
       error_message: gettext("Select at least one chapter before continuing the course plan.")
     )}
  end

  def handle_event("approve_lesson", %{"lesson_id" => lesson_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _lesson} <- available_lesson(run, lesson_id),
         {:ok, _lesson} <- CourseImport.approve_lesson(run.id, lesson_id, socket.assigns.author),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("approve_all", _params, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <- CourseImport.approve_all_lessons(run.id, socket.assigns.author) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("edit_lesson", %{"lesson_id" => lesson_id}, socket) do
    case available_lesson(socket.assigns.run, lesson_id) do
      {:ok, _lesson} ->
        {:noreply, assign(socket, editing_lesson_id: lesson_id, rejecting_lesson_id: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: course_import_error(reason))}
    end
  end

  def handle_event("close_lesson_editor", _params, socket) do
    {:noreply, assign(socket, editing_lesson_id: nil)}
  end

  def handle_event("save_lesson", %{"lesson_id" => lesson_id, "lesson_plan" => attrs}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, lesson} <- available_lesson(run, lesson_id),
         {:ok, _lesson} <-
           CourseImport.update_lesson_plan(
             lesson_id,
             socket.assigns.author,
             lesson_plan_payload(attrs, lesson),
             Map.get(attrs, "plan_mode")
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply,
       socket
       |> assign(error_message: nil, editing_lesson_id: nil)
       |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_reject_lesson", %{"lesson_id" => lesson_id}, socket) do
    case available_lesson(socket.assigns.run, lesson_id) do
      {:ok, _lesson} ->
        {:noreply, assign(socket, rejecting_lesson_id: lesson_id, editing_lesson_id: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: course_import_error(reason))}
    end
  end

  def handle_event("close_reject_lesson", _params, socket) do
    {:noreply, assign(socket, rejecting_lesson_id: nil)}
  end

  def handle_event("reject_lesson", %{"lesson_id" => lesson_id, "reason" => reason}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _lesson} <- available_lesson(run, lesson_id),
         {:ok, _lesson} <-
           CourseImport.reject_lesson(run.id, lesson_id, socket.assigns.author, reason),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply,
       socket
       |> assign(error_message: nil, rejecting_lesson_id: nil)
       |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("regenerate_lesson", %{"lesson_id" => lesson_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _lesson} <- available_lesson(run, lesson_id),
         {:ok, _lesson} <-
           CourseImport.regenerate_lesson(run.id, lesson_id, socket.assigns.author),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("research_enrichment", %{"proposal_id" => proposal_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _proposal} <-
           CourseImport.request_enrichment_research(
             run.id,
             proposal_id,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "approve_enrichment",
        %{
          "proposal_id" => proposal_id,
          "research_set_id" => research_set_id,
          "content_hash" => content_hash
        },
        socket
      ) do
    with %{} = run <- socket.assigns.run,
         {:ok, _research} <-
           CourseImport.approve_enrichment_evidence(
             run.id,
             proposal_id,
             research_set_id,
             content_hash,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("approve_enrichment", %{"proposal_id" => proposal_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _proposal} <-
           CourseImport.approve_enrichment_proposal(
             run.id,
             proposal_id,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "reject_enrichment_evidence",
        %{
          "proposal_id" => proposal_id,
          "research_set_id" => research_set_id,
          "content_hash" => content_hash
        },
        socket
      ) do
    with %{} = run <- socket.assigns.run,
         {:ok, _research} <-
           CourseImport.reject_enrichment_evidence(
             run.id,
             proposal_id,
             research_set_id,
             content_hash,
             socket.assigns.author,
             "Rejected during evidence review"
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("omit_enrichment", %{"proposal_id" => proposal_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _proposal} <-
           CourseImport.omit_enrichment_proposal(
             run.id,
             proposal_id,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "generate_simulation",
        %{
          "proposal_id" => proposal_id,
          "simulation_spec_id" => simulation_spec_id,
          "simulation_spec_hash" => simulation_spec_hash,
          "author_feedback" => author_feedback
        },
        socket
      ) do
    with %{} = run <- socket.assigns.run,
         {:ok, _artifact} <-
           CourseImport.request_simulation_generation(
             run.id,
             proposal_id,
             simulation_spec_id,
             simulation_spec_hash,
             author_feedback,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("generate_simulation_spec", %{"proposal_id" => proposal_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _spec} <-
           CourseImport.request_simulation_spec(
             run.id,
             proposal_id,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "approve_simulation",
        %{"artifact_id" => artifact_id, "version" => version, "content_hash" => content_hash},
        socket
      ) do
    with %{} = run <- socket.assigns.run,
         {version, ""} <- Integer.parse(version),
         {:ok, _artifact} <-
           CourseImport.approve_simulation_artifact(
             run.id,
             artifact_id,
             version,
             content_hash,
             socket.assigns.author
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reject_simulation", %{"artifact_id" => artifact_id}, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, _artifact} <-
           CourseImport.reject_simulation_artifact(
             run.id,
             artifact_id,
             socket.assigns.author,
             "Rejected during simulation preview review"
           ),
         {:ok, refreshed} <-
           CourseImport.get_run(socket.assigns.project, socket.assigns.author, run.id) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(refreshed)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("apply", _params, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <-
           CourseImport.start_apply(socket.assigns.project, run.id, socket.assigns.author) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_run", _params, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <- CourseImport.cancel_run(run.id, socket.assigns.author) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("retry_run", _params, socket) do
    with %{} = run <- socket.assigns.run,
         {:ok, updated} <- CourseImport.retry_run(run.id, socket.assigns.author) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated)}
    else
      {:error, reason} -> {:noreply, assign(socket, error_message: course_import_error(reason))}
      _ -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:poll_run, %{assigns: %{run: nil}} = socket), do: {:noreply, socket}

  def handle_info({:openstax_course_import_run_updated, %{run_id: run_id}}, socket) do
    if socket.assigns.run && socket.assigns.run.id == run_id do
      {:noreply, schedule_pubsub_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_run_from_pubsub, socket) do
    socket
    |> assign(pubsub_refresh_timer: nil)
    |> then(&handle_info(:poll_run, &1))
  end

  def handle_info(:poll_run, socket) do
    case CourseImport.get_run_checkpoint(
           socket.assigns.project,
           socket.assigns.author,
           socket.assigns.run.id
         ) do
      {:ok, checkpoint} ->
        {:noreply, refresh_from_checkpoint(socket, checkpoint)}

      {:error, reason} ->
        {:noreply, socket |> cancel_poll() |> assign(error_message: course_import_error(reason))}
    end
  end

  defp refresh_from_checkpoint(socket, checkpoint) do
    current = socket.assigns.run

    if current.status == checkpoint.status and checkpoint.status in @polling_statuses do
      refreshed = %{
        current
        | progress: checkpoint.progress,
          error: checkpoint.error,
          result: checkpoint.result,
          latest_plan_version: checkpoint.latest_plan_version,
          finished_at: checkpoint.finished_at,
          updated_at: checkpoint.updated_at
      }

      assign_run(socket, refreshed)
    else
      case CourseImport.get_run(
             socket.assigns.project,
             socket.assigns.author,
             checkpoint.id
           ) do
        {:ok, detailed_run} ->
          assign_run(socket, detailed_run)

        {:error, reason} ->
          socket
          |> cancel_poll()
          |> assign(error_message: course_import_error(reason))
      end
    end
  end

  defp assign_run(socket, run) do
    socket
    |> cancel_poll()
    |> cancel_pubsub_refresh()
    |> subscribe_to_run(run)
    |> assign(run: run, run_estimate: Estimator.estimate(run))
    |> assign_scope_selection(run)
    |> schedule_poll(run)
  end

  defp assign_scope_selection(socket, %{status: :awaiting_scope} = run) do
    selected_ids =
      run
      |> scope_chapters()
      |> Enum.filter(& &1.selected)
      |> Enum.map(& &1.id)

    assign(socket, scope_selected_ids: selected_ids)
  end

  defp assign_scope_selection(socket, _run), do: socket

  defp subscribe_to_run(socket, %{id: run_id}) do
    if connected?(socket) && socket.assigns.subscribed_run_id != run_id do
      :ok = PubSub.subscribe(run_id)
      assign(socket, subscribed_run_id: run_id)
    else
      socket
    end
  end

  defp schedule_poll(socket, %{status: status} = run) do
    if status in @polling_statuses or lesson_planning_summary(run).active_items != [] or
         enrichment_work_active?(run) do
      assign(socket, poll_timer: Process.send_after(self(), :poll_run, @poll_interval_ms))
    else
      socket
    end
  end

  defp enrichment_work_active?(run) do
    run
    |> Map.get(:enrichment_proposals, [])
    |> List.wrap()
    |> Enum.any?(fn proposal ->
      proposal.research_status == "running" or
        Enum.any?(
          Map.get(proposal, :simulation_artifacts, []),
          &(&1.status == "generating")
        )
    end)
  end

  defp cancel_poll(%{assigns: %{poll_timer: nil}} = socket), do: socket

  defp cancel_poll(socket) do
    Process.cancel_timer(socket.assigns.poll_timer)
    assign(socket, poll_timer: nil)
  end

  defp schedule_pubsub_refresh(%{assigns: %{pubsub_refresh_timer: nil}} = socket) do
    assign(
      socket,
      pubsub_refresh_timer:
        Process.send_after(self(), :refresh_run_from_pubsub, @pubsub_refresh_debounce_ms)
    )
  end

  defp schedule_pubsub_refresh(socket), do: socket

  defp cancel_pubsub_refresh(%{assigns: %{pubsub_refresh_timer: nil}} = socket), do: socket

  defp cancel_pubsub_refresh(socket) do
    Process.cancel_timer(socket.assigns.pubsub_refresh_timer)
    assign(socket, pubsub_refresh_timer: nil)
  end

  defp maybe_patch_run_path(socket, run) do
    if connected?(socket),
      do: push_patch(socket, to: run_path(socket.assigns.project.slug, run.id), replace: true),
      else: socket
  end

  defp run_path(project_slug, run_id),
    do: ~p"/workspaces/course_author/#{project_slug}/curriculum/import/openstax?run_id=#{run_id}"

  defp import_form, do: Component.to_form(%{"source_url" => ""}, as: @form_name)
  defp form_with_errors(attrs), do: Component.to_form(attrs, as: @form_name)

  defp progress_heading(:preflighting), do: gettext("Checking the OpenStax link")
  defp progress_heading(:awaiting_scope), do: gettext("Preparing the book scope")
  defp progress_heading(:ingesting), do: gettext("Reading the selected source")
  defp progress_heading(:planning_outline), do: gettext("Building the unit outline")
  defp progress_heading(:planning_lessons), do: gettext("Planning lessons and questions")
  defp progress_heading(:awaiting_outline_approval), do: gettext("Review the course outline")
  defp progress_heading(:awaiting_lesson_approval), do: gettext("Review the lesson plans")
  defp progress_heading(:compiling), do: gettext("Ready for you to create the course")
  defp progress_heading(:staging_media), do: gettext("Copying approved OpenStax figures")
  defp progress_heading(:applying), do: gettext("Creating approved lessons")
  defp progress_heading(:completed), do: gettext("Course created")
  defp progress_heading(:failed), do: gettext("Course import failed")
  defp progress_heading(:cancelled), do: gettext("Course import cancelled")
  defp progress_heading(_), do: gettext("Updating course import")

  defp estimate_primary_text(estimate, status) do
    case estimate_value(estimate, "state", "unavailable") do
      "estimated" ->
        gettext("About %{range} until %{milestone}.",
          range: estimate_range(estimate),
          milestone: estimate_milestone(estimate)
        )

      "estimating" ->
        gettext("Estimating time until %{milestone}…",
          milestone: estimate_milestone(estimate)
        )

      "waiting_for_user" ->
        waiting_estimate_text(status)

      "completed" ->
        gettext("Course creation is complete.")

      "stopped" ->
        gettext("Background timing has stopped.")

      _ ->
        gettext("A time estimate is not available yet.")
    end
  end

  defp estimate_detail_text(estimate, status) do
    state = estimate_value(estimate, "state", "unavailable")
    work_state = estimate_value(estimate, "work_state", nil)
    queued = estimate_value(estimate, "queued", 0)
    retrying = estimate_value(estimate, "retrying", 0)

    cond do
      work_state == "retrying" or retrying > 0 ->
        gettext(
          "One or more lessons are retrying. The known retry delay is included; additional retries may increase the range."
        )

      work_state == "queued" or (status == :planning_lessons and queued > 0) ->
        gettext(
          "Some work is waiting for an AI worker. The range covers lesson processing, but unpredictable global queue time is not included."
        )

      state == "waiting_for_user" and estimate_has_range?(estimate) ->
        waiting_forecast_text(estimate, status)

      state == "estimating" ->
        estimating_detail_text(estimate)

      state == "estimated" ->
        estimated_detail_text(estimate)

      state == "completed" ->
        gettext(
          "The completion email and curriculum link remain available after you leave this page."
        )

      state == "stopped" ->
        gettext("No additional background work is running for this import.")

      true ->
        gettext("The estimate will appear after enough source or lesson progress is available.")
    end
  end

  defp waiting_estimate_text(:awaiting_scope),
    do: gettext("Waiting for your chapter selection. Background timing is paused.")

  defp waiting_estimate_text(:awaiting_outline_approval),
    do: gettext("Waiting for you to approve the course outline. Background timing is paused.")

  defp waiting_estimate_text(:awaiting_lesson_approval),
    do: gettext("Waiting for lesson plan review. Background timing is paused.")

  defp waiting_estimate_text(:compiling),
    do: gettext("Waiting for you to start course creation. Background timing is paused.")

  defp waiting_estimate_text(_),
    do: gettext("Waiting for your next step. Background timing is paused.")

  defp waiting_forecast_text(estimate, :awaiting_outline_approval) do
    gettext("After approval, allow about %{range} until %{milestone}.",
      range: estimate_range(estimate),
      milestone: estimate_milestone(estimate)
    )
  end

  defp waiting_forecast_text(estimate, :compiling) do
    gettext("After you start course creation, allow about %{range} until %{milestone}.",
      range: estimate_range(estimate),
      milestone: estimate_milestone(estimate)
    )
  end

  defp waiting_forecast_text(estimate, _status) do
    gettext("When work resumes, allow about %{range} until %{milestone}.",
      range: estimate_range(estimate),
      milestone: estimate_milestone(estimate)
    )
  end

  defp estimating_detail_text(estimate) do
    case estimate_progress(estimate) do
      {completed, total} when completed > 0 ->
        gettext(
          "Based on %{completed} of %{total} items completed. The range will adjust as work continues.",
          completed: completed,
          total: total
        )

      _ ->
        gettext(
          "We will show a range after enough work has completed to measure the current pace."
        )
    end
  end

  defp estimated_detail_text(estimate) do
    confidence = estimate_value(estimate, "confidence", "low")
    parallel_suffix = parallel_estimate_suffix(estimate)

    case estimate_progress(estimate) do
      {completed, total} ->
        if confidence == "low" do
          gettext(
            "Early estimate based on %{completed} of %{total} items completed. It will adjust as work continues.%{parallel_suffix}",
            completed: completed,
            total: total,
            parallel_suffix: parallel_suffix
          )
        else
          gettext(
            "Based on %{completed} of %{total} items completed. The range will adjust as work continues.%{parallel_suffix}",
            completed: completed,
            total: total,
            parallel_suffix: parallel_suffix
          )
        end

      _ ->
        gettext("This range will adjust as work continues.%{parallel_suffix}",
          parallel_suffix: parallel_suffix
        )
    end
  end

  defp parallel_estimate_suffix(estimate) do
    case estimate_value(estimate, "parallelism", 1) do
      parallelism when is_integer(parallelism) and parallelism > 1 ->
        gettext(" Up to %{count} lesson plans are generated at once.", count: parallelism)

      _ ->
        ""
    end
  end

  defp estimate_milestone(estimate) do
    case estimate_value(estimate, "milestone", "lesson_plans_ready") do
      "scope_ready" -> gettext("chapter selection is ready")
      "outline_ready" -> gettext("the course outline is ready")
      "lesson_plans_ready" -> gettext("lesson plans are ready")
      "course_created" -> gettext("the course is created")
      _ -> gettext("the next review step is ready")
    end
  end

  defp estimate_range(estimate) do
    lower = estimate_value(estimate, "lower_seconds", nil)
    upper = estimate_value(estimate, "upper_seconds", nil)

    cond do
      valid_seconds?(lower) and valid_seconds?(upper) and lower < upper ->
        lower_text = format_estimate_duration(lower)
        upper_text = format_estimate_duration(upper)

        if lower_text == upper_text do
          upper_text
        else
          gettext("%{lower}–%{upper}", lower: lower_text, upper: upper_text)
        end

      valid_seconds?(upper) ->
        format_estimate_duration(upper)

      valid_seconds?(lower) ->
        format_estimate_duration(lower)

      true ->
        gettext("an unknown amount of time")
    end
  end

  defp estimate_has_range?(estimate) do
    valid_seconds?(estimate_value(estimate, "lower_seconds", nil)) or
      valid_seconds?(estimate_value(estimate, "upper_seconds", nil))
  end

  defp estimate_elapsed_text(estimate) do
    estimate
    |> estimate_value("stage_elapsed_seconds", nil)
    |> case do
      seconds when is_number(seconds) and seconds >= 0 ->
        gettext("Current stage elapsed: %{duration}",
          duration: format_estimate_duration(seconds)
        )

      _ ->
        nil
    end
  end

  defp show_estimate_elapsed?(estimate) do
    estimate_value(estimate, "state", "unavailable") in ["estimated", "estimating"] and
      is_binary(estimate_elapsed_text(estimate))
  end

  defp estimate_stalled?(estimate), do: estimate_value(estimate, "stalled", false) == true

  defp estimate_last_progress_text(estimate) do
    with {:ok, last_progress_at} <-
           estimate_datetime(estimate_value(estimate, "last_progress_at", nil)),
         {:ok, calculated_at} <- estimate_datetime(estimate_value(estimate, "calculated_at", nil)),
         seconds when is_integer(seconds) and seconds >= 0 <-
           DateTime.diff(calculated_at, last_progress_at, :second) do
      gettext("Last progress checkpoint: %{duration} ago.",
        duration: format_estimate_duration(seconds)
      )
    else
      _ -> gettext("No recent progress checkpoint is available.")
    end
  end

  defp estimate_progress(estimate) do
    completed = estimate_value(estimate, "completed", nil)
    total = estimate_value(estimate, "total", nil)

    if is_integer(completed) and completed >= 0 and is_integer(total) and total > 0 and
         completed <= total,
       do: {completed, total},
       else: nil
  end

  defp estimate_value(estimate, key, default) when is_map(estimate) do
    Map.get(estimate, key, default)
  end

  defp estimate_value(_, _key, default), do: default

  defp estimate_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp estimate_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp estimate_datetime(_), do: :error

  defp format_estimate_duration(seconds) when is_float(seconds),
    do: format_estimate_duration(round(seconds))

  defp format_estimate_duration(seconds) when is_integer(seconds) and seconds < 60,
    do: gettext("under a minute")

  defp format_estimate_duration(seconds) when is_integer(seconds) and seconds < 3_600 do
    minutes = max(1, round(seconds / 60))
    ngettext("1 minute", "%{count} minutes", minutes)
  end

  defp format_estimate_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      minutes == 0 ->
        ngettext("1 hour", "%{count} hours", hours)

      hours == 1 ->
        gettext("1 hour %{minutes} minutes", minutes: minutes)

      true ->
        gettext("%{hours} hours %{minutes} minutes", hours: hours, minutes: minutes)
    end
  end

  defp valid_seconds?(seconds), do: is_number(seconds) and seconds >= 0

  defp units_for_run(%{units: units}) when is_list(units), do: units
  defp units_for_run(_), do: []

  defp lessons_for_unit(%{lessons: lessons}) when is_list(lessons), do: lessons
  defp lessons_for_unit(_), do: []

  defp lesson_count(unit), do: unit |> lessons_for_unit() |> length()

  defp total_lesson_count(run) do
    run
    |> units_for_run()
    |> Enum.flat_map(&lessons_for_unit/1)
    |> length()
  end

  defp lesson_planning_summary(run) do
    progress_planning =
      run.progress
      |> Kernel.||(%{})
      |> map_string_key("lesson_planning", %{})

    progress_counts = map_string_key(progress_planning, "counts", %{})
    lessons = run |> units_for_run() |> Enum.flat_map(&lessons_for_unit/1)

    state_counts =
      Enum.reduce(
        lessons,
        %{
          "pending" => 0,
          "queued" => 0,
          "running" => 0,
          "retrying" => 0,
          "completed" => 0,
          "failed" => 0,
          "cancelled" => 0
        },
        fn lesson, counts ->
          Map.update!(counts, lesson_planning_state(lesson), &(&1 + 1))
        end
      )

    count = fn key, fallback ->
      if lessons != [] do
        fallback
      else
        direct = map_string_key(progress_planning, key, nil)
        nested = map_string_key(progress_counts, key, nil)

        cond do
          is_integer(direct) and direct >= 0 -> direct
          is_integer(nested) and nested >= 0 -> nested
          true -> fallback
        end
      end
    end

    total = count.("total", length(lessons))

    parallelism =
      map_string_key(progress_planning, "parallelism", nil) ||
        map_string_key(progress_planning, "configured_parallelism", nil) ||
        Map.get(run, :lesson_planning_parallelism) || 1

    %{
      total: total,
      pending: count.("pending", state_counts["pending"]),
      queued: count.("queued", state_counts["queued"]),
      running: count.("running", state_counts["running"]),
      retrying: count.("retrying", state_counts["retrying"]),
      completed: count.("completed", state_counts["completed"]),
      failed: count.("failed", state_counts["failed"]),
      parallelism: if(is_integer(parallelism) and parallelism > 0, do: parallelism, else: 1),
      active_items: planning_active_items(progress_planning, lessons)
    }
  end

  defp planning_active_items(progress_planning, lessons) do
    items =
      map_string_key(
        progress_planning,
        "active_items",
        map_string_key(progress_planning, "active_lessons", nil)
      )

    case items do
      items when is_list(items) and items != [] ->
        Enum.filter(items, &is_map/1)

      _ ->
        lessons
        |> Enum.filter(&lesson_busy?/1)
        |> Enum.sort_by(fn lesson ->
          {Map.get(lesson, :planning_position) || 2_147_483_647, lesson.order || 2_147_483_647}
        end)
        |> Enum.map(fn lesson ->
          %{
            "lesson_id" => lesson.id,
            "title" => lesson.title,
            "state" => lesson_planning_state(lesson),
            "attempt" => Map.get(lesson, :planning_attempts) || 0,
            "position" => Map.get(lesson, :planning_position)
          }
        end)
    end
  end

  defp lesson_planning_summary_text(run) do
    planning = lesson_planning_summary(run)

    [
      gettext("%{completed} of %{total} ready",
        completed: planning.completed,
        total: planning.total
      ),
      planning_count_text(planning.running, "generating"),
      planning_count_text(planning.queued, "queued"),
      planning_count_text(planning.retrying, "retrying"),
      planning_count_text(planning.failed, "failed")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp planning_count_text(0, _state), do: nil

  defp planning_count_text(count, "generating"),
    do: ngettext("1 generating", "%{count} generating", count)

  defp planning_count_text(count, "queued"),
    do: ngettext("1 queued", "%{count} queued", count)

  defp planning_count_text(count, "retrying"),
    do: ngettext("1 retrying", "%{count} retrying", count)

  defp planning_count_text(count, "failed"),
    do: ngettext("1 failed", "%{count} failed", count)

  defp planning_parallelism_text(run) do
    parallelism = lesson_planning_summary(run).parallelism

    ngettext(
      "Generating one lesson plan at a time",
      "Generating up to %{count} lesson plans at once",
      parallelism
    )
  end

  defp active_planning_item_text(item) do
    title =
      map_string_key(item, "title", nil) ||
        map_string_key(item, "lesson_title", nil) ||
        gettext("Lesson %{position}",
          position: map_string_key(item, "position", gettext("in progress"))
        )

    attempt =
      case map_string_key(item, "attempt", map_string_key(item, "planning_attempts", 0)) do
        attempt when is_integer(attempt) and attempt >= 0 -> attempt
        _ -> 0
      end

    case map_string_key(item, "state", "queued") |> to_string() do
      "running" ->
        gettext("Generating: %{title}", title: title)

      "retrying" ->
        gettext("Retrying attempt %{attempt}: %{title}", attempt: max(attempt, 1), title: title)

      _ ->
        gettext("Queued: %{title}", title: title)
    end
  end

  defp lesson_planning_state(lesson) do
    case Map.get(lesson, :planning_state) do
      state when state in ["pending", :pending] ->
        if pending_regeneration?(lesson),
          do: "pending",
          else: status_derived_lesson_planning_state(Map.get(lesson, :status))

      state
      when state in [
             "queued",
             "running",
             "retrying",
             "completed",
             "failed",
             "cancelled"
           ] ->
        state

      state
      when state in [:queued, :running, :retrying, :completed, :failed, :cancelled] ->
        Atom.to_string(state)

      _ ->
        status_derived_lesson_planning_state(Map.get(lesson, :status))
    end
  end

  defp status_derived_lesson_planning_state(status)
       when status in [
              "ready_for_review",
              "approved",
              "needs_attention",
              "needs_repair",
              "compiled",
              "applied"
            ],
       do: "completed"

  defp status_derived_lesson_planning_state("failed"), do: "failed"
  defp status_derived_lesson_planning_state(_status), do: "pending"

  defp pending_regeneration?(lesson) do
    Map.get(lesson, :planning_operation) in ["regenerate", :regenerate] and
      is_binary(Map.get(lesson, :planning_request_id))
  end

  defp lesson_busy?(lesson),
    do: lesson_planning_state(lesson) in ["pending", "queued", "running", "retrying"]

  defp lesson_planning_failed?(lesson), do: lesson_planning_state(lesson) == "failed"

  defp lesson_busy_label(lesson) do
    case lesson_planning_state(lesson) do
      "running" -> gettext("Regenerating")
      "retrying" -> gettext("Retrying regeneration")
      _ -> gettext("Regeneration queued")
    end
  end

  defp regenerate_button_label(lesson) do
    if lesson_planning_failed?(lesson) and Map.get(lesson, :planning_operation) == "regenerate",
      do: gettext("Retry regeneration"),
      else: gettext("Regenerate")
  end

  defp lesson_planning_error_message(lesson) do
    error = Map.get(lesson, :planning_error) || %{}
    message = map_string_key(error, "message", nil) || map_string_key(error, "reason", nil)

    if is_binary(message) and String.trim(message) != "",
      do: message,
      else: gettext("The lesson could not be regenerated. Its previous plan is still available.")
  end

  defp lesson_planning_failure_categories(run) do
    run
    |> units_for_run()
    |> Enum.flat_map(&lessons_for_unit/1)
    |> Enum.filter(&lesson_planning_failed?/1)
    |> Enum.map(fn lesson ->
      lesson
      |> Map.get(:planning_error)
      |> Kernel.||(%{})
      |> map_string_key("category", "unknown")
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {category, count} ->
      %{category: category, label: lesson_planning_failure_category_label(category), count: count}
    end)
    |> Enum.sort_by(fn item -> {-item.count, item.label} end)
  end

  defp lesson_planning_failure_category_label("content_validation_exhausted"),
    do: gettext("Basic content validation exhausted")

  defp lesson_planning_failure_category_label("content_quality_exhausted"),
    do: gettext("Content critic repair budget exhausted")

  defp lesson_planning_failure_category_label("content_quality_stalled"),
    do: gettext("Content critic findings repeated")

  defp lesson_planning_failure_category_label("question_quality_exhausted"),
    do: gettext("Question critic repair budget exhausted")

  defp lesson_planning_failure_category_label("question_quality_stalled"),
    do: gettext("Question critic findings repeated")

  defp lesson_planning_failure_category_label("agent_persistence_failed"),
    do: gettext("Question-agent startup failed")

  defp lesson_planning_failure_category_label("question_agent_exhausted"),
    do: gettext("Question-agent review exhausted")

  defp lesson_planning_failure_category_label("provider_timeout"),
    do: gettext("Content provider timeout")

  defp lesson_planning_failure_category_label("rate_limited"),
    do: gettext("Content provider throttling")

  defp lesson_planning_failure_category_label("provider_unavailable"),
    do: gettext("Content provider unavailable")

  defp lesson_planning_failure_category_label("invalid_provider_response"),
    do: gettext("Invalid content provider response")

  defp lesson_planning_failure_category_label("provider_not_configured"),
    do: gettext("Content provider not configured")

  defp lesson_planning_failure_category_label("provider_unauthorized"),
    do: gettext("Content provider credentials rejected")

  defp lesson_planning_failure_category_label("provider_forbidden"),
    do: gettext("Content provider request forbidden")

  defp lesson_planning_failure_category_label("provider_request_rejected"),
    do: gettext("Content provider request rejected")

  defp lesson_planning_failure_category_label("unclassified_generation_failure"),
    do: gettext("Unexpected generation response")

  defp lesson_planning_failure_category_label("lesson_plan_persistence_failed"),
    do: gettext("Lesson plan could not be saved")

  defp lesson_planning_failure_category_label("internal_exception"),
    do: gettext("Internal lesson-planning error")

  defp lesson_planning_failure_category_label(_category),
    do: gettext("Other lesson-planning failure")

  defp available_lesson(run, lesson_id) do
    case find_lesson(run, lesson_id) do
      nil -> {:error, :not_found}
      lesson -> if lesson_busy?(lesson), do: {:error, :lesson_plan_busy}, else: {:ok, lesson}
    end
  end

  defp approved_lesson_count(run) do
    run
    |> units_for_run()
    |> Enum.flat_map(&lessons_for_unit/1)
    |> Enum.count(&(&1.status in ["approved", "compiled", "applied"]))
  end

  defp assessment_payload(%{assessment_payload: payload}) when is_map(payload), do: payload
  defp assessment_payload(_), do: %{}

  defp assessment_title(unit),
    do: assessment_payload(unit)["title"] || gettext("Unit assessment")

  defp assessment_mode(unit),
    do: assessment_payload(unit)["authoring_mode"] || "basic"

  defp assessment_questions(unit) do
    case assessment_payload(unit)["questions"] do
      questions when is_list(questions) -> questions
      _ -> []
    end
  end

  defp assessment_evidence_links(unit) do
    case assessment_payload(unit)["source_evidence_links"] do
      links when is_list(links) -> links
      _ -> []
    end
  end

  defp processing_step(:preflighting), do: 1
  defp processing_step(:awaiting_scope), do: 2
  defp processing_step(:ingesting), do: 3
  defp processing_step(:planning_outline), do: 4
  defp processing_step(:awaiting_outline_approval), do: 4
  defp processing_step(:planning_lessons), do: 5
  defp processing_step(:awaiting_lesson_approval), do: 5
  defp processing_step(:compiling), do: 6
  defp processing_step(:staging_media), do: 7
  defp processing_step(:applying), do: 8
  defp processing_step(:completed), do: 8
  defp processing_step(_), do: 0

  defp processing_progress_total_steps, do: length(@processing_statuses)

  defp processing_progress_minimum, do: 1

  defp processing_progress_maximum, do: processing_progress_total_steps()

  defp processing_progress_text(status) do
    current = processing_step(status)
    total = processing_progress_total_steps()
    gettext("Step %{current} of %{total}", current: current, total: total)
  end

  defp processing_progress_text_for_run(%{status: :planning_lessons} = run) do
    planning = lesson_planning_summary(run)

    if planning.total > 0 do
      gettext("%{completed} of %{total} lesson plans ready",
        completed: planning.completed,
        total: planning.total
      )
    else
      processing_progress_text(run.status)
    end
  end

  defp processing_progress_text_for_run(run), do: processing_progress_text(run.status)

  defp processing_progress_minimum_for_run(%{status: :planning_lessons}), do: 0
  defp processing_progress_minimum_for_run(_run), do: processing_progress_minimum()

  defp processing_progress_maximum_for_run(%{status: :planning_lessons} = run) do
    case lesson_planning_summary(run).total do
      total when total > 0 -> total
      _ -> processing_progress_maximum()
    end
  end

  defp processing_progress_maximum_for_run(_run), do: processing_progress_maximum()

  defp processing_progress_for_run(%{status: :planning_lessons} = run) do
    planning = lesson_planning_summary(run)
    if planning.total > 0, do: planning.completed, else: processing_progress(run.status)
  end

  defp processing_progress_for_run(run), do: processing_progress(run.status)

  defp processing_progress_width_for_run(%{status: :planning_lessons} = run) do
    planning = lesson_planning_summary(run)

    if planning.total > 0 do
      percentage = min(planning.completed / planning.total * 100, 100)
      :erlang.float_to_binary(percentage, [{:decimals, 1}])
    else
      processing_progress_width(run.status)
    end
  end

  defp processing_progress_width_for_run(run), do: processing_progress_width(run.status)

  defp processing_progress_percentage(status) do
    current = processing_step(status)

    if processing_progress_total_steps() > 0 do
      current * 100 / processing_progress_total_steps()
    else
      0
    end
  end

  defp processing_progress(status), do: processing_step(status)

  defp processing_progress_width(status),
    do: :erlang.float_to_binary(processing_progress_percentage(status), [{:decimals, 1}])

  defp workflow_stages do
    [
      {:preflighting, gettext("Check source")},
      {:awaiting_scope, gettext("Choose chapters")},
      {:planning_outline, gettext("Plan outline")},
      {:planning_lessons, gettext("Plan lessons")},
      {:awaiting_lesson_approval, gettext("Review plans")},
      {:compiling, gettext("Compile")},
      {:staging_media, gettext("Copy figures")},
      {:applying, gettext("Create course")}
    ]
  end

  defp timeline_stage_class(stage, status) do
    current = timeline_stage_position(status)
    stage_step = timeline_stage_position(stage)

    cond do
      status in [:completed] || stage_step < current ->
        "openstax-course-import-timeline-step is-complete"

      stage_step == current ->
        "openstax-course-import-timeline-step is-active"

      true ->
        "openstax-course-import-timeline-step"
    end
  end

  defp stage_is_active?(stage, status),
    do: String.contains?(timeline_stage_class(stage, status), "is-active")

  defp timeline_stage_position(:preflighting), do: 1
  defp timeline_stage_position(:awaiting_scope), do: 2

  defp timeline_stage_position(status)
       when status in [:ingesting, :planning_outline, :awaiting_outline_approval],
       do: 3

  defp timeline_stage_position(:planning_lessons), do: 4
  defp timeline_stage_position(:awaiting_lesson_approval), do: 5
  defp timeline_stage_position(:compiling), do: 6
  defp timeline_stage_position(:staging_media), do: 7
  defp timeline_stage_position(status) when status in [:applying, :completed], do: 8
  defp timeline_stage_position(_), do: 0

  defp source_excerpt(lesson),
    do: lesson.source_excerpt || ""

  defp scope_chapters(run) do
    manifest = run.scope_manifest || %{}

    ["chapters", "discovered_chapters", "sections"]
    |> Enum.find_value([], fn key ->
      case Map.get(manifest, key) do
        chapters when is_list(chapters) -> chapters
        _ -> nil
      end
    end)
    |> Enum.map(&normalize_chapter/1)
  end

  defp normalize_chapter(%{} = chapter) do
    %{
      id: to_string(Map.get(chapter, "id") || Map.get(chapter, :id) || ""),
      title: Map.get(chapter, "title") || Map.get(chapter, :title) || gettext("Untitled chapter"),
      detail: Map.get(chapter, "detail") || Map.get(chapter, :detail),
      selected: Map.get(chapter, "selected", Map.get(chapter, :selected, true))
    }
  end

  defp normalize_chapter(chapter) when is_binary(chapter),
    do: %{id: chapter, title: chapter, detail: nil, selected: true}

  defp normalize_chapter(_),
    do: %{id: "", title: gettext("Untitled chapter"), detail: nil, selected: false}

  defp latest_plan(lesson), do: lesson.plans |> List.wrap() |> List.first()

  defp find_lesson(run, lesson_id) do
    run
    |> units_for_run()
    |> Enum.flat_map(&lessons_for_unit/1)
    |> Enum.find(&(to_string(&1.id) == to_string(lesson_id)))
  end

  defp plan_content(lesson, key, fallback \\ "") do
    case latest_plan(lesson) do
      %{content_payload: content} when is_map(content) ->
        map_string_key(content, key, fallback)

      _ ->
        fallback
    end
  end

  defp v5_lesson?(lesson), do: plan_content(lesson, "schema_version", 0) == 5
  defp v6_lesson?(lesson), do: plan_content(lesson, "schema_version", 0) == 6
  defp current_lesson?(lesson), do: v5_lesson?(lesson) or v6_lesson?(lesson)

  defp plan_content_groups(lesson) do
    lesson
    |> plan_content("content_groups", [])
    |> normalize_plan_maps()
  end

  defp plan_synthesis(lesson), do: plan_content(lesson, "synthesis", %{})

  defp v5_group_source_blocks(group), do: plan_item_maps(group, "source_blocks")
  defp v5_group_media(group), do: plan_item_maps(group, "media")

  defp v5_source_block_preview_text(block) do
    ast_text =
      block
      |> plan_item_value("ast", [])
      |> v5_ast_preview_text()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if ast_text == "", do: plan_item_value(block, "text"), else: ast_text
  end

  defp v5_ast_preview_text(value) when is_map(value) do
    [
      map_string_key(value, "text", ""),
      v5_ast_preview_text(map_string_key(value, "children", []))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp v5_ast_preview_text(value) when is_list(value),
    do: Enum.map_join(value, " ", &v5_ast_preview_text/1)

  defp v5_ast_preview_text(_value), do: ""

  defp v5_generation_metadata(lesson) do
    case latest_plan(lesson) do
      %{generation_metadata: metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp v5_quality_gate(lesson) do
    lesson
    |> v5_generation_metadata()
    |> map_string_key("quality_gate", %{})
  end

  defp v5_quality_confidence(lesson) do
    lesson
    |> v5_quality_gate()
    |> map_string_key("confidence", 0.0)
    |> case do
      value when is_integer(value) ->
        value / 1

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {number, _rest} -> number
          _ -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp v5_quality_confidence_label(lesson) do
    percentage = v5_quality_confidence(lesson) * 100
    :erlang.float_to_binary(percentage, decimals: 0) <> "%"
  end

  defp v5_quality_findings(lesson, severity) do
    gate = v5_quality_gate(lesson)

    findings =
      case severity do
        "hard_blocker" -> map_string_key(gate, "hard_blockers", [])
        "repair" -> map_string_key(gate, "repairs", [])
        "advisory" -> map_string_key(gate, "advisories", [])
        _ -> []
      end

    normalize_plan_maps(findings)
  end

  defp v5_role_rows(lesson) do
    lesson
    |> v5_generation_metadata()
    |> map_string_key("roles", %{})
    |> Enum.map(fn {role, identity} ->
      %{
        "role" => humanize_check_key(role),
        "model" => map_string_key(identity, "model", gettext("Not recorded")),
        "provider" => map_string_key(identity, "provider", "") |> to_string()
      }
    end)
    |> Enum.sort_by(& &1["role"])
  end

  defp v5_repair_history(lesson) do
    lesson
    |> v5_generation_metadata()
    |> map_string_key("repair_history", %{})
    |> Enum.flat_map(fn {stage, attempts} ->
      attempts
      |> List.wrap()
      |> Enum.map(fn attempt ->
        %{
          "stage" => humanize_check_key(stage),
          "attempt" => map_string_key(attempt, "attempt", 0),
          "model_usage" => map_string_key(attempt, "model_usage", %{})
        }
      end)
    end)
  end

  defp current_lesson_approvable?(lesson) do
    if current_lesson?(lesson) do
      gate = v5_quality_gate(lesson)

      map_string_key(gate, "approved", false) == true and
        v5_quality_confidence(lesson) >= 0.9 and
        v5_quality_findings(lesson, "hard_blocker") == [] and
        v5_quality_findings(lesson, "repair") == [] and
        check_status(lesson_checks(lesson)) in ["ok", "passed"]
    else
      false
    end
  end

  defp plan_media(lesson) do
    lesson
    |> plan_content("media", [])
    |> normalize_plan_maps()
  end

  defp plan_experience_blueprint(lesson), do: plan_content(lesson, "experience_blueprint", %{})

  defp plan_experience_stages(lesson) do
    lesson
    |> plan_experience_blueprint()
    |> map_string_key("stages", [])
    |> normalize_plan_maps()
  end

  defp plan_experience_activities(lesson) do
    lesson
    |> plan_experience_blueprint()
    |> map_string_key("activities", [])
    |> normalize_plan_maps()
  end

  defp plan_experience_duration(lesson) do
    lesson
    |> plan_experience_blueprint()
    |> map_string_key("duration_manifest", %{})
  end

  defp plan_experience_stage_items(stage), do: plan_item_maps(stage, "items")

  defp plan_experience_activity(lesson, activity_id) do
    Enum.find(
      plan_experience_activities(lesson),
      &(plan_item_value(&1, "id") == activity_id)
    )
  end

  defp plan_experience_content_group(lesson, group_id) do
    Enum.find(plan_content_groups(lesson), &(plan_item_value(&1, "id") == group_id))
  end

  defp plan_activity_choices(nil), do: []
  defp plan_activity_choices(activity), do: plan_item_maps(activity, "choices")

  defp lesson_learning_objectives(lesson) do
    case plan_content(lesson, "learning_objectives", []) |> normalize_plan_strings() do
      [] -> normalize_plan_strings(lesson.source_objectives)
      objectives -> objectives
    end
  end

  defp lesson_excluded_blocks(lesson) do
    lesson
    |> plan_content("coverage_manifest", %{})
    |> map_string_key("excluded_blocks", [])
    |> normalize_plan_maps()
  end

  defp lesson_coverage_rows(lesson) do
    coverage = plan_content(lesson, "coverage_manifest", %{})

    available =
      map_string_key(
        coverage,
        "available_source_block_ids",
        map_string_key(coverage, "available_block_ids", [])
      )
      |> normalize_plan_strings()

    included =
      map_string_key(
        coverage,
        "included_source_block_ids",
        map_string_key(coverage, "included_block_ids", [])
      )
      |> normalize_plan_strings()

    excluded =
      coverage
      |> map_string_key("excluded_blocks", [])
      |> normalize_plan_maps()
      |> Map.new(fn entry ->
        {plan_item_value(entry, "id"), plan_item_value(entry, "reason")}
      end)

    Enum.map(available, fn block_id ->
      cond do
        block_id in included ->
          %{"id" => block_id, "status" => gettext("Included"), "reason" => ""}

        Map.has_key?(excluded, block_id) ->
          %{
            "id" => block_id,
            "status" => gettext("Excluded"),
            "reason" => Map.get(excluded, block_id, "")
          }

        true ->
          %{
            "id" => block_id,
            "status" => gettext("Unaccounted for"),
            "reason" => gettext("This source block must be included or explicitly excluded.")
          }
      end
    end)
  end

  defp lesson_enrichment_proposals(run, lesson) do
    run
    |> Map.get(:enrichment_proposals, [])
    |> List.wrap()
    |> Enum.filter(&(&1.lesson_id == lesson.id))
    |> Enum.sort_by(& &1.rank)
  end

  defp proposal_artifacts(proposal) do
    proposal
    |> Map.get(:simulation_artifacts, [])
    |> List.wrap()
    |> Enum.sort_by(& &1.version, :desc)
  end

  defp proposal_research_sets(proposal) do
    proposal
    |> Map.get(:research_sets, [])
    |> List.wrap()
    |> Enum.sort_by(& &1.version, :desc)
  end

  defp reviewable_research_set(proposal),
    do: Enum.find(proposal_research_sets(proposal), &(&1.status == "evidence_review"))

  defp proposal_specs(proposal) do
    proposal
    |> Map.get(:simulation_specs, [])
    |> List.wrap()
    |> Enum.sort_by(& &1.version, :desc)
  end

  defp active_proposal_spec(proposal),
    do: Enum.find(proposal_specs(proposal), &(&1.status == "designing"))

  defp reviewable_proposal_spec(proposal),
    do: Enum.find(proposal_specs(proposal), &(&1.status == "ready_for_review"))

  defp latest_proposal_spec(proposal), do: List.first(proposal_specs(proposal))

  defp approved_proposal_artifact(proposal),
    do: Enum.find(proposal_artifacts(proposal), &(&1.status == "approved"))

  defp active_proposal_artifact(proposal),
    do: Enum.find(proposal_artifacts(proposal), &(&1.status == "generating"))

  defp reviewable_proposal_artifact(proposal),
    do: Enum.find(proposal_artifacts(proposal), &(&1.status == "ready_for_review"))

  defp latest_proposal_artifact(proposal), do: List.first(proposal_artifacts(proposal))

  defp simulation_spec_identity(spec_payload) do
    domain = simulation_spec_value(spec_payload, "domain")
    rendering = simulation_spec_value(spec_payload, "rendering_mode")

    [domain, rendering]
    |> Enum.reject(&(&1 in [nil, "", "—"]))
    |> Enum.map_join(" · ", &humanize_check_key/1)
    |> case do
      "" -> gettext("Recorded design")
      identity -> identity
    end
  end

  defp simulation_spec_value(spec_payload, key) do
    case map_string_key(spec_payload, key, nil) do
      value when is_binary(value) and value != "" -> value
      value when is_number(value) -> to_string(value)
      value when is_map(value) -> simulation_summary_value(value)
      _ -> "—"
    end
  end

  defp simulation_spec_list(spec_payload, key) do
    spec_payload
    |> map_string_key(key, [])
    |> List.wrap()
    |> Enum.map(&simulation_summary_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp simulation_spec_guided_tasks(spec_payload) do
    spec_payload
    |> map_string_key("guided_tasks", [])
    |> List.wrap()
    |> Enum.map(fn task ->
      map_string_key(task, "prompt", map_string_key(task, "task", ""))
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp simulation_spec_parameters(spec_payload),
    do:
      spec_payload
      |> map_string_key("parameters", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

  defp simulation_parameter_range(parameter) do
    minimum = map_string_key(parameter, "min", "—")
    maximum = map_string_key(parameter, "max", "—")
    step = map_string_key(parameter, "step", "—")
    "#{minimum}–#{maximum} (step #{step})"
  end

  defp simulation_parameter_unit(parameter) do
    cond do
      map_string_key(parameter, "unitless", false) == true -> gettext("Unitless")
      true -> map_string_key(parameter, "unit", "—")
    end
  end

  defp simulation_capi_declarations(spec_payload, direction) do
    spec_payload
    |> map_string_key("capi_manifest", %{})
    |> map_string_key(direction, [])
    |> List.wrap()
    |> Enum.map(fn declaration ->
      key = map_string_key(declaration, "key", "?")
      type = map_string_key(declaration, "type", "?")
      "#{key}: #{type}"
    end)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp simulation_accessibility_summary(spec_payload) do
    spec_payload
    |> map_string_key("accessibility", %{})
    |> enrichment_evidence_rows()
    |> Enum.map_join("; ", fn row -> "#{row.label}: #{row.value}" end)
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp simulation_summary_value(value) when is_binary(value), do: value
  defp simulation_summary_value(value) when is_number(value), do: to_string(value)

  defp simulation_summary_value(value) when is_map(value) do
    map_string_key(
      value,
      "text",
      map_string_key(
        value,
        "description",
        map_string_key(value, "prompt", map_string_key(value, "guidance", ""))
      )
    )
  end

  defp simulation_summary_value(_value), do: ""

  defp simulation_artifact_repair_count(artifact) do
    artifact
    |> Map.get(:generation_metadata, %{})
    |> map_string_key("builder_repair_count", 0)
  end

  defp simulation_artifact_attempts(artifact) do
    case Map.get(artifact, :attempts, []) do
      attempts when is_list(attempts) -> Enum.sort_by(attempts, & &1.attempt_number)
      _ -> []
    end
  end

  defp simulation_attempt_findings(attempt) do
    attempt
    |> Map.get(:findings, [])
    |> List.wrap()
    |> Enum.map(fn finding ->
      code =
        map_string_key(
          finding,
          "code",
          map_string_key(finding, "category", gettext("validation finding"))
        )

      message = map_string_key(finding, "message", "")
      path = map_string_key(finding, "path", "")
      details = map_string_key(finding, "details", nil)

      [
        code,
        message,
        path,
        if(is_nil(details), do: nil, else: enrichment_evidence_value(details))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(": ")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> case do
      "" -> gettext("No findings recorded")
      findings -> findings
    end
  end

  defp simulation_artifact_size(%{byte_size: size}) when is_integer(size) do
    cond do
      size >= 1_000_000 -> "#{Float.round(size / 1_000_000, 1)} MB"
      size >= 1_000 -> "#{Float.round(size / 1_000, 1)} KB"
      true -> "#{size} B"
    end
  end

  defp simulation_artifact_size(_artifact), do: "—"

  defp short_content_hash(value) when is_binary(value) and byte_size(value) > 12,
    do: String.slice(value, 0, 12) <> "…"

  defp short_content_hash(value) when is_binary(value), do: value
  defp short_content_hash(_value), do: "—"

  defp simulation_preview_url(%{status: status, validation_status: validation_status} = artifact) do
    if status in ["ready_for_review", "approved"] and validation_status == "passed" do
      case Enrichment.artifact_url(artifact, allow_preview: true) do
        {:ok, url} -> url
        {:error, _reason} -> nil
      end
    end
  end

  defp simulation_preview_url(_artifact), do: nil

  defp proposal_kind_label("generated_simulation"), do: gettext("Generated simulation")
  defp proposal_kind_label("existing_simulation"), do: gettext("Existing simulation")
  defp proposal_kind_label("external_resource"), do: gettext("Curated resource")
  defp proposal_kind_label("article"), do: gettext("Article")
  defp proposal_kind_label("video"), do: gettext("Video")
  defp proposal_kind_label(kind), do: humanize_check_key(kind)

  defp proposal_state_label(state), do: humanize_check_key(state)

  defp proposal_can_approve?(proposal, lesson, capabilities) do
    case proposal.kind do
      "generated_simulation" ->
        proposal.state == "evidence_review" and lesson.plan_mode == "advanced" and
          capabilities.generated_enabled and not is_nil(reviewable_research_set(proposal))

      _ ->
        proposal.state == "proposed" and proposal.research_status == "completed" and
          is_map(proposal.research_evidence) and
          map_size(proposal.research_evidence) > 0 and
          is_binary(curated_resource_url(proposal))
    end
  end

  defp curated_resource_url(%{resource_url: url}) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port} = uri
      when is_binary(host) and host != "" and (is_nil(port) or port == 443) ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp curated_resource_url(_proposal), do: nil

  defp proposal_can_generate?(proposal, capabilities) do
    proposal.kind == "generated_simulation" and
      proposal.state in ["designing", "artifact_review"] and
      capabilities.generated_available and is_nil(active_proposal_artifact(proposal)) and
      is_nil(reviewable_proposal_artifact(proposal)) and
      is_nil(approved_proposal_artifact(proposal)) and
      not is_nil(reviewable_proposal_spec(proposal))
  end

  defp proposal_can_design?(proposal, capabilities) do
    proposal.kind == "generated_simulation" and proposal.state == "designing" and
      capabilities.generated_enabled and is_nil(active_proposal_spec(proposal)) and
      is_nil(reviewable_proposal_spec(proposal))
  end

  defp enrichment_evidence_rows(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, item} ->
      %{label: humanize_check_key(to_string(key)), value: enrichment_evidence_value(item)}
    end)
  end

  defp enrichment_evidence_rows(_), do: []

  defp enrichment_evidence_value(value) when is_binary(value), do: value
  defp enrichment_evidence_value(value) when is_number(value), do: to_string(value)
  defp enrichment_evidence_value(value) when is_boolean(value), do: to_string(value)

  defp enrichment_evidence_value(values) when is_list(values),
    do: Enum.map_join(values, ", ", &enrichment_evidence_value/1)

  defp enrichment_evidence_value(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> gettext("Recorded")
    end
  end

  defp enrichment_evidence_value(_), do: gettext("Recorded")

  defp lesson_flow_steps(lesson) do
    base =
      [
        if(lesson_learning_objectives(lesson) != [],
          do: %{"role" => "orientation", "label" => gettext("Orientation and objectives")}
        )
      ]
      |> Enum.reject(&is_nil/1)

    middle =
      if v6_lesson?(lesson) do
        lesson
        |> plan_experience_stages()
        |> Enum.map(fn stage ->
          role = stage |> plan_item_strings("roles") |> List.first() || "exploration"

          %{
            "role" => role,
            "label" => plan_item_value(stage, "title", humanize_check_key(role))
          }
        end)
      else
        questions = plan_questions(lesson)

        groups = plan_content_groups(lesson)

        group_ids =
          groups
          |> Enum.map(&plan_item_value(&1, "id"))
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        interleaved =
          groups
          |> Enum.flat_map(fn group ->
            group_id = plan_item_value(group, "id")

            instruction = %{
              "role" => "instruction",
              "label" =>
                plan_item_value(
                  group,
                  "title",
                  gettext("Source evidence")
                )
            }

            nearby_practice =
              questions
              |> Enum.filter(&(plan_item_value(&1, "placement_after_section_id") == group_id))
              |> Enum.map(fn _question ->
                %{
                  "role" => "practice",
                  "label" => gettext("Learn by doing")
                }
              end)

            [instruction | nearby_practice]
          end)

        unplaced_practice =
          questions
          |> Enum.reject(fn question ->
            MapSet.member?(
              group_ids,
              plan_item_value(question, "placement_after_section_id")
            )
          end)
          |> Enum.map(fn _question ->
            %{"role" => "practice", "label" => gettext("Learn by doing")}
          end)

        interleaved ++ unplaced_practice
      end

    ending =
      [
        if(plan_synthesis(lesson) not in [%{}, nil],
          do: %{"role" => "synthesis", "label" => gettext("Synthesis")}
        ),
        %{"role" => "attribution", "label" => gettext("Attribution")}
      ]
      |> Enum.reject(&is_nil/1)

    base ++ middle ++ ending
  end

  defp rich_lesson_material?(lesson) do
    plan_content_groups(lesson) != [] or
      plan_media(lesson) != [] or
      plan_synthesis(lesson) not in [%{}, nil] or
      plan_questions(lesson) != []
  end

  defp lesson_instructional_word_count(lesson) do
    group_text =
      lesson
      |> plan_content_groups()
      |> Enum.flat_map(fn group ->
        [
          plan_item_value(group, "title")
          | Enum.map(v5_group_source_blocks(group), &v5_source_block_preview_text/1)
        ]
      end)

    group_text
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp lesson_coverage(lesson) do
    coverage = plan_content(lesson, "coverage_manifest", %{})

    available =
      map_string_key(
        coverage,
        "available_source_block_ids",
        map_string_key(coverage, "available_block_ids", [])
      )
      |> List.wrap()

    included =
      map_string_key(
        coverage,
        "included_source_block_ids",
        map_string_key(coverage, "included_block_ids", [])
      )
      |> List.wrap()

    excluded = map_string_key(coverage, "excluded_blocks", []) |> List.wrap()

    %{
      available: length(available),
      accounted_for:
        (included ++ Enum.map(excluded, &map_string_key(&1, "id", nil)))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> length()
    }
  end

  defp failed_lesson_checks(lesson) do
    lesson
    |> lesson_checks()
    |> map_string_key("results", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and map_string_key(&1, "status", "pending") == "failed"))
  end

  defp lesson_needs_author_review?(lesson) do
    Map.get(lesson, :status) in ["needs_repair", "needs_attention"] or
      check_status(lesson_checks(lesson)) == "failed" or
      failed_lesson_checks(lesson) != []
  end

  defp check_type_label(result) do
    case map_string_key(result, "check_type", "") do
      "source_fidelity" -> gettext("Source fidelity")
      "pedagogy_assessment" -> gettext("Pedagogy and assessment")
      "torus_accessibility" -> gettext("Torus and accessibility")
      other -> humanize_check_key(other)
    end
  end

  defp check_issues(result) do
    result
    |> map_string_key("findings", %{})
    |> map_string_key("issues", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp check_repair_items(result) do
    result
    |> map_string_key("repair_plan", %{})
    |> case do
      repair_plan when is_map(repair_plan) ->
        repair_plan
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.flat_map(fn {key, value} ->
          case repair_value_text(value) do
            nil -> []
            text -> [{humanize_check_key(key), text}]
          end
        end)

      _ ->
        []
    end
  end

  defp humanize_check_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp repair_value_text(value) when value in [nil, false, "", []], do: nil
  defp repair_value_text(true), do: gettext("Required")
  defp repair_value_text(value) when is_binary(value), do: value
  defp repair_value_text(value) when is_number(value), do: to_string(value)

  defp repair_value_text(values) when is_list(values) do
    cond do
      Enum.all?(values, &is_binary/1) -> Enum.join(values, ", ")
      Enum.all?(values, &is_number/1) -> Enum.join(values, "–")
      true -> gettext("%{count} items to review", count: length(values))
    end
  end

  defp repair_value_text(value) when is_map(value),
    do: gettext("%{count} fields to review", count: map_size(value))

  defp repair_value_text(_value), do: gettext("Review required")

  defp lesson_rejection_reason(lesson) do
    case latest_plan(lesson) do
      %{rejection_reason: reason} when is_binary(reason) -> String.trim(reason)
      _ -> ""
    end
  end

  defp question_type_label(question) do
    case map_string_key(question, "type", "short_answer") do
      "multiple_choice" -> gettext("Multiple choice")
      "short_answer" -> gettext("Reflection")
      type -> type
    end
  end

  defp plan_item_value(item, key, fallback \\ "")

  defp plan_item_value(item, key, fallback) when is_map(item),
    do: map_string_key(item, key, fallback)

  defp plan_item_value(_item, _key, fallback), do: fallback

  defp map_string_key(map, key, fallback) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fallback, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp map_string_key(_map, _key, fallback), do: fallback

  defp plan_item_strings(item, key) do
    item
    |> plan_item_value(key, [])
    |> normalize_plan_strings()
  end

  defp plan_item_maps(item, key) do
    item
    |> plan_item_value(key, [])
    |> normalize_plan_maps()
  end

  defp normalize_plan_maps(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp normalize_plan_maps(_), do: []

  defp normalize_plan_strings(items) when is_list(items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_plan_strings(_), do: []

  defp question_text(%{} = question),
    do: Map.get(question, "prompt") || Map.get(question, :prompt) || ""

  defp question_text(question) when is_binary(question), do: question
  defp question_text(_), do: ""

  defp lesson_checks(lesson) do
    latest_plan(lesson)
    |> case do
      %{checks_snapshot: checks} when is_map(checks) -> checks
      _ -> %{}
    end
  end

  defp check_status(checks) do
    checks["status"] || checks[:status] || "pending"
  end

  defp run_progress(run) do
    progress = run.progress || %{}
    totals = progress["stage_totals"] || progress[:stage_totals] || []

    case totals do
      totals when is_list(totals) -> totals
      _ -> []
    end
  end

  defp run_persisted_counts(run) do
    counts =
      run.progress
      |> Kernel.||(%{})
      |> map_string_key("counts", %{})

    [
      {gettext("Sections extracted"), map_string_key(counts, "sections_extracted", nil)},
      {gettext("Source blocks extracted"),
       map_string_key(counts, "source_blocks_extracted", nil)},
      {gettext("Source figures discovered"),
       map_string_key(counts, "source_assets_discovered", nil)},
      {gettext("Plans checked"), map_string_key(counts, "plans_checked", nil)},
      {gettext("Figures staged"), map_string_key(counts, "assets_staged", nil)},
      {gettext("Lessons created"), map_string_key(counts, "lessons_created", nil)}
    ]
    |> Enum.filter(fn {_label, count} -> is_integer(count) and count >= 0 end)
  end

  defp run_error_message(run) do
    error = run.error || %{}

    error["message"] || error[:message] || error["reason"] || error[:reason] ||
      gettext("The import stopped before the course could be created.")
  end

  defp run_has_error?(run), do: is_map(run.error) and map_size(run.error) > 0

  defp run_error_phase(run) do
    run.error
    |> Kernel.||(%{})
    |> map_string_key("phase", "")
    |> to_string()
  end

  defp run_error_media_ids(run) do
    run.error
    |> Kernel.||(%{})
    |> map_string_key("source_media_ids", [])
    |> normalize_plan_strings()
  end

  defp attention_lesson_titles(run) do
    run
    |> units_for_run()
    |> Enum.flat_map(&lessons_for_unit/1)
    |> Enum.filter(&(&1.status in ["needs_attention", "needs_repair"]))
    |> Enum.map(& &1.title)
    |> Enum.filter(&is_binary/1)
  end

  defp lesson_sections(lesson),
    do: if(is_list(lesson.source_sections), do: lesson.source_sections, else: [])

  defp lesson_evidence_links(lesson),
    do: if(is_list(lesson.source_evidence_links), do: lesson.source_evidence_links, else: [])

  defp question_count(lesson) do
    if v6_lesson?(lesson) do
      length(plan_experience_activities(lesson))
    else
      lesson
      |> plan_questions()
      |> length()
    end
  end

  defp run_recoverable?(run) do
    error = run.error || %{}
    Map.get(error, "recoverable", Map.get(error, :recoverable, true)) != false
  end

  defp lesson_plan_payload(attrs, lesson) do
    existing_content =
      case latest_plan(lesson) do
        %{content_payload: content} when is_map(content) -> content
        _ -> %{}
      end

    learning_objectives =
      attrs
      |> Map.get("learning_objectives", Map.get(attrs, "objective", ""))
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    learning_objectives =
      case learning_objectives do
        [] -> lesson_learning_objectives(lesson)
        objectives -> objectives
      end

    content =
      existing_content
      |> Map.delete(:objective)
      |> Map.delete(:learning_objectives)
      |> Map.delete(:narrative)
      |> Map.put("objective", List.first(learning_objectives) || "")
      |> Map.put("learning_objectives", learning_objectives)
      |> Map.put("narrative", Map.get(attrs, "narrative", ""))
      |> maybe_update_current_orientation(Map.get(attrs, "narrative", ""))

    existing_questions = plan_questions(lesson)

    questions =
      case {Map.get(attrs, "question_order"), Map.get(attrs, "question_prompts")} do
        {order, prompts} when is_list(order) and is_map(prompts) ->
          existing_by_id =
            Map.new(existing_questions, fn question ->
              {to_string(map_string_key(question, "id", "")), question}
            end)

          order
          |> Enum.map(&to_string/1)
          |> Enum.flat_map(fn id ->
            prompt = prompts |> Map.get(id, "") |> String.trim()

            if prompt == "" do
              []
            else
              [question_with_prompt(Map.get(existing_by_id, id), prompt)]
            end
          end)

        _ ->
          attrs
          |> Map.get("questions", "")
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.with_index()
          |> Enum.map(fn {prompt, index} ->
            existing_questions
            |> Enum.at(index)
            |> question_with_prompt(prompt)
          end)
      end

    %{
      "content_payload" => content,
      "questions_payload" => %{"items" => questions}
    }
  end

  defp maybe_update_current_orientation(%{"schema_version" => schema} = content, overview)
       when schema in [5, 6] and is_binary(overview) do
    put_in(content, [Access.key("orientation", %{}), "overview"], String.trim(overview))
  end

  defp maybe_update_current_orientation(content, _overview), do: content

  defp plan_questions(lesson) do
    case latest_plan(lesson) do
      %{questions_payload: %{"items" => questions}} when is_list(questions) ->
        questions

      _ ->
        []
    end
  end

  defp question_with_prompt(%{} = question, prompt) do
    question
    |> Map.delete(:prompt)
    |> Map.put("prompt", prompt)
    |> Map.put_new("type", "short_answer")
  end

  defp question_with_prompt(_question, prompt),
    do: %{"prompt" => prompt, "type" => "short_answer"}

  defp media_preview_url(media) do
    url =
      map_string_key(media, "project_url", nil) ||
        map_string_key(media, "source_url", nil) ||
        map_string_key(media, "src", nil)

    case URI.parse(url || "") do
      %URI{scheme: "https", host: host, userinfo: nil}
      when host in ["openstax.org", "assets.openstax.org"] ->
        url

      %URI{scheme: nil, host: nil, path: "/" <> _path} ->
        url

      _ ->
        nil
    end
  end

  defp course_import_error(:invalid_openstax_url),
    do:
      gettext(
        "Use a full OpenStax book link, such as https://openstax.org/details/books/introduction-computer-science."
      )

  defp course_import_error(:run_in_progress),
    do: gettext("A course import is already running for this curriculum.")

  defp course_import_error(:feature_disabled),
    do: gettext("OpenStax course import is not available for this project.")

  defp course_import_error(:project_root_not_empty),
    do:
      gettext(
        "Create the OpenStax course in a project with an empty root curriculum. Move or remove the existing curriculum first."
      )

  defp course_import_error(:target_must_be_project_root),
    do: gettext("OpenStax course import can only create a course at the project root.")

  defp course_import_error(:lessons_pending_approval),
    do: gettext("Approve every lesson before creating the course.")

  defp course_import_error(:bulk_approval_disabled),
    do: gettext("Bulk lesson approval is not enabled in this environment.")

  defp course_import_error({:approved_enrichment_incomplete, _proposal_ids}),
    do:
      gettext(
        "Complete, reject, or omit every approved simulation proposal before creating the course."
      )

  defp course_import_error(:simulation_generation_unavailable),
    do:
      gettext(
        "Simulation generation is not available. Enable the project flag and configure the generator, isolated container runtime, and artifact storage, or omit this proposal."
      )

  defp course_import_error(:simulation_generation_in_progress),
    do: gettext("This proposal already has a simulation preview in progress or awaiting review.")

  defp course_import_error(:simulation_author_feedback_too_long),
    do: gettext("Keep simulation builder guidance to 2,000 characters or fewer.")

  defp course_import_error(:generated_enrichment_requires_advanced_authoring),
    do: gettext("Generated simulations can be approved only for Advanced Author lessons.")

  defp course_import_error(:research_unavailable),
    do: gettext("Curated-resource research is not configured for this project.")

  defp course_import_error(:curated_enrichment_not_ready),
    do:
      gettext(
        "Complete curated-resource research and review its HTTPS link and evidence before approving this proposal."
      )

  defp course_import_error(:artifact_invalid),
    do: gettext("This simulation artifact has not passed all required validation checks.")

  defp course_import_error(:no_lessons_to_approve),
    do: gettext("There are no lesson plans available to approve yet.")

  defp course_import_error(:no_chapters_selected),
    do: gettext("Select at least one chapter before continuing the course plan.")

  defp course_import_error(:not_recoverable),
    do: gettext("This import cannot be retried. Start a new run from the selected book link.")

  defp course_import_error(:retry_job_already_active),
    do:
      gettext(
        "A background worker is still handling this import. Refresh its status before retrying."
      )

  defp course_import_error(:lesson_plan_busy),
    do:
      gettext(
        "That lesson is being regenerated. Wait for its new plan before editing, approving, or requesting another regeneration."
      )

  defp course_import_error(:v5_quality_gate_not_approved),
    do: gettext("The independent critic has not approved this Basic lesson yet.")

  defp course_import_error(:v5_quality_hard_blockers),
    do: gettext("Resolve every hard blocker before approving this Basic lesson.")

  defp course_import_error(:v5_quality_repairs_pending),
    do: gettext("Resolve every required critic repair before approving this Basic lesson.")

  defp course_import_error(:v5_source_coverage_incomplete),
    do: gettext("The Basic lesson does not yet account for every required source block.")

  defp course_import_error(:v5_quality_checks_failed),
    do: gettext("The Basic lesson still has failed deterministic checks.")

  defp course_import_error(:plan_schema_version_mismatch),
    do: gettext("The lesson plan does not match this import's Basic-page schema version.")

  defp course_import_error(:project_publication_changed),
    do: gettext("The project changed while the import was starting. Refresh and try again.")

  defp course_import_error({:invalid_status, _, _}),
    do: gettext("That action is not ready yet. The import status has changed; please try again.")

  defp course_import_error({:compile_failed, _}),
    do:
      gettext(
        "One or more lesson plans could not be compiled. Edit or regenerate the affected plan, approve it again, and retry."
      )

  defp course_import_error(_),
    do: gettext("The OpenStax import could not continue. Please try again.")
end
