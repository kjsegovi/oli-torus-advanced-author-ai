defmodule Oli.GoogleSlides.ImportWorkflow.ToolLoop do
  @moduledoc """
  Runs a bounded, provider-independent tool loop for Google Slides lesson planning.

  Tool handlers operate on a semantic draft value. They must not create or edit
  Torus authoring resources.
  """

  alias Oli.GenAI.Completions.{Function, Message, ServiceConfig}
  alias Oli.GenAI.Execution

  @default_max_steps 80
  @default_max_input_tokens 400_000

  @type tool_state :: term()
  @type tool_result ::
          {:ok, tool_state(), term()}
          | {:retry, tool_state(), term()}
          | {:done, tool_state(), term()}
          | {:error, term()}

  @callback functions() :: [Function.t() | map()]
  @callback functions(tool_state()) :: [Function.t() | map()]
  @callback call(String.t(), map(), tool_state()) :: tool_result()
  @optional_callbacks functions: 1

  @spec run(
          [Message.t()],
          ServiceConfig.t(),
          module(),
          tool_state(),
          keyword()
        ) ::
          {:ok, tool_state(), map()}
          | {:checkpoint, tool_state(), map()}
          | {:error, term(), tool_state()}
  def run(messages, %ServiceConfig{} = service_config, tools_module, initial_state, opts \\ [])
      when is_list(messages) and is_atom(tools_module) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    max_input_tokens = Keyword.get(opts, :max_input_tokens, @default_max_input_tokens)
    completion_fun = Keyword.get(opts, :completion_fun, &complete/4)
    checkpoint_on_input_budget = Keyword.get(opts, :checkpoint_on_input_budget, false)

    do_run(
      messages,
      service_config,
      tools_module,
      tool_functions(tools_module, initial_state),
      initial_state,
      0,
      max_steps,
      completion_fun,
      [],
      %{
        used_input_tokens: 0,
        max_input_tokens: max_input_tokens,
        checkpoint_on_input_budget: checkpoint_on_input_budget
      }
    )
  end

  defp do_run(
         _messages,
         _service_config,
         _tools_module,
         _functions,
         state,
         steps,
         max_steps,
         _completion_fun,
         metadata,
         _budget
       )
       when steps >= max_steps do
    {:error, {:tool_budget_exhausted, max_steps, Enum.reverse(metadata)}, state}
  end

  defp do_run(
         messages,
         service_config,
         tools_module,
         functions,
         state,
         steps,
         max_steps,
         completion_fun,
         metadata,
         budget
       ) do
    estimated_input_tokens = estimate_request_tokens(messages, functions)
    next_used_input_tokens = budget.used_input_tokens + estimated_input_tokens

    if next_used_input_tokens > budget.max_input_tokens do
      if budget.checkpoint_on_input_budget do
        {:checkpoint, state,
         %{
           reason: "input_budget",
           steps: steps,
           executions: Enum.reverse(metadata),
           prompt_tokens: budget.used_input_tokens,
           next_request_estimate: estimated_input_tokens
         }}
      else
        {:error,
         {:input_token_budget_exhausted, budget.max_input_tokens, budget.used_input_tokens,
          estimated_input_tokens}, state}
      end
    else
      request_ctx = %{
        request_type: :generate,
        feature: :google_slides_import,
        service_config_id: service_config.id
      }

      case completion_fun.(request_ctx, messages, functions, service_config) do
        {:ok, %{content: content} = response} ->
          budget = charge_input_tokens(budget, content, estimated_input_tokens)

          execution_metadata =
            response
            |> Map.get(:metadata, %{})
            |> Map.put(:estimated_input_tokens, estimated_input_tokens)
            |> Map.put(
              :charged_input_tokens,
              charged_input_tokens(content, estimated_input_tokens)
            )
            |> maybe_put_usage(content)

          handle_completion(
            content,
            messages,
            service_config,
            tools_module,
            functions,
            state,
            steps,
            max_steps,
            completion_fun,
            [execution_metadata | metadata],
            budget
          )

        {:error, reason} ->
          {:error, {:completion_failed, reason}, state}

        other ->
          {:error, {:invalid_completion_result, other}, state}
      end
    end
  end

  defp handle_completion(
         content,
         _messages,
         _service_config,
         _tools_module,
         _functions,
         state,
         steps,
         _max_steps,
         _completion_fun,
         metadata,
         budget
       )
       when is_binary(content) do
    {:ok, state,
     %{
       steps: steps,
       final_message: content,
       executions: Enum.reverse(metadata),
       estimated_input_tokens: budget.used_input_tokens
     }}
  end

  defp handle_completion(
         content,
         messages,
         service_config,
         tools_module,
         functions,
         state,
         steps,
         max_steps,
         completion_fun,
         metadata,
         budget
       )
       when is_map(content) do
    with {:ok, call} <- extract_tool_call(content),
         {:ok, arguments} <- decode_arguments(call.arguments),
         result <- safe_tool_call(tools_module, call.name, arguments, state) do
      case result do
        {:ok, new_state, tool_output} ->
          function_message = function_result_message(call, arguments, tool_output)

          do_run(
            messages ++ [function_message],
            service_config,
            tools_module,
            functions,
            new_state,
            steps + 1,
            max_steps,
            completion_fun,
            metadata,
            budget
          )

        {:retry, new_state, tool_output} ->
          function_message = function_result_message(call, arguments, tool_output)

          do_run(
            replace_retry_feedback(messages, function_message),
            service_config,
            tools_module,
            functions,
            new_state,
            steps + 1,
            max_steps,
            completion_fun,
            metadata,
            budget
          )

        {:done, new_state, tool_output} ->
          {:ok, new_state,
           %{
             steps: steps + 1,
             final_message: encode_tool_output(tool_output),
             executions: Enum.reverse(metadata),
             estimated_input_tokens: budget.used_input_tokens
           }}

        {:error, reason} ->
          function_message =
            function_result_message(call, arguments, %{
              ok: false,
              error: bounded_tool_error(reason)
            })

          do_run(
            messages ++ [function_message],
            service_config,
            tools_module,
            functions,
            state,
            steps + 1,
            max_steps,
            completion_fun,
            metadata,
            budget
          )

        other ->
          {:error, {:invalid_tool_result, call.name, other}, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_completion(
         content,
         _messages,
         _config,
         _tools,
         _functions,
         state,
         _steps,
         _max,
         _fun,
         _meta,
         _budget
       ) do
    {:error, {:invalid_completion_content, content}, state}
  end

  defp extract_tool_call(payload) do
    case get_in(payload, ["choices", Access.at(0), "message", "tool_calls", Access.at(0)]) do
      %{
        "id" => id,
        "function" => %{"name" => name, "arguments" => arguments}
      }
      when is_binary(name) ->
        {:ok, %{id: id, name: name, arguments: arguments}}

      _ ->
        {:error, {:missing_tool_call, payload}}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, {:invalid_tool_arguments, arguments}}
    end
  end

  defp decode_arguments(arguments), do: {:error, {:invalid_tool_arguments, arguments}}

  # Tool arguments originate with the model even though the available handlers
  # are trusted. A malformed argument must become a bounded tool error that the
  # model can repair, not an exception that terminates the durable import run.
  defp safe_tool_call(tools_module, name, arguments, state) do
    tools_module.call(name, arguments, state)
  rescue
    exception ->
      {:error, {:tool_execution_failed, exception_name(exception)}}
  end

  defp exception_name(%{__struct__: module}) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp exception_name(_exception), do: "Exception"

  defp function_result_message(call, arguments, tool_output) do
    %Message{
      role: :function,
      content: encode_tool_output(tool_output),
      name: call.name,
      id: call.id,
      input: arguments
    }
  end

  defp replace_retry_feedback(messages, %Message{name: name} = function_message) do
    messages
    |> Enum.reject(fn
      %Message{role: role, name: ^name} when role in [:function, "function"] -> true
      _message -> false
    end)
    |> Kernel.++([function_message])
  end

  defp encode_tool_output(output) when is_binary(output), do: output
  defp encode_tool_output(output), do: Jason.encode!(output)

  defp bounded_tool_error(reason) do
    rendered =
      case Jason.encode(reason) do
        {:ok, encoded} -> encoded
        {:error, _} -> inspect(reason, limit: 50, printable_limit: 4_000)
      end

    if byte_size(rendered) > 8_000 do
      binary_part(rendered, 0, 8_000) <> "…"
    else
      rendered
    end
  end

  defp maybe_put_usage(metadata, %{"usage" => usage}) when is_map(usage),
    do: Map.put(metadata, :usage, usage)

  defp maybe_put_usage(metadata, %{usage: usage}) when is_map(usage),
    do: Map.put(metadata, :usage, usage)

  defp maybe_put_usage(metadata, _content), do: metadata

  defp charge_input_tokens(budget, content, estimated_input_tokens) do
    charged = charged_input_tokens(content, estimated_input_tokens)
    %{budget | used_input_tokens: budget.used_input_tokens + charged}
  end

  defp charged_input_tokens(%{"usage" => usage}, fallback) when is_map(usage),
    do: prompt_tokens(usage, fallback)

  defp charged_input_tokens(%{usage: usage}, fallback) when is_map(usage),
    do: prompt_tokens(usage, fallback)

  defp charged_input_tokens(_content, fallback), do: fallback

  defp prompt_tokens(%{"prompt_tokens" => tokens}, _fallback)
       when is_integer(tokens) and tokens >= 0,
       do: tokens

  defp prompt_tokens(%{prompt_tokens: tokens}, _fallback)
       when is_integer(tokens) and tokens >= 0,
       do: tokens

  defp prompt_tokens(_usage, fallback), do: fallback

  defp estimate_request_tokens(messages, functions) do
    characters = encoded_size(messages) + encoded_size(functions)
    max(div(characters + 3, 4), 1)
  end

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> value |> inspect(limit: :infinity) |> byte_size()
    end
  end

  defp complete(request_ctx, messages, functions, service_config) do
    Execution.generate_with_metadata(request_ctx, messages, functions, service_config)
  end

  defp tool_functions(tools_module, initial_state) do
    if function_exported?(tools_module, :functions, 1) do
      tools_module.functions(initial_state)
    else
      tools_module.functions()
    end
  end
end
