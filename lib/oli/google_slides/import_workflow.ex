defmodule Oli.GoogleSlides.ImportWorkflow do
  @moduledoc """
  Author-facing facade for the AI-assisted Google Slides import workflow.

  Analysis and planning are durable but non-mutating. Course content is only
  created after an author approves the current plan and starts generation.
  """

  alias Oli.Accounts.Author
  alias Oli.Authoring.Course
  alias Oli.Authoring.Course.Project
  alias Oli.GoogleSlides.{GenAI, ImportRun, ImportRuns, SlidesImport}
  alias Oli.GoogleSlides.ImportWorkflow.AnswerResolver
  alias Oli.Resources.Revision

  @spec available?(Project.t(), Author.t()) :: boolean()
  def available?(%Project{} = project, %Author{} = author) do
    SlidesImport.import_available?(project, author) and GenAI.configured?()
  rescue
    _ -> false
  end

  @spec start_analysis(Project.t(), Revision.t(), Author.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def start_analysis(
        %Project{} = project,
        %Revision{} = target_container,
        %Author{} = author,
        attrs
      )
      when is_map(attrs) do
    options = %{
      "layout_mode" => value(attrs, :layout_mode, "responsive")
    }

    if available?(project, author) do
      ImportRuns.start_analysis(project, author, target_container, %{
        presentation_url: value(attrs, :presentation_url),
        options: options
      })
    else
      {:error, :import_unavailable}
    end
  end

  @spec get_run(Project.t(), Author.t(), Ecto.UUID.t()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def get_run(%Project{} = project, %Author{} = author, run_id) do
    ImportRuns.get_run(project, author, run_id)
  end

  @spec get_active_run(Project.t(), Author.t(), pos_integer()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def get_active_run(
        %Project{} = project,
        %Author{} = author,
        target_container_resource_id
      )
      when is_integer(target_container_resource_id) do
    ImportRuns.get_active_run(project, author, target_container_resource_id)
  end

  @spec submit_answers(ImportRun.t(), Author.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def submit_answers(%ImportRun{} = run, %Author{} = author, answers) when is_map(answers) do
    with {:ok, project} <- fetch_project(run.project_id),
         true <- available?(project, author),
         {:ok, _validated_plan} <- AnswerResolver.apply(run.lesson_plan, answers) do
      ImportRuns.submit_answers(project, author, run.id, answers)
    else
      false -> {:error, :import_unavailable}
      {:error, _} = error -> error
    end
  end

  @spec submit_structure_decision(
          ImportRun.t(),
          Author.t(),
          non_neg_integer(),
          :one_lesson | :split | String.t()
        ) :: {:ok, ImportRun.t()} | {:error, term()}
  def submit_structure_decision(
        %ImportRun{} = run,
        %Author{} = author,
        proposal_version,
        decision
      ) do
    with {:ok, project} <- fetch_project(run.project_id) do
      ImportRuns.submit_structure_decision(
        project,
        author,
        run.id,
        proposal_version,
        decision
      )
    end
  end

  @spec approve_analysis_continuation(
          ImportRun.t(),
          Author.t(),
          non_neg_integer()
        ) :: {:ok, ImportRun.t()} | {:error, term()}
  def approve_analysis_continuation(
        %ImportRun{} = run,
        %Author{} = author,
        checkpoint_version
      ) do
    with {:ok, project} <- fetch_project(run.project_id) do
      ImportRuns.approve_analysis_continuation(
        project,
        author,
        run.id,
        checkpoint_version
      )
    end
  end

  @spec approve_plan(ImportRun.t(), Author.t(), non_neg_integer()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def approve_plan(%ImportRun{} = run, %Author{} = author, plan_version)
      when is_integer(plan_version) and plan_version >= 0 do
    with {:ok, project} <- fetch_project(run.project_id) do
      ImportRuns.approve_plan(project, author, run.id, plan_version)
    end
  end

  @spec generate(ImportRun.t(), Author.t(), non_neg_integer()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def generate(%ImportRun{} = run, %Author{} = author, plan_version)
      when is_integer(plan_version) and plan_version >= 0 do
    with {:ok, project} <- fetch_project(run.project_id) do
      ImportRuns.start_generation(
        project,
        author,
        run.id,
        plan_version: plan_version,
        presentation_fingerprint: run.presentation_fingerprint
      )
    end
  end

  @spec cancel(ImportRun.t(), Author.t()) :: {:ok, ImportRun.t()} | {:error, term()}
  def cancel(%ImportRun{} = run, %Author{} = author) do
    with {:ok, project} <- fetch_project(run.project_id) do
      ImportRuns.cancel(project, author, run.id)
    end
  end

  defp fetch_project(project_id) do
    case Course.get_project!(project_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :project_not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :project_not_found}
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
