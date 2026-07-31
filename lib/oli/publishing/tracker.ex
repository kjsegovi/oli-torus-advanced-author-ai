defmodule Oli.Publishing.ChangeTracker do
  import Ecto.Query

  alias Oli.Publishing
  alias Oli.Publishing.{PublishedResource}
  alias Oli.Repo

  @course_import_active_statuses [
    :preflighting,
    :awaiting_scope,
    :ingesting,
    :staging_media,
    :planning_outline,
    :awaiting_outline_approval,
    :planning_lessons,
    :awaiting_lesson_approval,
    :compiling,
    :applying
  ]

  @doc """
  Tracks the creation of a new revision for the current
  unpublished publication.  If `changes` argument is
  supplied it treats the `revision` argument as a base
  revision and creates a new revision from this base with
  the applied changes.  If `changes` argument is not supplied or
  is nil, then the `revision` argument is assumed to be an
  already new revision.
  """
  def track_revision(project_slug, revision, changes \\ nil, opts \\ []) do
    publication = Publishing.project_working_publication(project_slug)

    operation = fn ->
      with :ok <- guard_root_change(publication, revision, changes, opts) do
        process_change(
          publication,
          revision,
          &Oli.Resources.create_revision_from_previous/2,
          changes
        )
      end
    end

    if root_revision?(publication, revision) and not Repo.in_transaction?() do
      case Repo.transaction(fn ->
             case operation.() do
               {:ok, value} -> value
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    else
      operation.()
    end
  end

  @doc false
  def lock_project_root(publication, allowed_course_import_run_id \\ nil)

  def lock_project_root(
        %{id: publication_id, project_id: project_id, root_resource_id: root_resource_id},
        allowed_course_import_run_id
      ) do
    lock_root_mapping(publication_id, root_resource_id)

    ensure_course_import_owner(
      project_id,
      root_resource_id,
      allowed_course_import_run_id
    )
  end

  defp process_change(publication, revision, processor, changes) do
    with {:ok, resultant_revision} <-
           (case changes do
              nil -> {:ok, revision}
              change -> processor.(revision, change)
            end),
         {:ok, %PublishedResource{}} <-
           Publishing.upsert_published_resource(publication, resultant_revision) do
      {:ok, resultant_revision}
    end
  end

  defp guard_root_change(publication, revision, changes, opts) do
    if root_revision?(publication, revision) do
      allowed_run_id = Keyword.get(opts, :course_import_run_id)

      with :ok <- lock_project_root(publication, allowed_run_id),
           :ok <-
             ensure_import_root_is_current(
               publication.id,
               revision,
               changes,
               allowed_run_id
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp root_revision?(%{root_resource_id: root_resource_id}, %{resource_id: resource_id}),
    do: root_resource_id == resource_id

  defp root_revision?(_, _), do: false

  defp lock_root_mapping(publication_id, resource_id) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
      [publication_id, resource_id]
    )

    :ok
  end

  # Existing authoring operations intentionally tolerate a stale container
  # revision and compute a replacement child list from the user's view. The
  # course-import apply path is stricter because it owns an atomic full-root
  # publish and must never replace a concurrently advanced root mapping.
  defp ensure_import_root_is_current(publication_id, revision, changes, allowed_run_id)
       when is_binary(allowed_run_id),
       do: ensure_current_root_revision(publication_id, revision, changes)

  defp ensure_import_root_is_current(_publication_id, _revision, _changes, _allowed_run_id),
    do: :ok

  defp ensure_current_root_revision(publication_id, revision, changes) do
    case Repo.one(
           from(mapping in PublishedResource,
             where:
               mapping.publication_id == ^publication_id and
                 mapping.resource_id == ^revision.resource_id,
             lock: "FOR UPDATE"
           )
         ) do
      %PublishedResource{revision_id: revision_id} ->
        current_base? = revision_id == revision.id
        direct_successor? = is_nil(changes) and revision.previous_revision_id == revision_id

        if current_base? or direct_successor?,
          do: :ok,
          else: {:error, :stale_root_revision}

      nil ->
        {:error, :root_mapping_not_found}
    end
  end

  defp ensure_course_import_owner(project_id, root_resource_id, allowed_run_id) do
    query =
      from(run in Oli.OpenStax.CourseImport.Run,
        where:
          run.project_id == ^project_id and
            run.target_root_container_resource_id == ^root_resource_id and
            run.status in ^@course_import_active_statuses,
        select: run.id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> :ok
      ^allowed_run_id when is_binary(allowed_run_id) -> :ok
      _run_id -> {:error, :course_import_in_progress}
    end
  end
end
