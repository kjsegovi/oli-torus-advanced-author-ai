defmodule Oli.GoogleSlides.ImportRuns.AnalysisWorker do
  @moduledoc """
  Runs the configured, non-mutating Google Slides analysis workflow.

  The default callback is `Oli.GoogleSlides.ImportWorkflow.Analysis`. Override
  it with `:google_slides_import_analysis_workflow` in the `:oli`
  application environment for tests or alternate implementations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      # A continuation may be enqueued immediately after this job records
      # blockers, while Oban still considers this job executing.
      states: [:available, :scheduled, :retryable]
    ]

  alias Oli.GoogleSlides.ImportRuns

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id} = args,
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    checkpoint_version = Map.get(args, "checkpoint_version", 0)

    case ImportRuns.fetch_run(run_id) do
      nil ->
        {:discard, :run_not_found}

      %{status: :cancelled} ->
        :ok

      %{status: :analyzing} = run ->
        if stale_checkpoint?(run, checkpoint_version) do
          {:discard, :stale_checkpoint}
        else
          execute(run_id, checkpoint_version, attempt, max_attempts)
        end

      %{status: status} ->
        {:discard, {:invalid_run_status, status}}
    end
  end

  defp execute(run_id, checkpoint_version, attempt, max_attempts) do
    workflow_module()
    |> apply(:perform, [run_id])
    |> case do
      :ok ->
        :ok

      {:ok, outcome, attrs}
      when outcome in [
             :awaiting_structure,
             :awaiting_budget,
             :awaiting_answers,
             :ready_for_review
           ] ->
        case ImportRuns.complete_analysis(run_id, outcome, attrs) do
          {:ok, _run} ->
            :ok

          {:error, reason} ->
            handle_failure(run_id, reason, attempt, max_attempts)
        end

      {:checkpoint, attrs} when is_map(attrs) ->
        case ImportRuns.checkpoint_analysis(run_id, checkpoint_version, attrs) do
          {:ok, _run} ->
            :ok

          {:error, :stale_checkpoint} ->
            {:discard, :stale_checkpoint}

          {:error, reason} ->
            handle_failure(run_id, reason, attempt, max_attempts)
        end

      {:error, reason} ->
        handle_failure(run_id, reason, attempt, max_attempts)

      other ->
        handle_failure(run_id, {:invalid_workflow_result, other}, attempt, max_attempts)
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

  defp stale_checkpoint?(%{analysis_version: version}, _checkpoint_version) when version < 2,
    do: false

  defp stale_checkpoint?(%{analysis_state: state}, checkpoint_version) do
    persisted_version =
      case state do
        %{"checkpoint_version" => version} when is_integer(version) -> version
        %{checkpoint_version: version} when is_integer(version) -> version
        _ -> 0
      end

    persisted_version != checkpoint_version
  end

  defp handle_failure(run_id, reason, attempt, max_attempts) do
    cond do
      retryable_error?(reason) and attempt < max_attempts ->
        persist_retry(run_id, reason, attempt)

      true ->
        persist_failure(run_id, reason, attempt)
    end
  end

  defp persist_retry(run_id, reason, attempt) do
    case ImportRuns.record_retry(run_id, :analysis, reason, attempt) do
      {:ok, _run} -> {:error, reason}
      {:error, lifecycle_error} -> lifecycle_write_failed(run_id, lifecycle_error)
    end
  end

  defp persist_failure(run_id, reason, attempt) do
    case ImportRuns.fail(run_id, :analysis, reason, attempt) do
      {:ok, _run} -> {:discard, reason}
      {:error, lifecycle_error} -> lifecycle_write_failed(run_id, lifecycle_error)
    end
  end

  # A cancel may win the row lock after analysis has begun. In that case the
  # worker must leave the terminal state alone instead of reviving or retrying
  # the run.
  defp lifecycle_write_failed(run_id, lifecycle_error) do
    case ImportRuns.fetch_run(run_id) do
      nil ->
        {:discard, :run_not_found}

      %{status: :analyzing} ->
        {:error, {:analysis_lifecycle_write_failed, lifecycle_error}}

      _terminal_or_advanced_run ->
        :ok
    end
  end

  @doc false
  def retryable_error?({:completion_failed, reason}), do: retryable_error?(reason)
  def retryable_error?({:error, reason}), do: retryable_error?(reason)

  def retryable_error?({kind, status, _body})
      when kind in [:http_status, :token_http_status],
      do: transient_status?(status)

  def retryable_error?(%{status_code: status}), do: transient_status?(status)
  def retryable_error?(%{"status_code" => status}), do: transient_status?(status)
  def retryable_error?(%HTTPoison.Error{reason: reason}), do: retryable_error?(reason)
  def retryable_error?(%ErlangError{original: reason}), do: retryable_error?(reason)

  def retryable_error?({:failed_connect, _details}), do: true

  def retryable_error?(reason)
      when reason in [
             :timeout,
             :connect_timeout,
             :recv_timeout,
             :closed,
             :econnrefused,
             :econnreset,
             :enetdown,
             :enetunreach,
             :ehostdown,
             :ehostunreach,
             :nxdomain,
             :socket_closed_remotely,
             :over_capacity,
             :secondary_breaker_open,
             :secondary_over_capacity,
             :all_breakers_open,
             :backup_breaker_open
           ],
      do: true

  def retryable_error?(_reason), do: false

  defp transient_status?(status) when status in [408, 425, 429], do: true

  defp transient_status?(status) when is_integer(status) and status >= 500 and status <= 599,
    do: true

  defp transient_status?(_status), do: false

  defp workflow_module do
    Application.get_env(
      :oli,
      :google_slides_import_analysis_workflow,
      Oli.GoogleSlides.ImportWorkflow.Analysis
    )
  end
end
