defmodule Oli.GenAI.Agent.Server do
  use GenServer
  require Logger

  alias Oli.GenAI.Agent.{Critic, Decision, LLMBridge, Persistence, PubSub, Summarizer, ToolBroker}

  defmodule Step do
    @enforce_keys [:num, :action, :observation]
    defstruct [
      :num,
      :action,
      :observation,
      :rationale_summary,
      :latency_ms,
      :tokens_in,
      :tokens_out
    ]

    @type t :: %__MODULE__{
            num: integer(),
            action: map(),
            observation: term(),
            rationale_summary: String.t() | nil,
            latency_ms: integer() | nil,
            tokens_in: integer() | nil,
            tokens_out: integer() | nil
          }
  end

  defmodule State do
    defstruct [
      :id,
      :goal,
      :plan,
      # :idle | :thinking | :acting | :awaiting_tool | :done | :error | :paused | :cancelled
      :status,
      :budgets,
      :service_config,
      :policy,
      :tool_broker,
      :tool_context,
      :system_instructions,
      :llm_bridge,
      :context_summary,
      :short_window,
      :steps,
      :inflight,
      :metadata,
      :tokens_used,
      :input_tokens_used,
      :output_tokens_used,
      :cost_cents,
      :start_time,
      :provider_retries,
      :max_provider_retries,
      :result
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            goal: String.t(),
            plan: [String.t()],
            status: atom(),
            budgets: map(),
            service_config: map() | nil,
            policy: module() | nil,
            tool_broker: module(),
            tool_context: map(),
            system_instructions: String.t() | nil,
            llm_bridge: module(),
            context_summary: String.t(),
            short_window: [map()],
            steps: [Step.t()],
            inflight: map(),
            metadata: map(),
            tokens_used: integer(),
            input_tokens_used: integer(),
            output_tokens_used: integer(),
            cost_cents: integer(),
            start_time: DateTime.t(),
            provider_retries: non_neg_integer(),
            max_provider_retries: non_neg_integer(),
            result: map() | nil
          }
  end

  # Client API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(args[:run_id]))
  end

  def pause(run_id) do
    GenServer.call(via_tuple(run_id), :pause)
  end

  def resume(run_id) do
    GenServer.call(via_tuple(run_id), :resume)
  end

  def cancel(run_id) do
    GenServer.call(via_tuple(run_id), :cancel)
  end

  def status(run_id) do
    GenServer.call(via_tuple(run_id), :status)
  end

  def info(run_id) do
    GenServer.call(via_tuple(run_id), :info)
  end

  def whereis(run_id) do
    case Registry.lookup(Oli.GenAI.Agent.Registry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Server Callbacks

  @impl true
  def init(args) do
    id = Map.get(args, :run_id, Ecto.UUID.generate())

    state = %State{
      id: id,
      goal: Map.fetch!(args, :goal),
      plan: Map.get(args, :plan, []),
      status: :idle,
      budgets: Map.merge(default_budgets(), Map.get(args, :budgets, %{})),
      service_config: Map.get(args, :service_config),
      policy: Map.get(args, :policy),
      tool_broker: Map.get(args, :tool_broker, ToolBroker),
      tool_context: Map.get(args, :tool_context, %{}),
      system_instructions: Map.get(args, :system_instructions),
      llm_bridge: Map.get(args, :llm_bridge, LLMBridge),
      context_summary: Map.get(args, :context_summary, ""),
      short_window: Map.get(args, :initial_messages, []),
      steps: [],
      inflight: %{},
      metadata: Map.get(args, :metadata, %{}),
      tokens_used: 0,
      input_tokens_used: 0,
      output_tokens_used: 0,
      cost_cents: 0,
      start_time: DateTime.utc_now(),
      provider_retries: 0,
      max_provider_retries: Map.get(args, :max_provider_retries, 2),
      result: nil
    }

    persistence_result =
      Persistence.create_run(%{
        id: id,
        goal: state.goal,
        run_type: Map.get(args, :run_type, "general"),
        plan: %{steps: state.plan},
        status: "running",
        budgets: state.budgets,
        metadata: state.metadata,
        user_id: Map.get(args, :user_id),
        author_id: Map.get(args, :author_id),
        project_id: Map.get(args, :project_id),
        section_id: Map.get(args, :section_id),
        model: primary_model_name(state.service_config)
      })

    case persistence_result do
      {:ok, _run} ->
        Process.send_after(self(), :step, 0)
        {:ok, state}

      {:error, %Ecto.Changeset{} = changeset} ->
        details = persistence_error_details(changeset)
        Logger.error("Agent run persistence failed: #{inspect(details)}")
        {:stop, {:run_persistence_failed, details}}

      {:error, reason} ->
        Logger.error("Agent run persistence failed: #{inspect(reason)}")
        {:stop, {:run_persistence_failed, %{reason: safe_reason(reason)}}}
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    new_state = %{state | status: :paused}
    PubSub.broadcast_status(state.id, %{status: :paused})
    {:reply, :ok, new_state}
  end

  def handle_call(:resume, _from, %{status: :paused} = state) do
    new_state = %{state | status: :idle}
    PubSub.broadcast_status(state.id, %{status: :idle})
    Process.send_after(self(), :step, 0)
    {:reply, :ok, new_state}
  end

  def handle_call(:resume, _from, state) do
    {:reply, {:error, "Not paused"}, state}
  end

  def handle_call(:cancel, _from, state) do
    new_state = %{state | status: :cancelled}
    PubSub.broadcast_status(state.id, %{status: :cancelled})
    Persistence.update_run(state.id, %{status: "cancelled", finished_at: DateTime.utc_now()})
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    status_info = %{
      id: state.id,
      status: state.status,
      goal: state.goal,
      plan: state.plan,
      steps_completed: length(state.steps)
    }

    {:reply, {:ok, status_info}, state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      status: state.status,
      goal: state.goal,
      plan: state.plan,
      steps_completed: length(state.steps),
      last_step: List.first(state.steps),
      budgets: state.budgets,
      context_summary: state.context_summary,
      metadata: state.metadata,
      tokens_used: state.tokens_used,
      input_tokens_used: state.input_tokens_used,
      output_tokens_used: state.output_tokens_used,
      cost_cents: state.cost_cents
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:result, _from, %{result: nil} = state) do
    {:reply, {:pending, state.status}, state}
  end

  def handle_call(:result, _from, state) do
    {:reply, {:ok, state.result}, state}
  end

  @impl true
  def handle_info(:step, %{status: status} = state)
      when status in [:paused, :cancelled, :done, :error] do
    # Don't process steps when paused, cancelled, done, or in error
    {:noreply, state}
  end

  def handle_info(:step, %{status: :awaiting_tool} = state) do
    # Wait for tool to complete
    {:noreply, state}
  end

  def handle_info(:step, state) do
    state = %{state | status: :thinking}

    # Check budgets and policy
    case check_stop_conditions(state) do
      {:stop, terminal_status, reason} ->
        Logger.info("Agent stopping: #{reason}")
        finalize_run(state, terminal_status, reason)

      :continue ->
        process_think_phase(state)
    end
  end

  def handle_info({:tool_result, call_id, result}, %{inflight: inflight} = state) do
    case Map.get(inflight, call_id) do
      nil ->
        Logger.warning("Received result for unknown tool call: #{call_id}")
        {:noreply, state}

      tool_info ->
        state = handle_tool_observation(state, tool_info, result)
        new_inflight = Map.delete(inflight, call_id)
        new_state = %{state | inflight: new_inflight, status: :idle}

        # Schedule next step
        Process.send_after(self(), :step, 100)
        {:noreply, new_state}
    end
  end

  # Private functions

  defp via_tuple(run_id) do
    {:via, Registry, {Oli.GenAI.Agent.Registry, run_id}}
  end

  defp default_budgets do
    %{
      max_steps: 50,
      max_tokens: 100_000,
      max_cost_cents: 1000,
      deadline_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }
  end

  defp primary_model_name(%{primary_model: %{model: model}}), do: model
  defp primary_model_name(_service_config), do: nil

  defp check_stop_conditions(state) do
    cond do
      # Check step limit
      length(state.steps) >= state.budgets.max_steps ->
        {:stop, :step_budget_exhausted, "Step limit reached"}

      # Check token budget
      state.tokens_used >= state.budgets.max_tokens ->
        {:stop, :token_budget_exhausted, "Token budget exceeded"}

      # Check cost budget
      state.cost_cents >= state.budgets.max_cost_cents ->
        {:stop, :cost_budget_exhausted, "Cost budget exceeded"}

      # Check deadline
      DateTime.compare(DateTime.utc_now(), state.budgets.deadline_at) == :gt ->
        {:stop, :deadline_exceeded, "Deadline exceeded"}

      # Check for looping
      Critic.looping?(state.steps) ->
        {:stop, :loop_detected, "Detected looping behavior"}

      # Check policy
      state.policy && state.policy.stop_reason?(state) ->
        case state.policy.stop_reason?(state) do
          nil -> :continue
          {:done, reason} -> {:stop, :completed, reason}
        end

      true ->
        :continue
    end
  end

  defp process_think_phase(state) do
    start_time = System.monotonic_time(:millisecond)

    # Build messages for LLM
    messages = build_messages(state)

    # Get decision from LLM
    opts = %{
      service_config: state.service_config,
      temperature: 0.7,
      max_tokens: Map.get(state.metadata, :max_tokens_per_step, 2000)
    }

    opts = Map.put(opts, :tools, state.tool_broker.tools_for_completion())

    case state.llm_bridge.next_decision_with_metadata(messages, opts) do
      {:ok, decision, usage} ->
        latency_ms = System.monotonic_time(:millisecond) - start_time
        state = track_usage_metadata(state, usage)

        # Validate decision
        case Decision.validate(decision) do
          :ok ->
            process_policy_phase(state, decision, latency_ms, usage)

          {:error, errors} ->
            Logger.error("Invalid decision: #{inspect(errors)}")
            finalize_run(state, :invalid_decision, "Invalid decision from LLM")
        end

      {:error, reason} ->
        handle_provider_failure(state, reason)
    end
  end

  defp process_policy_phase(state, decision, latency_ms, usage) do
    case allowed_action?(state, decision) do
      true ->
        process_act_phase(state, decision, latency_ms, usage)

      {false, reason} ->
        step = %Step{
          num: length(state.steps) + 1,
          action: decision_action(decision),
          observation: %{error: "Policy denied action: #{reason}"},
          rationale_summary: decision.rationale_summary,
          latency_ms: latency_ms,
          tokens_in: usage.input_tokens,
          tokens_out: usage.output_tokens
        }

        new_state = update_state_with_step(state, step)

        policy_message = %{
          role: :user,
          content: "Policy feedback: #{Jason.encode!(step.observation)}"
        }

        Process.send_after(self(), :step, 100)

        {:noreply,
         %{new_state | status: :idle, short_window: new_state.short_window ++ [policy_message]}}
    end
  end

  defp allowed_action?(%{policy: nil}, _decision), do: true
  defp allowed_action?(state, decision), do: state.policy.allowed_action?(decision, state)

  defp track_usage_metadata(state, usage) do
    metadata =
      state.metadata
      |> maybe_put_metadata(:provider, usage[:provider])
      |> maybe_put_metadata(:model, usage[:model])

    %{state | metadata: metadata}
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp handle_provider_failure(state, reason) do
    Logger.error("LLM error: #{inspect(reason)}")

    if retryable_provider_failure?(reason) and state.provider_retries < state.max_provider_retries do
      retries = state.provider_retries + 1
      Process.send_after(self(), :step, retries * 500)
      {:noreply, %{state | status: :idle, provider_retries: retries}}
    else
      details = provider_failure_details(reason)
      metadata = Map.put(state.metadata, :provider_failure, details)

      finalize_run(
        %{state | metadata: metadata},
        :provider_failure,
        provider_failure_message(details)
      )
    end
  end

  defp build_messages(state) do
    system_prompt = build_system_prompt(state)

    messages = [
      %{role: :system, content: system_prompt}
    ]

    # Add context summary if present
    messages =
      if state.context_summary != "" do
        messages ++ [%{role: :system, content: "Context: #{state.context_summary}"}]
      else
        messages
      end

    # Add short window messages
    messages ++ state.short_window
  end

  defp build_system_prompt(state) do
    tools_desc =
      state.tool_broker.describe()
      |> Enum.map(fn tool -> "- #{tool.name}: #{tool.desc}" end)
      |> Enum.join("\n")

    scoped_instructions =
      case state.system_instructions do
        instructions when is_binary(instructions) and instructions != "" ->
          "\nAdditional required instructions:\n#{instructions}\n"

        _ ->
          ""
      end

    """
    You are an AI agent working to achieve the following goal:
    #{state.goal}

    Current plan:
    #{Enum.join(state.plan, "\n")}

    Available tools:
    #{tools_desc}
    #{scoped_instructions}

    Steps completed: #{length(state.steps)}
    Budget remaining: #{state.budgets.max_steps - length(state.steps)} steps

    Respond with one of:
    - Use a tool: {"action": "tool", "name": "tool_name", "args": {...}}
    - Send a message: {"action": "message", "content": "..."}
    - Replan: {"action": "replan", "updated_plan": [...], "rationale": "..."}
    - Complete: {"action": "done", "rationale": "..."}
    """
  end

  defp process_act_phase(state, decision, latency_ms, usage) do
    case decision.next_action do
      "tool" ->
        execute_tool_action(state, decision, latency_ms, usage)

      "message" ->
        execute_message_action(state, decision, latency_ms, usage)

      "replan" ->
        execute_replan_action(state, decision, latency_ms, usage)

      "done" ->
        execute_done_action(state, decision, latency_ms, usage)
    end
  end

  defp execute_tool_action(state, decision, latency_ms, usage) do
    call_id = decision.tool_call_id || generate_call_id()

    # Store inflight tool call
    tool_info = %{
      call_id: call_id,
      name: decision.tool_name,
      args: decision.arguments,
      provider_output: decision.provider_output,
      started_at: DateTime.utc_now(),
      latency_ms: latency_ms,
      tokens_in: usage.input_tokens,
      tokens_out: usage.output_tokens
    }

    new_inflight = Map.put(state.inflight, call_id, tool_info)
    new_state = %{state | status: :awaiting_tool, inflight: new_inflight}

    # Execute tool asynchronously
    parent = self()

    Task.start(fn ->
      context = Map.put(state.tool_context, :run_id, state.id)
      result = state.tool_broker.call(decision.tool_name, decision.arguments, context)
      send(parent, {:tool_result, call_id, result})
    end)

    {:noreply, new_state}
  end

  defp execute_message_action(state, decision, latency_ms, usage) do
    step = %Step{
      num: length(state.steps) + 1,
      action: %{type: "message", content: decision.assistant_message},
      observation: %{acknowledged: true},
      rationale_summary: decision.rationale_summary,
      latency_ms: latency_ms,
      tokens_in: usage.input_tokens,
      tokens_out: usage.output_tokens
    }

    new_state = update_state_with_step(state, step)

    new_state = %{
      new_state
      | short_window:
          new_state.short_window ++
            [
              %{role: :assistant, content: decision.assistant_message}
            ]
    }

    # Schedule next step
    Process.send_after(self(), :step, 100)
    {:noreply, new_state}
  end

  defp execute_replan_action(state, decision, latency_ms, usage) do
    step = %Step{
      num: length(state.steps) + 1,
      action: %{type: "replan", new_plan: decision.updated_plan},
      observation: %{plan_updated: true},
      rationale_summary: decision.rationale_summary,
      latency_ms: latency_ms,
      tokens_in: usage.input_tokens,
      tokens_out: usage.output_tokens
    }

    new_state = update_state_with_step(state, step)
    new_state = %{new_state | plan: decision.updated_plan}

    # Persist updated plan
    Persistence.update_run(state.id, %{plan: %{steps: decision.updated_plan}})

    # Schedule next step
    Process.send_after(self(), :step, 100)
    {:noreply, new_state}
  end

  defp execute_done_action(state, decision, latency_ms, usage) do
    step = %Step{
      num: length(state.steps) + 1,
      action: %{type: "done"},
      observation: %{completed: true},
      rationale_summary: decision.rationale_summary,
      latency_ms: latency_ms,
      tokens_in: usage.input_tokens,
      tokens_out: usage.output_tokens
    }

    new_state = update_state_with_step(state, step)
    finalize_run(new_state, :completed, decision.rationale_summary || "Task completed")
  end

  defp handle_tool_observation(state, tool_info, result) do
    {observation, tokens} =
      case result do
        {:ok, %{content: content, token_cost: cost}} ->
          # Ensure observation is always a map
          obs = if is_map(content), do: content, else: %{content: content}
          {obs, cost}

        {:error, error} ->
          {%{error: error}, 0}
      end

    step = %Step{
      num: length(state.steps) + 1,
      action: %{type: "tool", name: tool_info.name, args: tool_info.args},
      observation: observation,
      latency_ms: tool_info.latency_ms,
      tokens_in: tool_info.tokens_in,
      tokens_out: tool_info.tokens_out + tokens
    }

    new_state = update_state_with_step(state, step)

    # Add tool result to short window in proper format
    tool_message = format_tool_result_message(tool_info, observation)
    %{new_state | short_window: new_state.short_window ++ [tool_message]}
  end

  defp update_state_with_step(state, step) do
    # Keep last 20 steps
    new_steps = [step | state.steps] |> Enum.take(20)

    # Update tokens and cost
    new_tokens = state.tokens_used + (step.tokens_in || 0) + (step.tokens_out || 0)
    new_input_tokens = state.input_tokens_used + (step.tokens_in || 0)
    new_output_tokens = state.output_tokens_used + (step.tokens_out || 0)
    new_cost = state.cost_cents + estimate_cost(step)

    # Update context summary if needed
    new_summary =
      if rem(length(new_steps), 5) == 0 do
        Summarizer.rollup(state.context_summary, step.observation)
      else
        state.context_summary
      end

    # Prune short window
    new_window = Summarizer.prune_window(state.short_window, 12)

    # Persist step (check for duplicates first)
    if Enum.any?(state.steps, fn s -> s.num == step.num end) do
      require Logger

      Logger.warning(
        "Attempting to persist duplicate step #{step.num} for run #{state.id}, skipping"
      )
    else
      case Persistence.append_step(%{
             run_id: state.id,
             step_num: step.num,
             phase: Atom.to_string(state.status),
             action: step.action,
             observation: step.observation,
             rationale_summary: step.rationale_summary,
             tokens_in: step.tokens_in,
             tokens_out: step.tokens_out,
             latency_ms: step.latency_ms
           }) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          # Log the error but don't crash the agent
          require Logger

          Logger.warning(
            "Failed to persist step #{step.num} for run #{state.id}: #{inspect(changeset.errors)}"
          )
      end
    end

    # Broadcast step
    PubSub.broadcast_step(state.id, step)

    %{
      state
      | steps: new_steps,
        tokens_used: new_tokens,
        input_tokens_used: new_input_tokens,
        output_tokens_used: new_output_tokens,
        cost_cents: new_cost,
        context_summary: new_summary,
        short_window: new_window
    }
  end

  defp finalize_run(state, terminal_status, reason) do
    final_status = if terminal_status == :completed, do: "completed", else: "error"

    result = %{
      run_id: state.id,
      status: final_status,
      terminal_status: terminal_status,
      reason: reason,
      steps_completed: length(state.steps),
      tokens_used: state.tokens_used,
      input_tokens: state.input_tokens_used,
      output_tokens: state.output_tokens_used,
      cost_cents: state.cost_cents,
      metadata: state.metadata
    }

    Persistence.update_run(state.id, %{
      status: final_status,
      terminal_status: to_string(terminal_status),
      terminal_reason: reason,
      metadata: state.metadata,
      finished_at: DateTime.utc_now(),
      tokens_in: state.input_tokens_used,
      tokens_out: state.output_tokens_used,
      cost_cents: state.cost_cents
    })

    PubSub.broadcast_status(state.id, %{
      status: final_status,
      reason: reason,
      steps_completed: length(state.steps)
    })

    {:noreply,
     %{state | status: if(final_status == "completed", do: :done, else: :error), result: result}}
  end

  defp decision_action(%Decision{next_action: "tool"} = decision),
    do: %{type: "tool", name: decision.tool_name, args: decision.arguments}

  defp decision_action(%Decision{next_action: action}), do: %{type: action}

  defp retryable_provider_failure?(reason) do
    status = provider_status(reason)

    status == 429 or status in 500..599 or
      contains_failure_atom?(reason, [
        :timeout,
        :connect_timeout,
        :recv_timeout,
        :closed,
        :econnrefused,
        :enetunreach
      ])
  end

  defp provider_failure_details(reason) do
    status = provider_status(reason)

    %{
      "category" => provider_failure_category(status, reason)
    }
    |> maybe_put_failure_detail("status_code", status)
    |> Map.merge(provider_error_fields(reason))
  end

  defp provider_failure_category(429, _reason), do: "rate_limited"
  defp provider_failure_category(status, _reason) when status in 500..599, do: "unavailable"
  defp provider_failure_category(status, _reason) when status in 400..499, do: "request_rejected"

  defp provider_failure_category(_status, reason) do
    if contains_failure_atom?(reason, [
         :timeout,
         :connect_timeout,
         :recv_timeout,
         :closed,
         :econnrefused,
         :enetunreach
       ]),
       do: "transport",
       else: "unknown"
  end

  defp provider_failure_message(%{"status_code" => 429}),
    do: "Provider rate limit reached (HTTP 429)."

  defp provider_failure_message(%{"status_code" => status}) when status in 500..599,
    do: "Provider is temporarily unavailable (HTTP #{status})."

  defp provider_failure_message(%{"status_code" => status}) when status in 400..499,
    do: "Provider rejected the agent request (HTTP #{status})."

  defp provider_failure_message(%{"category" => "transport"}),
    do: "Provider connection failed."

  defp provider_failure_message(_details), do: "Provider request failed."

  defp provider_status(status) when is_integer(status) and status in 400..599, do: status
  defp provider_status({:http_error, status}) when is_integer(status), do: status

  defp provider_status(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.find_value(&provider_status/1)
  end

  defp provider_status(term) when is_map(term) do
    direct =
      Map.get(term, :status_code) || Map.get(term, "status_code") || Map.get(term, :status) ||
        Map.get(term, "status") || Map.get(term, :http_status) || Map.get(term, "http_status")

    if is_integer(direct), do: direct, else: Enum.find_value(Map.values(term), &provider_status/1)
  end

  defp provider_status(term) when is_list(term), do: Enum.find_value(term, &provider_status/1)
  defp provider_status(_term), do: nil

  defp provider_error_fields(%{body: body}) when is_binary(body),
    do: decode_provider_error_fields(body)

  defp provider_error_fields(%{"body" => body}) when is_binary(body),
    do: decode_provider_error_fields(body)

  defp provider_error_fields(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.find_value(%{}, fn value ->
      case provider_error_fields(value) do
        fields when map_size(fields) > 0 -> fields
        _ -> nil
      end
    end)
  end

  defp provider_error_fields(term) when is_map(term) do
    term
    |> Map.values()
    |> Enum.find_value(%{}, fn value ->
      case provider_error_fields(value) do
        fields when map_size(fields) > 0 -> fields
        _ -> nil
      end
    end)
  end

  defp provider_error_fields(_term), do: %{}

  defp decode_provider_error_fields(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) ->
        %{}
        |> maybe_put_failure_detail("provider_error_type", safe_provider_field(error["type"]))
        |> maybe_put_failure_detail("provider_error_code", safe_provider_field(error["code"]))
        |> maybe_put_failure_detail("provider_error_param", safe_provider_field(error["param"]))

      _ ->
        %{}
    end
  end

  defp safe_provider_field(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp safe_provider_field(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_provider_field(_value), do: nil

  defp maybe_put_failure_detail(map, _key, nil), do: map
  defp maybe_put_failure_detail(map, key, value), do: Map.put(map, key, value)

  defp contains_failure_atom?(term, atoms) when is_atom(term), do: term in atoms

  defp contains_failure_atom?(term, atoms) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_failure_atom?(&1, atoms))

  defp contains_failure_atom?(term, atoms) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_failure_atom?(key, atoms) or contains_failure_atom?(value, atoms)
      end)

  defp contains_failure_atom?(term, atoms) when is_list(term),
    do: Enum.any?(term, &contains_failure_atom?(&1, atoms))

  defp contains_failure_atom?(_term, _atoms), do: false

  defp persistence_error_details(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, rendered ->
          String.replace(rendered, "%{#{key}}", to_string(value))
        end)
      end)

    %{errors: errors}
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp safe_reason(%{__struct__: module}), do: inspect(module)
  defp safe_reason(_reason), do: "persistence_error"

  defp generate_call_id do
    "call_" <> Ecto.UUID.generate()
  end

  defp estimate_cost(%Step{tokens_in: t_in, tokens_out: t_out}) do
    # Rough estimate: $0.01 per 1K tokens
    total_tokens = (t_in || 0) + (t_out || 0)
    # cents
    div(total_tokens, 100)
  end

  defp format_tool_result_message(tool_info, observation) do
    # Format tool result for LLM consumption - encode as JSON string for API
    content =
      case observation do
        content when is_binary(content) ->
          # If it's already a string, assume it's JSON and validate it
          case Jason.decode(content) do
            # Valid JSON string, keep as-is
            {:ok, _parsed} -> content
            # Not JSON, keep as plain string
            {:error, _} -> content
          end

        other ->
          # If it's not a string, encode it as JSON
          case Jason.encode(other) do
            {:ok, json_string} -> json_string
            {:error, _} -> inspect(other)
          end
      end

    %{
      role: :tool,
      content: content,
      tool_call_id: tool_info.call_id,
      tool_arguments: tool_info.args,
      provider_output: tool_info.provider_output,
      name: tool_info.name
    }
  end
end
