defmodule Oli.GenAI.Completions do
  @moduledoc """
  This module provides a unified interface for chat completion from any registered
  LLM model and provider.  This is only a chat completion inferface. There
  is no state management and no automatic function calling, no automatic retry, etc.

  Synchronous and asynchronous chat completion are supported via the
  `generate` and `stream` functions.
  """

  alias Oli.GenAI.Completions.RegisteredModel
  alias Oli.GenAI.ModuleCapabilities

  def generate(messages, functions, %RegisteredModel{} = registered_model) do
    get_provider(registered_model)
    |> apply(:generate, [messages, functions, registered_model])
  end

  def generate_with_metadata(messages, functions, %RegisteredModel{} = registered_model) do
    provider = get_provider(registered_model)

    if ModuleCapabilities.supports?(provider, :generate_with_metadata, 3) do
      apply(provider, :generate_with_metadata, [messages, functions, registered_model])
    else
      case apply(provider, :generate, [messages, functions, registered_model]) do
        {:ok, content} -> {:ok, %{content: content, response: nil}}
        {:error, _reason} = error -> error
      end
    end
  end

  def stream(messages, functions, %RegisteredModel{} = registered_model, response_handler_fn) do
    get_provider(registered_model)
    |> apply(:stream, [messages, functions, registered_model, response_handler_fn])
  end

  defp get_provider(%RegisteredModel{} = registered_model) do
    case registered_model.provider do
      :null -> Oli.GenAI.Completions.NullProvider
      :open_ai -> Oli.GenAI.Completions.OpenAICompliantProvider
      :claude -> Oli.GenAI.Completions.ClaudeProvider
    end
  end
end
