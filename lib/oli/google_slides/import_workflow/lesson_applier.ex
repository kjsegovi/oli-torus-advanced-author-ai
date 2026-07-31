defmodule Oli.GoogleSlides.ImportWorkflow.LessonApplier do
  @moduledoc """
  Applies an approved, compiled lesson inside the caller's database transaction.

  The AI never calls this module. It accepts deterministic compiler output,
  creates any confirmed objectives, creates one adaptive activity per screen,
  creates the Advanced Author page, and appends it to the selected container.

  Generation owns the outer transaction so the course changes and import-run
  completion are committed atomically. Broadcasts are deliberately exposed as
  a separate post-commit operation.
  """

  alias Oli.Accounts.Author
  alias Oli.Authoring.Broadcaster
  alias Oli.Authoring.Course
  alias Oli.Authoring.Course.Project
  alias Oli.Authoring.Editing.ActivityEditor
  alias Oli.GoogleSlides.AI.ImportPlan
  alias Oli.Publishing
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Publishing.ChangeTracker
  alias Oli.Repo
  alias Oli.Resources.{ResourceType, Revision, ScoringStrategy}

  @spec apply(Project.t(), Revision.t(), Author.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def apply(
        %Project{} = project,
        %Revision{} = container,
        %Author{} = author,
        compiled,
        lesson_plan
      )
      when is_map(compiled) and is_map(lesson_plan) do
    with {:ok, result} <-
           apply_many(project, container, author, [compiled], lesson_plan) do
      {:ok,
       result
       |> Map.put(:page_revision, List.first(result.page_revisions))
       |> Map.put(:activities, result.activities)}
    end
  end

  @doc """
  Creates every compiled lesson atomically inside the caller's transaction.

  Shared objectives are created once, all activities and pages are created
  before the container changes, and one container revision appends the ordered
  page list.
  """
  @spec apply_many(Project.t(), Revision.t(), Author.t(), [map()], map()) ::
          {:ok, map()} | {:error, term()}
  def apply_many(
        %Project{} = project,
        %Revision{} = container,
        %Author{} = author,
        compiled_lessons,
        import_plan
      )
      when is_list(compiled_lessons) and is_map(import_plan) do
    if Repo.in_transaction?() do
      plans = ImportPlan.lessons(import_plan)

      with true <- length(compiled_lessons) == length(plans),
           {:ok, objective_context} <-
             create_objectives(project, author, merged_objective_plan(plans)),
           {:ok, lesson_results} <-
             create_lessons(
               project,
               author,
               compiled_lessons,
               plans,
               objective_context
             ),
           {:ok, container_revision} <-
             append_pages(
               project,
               container,
               Enum.map(lesson_results, & &1.page_revision),
               author
             ) do
        {:ok,
         %{
           page_revisions: Enum.map(lesson_results, & &1.page_revision),
           container_revision: container_revision,
           activities: Enum.flat_map(lesson_results, & &1.activities),
           objectives: objective_context.created,
           lessons: lesson_results
         }}
      else
        false -> {:error, :compiled_lesson_count_mismatch}
        {:error, _} = error -> error
      end
    else
      {:error, :transaction_required}
    end
  end

  @doc """
  Broadcasts committed course changes after the generation transaction succeeds.
  """
  @spec broadcast(map(), String.t()) :: :ok
  def broadcast(result, project_slug) when is_map(result) and is_binary(project_slug) do
    Enum.each(result.objectives, &Broadcaster.broadcast_resource(&1, project_slug))

    Enum.each(result.activities, fn activity ->
      Broadcaster.broadcast_resource(activity.revision, project_slug)
    end)

    page_revisions =
      result[:page_revisions] || List.wrap(result[:page_revision])

    Enum.each(page_revisions, &Broadcaster.broadcast_resource(&1, project_slug))
    Broadcaster.broadcast_revision(result.container_revision, project_slug)
    :ok
  end

  defp create_lessons(
         project,
         author,
         compiled_lessons,
         plans,
         objective_context
       ) do
    compiled_lessons
    |> Enum.zip(plans)
    |> Enum.reduce_while({:ok, []}, fn {compiled, plan}, {:ok, created} ->
      with {:ok, activities} <-
             create_activities(project, author, compiled, objective_context),
           {:ok, page_content} <- attach_activities(compiled, activities),
           {:ok, page_revision} <-
             create_page(
               project,
               author,
               compiled,
               page_content,
               objective_ids_for_plan(plan, objective_context)
             ) do
        {:cont,
         {:ok,
          created ++
            [
              %{
                page_revision: page_revision,
                activities: activities,
                plan: plan
              }
            ]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_objectives(project, author, lesson_plan) do
    objectives = value(lesson_plan, :objectives, %{}) || %{}
    mapped = value(objectives, :mapped, []) || []
    proposed = value(objectives, :proposed, []) || []

    with {:ok, mapped_by_key} <- validated_mapped_objectives(project, mapped) do
      proposed
      |> Enum.filter(&(value(&1, :confirmed, false) == true))
      |> Enum.reduce_while({:ok, %{by_key: mapped_by_key, created: []}}, fn objective,
                                                                            {:ok, context} ->
        case create_objective(project, author, objective) do
          {:ok, revision} ->
            key = objective_key(objective, revision.resource_id)

            {:cont,
             {:ok,
              %{
                by_key: Map.put(context.by_key, key, revision.resource_id),
                created: context.created ++ [revision]
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, context} ->
          {:ok, Map.put(context, :all_ids, context.by_key |> Map.values() |> Enum.uniq())}

        error ->
          error
      end
    end
  end

  defp merged_objective_plan(plans) do
    mapped =
      plans
      |> Enum.flat_map(&(get_in(&1, ["objectives", "mapped"]) || []))
      |> Enum.uniq_by(fn objective ->
        value(objective, :objectiveId) || value(objective, :resource_id) ||
          value(objective, :key)
      end)

    proposed =
      plans
      |> Enum.flat_map(&(get_in(&1, ["objectives", "proposed"]) || []))
      |> Enum.uniq_by(fn objective -> value(objective, :key) || value(objective, :title) end)

    %{"objectives" => %{"mapped" => mapped, "proposed" => proposed}}
  end

  defp objective_ids_for_plan(plan, objective_context) do
    mapped =
      plan
      |> get_in(["objectives", "mapped"])
      |> List.wrap()
      |> Enum.map(fn objective ->
        objective
        |> objective_key(objective_resource_id(objective))
        |> then(&Map.get(objective_context.by_key, &1))
      end)

    proposed =
      plan
      |> get_in(["objectives", "proposed"])
      |> List.wrap()
      |> Enum.filter(&(value(&1, :confirmed, false) == true))
      |> Enum.map(fn objective ->
        key = value(objective, :key)
        Map.get(objective_context.by_key, to_string(key))
      end)

    (mapped ++ proposed)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp validated_mapped_objectives(project, mapped) do
    allowed_ids =
      project.slug
      |> AuthoringResolver.revisions_of_type(ResourceType.id_for_objective())
      |> Enum.map(& &1.resource_id)
      |> MapSet.new()

    Enum.reduce_while(mapped, {:ok, %{}}, fn objective, {:ok, acc} ->
      id = objective_resource_id(objective)

      if is_integer(id) and MapSet.member?(allowed_ids, id) do
        {:cont, {:ok, Map.put(acc, objective_key(objective, id), id)}}
      else
        {:halt, {:error, {:invalid_mapped_objective, id}}}
      end
    end)
  end

  defp create_objective(project, author, objective) do
    title =
      value(objective, :title) ||
        value(objective, :statement) ||
        value(objective, :description)

    if is_binary(title) and String.trim(title) != "" do
      attrs = %{
        title: String.trim(title),
        author_id: author.id,
        resource_type_id: ResourceType.id_for_objective()
      }

      with {:ok, %{revision: revision}} <- Course.create_and_attach_resource(project, attrs),
           %{} = publication <- Publishing.project_working_publication(project.slug),
           {:ok, _mapping} <- Publishing.upsert_published_resource(publication, revision) do
        {:ok, revision}
      else
        nil -> {:error, :working_publication_not_found}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_objective_title}
    end
  end

  defp create_activities(project, author, compiled, objective_context) do
    compiled
    |> value(:activities, [])
    |> Enum.reduce_while({:ok, []}, fn activity, {:ok, created} ->
      objective_ids = activity_objective_ids(activity, objective_context)

      case ActivityEditor.create(
             project.slug,
             "oli_adaptive",
             author,
             value(activity, :content, %{}),
             objective_ids,
             "embedded",
             value(activity, :title, "Imported screen")
           ) do
        {:ok, {revision, _transformed_content}} ->
          result = %{
            key: value(activity, :key),
            resource_id: revision.resource_id,
            slug: revision.slug,
            title: revision.title,
            revision: revision
          }

          {:cont, {:ok, created ++ [result]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp activity_objective_ids(activity, %{by_key: by_key}) do
    case value(activity, :objective_keys, []) do
      keys when is_list(keys) ->
        keys
        |> Enum.map(&Map.get(by_key, to_string(&1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp attach_activities(compiled, activities) do
    page_content = value(compiled, :page_content, %{})
    model = value(page_content, :model, [])

    case model do
      [group | rest] when is_map(group) ->
        references =
          Enum.map(activities, fn activity ->
            %{
              "type" => "activity-reference",
              "activitySlug" => activity.slug,
              "custom" => %{
                "sequenceId" => stable_sequence_id(activity.key),
                "sequenceName" => activity.title
              }
            }
          end)

        updated_group = Map.put(group, "children", references)
        {:ok, Map.put(page_content, "model", [updated_group | rest])}

      _ ->
        {:error, :invalid_compiled_page_model}
    end
  end

  defp create_page(project, author, compiled, page_content, objective_ids) do
    attrs = %{
      tags: [],
      objectives: %{"attached" => objective_ids},
      children: [],
      content: page_content,
      title: value(compiled, :title, "Imported Slides Lesson"),
      graded: false,
      ai_enabled: value(compiled, :runtime_ai_enabled, false) == true,
      max_attempts: 0,
      recommended_attempts: 0,
      scoring_strategy_id: ScoringStrategy.get_id_by_type("total"),
      resource_type_id: ResourceType.id_for_page(),
      author_id: author.id
    }

    with {:ok, %{revision: revision}} <- Course.create_and_attach_resource(project, attrs),
         {:ok, tracked_revision} <- ChangeTracker.track_revision(project.slug, revision) do
      {:ok, tracked_revision}
    end
  end

  defp append_pages(project, container, page_revisions, author) do
    children =
      (container.children || []) ++ Enum.map(page_revisions, & &1.resource_id)

    ChangeTracker.track_revision(project.slug, container, %{
      children: children,
      author_id: author.id
    })
  end

  defp objective_resource_id(objective) when is_map(objective) do
    objective
    |> then(fn objective ->
      value(objective, :resource_id) ||
        value(objective, :resourceId) ||
        value(objective, :objectiveId) ||
        value(objective, :id)
    end)
    |> normalize_resource_id()
  end

  defp objective_resource_id(_objective), do: nil

  defp normalize_resource_id(id) when is_integer(id), do: id

  defp normalize_resource_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_resource_id(_id), do: nil

  defp objective_key(objective, fallback) do
    objective
    |> value(:key, "objective_#{fallback}")
    |> to_string()
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp stable_sequence_id(key) do
    digest =
      :crypto.hash(:sha256, "sequence:#{key}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    "aa_seq_#{digest}"
  end
end
