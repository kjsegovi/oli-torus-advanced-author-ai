defmodule Oli.GoogleSlides.ImportWorkflow.Analysis do
  @moduledoc """
  Non-mutating Oban analysis workflow for a Google Slides import run.
  """

  @behaviour Oli.GoogleSlides.ImportRuns.AnalysisWorkflow

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleDocs.SlidesClient

  alias Oli.GoogleSlides.{
    Credentials,
    ImportRuns,
    PresentationParser
  }

  alias Oli.GoogleSlides.ImportWorkflow.{
    AnswerResolver,
    ChunkedAnalysis,
    FidelityValidator,
    ObjectiveCatalog,
    Planner,
    ProvenanceValidator,
    SourceSnapshot
  }

  alias Oli.Publishing.AuthoringResolver
  alias Oli.Repo
  alias Oli.Resources.ResourceType

  @impl true
  def perform(run_id) do
    case ImportRuns.fetch_run(run_id) do
      %{analysis_version: version} when version >= 2 -> ChunkedAnalysis.perform(run_id)
      _run -> perform_legacy(run_id)
    end
  end

  defp perform_legacy(run_id) do
    config = Application.get_env(:oli, :google_slides_ai_import, [])
    slides_client = Keyword.get(config, :slides_client, SlidesClient)
    credentials_module = Keyword.get(config, :credentials, Credentials)
    parser = Keyword.get(config, :presentation_parser, PresentationParser)
    planner = Keyword.get(config, :planner, Planner)
    snapshot_module = Keyword.get(config, :source_snapshot, SourceSnapshot)
    provenance_validator = Keyword.get(config, :provenance_validator, ProvenanceValidator)
    fidelity_validator = Keyword.get(config, :fidelity_validator, FidelityValidator)

    with %{} = run <- ImportRuns.fetch_run(run_id),
         %Project{} = project <- Repo.get(Project, run.project_id),
         %Author{} = author <- Repo.get(Author, run.author_id),
         :ok <- ensure_available(project, author),
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
         source_snapshot <-
           snapshot_module.build(presentation_json, slides, run.presentation_url),
         :ok <- ensure_complete_snapshot(snapshot_module, source_snapshot),
         :ok <- source_unchanged(run, source_snapshot),
         {:ok, trusted_plan} <-
           AnswerResolver.apply(run.lesson_plan, run.answers || %{}),
         objectives <- project_objectives(project),
         planner_context <-
           %{
             source_snapshot: source_snapshot,
             lesson_plan: trusted_plan,
             answers: run.answers || %{},
             layout_mode: get_in(run.options || %{}, ["layout_mode"]) || "responsive",
             allow_triggers: project.allow_triggers == true,
             objectives: objectives
           },
         {:ok, plan, planner_metadata} <-
           continue_planning(planner, trusted_plan, planner_context),
         {:ok, plan} <- ObjectiveCatalog.canonicalize(plan, objectives),
         {:ok, plan} <- fidelity_validator.reconcile(plan, source_snapshot),
         :ok <- provenance_validator.validate(plan, source_snapshot) do
      questions = planner_questions(planner, plan, source_snapshot)
      outcome = if questions == [], do: :ready_for_review, else: :awaiting_answers
      presentation = source_snapshot["presentation"]

      warnings =
        normalize_warnings(parse_warnings) ++
          prior_import_warnings(project, author, run, presentation["id"]) ++
          (plan["warnings"] || [])

      {:ok, outcome,
       %{
         presentation_id: presentation["id"],
         presentation_revision: presentation["revisionId"],
         presentation_fingerprint: presentation["fingerprint"],
         presentation_metadata: snapshot_module.metadata(source_snapshot),
         source_snapshot: source_snapshot,
         questions: questions,
         lesson_plan: plan,
         warnings: warnings,
         validation_results: %{
           "status" => if(outcome == :ready_for_review, do: "ready", else: "blocked"),
           "blockerCount" => length(plan["blockers"] || []),
           "warningCount" => length(warnings)
         },
         model_usage: normalize_planner_metadata(planner_metadata)
       }}
    else
      nil -> {:error, :import_run_context_not_found}
      {:error, _} = error -> error
      other -> {:error, {:analysis_failed, other}}
    end
  end

  defp source_unchanged(%{presentation_fingerprint: nil}, _snapshot), do: :ok

  defp source_unchanged(run, %{"presentation" => %{"fingerprint" => fingerprint}}) do
    if run.presentation_fingerprint == fingerprint, do: :ok, else: {:error, :stale_source}
  end

  defp ensure_available(project, author) do
    if Oli.GoogleSlides.ImportWorkflow.available?(project, author) do
      :ok
    else
      {:error, :import_unavailable}
    end
  end

  defp continue_planning(_planner, %{"blockers" => []} = plan, _context) do
    case Oli.GoogleSlides.AI.LessonPlan.finalize(plan) do
      {:ok, finalized} ->
        {:ok, finalized,
         %{
           steps: 0,
           executions: [],
           estimated_input_tokens: 0,
           resumed_without_model: true
         }}

      {:error, _errors} = error ->
        error
    end
  end

  defp continue_planning(planner, _plan, context), do: planner.plan(context)

  defp planner_questions(planner, plan, source_snapshot) do
    if function_exported?(planner, :questions, 2) do
      planner.questions(plan, source_snapshot)
    else
      planner.questions(plan)
    end
  end

  defp ensure_complete_snapshot(snapshot_module, snapshot) do
    complete? =
      if function_exported?(snapshot_module, :complete?, 1) do
        snapshot_module.complete?(snapshot)
      else
        snapshot["truncated"] != true
      end

    if complete? do
      :ok
    else
      {:error, {:source_snapshot_exceeds_limits, snapshot["limits"] || %{}}}
    end
  end

  defp project_objectives(project) do
    project.slug
    |> AuthoringResolver.revisions_of_type(ResourceType.id_for_objective())
    |> Enum.map(fn objective ->
      %{
        "objectiveId" => Integer.to_string(objective.resource_id),
        "title" => objective.title
      }
    end)
  end

  defp prior_import_warnings(project, author, run, presentation_id)
       when is_binary(presentation_id) do
    case ImportRuns.find_prior_completed_import(project, author, presentation_id, run.id) do
      {:ok, nil} ->
        []

      {:ok, prior} ->
        [
          %{
            "code" => "presentation_reimport",
            "message" =>
              "This presentation was imported before. Generating this plan will create a new lesson.",
            "priorRunId" => prior.id,
            "priorRevisionId" => prior.result_revision_id
          }
        ]

      _ ->
        []
    end
  end

  defp prior_import_warnings(_project, _author, _run, _presentation_id), do: []

  defp normalize_warnings(warnings) when is_list(warnings) do
    Enum.map(warnings, fn
      warning when is_map(warning) -> stringify_keys(warning)
      warning -> %{"code" => "source_warning", "message" => inspect(warning)}
    end)
  end

  defp normalize_warnings(_warnings), do: []

  defp normalize_planner_metadata(metadata) when is_map(metadata) do
    %{
      "steps" => metadata[:steps] || metadata["steps"] || 0,
      "executions" => metadata[:executions] || metadata["executions"] || [],
      "estimated_input_tokens" =>
        metadata[:estimated_input_tokens] || metadata["estimated_input_tokens"] || 0,
      "resumed_without_model" =>
        metadata[:resumed_without_model] || metadata["resumed_without_model"] || false
    }
  end

  defp normalize_planner_metadata(_metadata), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
