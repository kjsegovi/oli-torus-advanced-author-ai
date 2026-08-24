defmodule Oli.OpenStax.CourseImport.Compiler do
  @moduledoc """
  Provider-neutral dry-run compiler for OpenStax lesson and unit plans.

  The compiler validates every approved plan before persistence and emits a
  normalized artifact map used by the apply worker for both Basic and Advanced
  Author pages.
  """

  alias Oli.OpenStax.CourseImport.{AuthoringCompiler, Enrichment, ImportContract}

  @spec dry_run(map()) :: {:ok, map()} | {:error, term()}
  def dry_run(run), do: dry_run(run, [])

  @spec dry_run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(%{units: units} = run, opts) when is_list(units) and is_list(opts) do
    opts =
      opts
      |> put_run_plan_schema_version(run)
      |> put_preloaded_enrichments(run)

    with :ok <- require_current_run_schema(run),
         false <- Enum.empty?(units),
         {:ok, compiled_units} <- compile_units(units, opts) do
      {:ok,
       %{
         "run_id" => run.id,
         "units" => compiled_units,
         "lesson_count" => Enum.reduce(compiled_units, 0, &(&2 + length(&1["lessons"]))),
         "compiled_at" => DateTime.to_iso8601(DateTime.utc_now())
       }}
    else
      true -> {:error, :no_units_to_compile}
      {:error, _} = error -> error
    end
  end

  def dry_run(_, _), do: {:error, :invalid_run}

  defp require_current_run_schema(run), do: ImportContract.ensure_current_run(run)

  defp compile_units(units, opts) do
    units
    |> Enum.sort_by(& &1.order)
    |> Enum.reduce_while({:ok, []}, fn unit, {:ok, acc} ->
      with true <- unit.selected,
           {:ok, lessons} <- compile_lessons(unit.lessons, opts) do
        compiled = %{
          "unit_id" => unit.id,
          "title" => unit.unit_name,
          "lessons" => lessons
        }

        {:cont, {:ok, acc ++ [compiled]}}
      else
        false -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:unit_compile_failed, unit.id, reason}}}
      end
    end)
  end

  defp compile_lessons(lessons, opts) do
    lessons
    |> Enum.filter(& &1.selected)
    |> Enum.sort_by(& &1.order)
    |> Enum.reduce_while({:ok, []}, fn lesson, {:ok, acc} ->
      case compile_lesson(lesson, opts) do
        {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_lesson(%{status: "approved", plans: plans} = lesson, opts) do
    plan = Enum.max_by(plans, & &1.version, fn -> nil end)

    with false <- is_nil(plan),
         true <- plan.approved_by_user,
         {:ok, content_payload} <-
           inject_approved_enrichments(
             plan.content_payload,
             lesson.run_id,
             lesson.id,
             lesson.plan_mode,
             opts
           ),
         {:ok, artifact} <-
           AuthoringCompiler.compile(
             lesson.plan_mode,
             lesson.title,
             content_payload,
             plan.questions_payload,
             lesson.id,
             opts
           ) do
      {:ok,
       Map.merge(
         %{
           "lesson_id" => lesson.id,
           "title" => lesson.title,
           "mode" => lesson.plan_mode,
           "content_payload" => content_payload,
           "questions_payload" => plan.questions_payload,
           "source_evidence_links" => lesson.source_evidence_links
         },
         artifact
       )}
    else
      true -> {:error, {:lesson_not_compilable, lesson.id}}
      false -> {:error, {:lesson_not_compilable, lesson.id}}
      {:error, reason} -> {:error, {:lesson_artifact_invalid, lesson.id, reason}}
      _ -> {:error, {:lesson_not_compilable, lesson.id}}
    end
  end

  defp compile_lesson(lesson, _opts), do: {:error, {:lesson_not_approved, lesson.id}}

  defp inject_approved_enrichments(content, run_id, lesson_id, plan_mode, opts)
       when is_map(content) do
    case {Keyword.get(opts, :plan_schema_version), plan_mode, content["schema_version"]} do
      {7, "basic", 7} ->
        inject_current_enrichments(content, run_id, lesson_id, plan_mode, opts)

      {7, "advanced", 7} ->
        inject_current_enrichments(content, run_id, lesson_id, plan_mode, opts)

      {7, _mode, _content_schema} ->
        {:error, :plan_schema_version_mismatch}

      {version, _mode, _content_schema} ->
        {:error, {:unsupported_openstax_plan_schema, version}}
    end
  end

  defp inject_approved_enrichments(content, _run_id, _lesson_id, _plan_mode, _opts),
    do: {:ok, content}

  defp inject_current_enrichments(content, run_id, lesson_id, plan_mode, opts) do
    proposals =
      proposals_for_lesson(opts, run_id, lesson_id)
      |> Enum.filter(&(&1.state == "approved"))

    generated = Enum.filter(proposals, &(&1.kind == "generated_simulation"))
    curated = Enum.reject(proposals, &(&1.kind == "generated_simulation"))

    with {:ok, content} <- inject_curated_proposals(content, curated) do
      cond do
        generated == [] ->
          {:ok, content}

        plan_mode != "advanced" ->
          {:error, :generated_enrichment_requires_advanced_authoring}

        not generated_delivery_enabled?(opts) ->
          {:ok, remove_generated_references(content)}

        true ->
          inject_generated_proposals_v7(content, generated)
      end
    end
  end

  defp inject_generated_proposals_v7(content, proposals) do
    with {:ok, references} <- build_generated_references(proposals),
         {:ok, blueprint} <-
           place_generated_references(content["experience_blueprint"], references) do
      {:ok, Map.put(content, "experience_blueprint", blueprint)}
    end
  end

  defp build_generated_references(proposals) do
    proposals
    |> Enum.sort_by(& &1.rank)
    |> Enum.reduce_while({:ok, []}, fn proposal, {:ok, references} ->
      artifacts = Map.get(proposal, :simulation_artifacts, [])
      specs = Map.get(proposal, :simulation_specs, [])
      research_sets = Map.get(proposal, :research_sets, [])
      artifact = Enum.find(artifacts, &(&1.status == "approved"))

      spec =
        case artifact do
          nil -> nil
          artifact -> Enum.find(specs, &(&1.id == artifact.simulation_spec_id))
        end

      research =
        case spec do
          nil -> nil
          spec -> Enum.find(research_sets, &(&1.id == spec.research_set_id))
        end

      stage_id = get_in(proposal.placement || %{}, ["stage_id"])
      planner_id = get_in(proposal.metadata || %{}, ["planner_id"])

      if (artifact && spec && research && spec.status == "approved") and
           research.status == "approved" and spec.evidence_hash == research.content_hash and
           is_binary(stage_id) and is_binary(planner_id) do
        reference = %{
          "proposal_id" => proposal.id,
          "planner_id" => planner_id,
          "stage_id" => stage_id,
          "simulation_spec_id" => spec.id,
          "artifact_id" => artifact.id,
          "native_follow_up" => true,
          "remediation" => true
        }

        {:cont, {:ok, references ++ [reference]}}
      else
        {:halt, {:error, {:approved_generated_enrichment_invalid, proposal.id}}}
      end
    end)
  end

  defp place_generated_references(blueprint, references) when is_map(blueprint) do
    stages = List.wrap(blueprint["stages"])
    activities = List.wrap(blueprint["activities"])

    with true <-
           length(Enum.map(references, & &1["stage_id"])) ==
             length(Enum.uniq(Enum.map(references, & &1["stage_id"]))),
         {:ok, placements} <- reference_activity_placements(stages, references),
         true <-
           length(Enum.map(placements, &elem(&1, 0))) ==
             length(Enum.uniq(Enum.map(placements, &elem(&1, 0)))) do
      proposal_by_activity = Map.new(placements)

      tagged =
        Enum.map(activities, fn activity ->
          case Map.fetch(proposal_by_activity, activity["id"]) do
            {:ok, proposal_id} -> Map.put(activity, "enrichment_proposal_id", proposal_id)
            :error -> activity
          end
        end)

      {:ok,
       blueprint
       |> Map.put("activities", tagged)
       |> Map.put("enrichment_references", references)}
    else
      false -> {:error, :generated_simulation_placement_conflict}
      {:error, _} = error -> error
    end
  end

  defp place_generated_references(_blueprint, _references),
    do: {:error, :missing_experience_blueprint}

  defp reference_activity_placements(stages, references) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, placements} ->
      stage = Enum.find(stages, &(&1["id"] == reference["stage_id"]))

      activity_id =
        stage
        |> case do
          %{} -> Map.get(stage, "items", [])
          _ -> []
        end
        |> Enum.find_value(fn
          %{"kind" => "activity", "ref_id" => id} when is_binary(id) -> id
          _ -> nil
        end)

      if is_binary(activity_id) do
        {:cont, {:ok, placements ++ [{activity_id, reference["proposal_id"]}]}}
      else
        {:halt, {:error, :approved_simulation_has_no_native_follow_up}}
      end
    end)
  end

  defp remove_generated_references(content) do
    update_in(
      content,
      [Access.key("experience_blueprint", %{})],
      fn blueprint ->
        blueprint
        |> Map.put("enrichment_references", [])
        |> Map.update("activities", [], fn activities ->
          Enum.map(List.wrap(activities), &Map.delete(&1, "enrichment_proposal_id"))
        end)
      end
    )
  end

  defp generated_delivery_enabled?(opts) do
    enabled =
      Keyword.get(
        opts,
        :generated_simulation_delivery_enabled,
        Application.get_env(:oli, :openstax_generated_simulation_delivery_enabled, false)
      )

    kill_switch =
      Keyword.get(
        opts,
        :generated_simulation_kill_switch,
        Application.get_env(:oli, :openstax_generated_simulation_kill_switch, true)
      )

    enabled and not kill_switch
  end

  defp put_run_plan_schema_version(opts, run) do
    case Map.get(run, :plan_schema_version) do
      version when is_integer(version) -> Keyword.put_new(opts, :plan_schema_version, version)
      _ -> opts
    end
  end

  defp put_preloaded_enrichments(opts, run) do
    case Map.get(run, :enrichment_proposals) do
      proposals when is_list(proposals) ->
        opts
        |> Keyword.put_new(
          :enrichment_proposals_by_lesson,
          Enum.group_by(proposals, & &1.lesson_id)
        )
        |> put_preloaded_artifact_resolver(proposals)

      _not_loaded ->
        opts
    end
  end

  defp put_preloaded_artifact_resolver(opts, proposals) do
    if Enum.all?(proposals, &is_list(Map.get(&1, :simulation_artifacts))) do
      approved_by_proposal =
        proposals
        |> Enum.flat_map(&Map.get(&1, :simulation_artifacts, []))
        |> Enum.filter(&(&1.status == "approved"))
        |> Map.new(&{&1.proposal_id, &1})

      Keyword.put_new(opts, :simulation_artifact_resolver, fn proposal_id ->
        case Map.fetch(approved_by_proposal, proposal_id) do
          {:ok, artifact} -> {:ok, artifact}
          :error -> {:error, :artifact_not_approved}
        end
      end)
    else
      opts
    end
  end

  defp proposals_for_lesson(opts, run_id, lesson_id) do
    case Keyword.fetch(opts, :enrichment_proposals_by_lesson) do
      {:ok, by_lesson} when is_map(by_lesson) -> Map.get(by_lesson, lesson_id, [])
      _ -> Enrichment.list_proposals(run_id, lesson_id)
    end
  end

  defp inject_curated_proposals(content, proposals) do
    content = strip_enrichment_references(content)

    proposals
    |> Enum.sort_by(& &1.rank)
    |> Enum.reduce_while({:ok, []}, fn proposal, {:ok, acc} ->
      case curated_proposal_payload(proposal) do
        {:ok, payload} -> {:cont, {:ok, acc ++ [payload]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, curated} -> {:ok, Map.put(content, "curated_enrichments", curated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp curated_proposal_payload(proposal) do
    with "completed" <- proposal.research_status,
         evidence when is_map(evidence) and map_size(evidence) > 0 <- proposal.research_evidence,
         {:ok, url} <- safe_curated_url(proposal.resource_url) do
      uri = URI.parse(url)

      {:ok,
       %{
         "proposal_id" => proposal.id,
         "kind" => proposal.kind,
         "delivery_mode" => "annotated_link",
         "title" => proposal.resource_title || uri.host,
         "url" => url,
         "annotation" => proposal.instructional_rationale,
         "learner_task" => proposal.learner_task,
         "objective_ids" => proposal.objective_ids,
         "placement" => proposal.placement,
         "research_evidence" => evidence
       }}
    else
      _ -> {:error, {:approved_curated_enrichment_invalid, proposal.id}}
    end
  end

  defp safe_curated_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: host, userinfo: nil} = uri <- URI.parse(String.trim(url)),
         true <- is_binary(host) and host != "",
         true <- is_nil(uri.port) or uri.port == 443 do
      {:ok, URI.to_string(uri)}
    else
      _ -> {:error, :unsafe_curated_resource_url}
    end
  end

  defp safe_curated_url(_), do: {:error, :unsafe_curated_resource_url}

  defp strip_enrichment_references(content) do
    Map.delete(content, "curated_enrichments")
  end
end
