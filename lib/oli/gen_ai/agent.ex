defmodule Oli.GenAI.Agent do
  @moduledoc """
  Public API for starting/controlling agent runs and querying status.
  """

  alias Oli.GenAI.Agent.{Persistence, PubSub, RunSupervisor, Server}

  @type run_id :: String.t()
  @await_poll_interval_ms 250

  @spec start_run(map) :: {:ok, pid} | {:error, term}
  def start_run(%{} = args), do: RunSupervisor.start_run(args)

  @spec pause(run_id) :: :ok | {:error, term}
  def pause(run_id), do: call_server(run_id, :pause)

  @spec resume(run_id) :: :ok | {:error, term}
  def resume(run_id), do: call_server(run_id, :resume)

  @spec cancel(run_id) :: :ok | {:error, term}
  def cancel(run_id), do: call_server(run_id, :cancel)

  @spec status(run_id) :: {:ok, map} | {:error, term}
  def status(run_id), do: call_server(run_id, :status)

  @spec info(run_id) :: {:ok, map} | {:error, term}
  def info(run_id), do: call_server(run_id, :info)

  @doc "Waits until a run reaches a terminal state and returns its terminal result."
  @spec await_result(run_id, timeout()) :: {:ok, map()} | {:error, term()}
  def await_result(run_id, timeout \\ 600_000)

  def await_result(run_id, timeout) when is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_result_until(run_id, deadline)
  end

  @spec subscribe(run_id) :: :ok
  def subscribe(run_id) do
    topic = PubSub.topic(run_id)
    Phoenix.PubSub.subscribe(Oli.PubSub, topic)
  end

  defp call_server(run_id, msg) do
    case Server.whereis(run_id) do
      nil ->
        {:error, "Agent run not found: #{run_id}"}

      pid ->
        try do
          GenServer.call(pid, msg, 10_000)
        catch
          :exit, {:noproc, _} ->
            {:error, "Agent run not found: #{run_id}"}

          :exit, {:timeout, _} ->
            {:error, "Agent run timed out: #{run_id}"}
        end
    end
  end

  defp await_result_until(run_id, deadline) do
    case durable_result(run_id) do
      {:ok, result} ->
        {:ok, result}

      {:pending, _status} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :await_timeout}
        else
          Process.sleep(@await_poll_interval_ms)
          await_result_until(run_id, deadline)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp durable_result(run_id) do
    case Persistence.get_run(run_id) do
      %{status: "completed"} = run ->
        {:ok,
         %{
           run_id: run.id,
           status: "completed",
           terminal_status: terminal_status(run.terminal_status, :completed),
           reason: run.terminal_reason || "Recovered durable terminal result.",
           input_tokens: run.tokens_in || 0,
           output_tokens: run.tokens_out || 0,
           tokens_used: (run.tokens_in || 0) + (run.tokens_out || 0),
           cost_cents: run.cost_cents || 0,
           metadata: run.metadata || %{}
         }}

      %{status: "error"} = run ->
        {:ok,
         %{
           run_id: run.id,
           status: "error",
           terminal_status: terminal_status(run.terminal_status, :provider_failure),
           reason: run.terminal_reason || "Recovered durable failed result.",
           input_tokens: run.tokens_in || 0,
           output_tokens: run.tokens_out || 0,
           tokens_used: (run.tokens_in || 0) + (run.tokens_out || 0),
           cost_cents: run.cost_cents || 0,
           metadata: run.metadata || %{}
         }}

      %{status: status} when status in ["running", "paused"] ->
        {:pending, status}

      %{status: "cancelled"} = run ->
        {:ok,
         %{
           run_id: run.id,
           status: "cancelled",
           terminal_status: :cancelled,
           reason: run.terminal_reason || "Agent run was cancelled.",
           input_tokens: run.tokens_in || 0,
           output_tokens: run.tokens_out || 0,
           tokens_used: (run.tokens_in || 0) + (run.tokens_out || 0),
           cost_cents: run.cost_cents || 0,
           metadata: run.metadata || %{}
         }}

      _ ->
        {:error, "Agent run not found: #{run_id}"}
    end
  end

  defp terminal_status("completed", _fallback), do: :completed
  defp terminal_status("step_budget_exhausted", _fallback), do: :step_budget_exhausted
  defp terminal_status("token_budget_exhausted", _fallback), do: :token_budget_exhausted
  defp terminal_status("cost_budget_exhausted", _fallback), do: :cost_budget_exhausted
  defp terminal_status("deadline_exceeded", _fallback), do: :deadline_exceeded
  defp terminal_status("loop_detected", _fallback), do: :loop_detected
  defp terminal_status("invalid_decision", _fallback), do: :invalid_decision
  defp terminal_status("provider_failure", _fallback), do: :provider_failure
  defp terminal_status(_status, fallback), do: fallback
end
