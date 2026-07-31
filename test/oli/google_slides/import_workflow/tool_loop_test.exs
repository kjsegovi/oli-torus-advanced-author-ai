defmodule Oli.GoogleSlides.ImportWorkflow.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.{Function, Message, ServiceConfig}
  alias Oli.GoogleSlides.ImportWorkflow.ToolLoop

  defmodule DraftTools do
    @behaviour ToolLoop

    alias Oli.GenAI.Completions.Function

    @impl true
    def functions do
      [
        %Function{
          name: "add_screen",
          description: "Adds one screen to the semantic lesson draft",
          parameters: %{
            "type" => "object",
            "properties" => %{"title" => %{"type" => "string"}},
            "required" => ["title"]
          }
        }
      ]
    end

    @impl true
    def call("add_screen", %{"title" => "Reject me"}, _state) do
      {:error, :invalid_screen_title}
    end

    def call("add_screen", %{"title" => "Raise"}, _state) do
      raise ArgumentError, "private tool exception"
    end

    def call("add_screen", %{"title" => title}, state) do
      {:ok, state ++ [%{"title" => title}], %{screen_count: length(state) + 1}}
    end
  end

  defmodule RetryTools do
    @behaviour ToolLoop

    alias Oli.GenAI.Completions.Function

    @impl true
    def functions do
      [
        %Function{
          name: "apply_batch",
          description: "Applies a complete batch",
          parameters: %{"type" => "object"}
        }
      ]
    end

    @impl true
    def call("apply_batch", %{"complete" => true}, state) do
      {:done, state, %{"ok" => true}}
    end

    def call("apply_batch", arguments, state) do
      {:retry, state, %{"ok" => false, "attempt" => arguments["attempt"]}}
    end
  end

  defmodule StatefulTools do
    @behaviour ToolLoop

    alias Oli.GenAI.Completions.Function

    @impl true
    def functions, do: functions(nil)

    @impl true
    def functions(state) do
      name = if is_nil(state), do: "create", else: "update"
      [%Function{name: name, description: name, parameters: %{"type" => "object"}}]
    end

    @impl true
    def call(_name, _arguments, state), do: {:done, state, %{"ok" => true}}
  end

  test "executes semantic tools without mutating outside the draft state" do
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, messages, functions, _service_config ->
      assert [%Function{name: "add_screen"}] = functions

      case Process.get(:completion_count) do
        0 ->
          Process.put(:completion_count, 1)

          {:ok,
           %{
             content: %{
               "choices" => [
                 %{
                   "message" => %{
                     "tool_calls" => [
                       %{
                         "id" => "call_1",
                         "function" => %{
                           "name" => "add_screen",
                           "arguments" => ~s({"title":"Introduction"})
                         }
                       }
                     ]
                   }
                 }
               ]
             },
             metadata: %{model: "test-model"}
           }}

        1 ->
          assert %Message{
                   role: :function,
                   name: "add_screen",
                   id: "call_1",
                   input: %{"title" => "Introduction"}
                 } = List.last(messages)

          {:ok, %{content: "Planning complete", metadata: %{model: "test-model"}}}
      end
    end

    assert {:ok, [%{"title" => "Introduction"}], result} =
             ToolLoop.run(
               [Message.new(:user, "Build a lesson")],
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun
             )

    assert result.steps == 1
    assert result.final_message == "Planning complete"
    assert length(result.executions) == 2
  end

  test "enforces the cumulative input-token budget across tool turns" do
    messages = [Message.new(:user, "Build a lesson")]
    functions = DraftTools.functions()
    first_request_tokens = estimated_tokens(messages, functions)
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, _messages, _functions, _service_config ->
      Process.put(:completion_count, Process.get(:completion_count) + 1)

      {:ok,
       %{
         content:
           tool_call_payload("call_1", "add_screen", %{
             "title" => "Introduction"
           })
       }}
    end

    assert {:error,
            {:input_token_budget_exhausted, ^first_request_tokens, ^first_request_tokens,
             next_request_tokens}, [%{"title" => "Introduction"}]} =
             ToolLoop.run(
               messages,
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun,
               max_input_tokens: first_request_tokens
             )

    assert next_request_tokens > 0
    assert Process.get(:completion_count) == 1
  end

  test "returns validated draft state as a checkpoint at the input boundary" do
    messages = [Message.new(:user, "Build a lesson")]
    first_request_tokens = estimated_tokens(messages, DraftTools.functions())

    completion_fun = fn _ctx, _messages, _functions, _service_config ->
      {:ok,
       %{
         content:
           tool_call_payload("call_1", "add_screen", %{
             "title" => "Introduction"
           })
       }}
    end

    assert {:checkpoint, [%{"title" => "Introduction"}], metadata} =
             ToolLoop.run(
               messages,
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun,
               max_input_tokens: first_request_tokens,
               checkpoint_on_input_budget: true
             )

    assert metadata.reason == "input_budget"
    assert metadata.prompt_tokens == first_request_tokens
    assert length(metadata.executions) == 1
  end

  test "preserves provider usage and estimated input tokens in execution metadata" do
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, _messages, _functions, _service_config ->
      case Process.get(:completion_count) do
        0 ->
          Process.put(:completion_count, 1)

          {:ok,
           %{
             content:
               tool_call_payload("call_1", "add_screen", %{
                 "title" => "Introduction"
               })
               |> Map.put("usage", %{
                 "prompt_tokens" => 21,
                 "completion_tokens" => 5,
                 "total_tokens" => 26
               }),
             metadata: %{model: "test-model", provider: :open_ai}
           }}

        1 ->
          {:ok,
           %{
             content: "Planning complete",
             metadata: %{model: "test-model", provider: :open_ai}
           }}
      end
    end

    assert {:ok, [%{"title" => "Introduction"}], result} =
             ToolLoop.run(
               [Message.new(:user, "Build a lesson")],
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun
             )

    assert [
             %{
               model: "test-model",
               provider: :open_ai,
               estimated_input_tokens: first_estimate,
               usage: %{
                 "prompt_tokens" => 21,
                 "completion_tokens" => 5,
                 "total_tokens" => 26
               }
             },
             %{
               model: "test-model",
               provider: :open_ai,
               estimated_input_tokens: second_estimate
             }
           ] = result.executions

    assert first_estimate > 0
    assert second_estimate > first_estimate
    assert result.estimated_input_tokens == 21 + second_estimate
    assert Enum.at(result.executions, 0).charged_input_tokens == 21
    assert Enum.at(result.executions, 1).charged_input_tokens == second_estimate
  end

  test "returns a recoverable tool error to the model and continues planning" do
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, messages, _functions, _service_config ->
      case Process.get(:completion_count) do
        0 ->
          Process.put(:completion_count, 1)

          {:ok,
           %{
             content:
               tool_call_payload("call_invalid", "add_screen", %{
                 "title" => "Reject me"
               })
           }}

        1 ->
          Process.put(:completion_count, 2)

          assert %Message{
                   role: :function,
                   name: "add_screen",
                   id: "call_invalid",
                   input: %{"title" => "Reject me"},
                   content: content
                 } = List.last(messages)

          assert %{"ok" => false, "error" => error} = Jason.decode!(content)
          assert error =~ "invalid_screen_title"

          {:ok,
           %{
             content:
               tool_call_payload("call_repaired", "add_screen", %{
                 "title" => "Repaired title"
               })
           }}

        2 ->
          {:ok, %{content: "Planning complete"}}
      end
    end

    assert {:ok, [%{"title" => "Repaired title"}], result} =
             ToolLoop.run(
               [Message.new(:user, "Build a lesson")],
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun
             )

    assert result.steps == 2
    assert length(result.executions) == 3
  end

  test "turns tool handler exceptions into recoverable model feedback" do
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, messages, _functions, _service_config ->
      case Process.get(:completion_count) do
        0 ->
          Process.put(:completion_count, 1)

          {:ok,
           %{
             content:
               tool_call_payload("call_raised", "add_screen", %{
                 "title" => "Raise"
               })
           }}

        1 ->
          Process.put(:completion_count, 2)

          assert %Message{
                   role: :function,
                   name: "add_screen",
                   id: "call_raised",
                   content: content
                 } = List.last(messages)

          assert content =~ "tool_execution_failed"
          assert content =~ "ArgumentError"
          refute content =~ "private tool exception"

          {:ok,
           %{
             content:
               tool_call_payload("call_repaired", "add_screen", %{
                 "title" => "Repaired title"
               })
           }}

        2 ->
          {:ok, %{content: "Planning complete"}}
      end
    end

    assert {:ok, [%{"title" => "Repaired title"}], result} =
             ToolLoop.run(
               [Message.new(:user, "Build a lesson")],
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun
             )

    assert result.steps == 2
    assert length(result.executions) == 3
  end

  test "keeps only the latest rejected batch while the model repairs it" do
    Process.put(:completion_count, 0)

    completion_fun = fn _ctx, messages, _functions, _service_config ->
      attempt = Process.get(:completion_count)
      Process.put(:completion_count, attempt + 1)

      feedback = Enum.filter(messages, &match?(%Message{role: :function}, &1))

      case attempt do
        0 ->
          assert feedback == []
          {:ok, %{content: tool_call_payload("call_1", "apply_batch", %{"attempt" => 1})}}

        1 ->
          assert [%Message{id: "call_1"}] = feedback
          {:ok, %{content: tool_call_payload("call_2", "apply_batch", %{"attempt" => 2})}}

        2 ->
          assert [%Message{id: "call_2"}] = feedback
          {:ok, %{content: "Planning complete"}}
      end
    end

    assert {:ok, :draft, %{steps: 2}} =
             ToolLoop.run(
               [Message.new(:user, "Repair the draft")],
               %ServiceConfig{id: 1},
               RetryTools,
               :draft,
               completion_fun: completion_fun
             )
  end

  test "lets tools tailor their schema to the initial state" do
    parent = self()

    completion_fun = fn _ctx, _messages, functions, _service_config ->
      send(parent, Enum.map(functions, & &1.name))
      {:ok, %{content: tool_call_payload("call_update", "update", %{})}}
    end

    assert {:ok, :existing_draft, %{steps: 1}} =
             ToolLoop.run(
               [Message.new(:user, "Update the draft")],
               %ServiceConfig{id: 1},
               StatefulTools,
               :existing_draft,
               completion_fun: completion_fun
             )

    assert_received ["update"]
  end

  test "large rejected batches do not accumulate into a false input-budget failure" do
    Process.put(:completion_count, 0)
    large_payload = String.duplicate("source content ", 8_000)

    completion_fun = fn _ctx, _messages, _functions, _service_config ->
      attempt = Process.get(:completion_count) + 1
      Process.put(:completion_count, attempt)

      arguments =
        if attempt == 5 do
          %{"complete" => true}
        else
          %{"attempt" => attempt, "payload" => large_payload}
        end

      {:ok,
       %{
         content:
           tool_call_payload("call_#{attempt}", "apply_batch", arguments)
           |> Map.put("usage", %{"prompt_tokens" => 40_000})
       }}
    end

    assert {:ok, :draft, %{steps: 5, estimated_input_tokens: 200_000}} =
             ToolLoop.run(
               [Message.new(:user, large_payload)],
               %ServiceConfig{id: 1},
               RetryTools,
               :draft,
               completion_fun: completion_fun,
               max_input_tokens: 225_000
             )

    assert Process.get(:completion_count) == 5
  end

  test "stops at the configured tool budget" do
    completion_fun = fn _ctx, _messages, _functions, _service_config ->
      {:ok,
       %{
         content: %{
           "choices" => [
             %{
               "message" => %{
                 "tool_calls" => [
                   %{
                     "id" => "call_forever",
                     "function" => %{
                       "name" => "add_screen",
                       "arguments" => ~s({"title":"Again"})
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:error, {:tool_budget_exhausted, 1, _metadata}, [%{"title" => "Again"}]} =
             ToolLoop.run(
               [Message.new(:user, "Build a lesson")],
               %ServiceConfig{id: 1},
               DraftTools,
               [],
               completion_fun: completion_fun,
               max_steps: 1
             )
  end

  defp tool_call_payload(id, name, arguments) do
    %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => id,
                "function" => %{
                  "name" => name,
                  "arguments" => Jason.encode!(arguments)
                }
              }
            ]
          }
        }
      ]
    }
  end

  defp estimated_tokens(messages, functions) do
    characters =
      byte_size(Jason.encode!(messages)) +
        byte_size(Jason.encode!(functions))

    max(div(characters + 3, 4), 1)
  end
end
