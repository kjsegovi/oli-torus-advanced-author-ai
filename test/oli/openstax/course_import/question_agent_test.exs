defmodule Oli.OpenStax.CourseImport.QuestionAgentTest do
  use Oli.DataCase, async: false

  alias Oli.GenAI.Agent
  alias Oli.GenAI.Agent.{Decision, Persistence, RunSupervisor, Server}
  alias Oli.GenAI.Completions.ServiceConfig
  alias Oli.OpenStax.CourseImport.QuestionAgent

  defmodule SuccessfulBridge do
    @candidate %{
      "count_rationale" =>
        "One transfer question is sufficient for the single focused objective and short lesson.",
      "questions_payload" => %{
        "items" => [
          %{
            "prompt" =>
              "Explain how using one shared computation model makes an algorithm comparison fair.",
            "type" => "short_answer",
            "response_kind" => "application",
            "answer_guidance" =>
              "A strong answer identifies the shared assumptions and connects them to comparable costs.",
            "answer_keywords" => ["model", "assumptions", "cost"],
            "placement_after_section_id" => "section-models",
            "objective_ids" => ["objective-1"],
            "evidence_block_ids" => ["block-models"]
          }
        ]
      }
    }

    def candidate, do: @candidate

    def next_decision_with_metadata(messages, _opts) do
      reviewed? = Enum.any?(messages, &(&1[:name] == "review_openstax_questions"))
      tool_name = if reviewed?, do: "submit_openstax_questions", else: "review_openstax_questions"

      {:ok, %Decision{next_action: "tool", tool_name: tool_name, arguments: @candidate},
       %{input_tokens: 120, output_tokens: 80}}
    end
  end

  defmodule RetryingBridge do
    def next_decision_with_metadata(messages, opts) do
      attempts = Process.get({__MODULE__, :attempts}, 0)
      Process.put({__MODULE__, :attempts}, attempts + 1)

      if attempts < 2,
        do: {:error, :timeout},
        else:
          Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.next_decision_with_metadata(
            messages,
            opts
          )
    end
  end

  defmodule ToolHistoryBridge do
    def next_decision_with_metadata(messages, _opts) do
      candidate = Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.candidate()

      case Enum.find(messages, &(&1[:name] == "review_openstax_questions")) do
        nil ->
          {:ok,
           %Decision{
             next_action: "tool",
             tool_name: "review_openstax_questions",
             arguments: candidate
           }, %{input_tokens: 120, output_tokens: 80}}

        %{tool_call_id: call_id, tool_arguments: ^candidate} when is_binary(call_id) ->
          {:ok,
           %Decision{
             next_action: "tool",
             tool_name: "submit_openstax_questions",
             arguments: candidate
           }, %{input_tokens: 120, output_tokens: 80}}

        _invalid_history ->
          {:error, :invalid_tool_history}
      end
    end
  end

  defmodule ThrottledBridge do
    def next_decision_with_metadata(messages, opts) do
      attempts = Process.get({__MODULE__, :attempts}, 0)
      Process.put({__MODULE__, :attempts}, attempts + 1)

      if attempts == 0,
        do: {:error, %{status: 429}},
        else:
          Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.next_decision_with_metadata(
            messages,
            opts
          )
    end
  end

  defmodule RevisionBridge do
    def next_decision_with_metadata(messages, _opts) do
      reviewed =
        messages
        |> Enum.filter(&(&1[:name] == "review_openstax_questions"))
        |> List.last()

      {tool_name, candidate} =
        case reviewed do
          nil ->
            invalid =
              Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.candidate()
              |> put_in(
                ["questions_payload", "items", Access.at(0), "prompt"],
                "Start here"
              )

            {"review_openstax_questions", invalid}

          %{content: content} ->
            if Jason.decode!(content)["valid"] do
              {"submit_openstax_questions",
               Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.candidate()}
            else
              {"review_openstax_questions",
               Oli.OpenStax.CourseImport.QuestionAgentTest.SuccessfulBridge.candidate()}
            end
        end

      {:ok, %Decision{next_action: "tool", tool_name: tool_name, arguments: candidate},
       %{input_tokens: 120, output_tokens: 80}}
    end
  end

  defmodule BudgetBridge do
    def next_decision_with_metadata(_messages, _opts) do
      step = Process.get({__MODULE__, :step}, 0) + 1
      Process.put({__MODULE__, :step}, step)

      {:ok,
       %Decision{next_action: "message", assistant_message: "Considering candidate #{step}."},
       %{input_tokens: 20, output_tokens: 10}}
    end
  end

  defmodule RejectedRequestBridge do
    def next_decision_with_metadata(_messages, _opts) do
      {:error,
       %{
         status_code: 400,
         body:
           Jason.encode!(%{
             "error" => %{
               "message" => "do-not-persist provider body",
               "type" => "invalid_request_error",
               "param" => "messages.[3].role",
               "code" => nil
             }
           })
       }}
    end
  end

  test "reviews, submits, and persists an accepted Basic question draft" do
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: SuccessfulBridge
             )

    assert [%{"type" => "short_answer"}] = result.questions_payload["items"]

    question = hd(result.questions_payload["items"])

    assert question["objective_ids"] == ["objective-1"]
    assert question["mapped_objectives"] == ["Compare algorithms under one computation model"]

    assert result.generation_metadata["attempts"] == %{"reviews" => 1, "submissions" => 1}
    assert result.generation_metadata["token_usage"]["total"] == 400
    assert result.generation_metadata["terminal_status"] == "completed"

    run_id = result.generation_metadata["run_id"]
    :ok = DynamicSupervisor.terminate_child(RunSupervisor, Server.whereis(run_id))

    assert {:ok, durable_result} = Agent.await_result(run_id, 1_000)
    assert durable_result.terminal_status == :completed
    assert durable_result.input_tokens == 240
    assert durable_result.output_tokens == 160
  end

  test "await_result waits for a durable running agent instead of timing out on server responsiveness" do
    run_id = Ecto.UUID.generate()

    assert {:ok, _run} =
             Persistence.create_run(%{
               id: run_id,
               goal: "Wait for durable completion",
               run_type: "await_result_regression",
               status: "running"
             })

    completion =
      Task.async(fn ->
        Process.sleep(50)

        Persistence.update_run(run_id, %{
          status: "completed",
          terminal_status: "completed",
          terminal_reason: "Durable result completed.",
          tokens_in: 12,
          tokens_out: 8,
          finished_at: DateTime.utc_now()
        })
      end)

    assert {:ok, result} = Agent.await_result(run_id, 1_000)
    assert result.terminal_status == :completed
    assert result.tokens_used == 20
    assert {:ok, _run} = Task.await(completion)
  end

  test "persists an author-owned run without requiring a linked user" do
    author = author_fixture()
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               author_id: author.id,
               llm_bridge: SuccessfulBridge
             )

    run = Persistence.get_run(result.generation_metadata["run_id"])
    assert run.author_id == author.id
    assert is_nil(run.user_id)
  end

  test "carries the matching tool call ID and arguments into the next agent step" do
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: ToolHistoryBridge
             )

    assert result.generation_metadata["attempts"] == %{"reviews" => 1, "submissions" => 1}
  end

  @tag capture_log: true
  test "returns a controlled startup failure for an invalid author association" do
    {lesson, content} = lesson_context()

    assert {:error, {:question_agent_failed, _run_id, reason}} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               author_id: -1,
               llm_bridge: SuccessfulBridge
             )

    assert inspect(reason) =~ "run_persistence_failed"
    refute inspect(reason) =~ "A computation model defines"
  end

  @tag capture_log: true
  test "retries provider timeouts before completing the reviewed submission" do
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: RetryingBridge
             )

    assert result.generation_metadata["terminal_status"] == "completed"
    assert result.generation_metadata["attempts"]["reviews"] == 1
  end

  test "repairs a rejected review before submitting the accepted whole set" do
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: RevisionBridge
             )

    assert result.generation_metadata["attempts"] == %{"reviews" => 2, "submissions" => 1}
    assert hd(result.questions_payload["items"])["prompt"] =~ "shared computation model"
  end

  @tag capture_log: true
  test "retries provider throttling before completing the reviewed submission" do
    {lesson, content} = lesson_context()

    assert {:ok, result} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: ThrottledBridge
             )

    assert result.generation_metadata["terminal_status"] == "completed"
    assert result.generation_metadata["attempts"]["submissions"] == 1
  end

  test "reports agent budget exhaustion as a terminal quality failure" do
    {lesson, content} = lesson_context()

    assert {:error,
            {:terminal_question_agent_failure, :step_budget_exhausted, "Step limit reached"}} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               llm_bridge: BudgetBridge
             )
  end

  @tag capture_log: true
  test "returns a sanitized structured HTTP 400 without retrying it as transient" do
    {lesson, content} = lesson_context()
    run_id = Ecto.UUID.generate()

    assert {:error,
            {:provider_failure,
             %{
               "category" => "request_rejected",
               "status_code" => 400,
               "provider_error_type" => "invalid_request_error",
               "provider_error_param" => "messages.[3].role"
             }}} =
             QuestionAgent.generate(lesson, content, %ServiceConfig{id: 1},
               run_id: run_id,
               llm_bridge: RejectedRequestBridge
             )

    run = Persistence.get_run(run_id)
    assert run.terminal_reason == "Provider rejected the agent request (HTTP 400)."
    assert run.metadata["provider_failure"]["status_code"] == 400
    refute inspect(run) =~ "do-not-persist"
  end

  defp lesson_context do
    lesson = %{
      "id" => Ecto.UUID.generate(),
      "title" => "Computation models",
      "source_evidence_links" => ["https://openstax.org/books/test/pages/models"],
      "source_blocks" => [
        %{
          "id" => "block-models",
          "kind" => "paragraph",
          "text" => "A computation model defines the operations and costs used for comparison."
        }
      ]
    }

    content = %{
      "schema_version" => 5,
      "authoring_mode" => "basic",
      "title" => "Computation models",
      "learning_objectives" => ["Compare algorithms under one computation model"],
      "content_groups" => [
        %{
          "id" => "section-models",
          "title" => "Use one comparison model",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["block-models"]
        }
      ],
      "question_slots" => [
        %{
          "placement_after_group_id" => "section-models",
          "placement_after_section_id" => "section-models"
        }
      ],
      "synthesis" => %{"takeaways" => ["Shared assumptions make costs comparable."]}
    }

    {lesson, content}
  end
end
