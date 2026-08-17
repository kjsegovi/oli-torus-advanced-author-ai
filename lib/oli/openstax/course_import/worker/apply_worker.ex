defmodule Oli.OpenStax.CourseImport.Worker.ApplyWorker do
  @moduledoc """
  Atomically applies the dry-run-compiled OpenStax course hierarchy.

  Units, source-faithful lesson pages, embedded activities, the root
  revision, project attribution, lesson statuses, and run completion all commit
  in one database transaction.
  """

  use Oban.Worker,
    queue: :course_import,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Oli.Accounts.Author
  alias Oli.Authoring.Broadcaster
  alias Oli.Authoring.Course
  alias Oli.Authoring.Course.{Project, ProjectAttributes}
  alias Oli.Authoring.Editing.ActivityEditor
  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    AuthoringCompiler,
    Compiler,
    Lesson,
    MediaIngestor,
    Run,
    Unit
  }

  alias Oli.Publishing
  alias Oli.Publishing.{AuthoringResolver, ChangeTracker}
  alias Oli.Repo
  alias Oli.Resources.{ResourceType, Revision, ScoringStrategy}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with {:ok, run} <- CourseImport.fetch_run(run_id) do
      perform_run(run, attempt, max_attempts)
    else
      {:error, :not_found} -> {:discard, :run_not_found}
    end
  rescue
    exception ->
      retry_or_fail(
        run_id,
        attempt,
        max_attempts,
        {:internal_exception, Exception.message(exception)}
      )
  end

  defp perform_run(%Run{status: :applying} = run, attempt, max_attempts) do
    with {:ok, _run} <-
           CourseImport.set_progress(
             run.id,
             %{"stage" => "applying", "work_state" => "running"},
             :applying
           ),
         {:ok, detailed_run} <- CourseImport.run_with_resources(run.id),
         {:ok, checkpoint} <- CourseImport.compile_checkpoint(detailed_run),
         {:ok, media_urls} <- MediaIngestor.required_media_urls(run.id),
         {:ok, compiled} <-
           Compiler.dry_run(detailed_run,
             media_urls: media_urls,
             attribution: CourseImport.source_attribution(detailed_run)
           ),
         true <-
           MediaIngestor.required_media_ids(compiled) == checkpoint["required_media_ids"] do
      case apply_atomically(run.id, compiled) do
        {:ok, result} ->
          CourseImport.announce_run_update(result.completed_run)
          broadcast_created_resources(result)
          :ok

        {:error, reason} ->
          retry_or_fail(run.id, attempt, max_attempts, reason)
      end
    else
      false -> retry_or_fail(run.id, attempt, max_attempts, :required_media_selection_changed)
      {:error, reason} -> retry_or_fail(run.id, attempt, max_attempts, reason)
    end
  end

  defp perform_run(%Run{status: :completed}, _attempt, _max_attempts), do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts)
       when status in [:failed, :cancelled],
       do: :ok

  defp perform_run(%Run{status: status}, _attempt, _max_attempts),
    do: {:discard, {:invalid_run_status, status}}

  defp apply_atomically(run_id, compiled) do
    Repo.transaction(
      fn ->
        run =
          Repo.one!(
            from(run in Run,
              where: run.id == ^run_id,
              lock: "FOR UPDATE"
            )
          )

        ensure!(run.status == :applying, {:invalid_run_status, run.status})
        :ok = unwrap(CourseImport.ensure_apply_preconditions(run))

        project = Repo.get!(Project, run.project_id)
        author = Repo.get!(Author, run.author_id)
        publication = Publishing.project_working_publication(project.slug)

        ensure!(
          publication.root_resource_id == run.target_root_container_resource_id,
          :invalid_target
        )

        :ok = unwrap(ChangeTracker.lock_project_root(publication, run.id))

        root =
          AuthoringResolver.from_resource_id(
            project.slug,
            run.target_root_container_resource_id
          )

        ensure!(match?(%Revision{}, root), :root_container_not_found)
        ensure!((root.children || []) == [], :project_root_not_empty)

        created = create_units(project, author, compiled["units"])

        # A final read catches out-of-band curriculum edits that bypassed the
        # shared root lock. Any mismatch rolls back every resource above.
        latest_root =
          AuthoringResolver.from_resource_id(
            project.slug,
            run.target_root_container_resource_id
          )

        ensure!((latest_root.children || []) == [], :project_root_changed_during_apply)

        root_revision =
          unwrap(
            ChangeTracker.track_revision(
              project.slug,
              latest_root,
              %{
                children: Enum.map(created.units, & &1.revision.resource_id),
                author_id: author.id
              },
              course_import_run_id: run.id
            )
          )

        attribution_project =
          Repo.one!(
            from(candidate in Project,
              where: candidate.id == ^project.id,
              lock: "FOR UPDATE"
            )
          )

        attribution = openstax_attribution(run)
        updated_project = set_openstax_attribution!(attribution_project, attribution)
        mark_applied!(run.id)

        result_payload = %{
          "lessons_applied" => length(created.lesson_pages),
          "units_applied" => length(created.units),
          "unit_assessments_applied" => length(created.assessment_pages),
          "unit_resource_ids" => Enum.map(created.units, & &1.revision.resource_id),
          "lesson_resource_ids" => Enum.map(created.lesson_pages, & &1.resource_id),
          "assessment_resource_ids" => Enum.map(created.assessment_pages, & &1.resource_id),
          "root_revision_id" => root_revision.id,
          "license" => Map.take(attribution, ["license_type", "source_provider", "source_url"]),
          "completed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        completed_run = unwrap(CourseImport.complete_apply_in_transaction(run, result_payload))

        %{
          completed_run: completed_run,
          project: updated_project,
          root_revision: root_revision,
          units: created.units,
          lesson_pages: created.lesson_pages,
          assessment_pages: created.assessment_pages,
          activity_revisions: created.activity_revisions
        }
      end,
      timeout: :timer.minutes(25)
    )
  rescue
    exception -> {:error, {:apply_exception, Exception.message(exception)}}
  end

  defp create_units(project, author, compiled_units) do
    Enum.reduce(
      compiled_units,
      %{
        units: [],
        lesson_pages: [],
        assessment_pages: [],
        activity_revisions: []
      },
      fn unit, acc ->
        lesson_results =
          Enum.map(unit["lessons"], &create_lesson_page(project, author, &1))

        children = Enum.map(lesson_results, & &1.page.resource_id)

        unit_revision =
          create_container(project, author, unit["title"], children)

        %{
          units: acc.units ++ [%{unit_id: unit["unit_id"], revision: unit_revision}],
          lesson_pages: acc.lesson_pages ++ Enum.map(lesson_results, & &1.page),
          assessment_pages: acc.assessment_pages,
          activity_revisions:
            acc.activity_revisions ++
              Enum.flat_map(lesson_results, & &1.activities)
        }
      end
    )
  end

  defp create_lesson_page(project, author, artifact) do
    activities =
      create_compiled_activities(
        artifact["activities"],
        project,
        author,
        artifact["title"]
      )

    content =
      artifact["page_content_template"]
      |> AuthoringCompiler.realize_page(activity_ids(activities))
      |> unwrap()

    page =
      create_page(
        project,
        author,
        artifact["title"],
        content,
        false
      )

    %{page: page, activities: Enum.map(activities, & &1.revision)}
  end

  defp create_compiled_activities(activity_specs, project, author, title)
       when is_list(activity_specs) do
    activity_specs
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, index} ->
      case ActivityEditor.create(
             project.slug,
             spec["activity_type_slug"],
             author,
             spec["model"],
             [],
             "embedded",
             spec["title"] || "#{title} – Activity #{index}"
           ) do
        {:ok, {revision, _content}} ->
          %{key: spec["key"], revision: revision, title: revision.title}

        {:error, reason} ->
          Repo.rollback({:create_activity_failed, title, index, reason})
      end
    end)
  end

  defp create_compiled_activities(_, _project, _author, title),
    do: Repo.rollback({:invalid_compiled_activities, title})

  defp activity_ids(activities) do
    Map.new(activities, &{&1.key, &1.revision.resource_id})
  end

  defp create_page(project, author, title, content, graded) do
    attrs = %{
      tags: [],
      objectives: %{"attached" => []},
      children: [],
      content: content,
      title: title,
      graded: graded,
      ai_enabled: false,
      max_attempts: if(graded, do: 3, else: 0),
      recommended_attempts: if(graded, do: 1, else: 0),
      scoring_strategy_id: ScoringStrategy.get_id_by_type("total"),
      resource_type_id: ResourceType.id_for_page(),
      author_id: author.id
    }

    with {:ok, %{revision: revision}} <- Course.create_and_attach_resource(project, attrs),
         {:ok, tracked} <- ChangeTracker.track_revision(project.slug, revision) do
      tracked
    else
      {:error, reason} -> Repo.rollback({:create_page_failed, title, reason})
    end
  end

  defp create_container(project, author, title, children) do
    attrs = %{
      title: title,
      author_id: author.id,
      objectives: %{},
      children: children,
      content: %{"version" => "0.1.0", "model" => []},
      resource_type_id: ResourceType.id_for_container()
    }

    with {:ok, %{revision: revision}} <- Course.create_and_attach_resource(project, attrs),
         {:ok, tracked} <- ChangeTracker.track_revision(project.slug, revision) do
      tracked
    else
      {:error, reason} -> Repo.rollback({:create_unit_failed, title, reason})
    end
  end

  defp set_openstax_attribution!(project, attribution) do
    attributes = project.attributes || %ProjectAttributes{}

    attrs = %{
      "learning_language" => attributes.learning_language,
      "calculate_embeddings_on_publish" => attributes.calculate_embeddings_on_publish,
      "license" => %{
        "license_type" => attribution["license_type"],
        "custom_license_details" => "",
        "source_provider" => attribution["source_provider"],
        "source_title" => attribution["source_title"],
        "source_url" => attribution["source_url"],
        "source_attribution" => attribution["source_attribution"]
      }
    }

    project
    |> Project.changeset(%{"attributes" => attrs})
    |> Repo.update!()
  end

  defp openstax_attribution(run) do
    source = CourseImport.source_attribution(run)
    license_type = normalized_license_type(source["license_type"] || source["license"])
    license = license_label(license_type)

    title =
      source["source_title"] || get_in(run.preflight_snapshot || %{}, ["title"]) ||
        run.book_slug

    provider = source["source_provider"] || source["provider"] || "OpenStax"
    source_url = source["source_url"] || run.source_url

    %{
      "license_type" => Atom.to_string(license_type),
      "license" => license,
      "source_provider" => provider,
      "source_title" => title,
      "source_url" => source_url,
      "source_attribution" =>
        "#{title} by #{provider}, licensed #{license}. Source: #{source_url}"
    }
  end

  defp normalized_license_type(value) when is_binary(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    cond do
      String.contains?(normalized, "by_nc_nd") -> :cc_by_nc_nd
      String.contains?(normalized, "by_nc_sa") -> :cc_by_nc_sa
      String.contains?(normalized, "by_nc") -> :cc_by_nc
      String.contains?(normalized, "by_nd") -> :cc_by_nd
      String.contains?(normalized, "by_sa") -> :cc_by_sa
      true -> :cc_by
    end
  end

  defp normalized_license_type(_value), do: :cc_by

  defp license_label(:cc_by_nc_nd), do: "CC BY-NC-ND 4.0"
  defp license_label(:cc_by_nc_sa), do: "CC BY-NC-SA 4.0"
  defp license_label(:cc_by_nc), do: "CC BY-NC 4.0"
  defp license_label(:cc_by_nd), do: "CC BY-ND 4.0"
  defp license_label(:cc_by_sa), do: "CC BY-SA 4.0"
  defp license_label(:cc_by), do: "CC BY 4.0"

  defp mark_applied!(run_id) do
    Repo.update_all(
      from(lesson in Lesson,
        where: lesson.run_id == ^run_id and lesson.selected == true
      ),
      set: [status: "applied"]
    )

    Repo.update_all(
      from(unit in Unit, where: unit.run_id == ^run_id and unit.selected == true),
      set: [status: "approved"]
    )
  end

  defp broadcast_created_resources(result) do
    Enum.each(result.activity_revisions, &Broadcaster.broadcast_resource(&1, result.project.slug))
    Enum.each(result.lesson_pages, &Broadcaster.broadcast_resource(&1, result.project.slug))
    Enum.each(result.assessment_pages, &Broadcaster.broadcast_resource(&1, result.project.slug))

    Enum.each(result.units, fn unit ->
      Broadcaster.broadcast_resource(unit.revision, result.project.slug)
    end)

    Broadcaster.broadcast_revision(result.root_revision, result.project.slug)
    :ok
  rescue
    _ -> :ok
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(:ok), do: :ok
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp ensure!(true, _reason), do: :ok
  defp ensure!(false, reason), do: Repo.rollback(reason)

  defp retry_or_fail(run_id, attempt, max_attempts, reason) when attempt < max_attempts do
    _ =
      CourseImport.set_progress(
        run_id,
        %{
          "work_state" => "retrying",
          "attempt" => attempt,
          "max_attempts" => max_attempts
        },
        :applying
      )

    {:error, reason}
  end

  defp retry_or_fail(run_id, _attempt, _max_attempts, reason) do
    CourseImport.mark_failed(run_id, :apply, reason)
    {:discard, reason}
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 15)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)
end
