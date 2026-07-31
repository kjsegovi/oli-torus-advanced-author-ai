defmodule OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLive do
  use OliWeb, :live_view

  alias Ecto.Changeset
  alias Oli.GoogleDocs.SlidesClient
  alias Oli.GoogleSlides.Credentials
  alias Oli.GoogleSlides.ImportRuns.PubSub
  alias Oli.Publishing.AuthoringResolver
  alias Oli.ScopedFeatureFlags
  alias OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLive.SlidePreviewAdapter
  alias OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLive.WorkflowAdapter
  alias Phoenix.Component

  @form_name :google_slides_import
  @poll_interval_ms 1_000
  @polling_statuses [:analyzing, :generating]
  @source_coverage_review_limit 200

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    project = socket.assigns.project
    author = socket.assigns.current_author
    root_container = AuthoringResolver.root_container(project.slug)
    container_slug = Map.get(params, "container_slug")
    container = resolve_container(project.slug, container_slug, root_container)

    case container do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The selected curriculum container could not be found."))
         |> push_navigate(to: ~p"/workspaces/course_author/#{project.slug}/curriculum")}

      container ->
        available? = available?(project, author)

        {:ok,
         assign(socket,
           active: :curriculum,
           resource_slug: project.slug,
           resource_title: project.title,
           page_title: gettext("Import Google Slides | %{project}", project: project.title),
           project: project,
           author: author,
           container: container,
           return_path: curriculum_path(project.slug, container_slug),
           import_path: import_path(project.slug, container_slug),
           available?: available?,
           availability_message: availability_message(project, available?),
           service_account_email: Credentials.get_client_email(project.id),
           form: import_form(),
           run: nil,
           error_message: nil,
           poll_timer: nil,
           subscribed_run_id: nil,
           source_preview: nil,
           source_preview_image: nil,
           source_preview_zoomed?: false
         )}
    end
  end

  def available?(project, author), do: WorkflowAdapter.available?(project, author)

  @impl Phoenix.LiveView
  def handle_params(%{"run_id" => requested_run_id}, _uri, socket) do
    if requested_run_id == run_id(socket.assigns.run) do
      {:noreply, socket}
    else
      case WorkflowAdapter.get_run(
             socket.assigns.project,
             socket.assigns.author,
             requested_run_id
           ) do
        {:ok, run} ->
          target_container_resource_id = run_value(run, :target_container_resource_id)

          if is_nil(target_container_resource_id) or
               target_container_resource_id ==
                 run_value(socket.assigns.container, :resource_id) do
            {:noreply, socket |> assign(error_message: nil) |> assign_run(run)}
          else
            {:noreply,
             assign(
               socket,
               error_message: gettext("This import belongs to a different curriculum container.")
             )}
          end

        {:error, reason} ->
          {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

        other ->
          {:noreply, assign(socket, error_message: translate_workflow_error(other))}
      end
    end
  end

  def handle_params(_params, _uri, socket) do
    case WorkflowAdapter.get_active_run(
           socket.assigns.project,
           socket.assigns.author,
           run_value(socket.assigns.container, :resource_id)
         ) do
      {:ok, run} ->
        socket =
          socket
          |> assign(error_message: nil)
          |> assign_run(run)

        socket =
          if connected?(socket) do
            push_patch(socket,
              to: import_run_path(socket.assigns.import_path, run_id(run)),
              replace: true
            )
          else
            socket
          end

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> cancel_poll()
         |> assign(run: nil, error_message: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

      other ->
        {:noreply, assign(socket, error_message: translate_workflow_error(other))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate_import", %{"google_slides_import" => attrs}, socket) do
    changeset =
      attrs
      |> import_changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: Component.to_form(changeset, as: @form_name))}
  end

  def handle_event("analyze", %{"google_slides_import" => attrs}, socket) do
    cond do
      not socket.assigns.available? ->
        {:noreply,
         assign(socket,
           error_message:
             socket.assigns.availability_message ||
               gettext("Google Slides import is not available.")
         )}

      socket.assigns.run && run_status(socket.assigns.run) in @polling_statuses ->
        {:noreply, socket}

      true ->
        changeset =
          attrs
          |> import_changeset()
          |> Map.put(:action, :validate)

        case Changeset.apply_action(changeset, :validate) do
          {:ok, options} ->
            case WorkflowAdapter.start_analysis(
                   socket.assigns.project,
                   socket.assigns.container,
                   socket.assigns.author,
                   options
                 ) do
              {:ok, run} ->
                {:noreply,
                 socket
                 |> assign(
                   form: Component.to_form(changeset, as: @form_name),
                   error_message: nil
                 )
                 |> assign_run(run)
                 |> push_patch(to: import_run_path(socket.assigns.import_path, run_id(run)))}

              {:error, reason} ->
                {:noreply,
                 assign(socket,
                   form: Component.to_form(changeset, as: @form_name),
                   error_message: translate_workflow_error(reason)
                 )}

              other ->
                {:noreply,
                 assign(socket,
                   error_message: translate_workflow_error({:unexpected_result, other})
                 )}
            end

          {:error, invalid_changeset} ->
            {:noreply, assign(socket, form: Component.to_form(invalid_changeset, as: @form_name))}
        end
    end
  end

  def handle_event("submit_answers", %{"answers" => answers}, socket) when is_map(answers) do
    with run when not is_nil(run) <- socket.assigns.run,
         {:ok, updated_run} <-
           WorkflowAdapter.submit_answers(run, socket.assigns.author, normalize_answers(answers)) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated_run)}
    else
      nil ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

      other ->
        {:noreply, assign(socket, error_message: translate_workflow_error(other))}
    end
  end

  def handle_event("choose_structure", %{"decision" => decision}, socket) do
    with %{} = run <- socket.assigns.run,
         proposal_version when is_integer(proposal_version) <-
           get_in(analysis_state(run), ["structure_proposal", "version"]),
         {:ok, updated_run} <-
           WorkflowAdapter.submit_structure_decision(
             run,
             socket.assigns.author,
             proposal_version,
             decision
           ) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated_run)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

      _ ->
        {:noreply,
         assign(socket,
           error_message: gettext("The lesson structure proposal changed. Refresh and try again.")
         )}
    end
  end

  def handle_event("continue_analysis_budget", _params, socket) do
    with %{} = run <- socket.assigns.run,
         checkpoint_version when is_integer(checkpoint_version) <-
           analysis_state(run)["checkpoint_version"],
         {:ok, updated_run} <-
           WorkflowAdapter.approve_analysis_continuation(
             run,
             socket.assigns.author,
             checkpoint_version
           ) do
      {:noreply, socket |> assign(error_message: nil) |> assign_run(updated_run)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

      _ ->
        {:noreply,
         assign(socket,
           error_message: gettext("The analysis checkpoint changed. Refresh and try again.")
         )}
    end
  end

  def handle_event("open_source_preview", %{"question_id" => question_id}, socket) do
    with %{} = run <- socket.assigns.run,
         %{} = question <- find_question(run, question_id),
         %{} = preview <- question_source_preview(question, run) do
      {:noreply, load_source_preview(socket, run, preview)}
    else
      _ ->
        {:noreply, source_preview_error(socket)}
    end
  end

  def handle_event("open_review_source_preview", %{"slide_id" => slide_id}, socket) do
    with %{} = run <- socket.assigns.run,
         %{} = preview <- source_slide_preview(run, slide_id) do
      {:noreply, load_source_preview(socket, run, preview)}
    else
      _ ->
        {:noreply, source_preview_error(socket)}
    end
  end

  def handle_event("close_source_preview", _params, socket) do
    {:noreply,
     assign(socket,
       source_preview: nil,
       source_preview_image: nil,
       source_preview_zoomed?: false
     )}
  end

  def handle_event("toggle_source_preview_zoom", _params, socket) do
    if socket.assigns.source_preview do
      {:noreply, assign(socket, source_preview_zoomed?: !socket.assigns.source_preview_zoomed?)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_lesson", _params, socket) do
    case socket.assigns.run do
      nil ->
        {:noreply, socket}

      run ->
        plan_version = run_value(run, :plan_version, 0)

        with {:ok, approved_run} <- approve_plan(run, socket.assigns.author, plan_version),
             {:ok, generating_run} <-
               WorkflowAdapter.generate(approved_run, socket.assigns.author, plan_version) do
          {:noreply, socket |> assign(error_message: nil) |> assign_run(generating_run)}
        else
          {:error, reason} ->
            {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

          other ->
            {:noreply, assign(socket, error_message: translate_workflow_error(other))}
        end
    end
  end

  def handle_event("refresh_run", _params, socket), do: refresh_run(socket)

  def handle_event("discard_import", _params, socket) do
    case socket.assigns.run do
      nil ->
        {:noreply, socket}

      run ->
        case WorkflowAdapter.cancel(run, socket.assigns.author) do
          {:ok, _cancelled_run} ->
            {:noreply,
             socket
             |> cancel_poll()
             |> assign(run: nil, error_message: nil, form: import_form())
             |> push_patch(to: socket.assigns.import_path)}

          {:error, reason} ->
            {:noreply, assign(socket, error_message: translate_workflow_error(reason))}

          other ->
            {:noreply, assign(socket, error_message: translate_workflow_error(other))}
        end
    end
  end

  def handle_event("reset_import", _params, socket) do
    {:noreply,
     socket
     |> cancel_poll()
     |> assign(run: nil, error_message: nil, form: import_form())
     |> push_patch(to: socket.assigns.import_path)}
  end

  defp load_source_preview(socket, run, preview) do
    project = socket.assigns.project
    slide_id = preview.slide_id

    socket
    |> assign(
      source_preview: preview,
      source_preview_zoomed?: false,
      error_message: nil
    )
    |> assign_async(
      :source_preview_image,
      fn ->
        case SlidePreviewAdapter.fetch(project, run, slide_id) do
          {:ok, thumbnail} -> {:ok, %{source_preview_image: thumbnail}}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :slide_preview_unavailable}
        end
      end,
      reset: true
    )
  end

  defp source_preview_error(socket) do
    assign(
      socket,
      error_message:
        gettext("The source slide preview could not be opened. Review the original presentation.")
    )
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh_import_run, socket) do
    socket = assign(socket, poll_timer: nil)
    refresh_run(socket)
  end

  def handle_info({:google_slides_import_run_updated, %{run_id: run_id}}, socket) do
    if run_id == run_id(socket.assigns.run) do
      refresh_run(socket)
    else
      {:noreply, socket}
    end
  end

  defp refresh_run(socket) do
    case run_id(socket.assigns.run) do
      nil ->
        {:noreply, socket}

      run_id ->
        case WorkflowAdapter.get_run(
               socket.assigns.project,
               socket.assigns.author,
               run_id
             ) do
          {:ok, run} ->
            {:noreply, socket |> assign(error_message: nil) |> assign_run(run)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(error_message: translate_workflow_error(reason))
             |> cancel_poll()
             |> schedule_refresh()}

          other ->
            {:noreply,
             socket
             |> assign(error_message: translate_workflow_error(other))
             |> cancel_poll()
             |> schedule_refresh()}
        end
    end
  end

  defp approve_plan(run, author, plan_version) do
    case WorkflowAdapter.approve_plan(run, author, plan_version) do
      :ok -> {:ok, run}
      {:ok, approved_run} -> {:ok, approved_run}
      other -> other
    end
  end

  defp assign_run(socket, run) do
    socket
    |> cancel_poll()
    |> assign(run: run)
    |> maybe_subscribe()
    |> schedule_refresh()
  end

  defp maybe_subscribe(socket) do
    run_id = run_id(socket.assigns.run)

    if (connected?(socket) and run_id) && socket.assigns.subscribed_run_id != run_id do
      case PubSub.subscribe(run_id) do
        :ok -> assign(socket, subscribed_run_id: run_id)
        _ -> socket
      end
    else
      socket
    end
  rescue
    _ -> socket
  end

  defp schedule_refresh(socket) do
    if connected?(socket) and run_status(socket.assigns.run) in @polling_statuses do
      timer = Process.send_after(self(), :refresh_import_run, @poll_interval_ms)
      assign(socket, poll_timer: timer)
    else
      socket
    end
  end

  defp cancel_poll(%{assigns: %{poll_timer: timer}} = socket) when is_reference(timer) do
    Process.cancel_timer(timer)
    assign(socket, poll_timer: nil)
  end

  defp cancel_poll(socket), do: socket

  defp import_form do
    %{}
    |> import_changeset()
    |> Component.to_form(as: @form_name)
  end

  defp import_changeset(attrs) do
    {%{presentation_url: nil, layout_mode: "responsive"},
     %{presentation_url: :string, layout_mode: :string}}
    |> Changeset.cast(attrs, [:presentation_url, :layout_mode])
    |> Changeset.update_change(:presentation_url, &normalize_string/1)
    |> Changeset.validate_required([:presentation_url, :layout_mode])
    |> Changeset.validate_inclusion(:layout_mode, ["responsive", "pixel"])
    |> validate_presentation_url()
  end

  defp validate_presentation_url(changeset) do
    Changeset.validate_change(changeset, :presentation_url, fn :presentation_url, value ->
      case SlidesClient.get_presentation_id(value) do
        {:ok, _presentation_id} ->
          []

        _ ->
          [
            presentation_url:
              gettext("Enter a complete Google Slides URL containing `/presentation/d/`.")
          ]
      end
    end)
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value), do: value

  defp normalize_answers(answers) do
    Map.new(answers, fn {key, value} ->
      {to_string(key), if(is_binary(value), do: String.trim(value), else: value)}
    end)
  end

  defp resolve_container(_project_slug, nil, root_container), do: root_container

  defp resolve_container(project_slug, container_slug, _root_container) do
    AuthoringResolver.from_revision_slug(project_slug, container_slug)
  end

  defp curriculum_path(project_slug, nil),
    do: ~p"/workspaces/course_author/#{project_slug}/curriculum"

  defp curriculum_path(project_slug, container_slug),
    do: ~p"/workspaces/course_author/#{project_slug}/curriculum/#{container_slug}"

  defp import_path(project_slug, nil),
    do: ~p"/workspaces/course_author/#{project_slug}/curriculum/import/google-slides"

  defp import_path(project_slug, container_slug),
    do:
      ~p"/workspaces/course_author/#{project_slug}/curriculum/#{container_slug}/import/google-slides"

  defp import_run_path(base_path, run_id),
    do: base_path <> "?" <> URI.encode_query(%{run_id: run_id})

  defp availability_message(project, available?) do
    cond do
      available? ->
        nil

      not ScopedFeatureFlags.enabled?(:google_slides_import, project) ->
        gettext("Google Slides import is not enabled for this project.")

      not Credentials.configured?(project.id) ->
        gettext(
          "Google Slides import is not configured. Add a Google service account in project settings."
        )

      true ->
        gettext(
          "The AI-assisted Google Slides import workflow is not configured or you do not have access."
        )
    end
  rescue
    _ -> gettext("Google Slides import is not available.")
  end

  defp run_status(nil), do: nil
  defp run_status(run), do: run |> run_value(:status) |> normalize_status()

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "analyzing" -> :analyzing
      "awaiting_structure" -> :awaiting_structure
      "awaiting_budget" -> :awaiting_budget
      "awaiting_answers" -> :awaiting_answers
      "ready_for_review" -> :ready_for_review
      "generating" -> :generating
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      _ -> :unknown
    end
  end

  defp normalize_status(_), do: :unknown

  defp run_value(run, key, default \\ nil)

  defp run_value(nil, _key, default), do: default

  defp run_value(run, key, default) when is_map(run) do
    Map.get(run, key, Map.get(run, Atom.to_string(key), default))
  end

  defp run_value(_run, _key, default), do: default

  defp run_id(run), do: run_value(run, :id)

  defp questions(run) do
    case run_value(run, :questions, []) do
      questions when is_list(questions) -> questions
      _ -> []
    end
  end

  defp lesson_plan(run), do: run_value(run, :lesson_plan, %{}) || %{}

  defp plan_lessons(%{"kind" => "google_slides_lesson_plan_set", "lessons" => lessons})
       when is_list(lessons),
       do: lessons

  defp plan_lessons(%{} = plan), do: [plan]
  defp plan_lessons(_plan), do: []

  defp chunked_analysis?(run), do: run_value(run, :analysis_version, 1) >= 2

  defp analysis_state(run), do: run_value(run, :analysis_state, %{}) || %{}

  defp analysis_total_units(run), do: analysis_state(run)["total_units"]
  defp analysis_completed_units(run), do: analysis_state(run)["completed_units"] || 0
  defp analysis_determinate?(run), do: is_integer(analysis_total_units(run))

  defp analysis_progress_value(run) do
    min(analysis_completed_units(run), analysis_total_units(run) || 0)
  end

  defp analysis_progress_width(run) do
    total = analysis_total_units(run)

    if is_integer(total) and total > 0 do
      "#{Float.round(analysis_progress_value(run) / total * 100, 1)}%"
    else
      nil
    end
  end

  defp analysis_progress_text(run) do
    state = analysis_state(run)
    total = state["total_units"]
    completed = state["completed_units"] || 0
    range = state["current_slide_range"]

    slide_count =
      get_in(run_value(run, :source_snapshot, %{}) || %{}, ["presentation", "slideCount"])

    cond do
      not is_integer(total) ->
        gettext("Reading presentation structure")

      is_map(range) and range["start"] > 0 ->
        gettext(
          "Analyzing slides %{first}–%{last} of %{slides} · Step %{step} of %{total}",
          first: range["start"],
          last: range["end"],
          slides: slide_count || range["end"],
          step: min(completed + 1, total),
          total: total
        )

      true ->
        gettext("Analysis step %{step} of %{total}",
          step: min(completed + 1, total),
          total: total
        )
    end
  end

  defp structure_proposal(run), do: analysis_state(run)["structure_proposal"] || %{}
  defp split_lessons(run), do: get_in(structure_proposal(run), ["split", "lessons"]) || []

  defp budget_usage(run) do
    state = analysis_state(run)
    used = get_in(state, ["accumulated_usage", "prompt_tokens"]) || 0
    limit = state["budget_limit_tokens"] || 2_000_000
    {format_token_count(used), format_token_count(limit)}
  end

  defp budget_tranche(run) do
    run
    |> analysis_state()
    |> Map.get("budget_tranche_tokens", 2_000_000)
    |> format_token_count()
  end

  defp format_token_count(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_token_count(value), do: to_string(value)

  defp warnings(run) do
    case run_value(run, :warnings, []) do
      warnings when is_list(warnings) -> warnings
      _ -> []
    end
  end

  defp error_detail(run) do
    run
    |> run_value(:error, %{})
    |> case do
      message when is_binary(message) ->
        message

      %{} = error ->
        error
        |> then(&(run_value(&1, :message) || run_value(&1, :reason)))
        |> display_optional_value()

      _ ->
        nil
    end
  end

  defp error_reference(run) do
    run
    |> run_value(:error, %{})
    |> case do
      %{} = error ->
        error
        |> run_value(:code)
        |> display_optional_value()

      _ ->
        nil
    end
  end

  defp result_revision_slug(run) do
    result = run_value(run, :result, %{}) || %{}
    result_revision = run_value(run, :result_revision, %{}) || %{}

    run_value(run, :result_revision_slug) ||
      run_value(run, :revision_slug) ||
      run_value(result, :revision_slug) ||
      run_value(result, :result_revision_slug) ||
      run_value(result_revision, :slug)
  end

  defp plan_title(plan) do
    case plan_lessons(plan) do
      [single] ->
        lesson = run_value(single, :lesson, %{}) || %{}

        run_value(lesson, :title) ||
          run_value(single, :title) ||
          run_value(single, :lesson_title) ||
          gettext("Untitled imported lesson")

      lessons when lessons != [] ->
        gettext("%{count} imported lessons", count: length(lessons))

      _ ->
        gettext("Untitled imported lesson")
    end
  end

  defp plan_screens(plan) do
    Enum.flat_map(plan_lessons(plan), fn lesson_plan ->
      lesson = run_value(lesson_plan, :lesson, %{}) || %{}

      case run_value(lesson, :screens, run_value(lesson_plan, :screens, [])) do
        screens when is_list(screens) -> screens
        _ -> []
      end
    end)
  end

  defp plan_objectives(plan) do
    Enum.flat_map(plan_lessons(plan), fn lesson_plan ->
      case run_value(lesson_plan, :objectives, []) do
        objectives when is_list(objectives) ->
          objectives

        %{} = objectives ->
          objective_group(objectives, :mapped) ++ objective_group(objectives, :proposed)

        _ ->
          []
      end
    end)
  end

  defp objective_group(objectives, key) do
    case run_value(objectives, key, []) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp plan_assumptions(plan) do
    Enum.flat_map(plan_lessons(plan), fn lesson_plan ->
      case run_value(lesson_plan, :assumptions, []) do
        assumptions when is_list(assumptions) -> assumptions
        _ -> []
      end
    end)
  end

  defp plan_variables(plan) do
    Enum.flat_map(plan_lessons(plan), fn lesson_plan ->
      case run_value(lesson_plan, :variables, []) do
        variables when is_list(variables) -> variables
        _ -> []
      end
    end)
  end

  defp source_coverage(plan) do
    Enum.flat_map(plan_lessons(plan), fn lesson_plan ->
      case run_value(lesson_plan, :sourceCoverage, []) do
        coverage when is_list(coverage) -> coverage
        %{} = coverage -> record_list(coverage, :elements)
        _ -> []
      end
    end)
  end

  defp source_coverage_count(coverage, status) do
    Enum.count(coverage, &(normalize_coverage_value(run_value(&1, :status)) == status))
  end

  defp source_coverage_fidelity_count(coverage, fidelity) do
    Enum.count(coverage, &(normalize_coverage_value(run_value(&1, :fidelity)) == fidelity))
  end

  defp source_coverage_review_entries(coverage) do
    coverage
    |> Enum.filter(&source_coverage_review_required?/1)
    |> Enum.take(@source_coverage_review_limit)
  end

  defp source_coverage_review_total(coverage),
    do: Enum.count(coverage, &source_coverage_review_required?/1)

  defp source_coverage_review_remaining(coverage) do
    max(source_coverage_review_total(coverage) - @source_coverage_review_limit, 0)
  end

  defp source_coverage_review_required?(entry) do
    status = normalize_coverage_value(run_value(entry, :status))
    fidelity = normalize_coverage_value(run_value(entry, :fidelity))

    run_value(entry, :reviewRequired, false) == true or
      status != "included" or
      fidelity not in ["full", "native"]
  end

  defp source_coverage_heading(entry, index) do
    type = run_value(entry, :sourceType, "source element") |> display_value()
    summary = run_value(entry, :summary) |> display_optional_value()

    case summary do
      nil ->
        gettext("Element %{number}: %{type}", number: index + 1, type: type)

      summary ->
        gettext("Element %{number}: %{type} — %{summary}",
          number: index + 1,
          type: type,
          summary: bound_text(summary, 180)
        )
    end
  end

  defp source_coverage_status(entry) do
    case normalize_coverage_value(run_value(entry, :status)) do
      "included" -> gettext("Included")
      "author_omitted" -> gettext("Omitted by author")
      "unaccounted" -> gettext("Needs a decision")
      other when is_binary(other) and other != "" -> display_value(other)
      _ -> gettext("Unknown")
    end
  end

  defp source_coverage_fidelity(entry) do
    fidelity =
      entry
      |> run_value(:fidelity, "unspecified")
      |> display_value()

    disposition =
      run_value(entry, :appliedDisposition) ||
        run_value(entry, :suggestedDisposition)

    case display_optional_value(disposition) do
      nil -> fidelity
      ^fidelity -> fidelity
      disposition -> "#{fidelity} · #{disposition}"
    end
  end

  defp source_coverage_source(entry, run) do
    source_reference_label(
      %{
        "slideId" => run_value(entry, :slideId),
        "objectId" => run_value(entry, :objectId)
      },
      run
    )
  end

  defp source_coverage_targets(entry) do
    case run_value(entry, :targets, []) do
      targets when is_list(targets) and targets != [] ->
        targets
        |> Enum.map_join(", ", fn target ->
          [
            run_value(target, :kind),
            run_value(target, :screenKey),
            run_value(target, :key)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(" · ", &display_value/1)
        end)
        |> bound_text(480)

      _ ->
        gettext("No Torus target")
    end
  end

  defp normalize_coverage_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_coverage_value(value) when is_binary(value), do: value
  defp normalize_coverage_value(_value), do: nil

  defp plan_layout_label(plan) do
    plan = List.first(plan_lessons(plan)) || %{}

    layout =
      plan
      |> run_value(:lesson, %{})
      |> run_value(:layout, %{})

    mode = run_value(layout, :mode, "responsive") |> display_value()
    profile = run_value(layout, :styleProfile, "torus-default") |> display_value()

    gettext("Layout: %{mode}; style profile: %{profile}", mode: mode, profile: profile)
  end

  defp screen_title(screen, index) do
    run_value(screen, :title) ||
      run_value(screen, :screen_title) ||
      gettext("Screen %{number}", number: index + 1)
  end

  defp screen_contents_label(screen) do
    gettext(
      "%{parts} content part(s), %{interactions} interaction(s), %{rules} adaptivity rule(s)",
      parts: list_count(run_value(screen, :parts, [])),
      interactions: list_count(run_value(screen, :interactions, [])),
      rules: list_count(run_value(screen, :adaptivity, []))
    )
  end

  defp list_count(values) when is_list(values), do: length(values)
  defp list_count(_values), do: 0

  defp screen_parts(screen), do: record_list(screen, :parts)
  defp screen_interactions(screen), do: record_list(screen, :interactions)
  defp screen_adaptivity(screen), do: record_list(screen, :adaptivity)

  defp record_list(record, key) do
    case run_value(record, key, []) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp source_label(screen, run) do
    case review_source_previews(screen, run) do
      [] ->
        nil

      previews ->
        previews
        |> Enum.map_join(", ", & &1.label)
        |> then(&gettext("Based on %{slides}", slides: &1))
        |> bound_text(480)
    end
  end

  defp source_reference_label(reference, run) when is_map(reference) do
    slide =
      reference
      |> run_value(:slideId)
      |> then(&source_slide_preview(run, &1))
      |> case do
        %{label: label} -> label
        _ -> gettext("Source slide")
      end

    evidence =
      run_value(reference, :evidence) ||
        run_value(reference, :description) ||
        run_value(reference, :reference)

    [slide, if(present_value?(evidence), do: bounded_value(evidence, 240))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp source_reference_label(_reference, _run), do: gettext("Source slide")

  defp record_source_label(record, key, run) do
    case run_value(record, key, []) do
      values when is_list(values) and values != [] ->
        values
        |> Enum.map_join("; ", &source_reference_label(&1, run))
        |> bound_text(480)

      value when not is_nil(value) ->
        source_reference_label(value, run)

      _ ->
        gettext("Not provided")
    end
  end

  defp part_heading(part, index) do
    kind = run_value(part, :kind, "content") |> display_value()
    key = run_value(part, :key)

    if key do
      gettext("Part %{number}: %{kind} (%{key})",
        number: index + 1,
        kind: kind,
        key: display_value(key)
      )
    else
      gettext("Part %{number}: %{kind}", number: index + 1, kind: kind)
    end
  end

  defp part_content(part) do
    content = run_value(part, :content, %{})

    preferred =
      if is_map(content) do
        run_value(content, :text) ||
          run_value(content, :value) ||
          run_value(content, :html) ||
          run_value(content, :src)
      end

    bounded_value(preferred || content)
  end

  defp media_part?(part),
    do: run_value(part, :kind) in ~w(image audio video chart shape line word_art)

  defp media_accessibility_fields(part) do
    accessibility = run_value(part, :accessibility, %{}) || %{}

    case run_value(part, :kind) do
      kind when kind in ~w(image chart shape line word_art) ->
        [{gettext("Alternative text"), run_value(accessibility, :altText)}]

      "video" ->
        [
          {gettext("Captions"), run_value(accessibility, :captions)},
          {gettext("Transcript"), run_value(accessibility, :transcript)}
        ]

      "audio" ->
        [
          {gettext("Transcript"), run_value(accessibility, :transcript)},
          {gettext("Captions"), run_value(accessibility, :captions)}
        ]

      _ ->
        []
    end
  end

  defp accessibility_value(value) do
    if present_value?(value), do: bounded_value(value), else: gettext("Not provided")
  end

  defp interaction_heading(interaction, index) do
    key = run_value(interaction, :key)

    if key do
      gettext("Interaction %{number}: %{key}", number: index + 1, key: display_value(key))
    else
      gettext("Interaction %{number}", number: index + 1)
    end
  end

  defp interaction_prompt(interaction),
    do: bounded_value(run_value(interaction, :prompt) || gettext("Not provided"))

  defp interaction_component(interaction),
    do: bounded_value(run_value(interaction, :componentKey) || gettext("Not provided"))

  defp interaction_configuration(interaction),
    do: bounded_value(run_value(interaction, :configuration, %{}), 720)

  defp interaction_evaluation_policy(interaction),
    do: bounded_value(run_value(interaction, :evaluationPolicy, %{}), 720)

  defp interaction_correct_response(interaction) do
    cond do
      run_value(interaction, :manualGrading, false) == true ->
        gettext("Manual grading")

      is_nil(run_value(interaction, :correctResponse)) ->
        gettext("Not provided")

      true ->
        bounded_value(run_value(interaction, :correctResponse))
    end
  end

  defp interaction_scoring(interaction) do
    scoring = run_value(interaction, :scoring, %{}) || %{}
    mode = run_value(scoring, :mode, "formative") |> display_value()
    points = run_value(scoring, :points, 0) |> display_value()

    gettext("%{mode}; %{points} point(s)", mode: mode, points: points)
  end

  defp static_feedback_entries(interaction) do
    interaction
    |> run_value(:feedback, %{})
    |> run_value(:static, %{})
    |> case do
      feedback when is_map(feedback) ->
        feedback
        |> Enum.map(fn {key, value} -> {display_value(key), bounded_value(value)} end)
        |> Enum.sort_by(&elem(&1, 0))

      _ ->
        []
    end
  end

  defp runtime_ai(interaction) do
    interaction
    |> run_value(:feedback, %{})
    |> run_value(:runtimeAi, %{})
    |> case do
      runtime when is_map(runtime) -> runtime
      _ -> %{}
    end
  end

  defp runtime_ai_status(interaction) do
    runtime = runtime_ai(interaction)

    cond do
      run_value(runtime, :enabled, false) == true and
          run_value(runtime, :authorOptIn, false) == true ->
        gettext("Enabled with author opt-in")

      run_value(runtime, :enabled, false) == true ->
        gettext("Enabled; author opt-in is missing")

      run_value(runtime, :recommended, false) == true ->
        gettext("Recommended, not enabled")

      true ->
        gettext("Off")
    end
  end

  defp runtime_ai_prompt(interaction) do
    value = runtime_ai(interaction) |> run_value(:prompt)
    if present_value?(value), do: bounded_value(value), else: nil
  end

  defp runtime_ai_fallback(interaction) do
    value = runtime_ai(interaction) |> run_value(:staticFallbackKey)
    if present_value?(value), do: bounded_value(value, 160), else: nil
  end

  defp adaptivity_heading(rule, index) do
    case run_value(rule, :key) do
      nil -> gettext("Rule %{number}", number: index + 1)
      key -> gettext("Rule %{number}: %{key}", number: index + 1, key: display_value(key))
    end
  end

  defp adaptivity_condition(rule), do: bounded_value(run_value(rule, :condition, %{}), 420)
  defp adaptivity_action(rule), do: bounded_value(run_value(rule, :action, %{}), 420)

  defp variable_heading(variable, index) do
    key = run_value(variable, :key)
    type = run_value(variable, :type, "unknown")

    gettext("Variable %{number}: %{key} (%{type})",
      number: index + 1,
      key: display_value(key || gettext("Unnamed")),
      type: display_value(type)
    )
  end

  defp variable_initial_value(variable),
    do: bounded_value(run_value(variable, :initialValue))

  defp variable_purpose(variable),
    do: bounded_value(run_value(variable, :purpose) || gettext("Not provided"))

  defp objective_label(objective) when is_binary(objective), do: objective

  defp objective_label(objective),
    do:
      run_value(objective, :title) ||
        run_value(objective, :label) ||
        run_value(objective, :text) ||
        gettext("Objective")

  defp assumption_label(assumption) when is_binary(assumption), do: assumption
  defp assumption_label(assumption), do: run_value(assumption, :message) || inspect(assumption)

  defp question_id(question, index),
    do: run_value(question, :id) || run_value(question, :key) || "question-#{index + 1}"

  defp question_prompt(question, run) do
    case question_code(question, run) do
      "source_inventory_unaccounted" ->
        gettext("Should this slide content be kept in the imported lesson?")

      _ ->
        run_value(question, :prompt) ||
          run_value(question, :question) ||
          gettext("Additional information is required.")
    end
  end

  defp question_explanation(question, run) do
    run_value(question, :explanation) ||
      question_explanation_for_code(question_code(question, run))
  end

  defp question_explanation_for_code("source_inventory_unaccounted"),
    do:
      gettext(
        "This content appears in the original presentation, but it is not represented in the draft lesson yet. Keep it if learners need its meaning or appearance. Leave it out only when the content is decorative, duplicated, or intentionally unnecessary."
      )

  defp question_explanation_for_code(_code),
    do:
      gettext(
        "Torus cannot safely complete this part of the lesson plan without your input. Review the source context before answering."
      )

  defp question_subject(question, run) do
    run_value(question, :subject) ||
      question
      |> question_details(run)
      |> run_value(:summary)
      |> source_summary_label()
  end

  defp question_recommendation(question),
    do:
      question
      |> then(&(run_value(&1, :recommended_answer) || run_value(&1, :recommendation)))
      |> display_optional_value()

  defp question_source(question, run) do
    case question_source_preview(question, run) do
      %{label: label} ->
        label

      _ ->
        question
        |> then(&(run_value(&1, :source_label) || run_value(&1, :source)))
        |> human_question_source()
    end
  end

  defp question_options(question) do
    case run_value(question, :options, []) do
      options when is_list(options) -> options
      _ -> []
    end
  end

  defp question_fields(question) do
    case run_value(question, :fields, []) do
      fields when is_list(fields) and fields != [] -> fields
      _ -> [question]
    end
  end

  defp option_value(option) when is_binary(option), do: option
  defp option_value(option), do: run_value(option, :value) || run_value(option, :id) || ""

  defp option_label(option) when is_binary(option), do: option

  defp option_label(option),
    do: run_value(option, :label) || run_value(option, :value) || gettext("Option")

  defp question_option_label(question, run, option) do
    case {question_code(question, run), option_value(option)} do
      {"source_inventory_unaccounted", "include"} ->
        gettext("Keep this content in the lesson")

      {"source_inventory_unaccounted", "omit"} ->
        gettext("Leave this content out")

      _ ->
        option_label(option)
    end
  end

  defp find_question(run, question_id) when is_binary(question_id) do
    run
    |> questions()
    |> Enum.with_index()
    |> Enum.find_value(fn {question, index} ->
      if to_string(question_id(question, index)) == question_id, do: question
    end)
  end

  defp find_question(_run, _question_id), do: nil

  defp question_source_preview(question, run) do
    with refs when is_list(refs) <- question_source_refs(question, run),
         %{} = ref <- Enum.find(refs, &present_value?(run_value(&1, :slideId))),
         slide_id when is_binary(slide_id) <- run_value(ref, :slideId) do
      object_id = run_value(ref, :objectId)

      geometry =
        question
        |> question_details(run)
        |> run_value(:geometry)

      source_slide_preview(run, slide_id,
        object_id: object_id,
        geometry: geometry,
        subject: question_subject(question, run)
      )
    else
      _ -> nil
    end
  end

  defp review_source_previews(screen, run) do
    screen
    |> run_value(:sourceRefs, [])
    |> case do
      refs when is_list(refs) -> refs
      _ -> []
    end
    |> Enum.map(&run_value(&1, :slideId))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&source_slide_preview(run, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp source_slide_preview(run, slide_id, opts \\ [])

  defp source_slide_preview(run, slide_id, opts)
       when is_binary(slide_id) and slide_id != "" do
    snapshot = run_value(run, :source_snapshot, %{}) || %{}
    slides = run_value(snapshot, :slides, [])

    case Enum.with_index(slides)
         |> Enum.find(fn {candidate, _index} ->
           run_value(candidate, :objectId) == slide_id
         end) do
      {slide, slide_position} ->
        slide_number =
          case {run_value(snapshot, :schemaVersion), run_value(slide, :index)} do
            {3, index} when is_integer(index) and index > 0 -> index
            {_version, index} when is_integer(index) and index >= 0 -> index + 1
            _ -> slide_position + 1
          end

        title = run_value(slide, :title) |> display_optional_value()
        object_id = Keyword.get(opts, :object_id)
        inventory_entry = source_inventory_entry(slide, object_id)
        geometry = Keyword.get(opts, :geometry) || run_value(inventory_entry, :geometry)
        presentation = run_value(snapshot, :presentation, %{}) || %{}
        page_size = run_value(presentation, :pageSize, %{}) || %{}

        %{
          slide_id: slide_id,
          object_id: object_id,
          slide_number: slide_number,
          title: title,
          label: source_slide_label(slide_number, title),
          subject: Keyword.get(opts, :subject),
          overlay_style: source_overlay_style(page_size, geometry),
          original_url: source_slide_url(run, slide_id)
        }

      nil ->
        nil
    end
  end

  defp source_slide_preview(_run, _slide_id, _opts), do: nil

  defp question_source_refs(question, run) do
    case run_value(question, :sourceRefs, []) do
      refs when is_list(refs) and refs != [] ->
        refs

      _ ->
        question
        |> question_blocker(run)
        |> run_value(:sourceRefs, [])
    end
  end

  defp question_details(question, run) do
    case run_value(question, :details, %{}) do
      details when is_map(details) and map_size(details) > 0 ->
        details

      _ ->
        question
        |> question_blocker(run)
        |> run_value(:details, %{})
    end
  end

  defp question_blocker(question, run) do
    question_key = run_value(question, :key) || run_value(question, :id)

    blockers =
      run
      |> lesson_plan()
      |> plan_lessons()
      |> Enum.flat_map(&(run_value(&1, :blockers, []) || []))

    case blockers do
      values when is_list(values) ->
        Enum.find(values, &(run_value(&1, :key) == question_key))

      _ ->
        nil
    end
  end

  defp question_code(question, run),
    do: run_value(question, :code) || run_value(question_blocker(question, run), :code)

  defp human_question_source(nil), do: nil

  defp human_question_source(value) do
    value = display_optional_value(value)

    case value do
      "Source slide(s):" <> _machine_reference -> nil
      _ -> value
    end
  end

  defp source_inventory_entry(slide, object_id) when is_binary(object_id) do
    slide
    |> run_value(:sourceInventory, [])
    |> Enum.find(&(run_value(&1, :objectId) == object_id))
  end

  defp source_inventory_entry(_slide, _object_id), do: nil

  defp source_slide_label(slide_number, title) when is_binary(title) and title != "",
    do: gettext("Slide %{number} — %{title}", number: slide_number, title: title)

  defp source_slide_label(slide_number, _title),
    do: gettext("Slide %{number}", number: slide_number)

  defp source_summary_label(summary) when is_binary(summary) and summary != "",
    do: bound_text(summary, 320)

  defp source_summary_label(summary) when is_map(summary) do
    [:text, :title, :description, :label]
    |> Enum.find_value(fn key ->
      case run_value(summary, key) do
        value when is_binary(value) and value != "" -> bound_text(value, 320)
        _ -> nil
      end
    end)
  end

  defp source_summary_label(_summary), do: nil

  defp source_slide_url(run, slide_id) do
    case run_value(run, :presentation_url) do
      url when is_binary(url) and url != "" ->
        url
        |> URI.parse()
        |> Map.put(:fragment, "slide=id.#{slide_id}")
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp source_overlay_style(page_size, geometry)
       when is_map(page_size) and is_map(geometry) do
    with page_width when is_number(page_width) and page_width > 0 <-
           dimension_in_emu(run_value(page_size, :width)),
         page_height when is_number(page_height) and page_height > 0 <-
           dimension_in_emu(run_value(page_size, :height)),
         width when is_number(width) and width > 0 <-
           dimension_in_emu(run_value(geometry, :width)),
         height when is_number(height) and height > 0 <-
           dimension_in_emu(run_value(geometry, :height)),
         %{} = transform <- run_value(geometry, :transform, %{}),
         translate_x when is_number(translate_x) <-
           transform_translation_in_emu(transform, :translateX),
         translate_y when is_number(translate_y) <-
           transform_translation_in_emu(transform, :translateY) do
      scale_x = numeric_value(run_value(transform, :scaleX), 1.0)
      scale_y = numeric_value(run_value(transform, :scaleY), 1.0)
      shear_x = numeric_value(run_value(transform, :shearX), 0.0)
      shear_y = numeric_value(run_value(transform, :shearY), 0.0)

      {left, top, right, bottom} =
        affine_bounds(
          width,
          height,
          scale_x,
          scale_y,
          shear_x,
          shear_y,
          translate_x,
          translate_y
        )

      left = clamp(left, 0.0, page_width)
      top = clamp(top, 0.0, page_height)
      right = clamp(right, left, page_width)
      bottom = clamp(bottom, top, page_height)

      case {right - left, bottom - top} do
        {bounded_width, bounded_height} when bounded_width > 0 and bounded_height > 0 ->
          "left: #{percent(left, page_width)}%; top: #{percent(top, page_height)}%; " <>
            "width: #{percent(bounded_width, page_width)}%; height: #{percent(bounded_height, page_height)}%;"

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp source_overlay_style(_page_size, _geometry), do: nil

  defp affine_bounds(
         width,
         height,
         scale_x,
         scale_y,
         shear_x,
         shear_y,
         translate_x,
         translate_y
       ) do
    points =
      [{0.0, 0.0}, {width, 0.0}, {0.0, height}, {width, height}]
      |> Enum.map(fn {x, y} ->
        {
          scale_x * x + shear_x * y + translate_x,
          shear_y * x + scale_y * y + translate_y
        }
      end)

    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))

    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  defp dimension_in_emu(dimension) when is_map(dimension) do
    magnitude = run_value(dimension, :magnitude)
    unit = run_value(dimension, :unit, "EMU")

    case {magnitude, unit} do
      {value, "EMU"} when is_number(value) -> value * 1.0
      {value, "PT"} when is_number(value) -> value * 12_700.0
      _ -> nil
    end
  end

  defp dimension_in_emu(_dimension), do: nil

  defp transform_translation_in_emu(transform, key) do
    value = run_value(transform, key)

    case {value, run_value(transform, :unit, "EMU")} do
      {number, "EMU"} when is_number(number) -> number * 1.0
      {number, "PT"} when is_number(number) -> number * 12_700.0
      _ -> nil
    end
  end

  defp numeric_value(value, _default) when is_number(value), do: value * 1.0
  defp numeric_value(_value, default), do: default

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp percent(value, total),
    do: value |> Kernel./(total) |> Kernel.*(100.0) |> Float.round(3)

  defp source_preview_canvas_style(image, zoomed?) do
    width =
      image
      |> run_value(:width, 1_600)
      |> case do
        value when is_integer(value) and value > 0 -> value
        _ -> 1_600
      end

    case zoomed? do
      true -> "width: #{width}px;"
      false -> "width: min(#{width}px, 100%);"
    end
  end

  defp source_preview_image_alt(preview),
    do: gettext("Original %{slide}", slide: preview.label)

  defp warning_message(warning) when is_binary(warning), do: warning

  defp warning_message(warning),
    do:
      warning
      |> then(&(run_value(&1, :message) || run_value(&1, :code) || gettext("Import warning")))
      |> display_value()

  defp display_optional_value(nil), do: nil
  defp display_optional_value(value), do: display_value(value)

  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_atom(value), do: Atom.to_string(value)
  defp display_value(value) when is_number(value), do: to_string(value)
  defp display_value(value), do: bounded_value(value)

  defp bounded_value(value, max_length \\ 320)
  defp bounded_value(nil, _max_length), do: gettext("Not provided")
  defp bounded_value(value, max_length) when is_binary(value), do: bound_text(value, max_length)
  defp bounded_value(value, _max_length) when is_atom(value), do: Atom.to_string(value)
  defp bounded_value(value, _max_length) when is_number(value), do: to_string(value)

  defp bounded_value(value, max_length) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> bound_text(encoded, max_length)
      _ -> value |> inspect(limit: 12, printable_limit: max_length) |> bound_text(max_length)
    end
  end

  defp bounded_value(value, max_length),
    do: value |> inspect(limit: 12, printable_limit: max_length) |> bound_text(max_length)

  defp bound_text(value, max_length) when is_binary(value) do
    normalized = String.trim(value)

    if String.length(normalized) > max_length do
      String.slice(normalized, 0, max_length) <> "…"
    else
      normalized
    end
  end

  defp present_value?(nil), do: false
  defp present_value?(""), do: false
  defp present_value?([]), do: false
  defp present_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_value?(_value), do: true

  defp translate_workflow_error(:workflow_unavailable),
    do: gettext("The AI-assisted Google Slides import workflow is not configured.")

  defp translate_workflow_error(:import_unavailable),
    do:
      gettext(
        "Google Slides import is no longer available for this project. Check access and configuration before trying again."
      )

  defp translate_workflow_error(:feature_disabled),
    do: gettext("Google Slides import is not enabled for this project.")

  defp translate_workflow_error(:service_account_not_configured),
    do: gettext("A Google Slides service account must be configured before importing.")

  defp translate_workflow_error(:presentation_not_accessible),
    do:
      gettext(
        "The presentation could not be accessed. Share it with the configured service account and try again."
      )

  defp translate_workflow_error(:stale_plan),
    do: gettext("The lesson plan changed. Review the latest plan before generating the lesson.")

  defp translate_workflow_error(:stale_source),
    do: gettext("The Google Slides deck changed. Analyze it again before generating the lesson.")

  defp translate_workflow_error(:import_in_progress),
    do: gettext("This curriculum container already has an active Google Slides import.")

  defp translate_workflow_error({:invalid_answer, _question_id, message})
       when is_binary(message),
       do: message

  defp translate_workflow_error({:source_snapshot_exceeds_limits, _limits}),
    do:
      gettext(
        "This presentation is too large to analyze safely in one import. Split it into smaller lesson decks and try again."
      )

  defp translate_workflow_error({:input_token_budget_exhausted, _maximum, _used, _requested}),
    do:
      gettext(
        "The AI analysis reached its safety limit. Split the presentation into a smaller lesson deck and try again."
      )

  defp translate_workflow_error({:unexpected_result, _}),
    do: gettext("The import workflow returned an unexpected response. Try again.")

  defp translate_workflow_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp translate_workflow_error(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(fn
      %{"message" => message} when is_binary(message) -> [message]
      %{message: message} when is_binary(message) -> [message]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.take(3)
    |> Enum.join(" ")
    |> case do
      "" -> gettext("The answer could not be applied. Review it and try again.")
      message -> message
    end
  end

  defp translate_workflow_error(reason) when is_binary(reason), do: reason

  defp translate_workflow_error(_reason),
    do: gettext("The Google Slides import could not continue. Try again or contact support.")
end
