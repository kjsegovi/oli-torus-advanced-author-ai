defmodule Oli.OpenStax.CourseImport.LegacyPurge do
  @moduledoc """
  Development/test-only removal of pre-v6 OpenStax runs and the curriculum
  resources recorded in their apply manifests.

  Cleanup is transactional per project and idempotent. It never traverses an
  entire project looking for similarly named content; run result resource ids
  are the deletion authority.
  """

  import Ecto.Query

  require Logger

  alias Oli.Authoring.Course.{Project, ProjectAttributes}
  alias Oli.Authoring.MediaLibrary.MediaItem
  alias Oli.OpenStax.CourseImport.{Enrichment.ArtifactStorage, Media, Run, SimulationArtifact}
  alias Oli.Publishing
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Publishing.ChangeTracker
  alias Oli.Repo
  alias Oli.Resources
  alias Oli.Resources.Revision
  alias Oli.Resources.ResourceType

  @spec purge_all(keyword()) :: {:ok, map()} | {:error, term()}
  def purge_all(opts \\ []) do
    with :ok <- ensure_allowed_environment(opts) do
      project_ids =
        Repo.all(
          from run in Run,
            where: run.plan_schema_version < 6,
            distinct: true,
            select: run.project_id
        )

      project_ids
      |> Enum.reduce_while(
        {:ok, %{projects: 0, runs: 0, resources: 0, activities: 0}},
        fn project_id, {:ok, totals} ->
          case purge_project(project_id, opts) do
            {:ok, result} ->
              {:cont,
               {:ok,
                %{
                  projects: totals.projects + 1,
                  runs: totals.runs + result.runs,
                  resources: totals.resources + result.resources,
                  activities: totals.activities + result.activities
                }}}

            {:error, reason} ->
              {:halt, {:error, {:project_purge_failed, project_id, reason}}}
          end
        end
      )
    end
  end

  @spec purge_project(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def purge_project(project_id, opts \\ [])

  def purge_project(project_id, opts) when is_integer(project_id) do
    with :ok <- ensure_allowed_environment(opts),
         %Project{} = project <- Repo.get(Project, project_id) do
      result =
        Repo.transaction(
          fn -> purge_project_transaction(project, opts) end,
          timeout: :timer.minutes(10)
        )

      case result do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:ok, %{runs: 0, resources: 0, activities: 0}}
      {:error, _} = error -> error
    end
  end

  def purge_project(_project_id, _opts), do: {:error, :invalid_project_id}

  defp purge_project_transaction(project, opts) do
    runs =
      Repo.all(
        from run in Run,
          where: run.project_id == ^project.id and run.plan_schema_version < 6,
          lock: "FOR UPDATE"
      )

    manifests = Enum.map(runs, &manifest/1)
    page_ids = manifests |> Enum.flat_map(&(&1.lesson_ids ++ &1.assessment_ids)) |> Enum.uniq()
    unit_ids = manifests |> Enum.flat_map(& &1.unit_ids) |> Enum.uniq()
    resource_ids = Enum.uniq(unit_ids ++ page_ids)
    activity_ids = orphaned_run_activity_ids(project, page_ids)
    media_item_ids = removable_media_item_ids(project.id, Enum.map(runs, & &1.id))

    before_counts = resource_counts(project, resource_ids, activity_ids)

    Logger.info(
      "OpenStax legacy purge starting project=#{project.id} runs=#{length(runs)} " <>
        "resources=#{before_counts.resources} activities=#{before_counts.activities}"
    )

    fence_runs_and_jobs!(runs)
    discard_artifacts!(runs, opts)
    detach_units!(project, manifests, unit_ids)
    soft_delete_resources!(project, runs, resource_ids ++ activity_ids)

    if media_item_ids != [] do
      Repo.update_all(from(item in MediaItem, where: item.id in ^media_item_ids),
        set: [deleted: true]
      )
    end

    Enum.each(runs, &Repo.delete!/1)

    clear_attribution_if_unused!(project)
    after_counts = resource_counts(project, resource_ids, activity_ids)

    Logger.info(
      "OpenStax legacy purge finished project=#{project.id} runs=#{length(runs)} " <>
        "resources_before=#{before_counts.resources} resources_after=#{after_counts.resources} " <>
        "activities_before=#{before_counts.activities} activities_after=#{after_counts.activities}"
    )

    %{
      runs: length(runs),
      resources: before_counts.resources,
      activities: before_counts.activities,
      before: before_counts,
      after: after_counts
    }
  end

  defp manifest(run) do
    result = run.result || %{}
    root_revision_id = positive_integer(result["root_revision_id"])

    %{
      run: run,
      unit_ids: integer_ids(result["unit_resource_ids"]),
      lesson_ids: integer_ids(result["lesson_resource_ids"]),
      assessment_ids: integer_ids(result["assessment_resource_ids"]),
      root_revision_id: root_revision_id,
      root_resource_id:
        run.target_root_container_resource_id || root_resource_id(root_revision_id)
    }
  end

  defp root_resource_id(nil), do: nil

  defp root_resource_id(revision_id) do
    case Repo.get(Revision, revision_id) do
      %Revision{resource_id: resource_id} -> resource_id
      nil -> nil
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp integer_ids(values),
    do: values |> List.wrap() |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.uniq()

  defp detach_units!(_project, [], _unit_ids), do: :ok
  defp detach_units!(_project, _manifests, []), do: :ok

  defp detach_units!(project, manifests, unit_ids) do
    imported = MapSet.new(unit_ids)

    manifests
    |> Enum.uniq_by(& &1.root_resource_id)
    |> Enum.each(fn manifest ->
      root_id = manifest.root_resource_id

      case AuthoringResolver.from_resource_id(project.slug, root_id) do
        %{children: children} = root ->
          retained = Enum.reject(List.wrap(children), &MapSet.member?(imported, &1))

          if retained != List.wrap(children) do
            changes = %{children: retained, author_id: manifest.run.author_id}

            case ChangeTracker.track_revision(
                   project.slug,
                   root,
                   changes,
                   course_import_run_id: manifest.run.id
                 ) do
              {:ok, _revision} -> :ok
              {:error, reason} -> Repo.rollback({:root_detach_failed, root_id, reason})
            end
          end

        _ ->
          :ok
      end
    end)
  end

  defp fence_runs_and_jobs!([]), do: :ok

  defp fence_runs_and_jobs!(runs) do
    run_ids = Enum.map(runs, & &1.id)
    now = DateTime.utc_now()

    Repo.update_all(from(run in Run, where: run.id in ^run_ids),
      set: [status: :cancelled, finished_at: now, updated_at: now]
    )

    Enum.each(run_ids, fn run_id ->
      Repo.delete_all(
        from job in Oban.Job,
          where: fragment("? ->> 'run_id' = ?", job.args, ^run_id)
      )
    end)

    :ok
  end

  defp soft_delete_resources!(_project, [], _resource_ids), do: :ok

  defp soft_delete_resources!(project, runs, resource_ids) do
    author_id = runs |> List.first() |> Map.fetch!(:author_id)

    Enum.each(Enum.uniq(resource_ids), fn resource_id ->
      case AuthoringResolver.from_resource_id(project.slug, resource_id) do
        %{deleted: true} ->
          :ok

        %{} = revision ->
          case ChangeTracker.track_revision(project.slug, revision, %{
                 deleted: true,
                 author_id: author_id
               }) do
            {:ok, _revision} -> :ok
            {:error, reason} -> Repo.rollback({:resource_delete_failed, resource_id, reason})
          end

        nil ->
          :ok
      end
    end)
  end

  defp orphaned_run_activity_ids(_project, []), do: []

  defp orphaned_run_activity_ids(project, page_ids) do
    page_ids = MapSet.new(page_ids)

    imported_activity_ids =
      project.slug
      |> AuthoringResolver.from_resource_id(MapSet.to_list(page_ids))
      |> List.wrap()
      |> Enum.flat_map(fn
        %{content: %{"model" => _model}} = revision -> Resources.activity_references(revision)
        _revision -> []
      end)
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    if MapSet.size(imported_activity_ids) == 0 do
      []
    else
      publication = Publishing.project_working_publication(project.slug)
      parents = active_activity_parents(publication.id)

      imported_activity_ids
      |> Enum.filter(fn activity_id ->
        parents
        |> Map.get(activity_id, MapSet.new())
        |> MapSet.difference(page_ids)
        |> MapSet.size() == 0
      end)
    end
  end

  defp active_activity_parents(publication_id) do
    sql = """
    SELECT revision.resource_id,
           (reference.value ->> 'activity_id')::bigint AS activity_id
      FROM published_resources AS mapping
      JOIN revisions AS revision ON revision.id = mapping.revision_id
      CROSS JOIN LATERAL jsonb_path_query(
        revision.content,
        '$.** ? (@.type == "activity-reference")'
      ) AS reference(value)
     WHERE mapping.publication_id = $1
       AND revision.resource_type_id = $2
       AND revision.deleted IS FALSE
       AND reference.value ? 'activity_id'
    """

    result = Ecto.Adapters.SQL.query!(Repo, sql, [publication_id, ResourceType.id_for_page()])

    Enum.reduce(result.rows, %{}, fn [page_id, activity_id], parents ->
      Map.update(parents, activity_id, MapSet.new([page_id]), &MapSet.put(&1, page_id))
    end)
  end

  defp removable_media_item_ids(project_id, run_ids) do
    candidates =
      Repo.all(
        from media in Media,
          where:
            media.project_id == ^project_id and media.run_id in ^run_ids and
              not is_nil(media.media_item_id),
          select: media.media_item_id
      )
      |> Enum.uniq()

    referenced_elsewhere =
      Repo.all(
        from media in Media,
          where:
            media.project_id == ^project_id and media.run_id not in ^run_ids and
              media.media_item_id in ^candidates,
          select: media.media_item_id
      )
      |> MapSet.new()

    Enum.reject(candidates, &MapSet.member?(referenced_elsewhere, &1))
  end

  defp discard_artifacts!(runs, opts) do
    run_ids = Enum.map(runs, & &1.id)

    Repo.all(
      from artifact in SimulationArtifact,
        where: artifact.run_id in ^run_ids and artifact.storage_state in ["staged", "promoted"]
    )
    |> Enum.each(fn artifact ->
      case ArtifactStorage.discard(artifact, opts) do
        :ok ->
          :ok

        {:error, :artifact_storage_unavailable} ->
          Logger.warning(
            "OpenStax purge could not discard local artifact #{artifact.id}; database cleanup will continue"
          )

        {:error, reason} ->
          Repo.rollback({:artifact_discard_failed, artifact.id, reason})
      end
    end)
  end

  defp clear_attribution_if_unused!(project) do
    current_import_exists? =
      Repo.exists?(
        from run in Run,
          where:
            run.project_id == ^project.id and run.plan_schema_version == 6 and
              run.status == :completed
      )

    attributes = project.attributes || %ProjectAttributes{}
    openstax? = attributes.license && attributes.license.source_provider == "OpenStax"

    if not current_import_exists? and openstax? do
      project
      |> Project.changeset(%{
        "attributes" => %{
          "learning_language" => attributes.learning_language,
          "calculate_embeddings_on_publish" => attributes.calculate_embeddings_on_publish,
          "license" => %{"license_type" => "none", "custom_license_details" => ""}
        }
      })
      |> Repo.update!()
    end
  end

  defp resource_counts(project, resource_ids, activity_ids) do
    active = fn ids ->
      project.slug
      |> AuthoringResolver.from_resource_id(ids)
      |> List.wrap()
      |> Enum.count(&(&1.deleted != true))
    end

    %{resources: active.(resource_ids), activities: active.(activity_ids)}
  end

  defp ensure_allowed_environment(opts) do
    environment = Keyword.get(opts, :environment, Application.get_env(:oli, :env, Mix.env()))
    if environment in [:dev, :test], do: :ok, else: {:error, :legacy_purge_forbidden}
  end
end
