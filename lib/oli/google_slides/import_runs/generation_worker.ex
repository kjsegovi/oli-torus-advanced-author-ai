defmodule Oli.GoogleSlides.ImportRuns.GenerationWorker do
  @moduledoc """
  Runs the configured deterministic lesson-generation workflow.

  The default callback is `Oli.GoogleSlides.ImportWorkflow.Generation`.
  Override it with `:google_slides_import_generation_workflow` in the `:oli`
  application environment for tests or alternate implementations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Oli.GoogleSlides.ImportRuns

  @permanent_atoms [
    :answer_target_not_found,
    :cancelled,
    :google_slides_api_disabled,
    :import_run_context_not_found,
    :import_unavailable,
    :invalid_applier_result,
    :invalid_compiled_page_model,
    :invalid_objective_catalog,
    :invalid_objective_title,
    :invalid_presentation_url,
    :invalid_shape,
    :invalid_target_container,
    :lesson_plan_not_found,
    :not_authorized,
    :not_configured,
    :presentation_not_accessible,
    :result_revision_required,
    :stale_plan,
    :stale_source,
    :transaction_required,
    :working_publication_not_found
  ]

  @permanent_tuple_tags [
    :generation_failed,
    :invalid_lesson_plan,
    :invalid_mapped_objective,
    :invalid_run_status,
    :invalid_source_fidelity,
    :invalid_source_provenance,
    :invalid_transition,
    :missing_keys,
    :source_media_not_found,
    :source_snapshot_exceeds_limits
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case ImportRuns.fetch_run(run_id) do
      nil ->
        {:discard, :run_not_found}

      %{status: :cancelled} ->
        :ok

      %{status: :completed} ->
        :ok

      %{status: :generating} ->
        execute(run_id, attempt, max_attempts)

      %{status: status} ->
        {:discard, {:invalid_run_status, status}}
    end
  end

  defp execute(run_id, attempt, max_attempts) do
    workflow_module()
    |> apply(:perform, [run_id])
    |> case do
      {:ok, _completed_run} ->
        :ok

      {:error, reason} ->
        handle_failure(run_id, reason, attempt, max_attempts)

      other ->
        fail_immediately(run_id, {:invalid_workflow_result, other})
    end
  rescue
    exception ->
      handle_failure(
        run_id,
        ImportRuns.internal_exception(exception, __STACKTRACE__),
        attempt,
        max_attempts
      )
  end

  defp handle_failure(_run_id, :cancelled, _attempt, _max_attempts), do: :ok

  defp handle_failure(run_id, reason, _attempt, _max_attempts)
       when reason in @permanent_atoms do
    fail_immediately(run_id, reason)
  end

  defp handle_failure(run_id, reason, attempt, max_attempts) do
    cond do
      permanent_error?(reason) ->
        fail_immediately(run_id, reason)

      attempt >= max_attempts ->
        fail_immediately(run_id, reason)

      true ->
        case ImportRuns.record_retry(run_id, :generation, reason, attempt) do
          {:ok, _run} -> {:error, reason}
          {:error, transition_error} -> terminal_race_result(run_id, transition_error)
        end
    end
  end

  defp fail_immediately(run_id, reason) do
    case ImportRuns.fail(run_id, :generation, reason) do
      {:ok, _run} -> {:discard, reason}
      {:error, transition_error} -> terminal_race_result(run_id, transition_error)
    end
  end

  defp terminal_race_result(run_id, fallback_error) do
    case ImportRuns.fetch_run(run_id) do
      %{status: status} when status in [:cancelled, :completed] -> :ok
      %{status: :failed} -> {:discard, fallback_error}
      _ -> {:error, fallback_error}
    end
  end

  defp permanent_error?(%Ecto.Changeset{}), do: true

  defp permanent_error?({tag, _detail}) when tag in @permanent_tuple_tags, do: true

  defp permanent_error?({tag, _left, _right}) when tag in @permanent_tuple_tags, do: true

  defp permanent_error?({:http_status, status, _body}),
    do: permanent_http_status?(status)

  defp permanent_error?({:token_http_status, status, _body}),
    do: permanent_http_status?(status)

  defp permanent_error?(_reason), do: false

  defp permanent_http_status?(status) when status in 400..499,
    do: status not in [408, 425, 429]

  defp permanent_http_status?(_status), do: false

  defp workflow_module do
    Application.get_env(
      :oli,
      :google_slides_import_generation_workflow,
      Oli.GoogleSlides.ImportWorkflow.Generation
    )
  end
end
