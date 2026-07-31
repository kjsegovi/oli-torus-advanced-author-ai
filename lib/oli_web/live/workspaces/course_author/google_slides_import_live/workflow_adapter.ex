defmodule OliWeb.Workspaces.CourseAuthor.GoogleSlidesImportLive.WorkflowAdapter do
  @moduledoc """
  Keeps the Google Slides import LiveView coupled to the workflow facade instead
  of its persistence or background-job implementation.

  Tests and deployments can replace the workflow with the `:workflow` option in
  the `:google_slides_ai_import` application configuration.
  """

  @default_workflow Oli.GoogleSlides.ImportWorkflow

  def available?(project, author) do
    case call(:available?, [project, author]) do
      true -> true
      _ -> false
    end
  end

  def start_analysis(project, container, author, attrs),
    do: call(:start_analysis, [project, container, author, attrs])

  def get_run(project, author, run_id), do: call(:get_run, [project, author, run_id])

  def get_active_run(project, author, target_container_resource_id),
    do:
      optional_call(
        :get_active_run,
        [project, author, target_container_resource_id],
        {:error, :not_found}
      )

  def submit_answers(run, author, answers), do: call(:submit_answers, [run, author, answers])

  def submit_structure_decision(run, author, proposal_version, decision),
    do:
      call(:submit_structure_decision, [
        run,
        author,
        proposal_version,
        decision
      ])

  def approve_analysis_continuation(run, author, checkpoint_version),
    do:
      call(:approve_analysis_continuation, [
        run,
        author,
        checkpoint_version
      ])

  def approve_plan(run, author, plan_version),
    do: call(:approve_plan, [run, author, plan_version])

  def generate(run, author, plan_version), do: call(:generate, [run, author, plan_version])

  def cancel(run, author), do: call(:cancel, [run, author])

  def workflow do
    case Application.get_env(:oli, :google_slides_ai_import, []) do
      module when is_atom(module) ->
        module

      config when is_list(config) ->
        Keyword.get(config, :workflow, @default_workflow)

      %{} = config ->
        Map.get(config, :workflow) || Map.get(config, "workflow") || @default_workflow

      _ ->
        @default_workflow
    end
  end

  defp call(function, args) do
    workflow = workflow()

    if Code.ensure_loaded?(workflow) and function_exported?(workflow, function, length(args)) do
      apply(workflow, function, args)
    else
      {:error, :workflow_unavailable}
    end
  rescue
    _ -> {:error, :workflow_unavailable}
  end

  defp optional_call(function, args, default) do
    workflow = workflow()

    if Code.ensure_loaded?(workflow) and function_exported?(workflow, function, length(args)) do
      apply(workflow, function, args)
    else
      default
    end
  rescue
    _ -> default
  end
end
