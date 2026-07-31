defmodule Oli.GoogleSlides.ImportWorkflow.Generation do
  @moduledoc """
  Deterministic, approval-gated lesson generation workflow.

  The presentation is re-fetched and fingerprinted before any authoring data is
  written. The final lesson is then applied in one database transaction.
  """

  @behaviour Oli.GoogleSlides.ImportRuns.GenerationWorkflow

  import Ecto.Query

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.Authoring.Editing.Utils, as: EditingUtils
  alias Oli.GoogleDocs.SlidesClient

  alias Oli.GoogleSlides.{
    Credentials,
    ImportRun,
    ImportRuns,
    MediaIngestor,
    PresentationParser
  }

  alias Oli.GoogleSlides.ImportRuns.PubSub
  alias Oli.GoogleSlides.AI.ImportPlan

  alias Oli.GoogleSlides.ImportWorkflow.{
    FidelityValidator,
    LessonApplier,
    LessonCompiler,
    ProvenanceValidator,
    SourceCorpus,
    SourceSnapshot
  }

  alias Oli.Publishing
  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias Oli.Publishing.PublishedResource
  alias Oli.Resources.{ResourceType, Revision}

  @impl true
  def perform(run_id) do
    case ImportRuns.fetch_run(run_id) do
      nil ->
        {:error, :import_run_context_not_found}

      %ImportRun{status: :completed} = run ->
        {:ok, run}

      %ImportRun{} = run ->
        generate(run)
    end
  end

  defp generate(%ImportRun{} = run) do
    config = Application.get_env(:oli, :google_slides_ai_import, [])
    slides_client = config_value(config, :slides_client, SlidesClient)
    credentials_module = config_value(config, :credentials, Credentials)
    parser = config_value(config, :presentation_parser, PresentationParser)
    snapshot_module = config_value(config, :source_snapshot, SourceSnapshot)
    media_ingestor = config_value(config, :media_ingestor, MediaIngestor)
    compiler = config_value(config, :lesson_compiler, LessonCompiler)
    applier = config_value(config, :lesson_applier, LessonApplier)
    provenance_validator = config_value(config, :provenance_validator, ProvenanceValidator)
    fidelity_validator = config_value(config, :fidelity_validator, FidelityValidator)

    with :ok <- validate_approval(run),
         %Project{} = project <- Repo.get(Project, run.project_id),
         %Author{} = author <- Repo.get(Author, run.author_id),
         :ok <- ensure_available(project, author),
         {:ok} <- EditingUtils.authorize_user(author, project),
         %Revision{} = container <-
           AuthoringResolver.from_resource_id(
             project.slug,
             run.target_container_resource_id
           ),
         :ok <- validate_container(container),
         {:ok, credentials} <- credentials_module.get_credentials_map(project.id),
         {:ok, access_token} <- slides_client.fetch_access_token(credentials),
         {:ok, presentation_json} <-
           slides_client.fetch_presentation_json(
             run.presentation_url,
             access_token,
             credentials
           ),
         {:ok, slides, parse_warnings} <-
           parser.parse(presentation_json, access_token: access_token),
         {:ok, source_snapshot} <-
           build_generation_snapshot(
             run,
             snapshot_module,
             presentation_json,
             slides
           ),
         :ok <- validate_fingerprint(run, source_snapshot),
         :ok <-
           validate_source_import_plan(
             provenance_validator,
             run.lesson_plan,
             source_snapshot,
             :invalid_source_provenance
           ),
         :ok <-
           validate_source_import_plan(
             fidelity_validator,
             run.lesson_plan,
             source_snapshot,
             :invalid_source_fidelity
           ),
         required_image_ids <- required_image_ids(run.lesson_plan),
         {:ok, video_urls} <- resolve_required_videos(slides, run.lesson_plan),
         placeholder_media <-
           required_image_ids
           |> Map.new(&{&1, "staged://#{&1}"})
           |> Map.merge(video_urls),
         {:ok, _validated_compilation} <-
           compile_many(compiler, run.lesson_plan, placeholder_media, project),
         {:ok, image_urls, media_warnings} <-
           ingest_required_images(
             media_ingestor,
             slides,
             required_image_ids,
             project.slug,
             access_token
           ),
         media_urls <- Map.merge(image_urls, video_urls),
         {:ok, compiled} <- compile_many(compiler, run.lesson_plan, media_urls, project),
         {:ok, completed_run} <-
           apply_and_complete(
             run,
             project,
             author,
             compiled,
             applier,
             parse_warnings,
             media_warnings
           ) do
      {:ok, completed_run}
    else
      nil -> {:error, :import_run_context_not_found}
      {:error, _} = error -> error
      other -> {:error, {:generation_failed, other}}
    end
  end

  defp apply_and_complete(
         expected_run,
         expected_project,
         expected_author,
         compiled,
         applier,
         parse_warnings,
         media_warnings
       ) do
    Repo.transaction(fn ->
      with %ImportRun{} = locked_run <- lock_run(expected_run.id),
           :ok <- validate_locked_approval(locked_run, expected_run),
           %Project{} = project <- Repo.get(Project, locked_run.project_id),
           %Author{} = author <- Repo.get(Author, locked_run.author_id),
           :ok <- validate_locked_context(project, author, expected_project, expected_author),
           :ok <- ensure_available(project, author),
           {:ok} <- EditingUtils.authorize_user(author, project),
           {:ok, container} <-
             lock_latest_container(project, locked_run.target_container_resource_id),
           {:ok, result} <-
             apply_compiled(
               applier,
               project,
               container,
               author,
               compiled,
               locked_run.lesson_plan
             ),
           {:ok, completed_run} <-
             complete_run(
               locked_run,
               result,
               parse_warnings,
               media_warnings
             ) do
        {:completed, completed_run, result, project.slug}
      else
        %ImportRun{status: :completed} = completed_run ->
          {:already_completed, completed_run}

        nil ->
          Repo.rollback(:import_run_context_not_found)

        {:error, reason} ->
          Repo.rollback(reason)

        other ->
          Repo.rollback({:generation_failed, other})
      end
    end)
    |> case do
      {:ok, {:completed, completed_run, result, project_slug}} ->
        :ok = broadcast_course_changes(applier, result, project_slug)
        :ok = PubSub.broadcast(completed_run)
        {:ok, completed_run}

      {:ok, {:already_completed, completed_run}} ->
        {:ok, completed_run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_run(run_id) do
    Repo.one(
      from run in ImportRun,
        where: run.id == ^run_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_locked_approval(%ImportRun{status: :completed} = run, _expected_run),
    do: run

  defp validate_locked_approval(%ImportRun{} = run, %ImportRun{} = expected_run) do
    cond do
      run.status == :cancelled ->
        {:error, :cancelled}

      run.status != :generating ->
        {:error, {:invalid_run_status, run.status}}

      is_nil(run.lesson_plan) ->
        {:error, :lesson_plan_not_found}

      run.plan_version != run.approved_plan_version ->
        {:error, :stale_plan}

      run.approved_by_author_id != run.author_id or is_nil(run.approved_at) ->
        {:error, :stale_plan}

      run.plan_version != expected_run.plan_version or
        run.approved_plan_version != expected_run.approved_plan_version or
          run.lesson_plan != expected_run.lesson_plan ->
        {:error, :stale_plan}

      run.presentation_fingerprint != expected_run.presentation_fingerprint ->
        {:error, :stale_source}

      true ->
        :ok
    end
  end

  defp validate_locked_context(project, author, expected_project, expected_author) do
    if project.id == expected_project.id and author.id == expected_author.id do
      :ok
    else
      {:error, :import_run_context_not_found}
    end
  end

  defp lock_latest_container(project, resource_id) do
    with %{} = publication <- Publishing.project_working_publication(project.slug),
         %PublishedResource{} <-
           Repo.one(
             from mapping in PublishedResource,
               where:
                 mapping.publication_id == ^publication.id and
                   mapping.resource_id == ^resource_id,
               lock: "FOR UPDATE"
           ),
         %Revision{} = container <-
           AuthoringResolver.from_resource_id(project.slug, resource_id),
         :ok <- validate_container(container) do
      {:ok, container}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_target_container}
    end
  end

  defp complete_run(
         locked_run,
         result,
         parse_warnings,
         media_warnings
       )
       when is_map(result) do
    page_revisions =
      result[:page_revisions] || List.wrap(result[:page_revision])

    activities = result[:activities] || []

    with [%Revision{} = page_revision | _] <- page_revisions,
         true <- is_list(activities) do
      warnings = normalize_warnings(parse_warnings) ++ normalize_warnings(media_warnings)

      lesson_results =
        result[:lessons]
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.map(fn {lesson_result, index} ->
          revision = lesson_result[:page_revision]
          lesson_activities = lesson_result[:activities] || []

          %{
            "index" => index,
            "revision_id" => revision.id,
            "revision_slug" => revision.slug,
            "resource_id" => revision.resource_id,
            "screen_count" => length(lesson_activities),
            "activity_slugs" => Enum.map(lesson_activities, & &1.slug)
          }
        end)

      lesson_results =
        if lesson_results == [] do
          [
            %{
              "index" => 0,
              "revision_id" => page_revision.id,
              "revision_slug" => page_revision.slug,
              "resource_id" => page_revision.resource_id,
              "screen_count" => length(activities),
              "activity_slugs" => Enum.map(activities, & &1.slug)
            }
          ]
        else
          lesson_results
        end

      attrs = %{
        status: :completed,
        result_revision_id: page_revision.id,
        result: %{
          "revision_slug" => page_revision.slug,
          "resource_id" => page_revision.resource_id,
          "screen_count" => length(activities),
          "activity_slugs" => Enum.map(activities, & &1.slug),
          "lessons" => lesson_results
        },
        warnings: (locked_run.warnings || []) ++ warnings,
        validation_results: %{
          "status" => "applied",
          "sourceFingerprint" => locked_run.presentation_fingerprint,
          "screenCount" => length(activities),
          "lessonCount" => length(page_revisions)
        },
        model_usage: locked_run.model_usage || %{},
        error: nil,
        finished_at: DateTime.utc_now()
      }

      locked_run
      |> ImportRun.update_changeset(attrs)
      |> Repo.update()
    else
      _ -> {:error, :invalid_applier_result}
    end
  end

  defp complete_run(_locked_run, _result, _parse_warnings, _media_warnings),
    do: {:error, :invalid_applier_result}

  defp broadcast_course_changes(applier, result, project_slug) do
    if function_exported?(applier, :broadcast, 2) do
      applier.broadcast(result, project_slug)
    else
      :ok
    end
  end

  defp validate_approval(run) do
    cond do
      run.status != :generating ->
        {:error, {:invalid_run_status, run.status}}

      is_nil(run.lesson_plan) ->
        {:error, :lesson_plan_not_found}

      run.plan_version != run.approved_plan_version ->
        {:error, :stale_plan}

      run.approved_by_author_id != run.author_id or is_nil(run.approved_at) ->
        {:error, :stale_plan}

      true ->
        :ok
    end
  end

  defp ensure_available(project, author) do
    if Oli.GoogleSlides.SlidesImport.import_available?(project, author) do
      :ok
    else
      {:error, :import_unavailable}
    end
  end

  defp validate_container(%Revision{
         deleted: false,
         resource_type_id: resource_type_id
       }) do
    if resource_type_id == ResourceType.id_for_container(),
      do: :ok,
      else: {:error, :invalid_target_container}
  end

  defp validate_container(_container), do: {:error, :invalid_target_container}

  defp validate_fingerprint(run, %{"presentation" => %{"fingerprint" => fingerprint}}) do
    if run.presentation_fingerprint == fingerprint, do: :ok, else: {:error, :stale_source}
  end

  defp validate_source_import_plan(validator, import_plan, source_snapshot, failure_tag) do
    plans = ImportPlan.lessons(import_plan)
    multi? = length(plans) > 1

    plans
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {plan, index}, :ok ->
      lesson_snapshot = snapshot_for_plan(source_snapshot, plan)

      case validator.validate(plan, lesson_snapshot) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          detail = if multi?, do: %{lesson_index: index, errors: reason}, else: reason
          {:halt, {:error, {failure_tag, detail}}}

        other ->
          detail =
            if multi?,
              do: %{lesson_index: index, errors: {:invalid_validator_result, other}},
              else: {:invalid_validator_result, other}

          {:halt, {:error, {failure_tag, detail}}}
      end
    end)
  end

  defp compile_many(compiler, import_plan, media_urls, project) do
    result =
      if function_exported?(compiler, :compile_many, 3) do
        compiler.compile_many(import_plan, media_urls,
          allow_triggers: project.allow_triggers == true
        )
      else
        import_plan
        |> ImportPlan.lessons()
        |> Enum.reduce_while({:ok, []}, fn plan, {:ok, compiled} ->
          case compiler.compile(plan, media_urls, allow_triggers: project.allow_triggers == true) do
            {:ok, lesson} -> {:cont, {:ok, compiled ++ [lesson]}}
            {:error, errors} -> {:halt, {:error, errors}}
          end
        end)
      end

    case result do
      {:ok, compiled} when is_list(compiled) -> {:ok, compiled}
      {:error, errors} -> {:error, {:invalid_lesson_plan, errors}}
      other -> {:error, {:invalid_lesson_plan, {:invalid_compiler_result, other}}}
    end
  end

  defp required_image_ids(plan) do
    plan
    |> ImportPlan.lessons()
    |> Enum.flat_map(&(get_in(&1, ["lesson", "screens"]) || []))
    |> Enum.flat_map(&(&1["parts"] || []))
    |> Enum.flat_map(fn part ->
      content = part["content"] || %{}

      if image_backed_part?(part["kind"], content) and
           present_string?(content["sourceObjectId"]) do
        [content["sourceObjectId"]]
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp image_backed_part?("image", _content), do: true
  defp image_backed_part?(kind, _content) when kind in ["chart", "line"], do: true

  defp image_backed_part?("shape", content),
    do: not present_string?(content["text"])

  # Word art has a deterministic semantic-text path. Claiming it as a staged
  # raster image would be dishonest because the Slides parser does not export
  # a word-art bitmap.
  defp image_backed_part?("word_art", _content), do: false
  defp image_backed_part?(_kind, _content), do: false

  defp resolve_required_videos(slides, plan) do
    required_ids =
      plan
      |> ImportPlan.lessons()
      |> Enum.flat_map(&(get_in(&1, ["lesson", "screens"]) || []))
      |> Enum.flat_map(&(&1["parts"] || []))
      |> Enum.flat_map(fn part ->
        content = part["content"] || %{}

        if part["kind"] == "video" and is_binary(content["sourceObjectId"]) do
          [content["sourceObjectId"]]
        else
          []
        end
      end)
      |> Enum.uniq()

    available =
      slides
      |> Enum.flat_map(&(&1.content_blocks || []))
      |> Enum.reduce(%{}, fn
        %{type: "video", object_id: object_id, src: src}, acc
        when is_binary(object_id) and is_binary(src) ->
          Map.put(acc, object_id, src)

        _block, acc ->
          acc
      end)

    missing = Enum.reject(required_ids, &Map.has_key?(available, &1))

    case missing do
      [] -> {:ok, Map.take(available, required_ids)}
      _ -> {:error, {:source_media_not_found, missing}}
    end
  end

  defp ingest_required_images(_media_ingestor, _slides, [], _project_slug, _access_token),
    do: {:ok, %{}, []}

  defp ingest_required_images(
         media_ingestor,
         slides,
         required_ids,
         project_slug,
         access_token
       ) do
    required_ids = MapSet.new(required_ids)

    images =
      Enum.flat_map(slides, fn slide ->
        slide.images
        |> Enum.filter(&MapSet.member?(required_ids, &1.object_id))
        |> Enum.map(&Map.put(&1, :slide_index, slide.index))
      end)

    available_ids = MapSet.new(images, & &1.object_id)
    missing_source_ids = MapSet.difference(required_ids, available_ids) |> MapSet.to_list()

    case missing_source_ids do
      [] ->
        case media_ingestor.ingest_images(images, project_slug, access_token) do
          {:ok, urls, warnings} when is_map(urls) and is_list(warnings) ->
            missing_ingested_ids =
              required_ids
              |> Enum.reject(fn object_id ->
                case Map.get(urls, object_id) do
                  url when is_binary(url) -> String.trim(url) != ""
                  _url -> false
                end
              end)
              |> Enum.sort()

            case missing_ingested_ids do
              [] -> {:ok, Map.take(urls, MapSet.to_list(required_ids)), warnings}
              missing -> {:error, {:source_media_ingest_failed, missing}}
            end

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_media_ingestor_result, other}}
        end

      missing ->
        {:error, {:source_media_not_found, Enum.sort(missing)}}
    end
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp build_generation_snapshot(
         %{analysis_version: version} = run,
         _snapshot_module,
         presentation_json,
         slides
       )
       when version >= 2 do
    case SourceCorpus.build(presentation_json, slides, run.presentation_url) do
      {:ok, corpus} -> {:ok, corpus.validation_snapshot}
      {:error, _} = error -> error
    end
  end

  defp build_generation_snapshot(run, snapshot_module, presentation_json, slides) do
    {:ok, snapshot_module.build(presentation_json, slides, run.presentation_url)}
  end

  defp snapshot_for_plan(snapshot, plan) do
    slide_ids =
      plan
      |> Map.get("sourceCoverage", [])
      |> Enum.map(& &1["slideId"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    if MapSet.size(slide_ids) == 0 do
      snapshot
    else
      slides =
        snapshot
        |> Map.get("slides", [])
        |> Enum.filter(&MapSet.member?(slide_ids, &1["objectId"]))

      inventory = Enum.flat_map(slides, &Map.get(&1, "sourceInventory", []))

      snapshot
      |> Map.put("slides", slides)
      |> Map.put("slideAccounting", %{
        "discovered" => length(slides),
        "included" => length(slides),
        "omitted" => 0
      })
      |> Map.put("inventoryAccounting", %{
        "discovered" => length(inventory),
        "included" => length(inventory),
        "omitted" => 0
      })
    end
  end

  defp apply_compiled(applier, project, container, author, compiled, import_plan) do
    cond do
      function_exported?(applier, :apply_many, 5) ->
        applier.apply_many(project, container, author, compiled, import_plan)

      length(compiled) == 1 ->
        applier.apply(
          project,
          container,
          author,
          hd(compiled),
          hd(ImportPlan.lessons(import_plan))
        )

      true ->
        {:error, :multi_lesson_generation_not_supported}
    end
  end

  defp normalize_warnings(warnings) when is_list(warnings) do
    Enum.map(warnings, fn
      warning when is_map(warning) ->
        Map.new(warning, fn {key, value} -> {to_string(key), value} end)

      warning ->
        %{"code" => "generation_warning", "message" => inspect(warning)}
    end)
  end

  defp normalize_warnings(_warnings), do: []

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp config_value(_config, _key, default), do: default
end
