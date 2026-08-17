defmodule Oli.OpenStax.CourseImport.Worker.LessonPlanWorker do
  @moduledoc """
  Generates and validates one durable OpenStax lesson plan.

  Run generations and per-request UUIDs fence late results after cancellation,
  retry, or a newer reviewer regeneration request.
  """

  use Oban.Worker,
    queue: :course_import_ai,
    max_attempts: 4,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.AIPlanner

  @provider_attempt_limit 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, id: job_id, attempt: job_attempt, max_attempts: max_attempts}) do
    attempt = job_attempt + integer_arg(args, "attempt_offset", 0)

    case CourseImport.claim_lesson_plan_job(args, attempt, job_id) do
      {:ok, :already_completed} ->
        :ok

      {:ok, claim} ->
        case plan_lesson(claim, args) do
          {:ok, result} ->
            case CourseImport.complete_lesson_plan_job(args, result) do
              {:ok, _lesson, _run} ->
                :ok

              {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
                {:discard, reason}

              {:error, reason} ->
                retry_or_fail(
                  args,
                  attempt,
                  max_attempts,
                  {:lesson_plan_completion_failed, reason}
                )
            end

          {:error, reason} ->
            retry_or_fail(args, attempt, max_attempts, {:lesson_generation_failed, reason})
        end

      {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
        {:discard, reason}

      {:error, reason} ->
        retry_or_fail(args, attempt, max_attempts, reason)
    end
  rescue
    exception ->
      stacktrace = __STACKTRACE__

      Logger.error(
        "OpenStax lesson planning raised an unexpected exception\n" <>
          Exception.format(:error, exception, stacktrace)
      )

      retry_or_fail(
        args,
        job_attempt + integer_arg(args, "attempt_offset", 0),
        max_attempts,
        {:internal_exception, exception}
      )
  end

  defp retry_or_fail(args, attempt, max_attempts, reason) do
    {disposition, category} = classify_failure(reason)
    details = failure_details(reason)

    maybe_log_unclassified_failure(disposition, category, details)

    if disposition == :transient and retry_available?(attempt, max_attempts, category) do
      case CourseImport.retry_lesson_plan_job(args, attempt, category, details) do
        {:ok, _lesson, _run} ->
          {:error, category}

        {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
          {:discard, reason}

        {:error, _reason} ->
          {:error, category}
      end
    else
      _ = CourseImport.fail_lesson_plan_job(args, attempt, category, details)
      {:discard, category}
    end
  end

  defp plan_lesson(claim, job_args) do
    checkpoint_fun = fn stage, payload ->
      CourseImport.persist_lesson_generation_checkpoint(job_args, stage, payload)
    end

    opts = [
      plan_schema_version: claim.plan_schema_version,
      advanced_v6_enabled: claim.advanced_v6_enabled,
      author_id: claim.author_id,
      project_id: claim.project_id,
      generation_checkpoint: claim.generation_checkpoint,
      objective_ledger: claim.objective_ledger,
      checkpoint_fun: checkpoint_fun
    ]

    source = Map.put(claim.source, "id", claim.lesson_id)

    case Application.get_env(:oli, :openstax_course_import_lesson_planner, AIPlanner) do
      planner when is_atom(planner) ->
        planner.plan(source, claim.planning_position, opts)

      planner when is_function(planner, 3) ->
        planner.(source, claim.planning_position, opts)

      _invalid ->
        {:error, {:ai_configuration_failed, :invalid_lesson_planner}}
    end
  end

  # Provider/network failures and malformed model responses are safe to retry.
  # Configuration, authorization, and missing source invariants need user or
  # operator action and should fail without repeatedly spending tokens.
  defp classify_failure({:lesson_generation_failed, reason}),
    do: classify_generation_failure(reason)

  defp classify_failure({:lesson_plan_completion_failed, reason}),
    do: classify_completion_failure(reason)

  defp classify_failure({:ai_configuration_failed, reason}),
    do: {:permanent, configuration_category(reason)}

  defp classify_failure({:current_source_ast_required, :start_a_new_import}),
    do: {:permanent, :current_source_ast_required}

  defp classify_failure({:ai_planning_failed, {:content_validation_exhausted, _details}}),
    do: {:permanent, :content_validation_exhausted}

  defp classify_failure({:ai_planning_failed, {category, _details}})
       when category in [
              :content_quality_exhausted,
              :content_quality_stalled,
              :question_quality_exhausted,
              :question_quality_stalled
            ],
       do: {:permanent, category}

  defp classify_failure({:ai_planning_failed, reason})
       when is_tuple(reason) and elem(reason, 0) == :source_prompt_limit_exceeded,
       do: {:permanent, :source_prompt_limit_exceeded}

  defp classify_failure({:ai_planning_failed, reason})
       when is_tuple(reason) and elem(reason, 0) == :question_agent_failed do
    if contains_atom?(reason, [:run_persistence_failed]),
      do: {:permanent, :agent_persistence_failed},
      else: classify_provider_failure(reason)
  end

  defp classify_failure({:ai_planning_failed, reason}), do: classify_provider_failure(reason)
  defp classify_failure({:invalid_status, _, _}), do: {:permanent, :invalid_run_status}
  defp classify_failure(:invalid_lesson), do: {:permanent, :invalid_lesson}
  defp classify_failure(:missing_lesson_source), do: {:permanent, :missing_lesson_source}
  defp classify_failure(:missing_lesson_plan), do: {:permanent, :missing_lesson_plan}

  defp classify_failure({:internal_exception, %DBConnection.ConnectionError{}}),
    do: {:transient, :database_unavailable}

  defp classify_failure({:internal_exception, _}), do: {:permanent, :internal_exception}
  defp classify_failure(reason), do: classify_provider_failure(reason)

  defp classify_generation_failure(reason), do: classify_failure(reason)

  defp classify_completion_failure(%DBConnection.ConnectionError{}),
    do: {:transient, :database_unavailable}

  defp classify_completion_failure(reason)
       when reason in [
              :invalid_lesson_plan_result,
              :invalid_plan_mode,
              :plan_schema_version_immutable,
              :lesson_run_mismatch
            ],
       do: {:permanent, completion_category(reason)}

  defp classify_completion_failure(_reason),
    do: {:permanent, :lesson_plan_persistence_failed}

  defp completion_category(:plan_schema_version_immutable), do: :plan_schema_version_mismatch
  defp completion_category(_reason), do: :lesson_plan_persistence_failed

  defp classify_provider_failure(reason) do
    cond do
      contains_atom?(reason, [
        :step_budget_exhausted,
        :token_budget_exhausted,
        :cost_budget_exhausted,
        :deadline_exceeded,
        :loop_detected,
        :invalid_decision,
        :accepted_question_draft_missing
      ]) ->
        {:permanent, :question_agent_exhausted}

      contains_http_status?(reason, 429) ->
        {:transient, :rate_limited}

      contains_http_5xx?(reason) ->
        {:transient, :provider_unavailable}

      contains_http_status?(reason, 401) ->
        {:permanent, :provider_unauthorized}

      contains_http_status?(reason, 403) ->
        {:permanent, :provider_forbidden}

      contains_http_4xx?(reason) ->
        {:permanent, :provider_request_rejected}

      contains_atom?(reason, [
        :timeout,
        :connect_timeout,
        :recv_timeout,
        :closed,
        :econnrefused,
        :enetunreach
      ]) ->
        {:transient, :provider_timeout}

      contains_atom?(reason, [
        :invalid_json,
        :invalid_response,
        :invalid_execution_response,
        :invalid_ai_response,
        :invalid_advanced_experience
      ]) ->
        {:transient, :invalid_provider_response}

      true ->
        {:permanent, :unclassified_generation_failure}
    end
  end

  defp retry_available?(attempt, max_attempts, category) do
    attempt < min(max_attempts, category_attempt_limit(category, max_attempts))
  end

  defp category_attempt_limit(category, _max_attempts)
       when category in [
              :rate_limited,
              :provider_unavailable,
              :provider_timeout,
              :invalid_provider_response
            ],
       do: @provider_attempt_limit

  defp category_attempt_limit(_category, max_attempts), do: max_attempts

  defp configuration_category(reason) do
    cond do
      contains_atom?(reason, [:unauthorized, :invalid_api_key]) ->
        :provider_unauthorized

      contains_atom?(reason, [:not_configured, :missing_feature_config]) ->
        :provider_not_configured

      true ->
        :provider_configuration_error
    end
  end

  defp failure_details({:ai_planning_failed, {:content_validation_exhausted, details}})
       when is_map(details) do
    findings = Map.get(details, :findings, Map.get(details, "findings", []))

    %{
      "phase" => "basic_content_validation",
      "validation_attempts" => Map.get(details, :attempts, Map.get(details, "attempts", 0)),
      "finding_codes" =>
        findings
        |> List.wrap()
        |> Enum.map(fn finding -> finding["code"] || finding[:code] end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.take(12)
    }
  end

  defp failure_details({:ai_planning_failed, {category, details}})
       when category in [
              :content_quality_exhausted,
              :content_quality_stalled,
              :question_quality_exhausted,
              :question_quality_stalled
            ] and is_map(details) do
    %{
      "phase" =>
        if(category in [:content_quality_exhausted, :content_quality_stalled],
          do: "v5_content_review",
          else: "v5_question_review"
        ),
      "reason" => Atom.to_string(category),
      "attempts" => details["attempts"] || details[:attempts] || 0,
      "confidence" => details["confidence"] || details[:confidence] || 0.0,
      "finding_codes" =>
        details
        |> then(&(Map.get(&1, "findings") || Map.get(&1, :findings) || []))
        |> List.wrap()
        |> Enum.map(&(&1["code"] || &1[:code]))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.take(20)
    }
  end

  defp failure_details({:ai_planning_failed, reason}) do
    case safe_provider_failure_details(reason) do
      nil ->
        cond do
          contains_atom?(reason, [:run_persistence_failed]) ->
            %{"phase" => "question_agent_start", "reason" => "run_persistence_failed"}

          contains_atom?(reason, [
            :step_budget_exhausted,
            :token_budget_exhausted,
            :cost_budget_exhausted,
            :deadline_exceeded,
            :loop_detected,
            :invalid_decision,
            :accepted_question_draft_missing
          ]) ->
            %{"phase" => "question_agent", "reason" => "agent_budget_or_validation_exhausted"}

          true ->
            %{"phase" => "provider_or_response"}
        end

      details ->
        Map.put(details, "phase", "question_agent_provider")
    end
  end

  defp failure_details({:lesson_generation_failed, reason}) do
    details = failure_details(reason) |> Map.put_new("phase", "lesson_generation")

    if details == %{"phase" => "provider_or_response"} do
      Map.put(details, "reason_code", safe_reason_code(reason))
    else
      details
    end
  end

  defp failure_details({:lesson_plan_completion_failed, reason}) do
    %{
      "phase" => "lesson_plan_persistence",
      "reason_code" => safe_reason_code(reason)
    }
  end

  defp failure_details({:internal_exception, exception}) do
    %{
      "phase" => "lesson_planning",
      "exception" => exception_module(exception)
    }
  end

  defp failure_details({:ai_configuration_failed, _reason}),
    do: %{"phase" => "provider_configuration"}

  defp failure_details({:current_source_ast_required, :start_a_new_import}),
    do: %{
      "phase" => "current_source_ast",
      "message" =>
        "This lesson does not contain the current source AST. Start a new OpenStax import instead of retrying this run."
    }

  defp failure_details(_reason), do: %{}

  defp safe_provider_failure_details({:provider_failure, details}) when is_map(details) do
    Map.take(details, [
      "category",
      "status_code",
      "provider_error_type",
      "provider_error_code",
      "provider_error_param"
    ])
  end

  defp safe_provider_failure_details(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.find_value(&safe_provider_failure_details/1)
  end

  defp safe_provider_failure_details(term) when is_list(term),
    do: Enum.find_value(term, &safe_provider_failure_details/1)

  defp safe_provider_failure_details(_term), do: nil

  defp exception_module(%{__struct__: module}), do: inspect(module)
  defp exception_module(module) when is_atom(module), do: inspect(module)
  defp exception_module(_exception), do: "Exception"

  defp safe_reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason_code({:ai_planning_failed, reason}), do: safe_reason_code(reason)

  defp safe_reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason
    |> elem(0)
    |> safe_reason_code()
  end

  defp safe_reason_code(%{__struct__: module}), do: inspect(module)
  defp safe_reason_code(_reason), do: "unknown"

  defp maybe_log_unclassified_failure(disposition, category, details)
       when category in [:unclassified_generation_failure, :lesson_plan_persistence_failed] do
    Logger.warning("OpenStax lesson planning stopped on an unclassified failure",
      disposition: disposition,
      category: category,
      phase: details["phase"],
      reason_code: details["reason_code"]
    )
  end

  defp maybe_log_unclassified_failure(_disposition, _category, _details), do: :ok

  defp contains_http_5xx?(term), do: Enum.any?(500..599, &contains_http_status?(term, &1))
  defp contains_http_4xx?(term), do: Enum.any?(400..499, &contains_http_status?(term, &1))

  defp contains_http_status?(status, status) when is_integer(status), do: true

  defp contains_http_status?(term, status) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&contains_http_status?(&1, status))
  end

  defp contains_http_status?(term, status) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      (key in [:status, "status", :status_code, "status_code"] and value == status) or
        contains_http_status?(value, status)
    end)
  end

  defp contains_http_status?(term, status) when is_list(term),
    do: Enum.any?(term, &contains_http_status?(&1, status))

  defp contains_http_status?(_term, _status), do: false

  defp contains_atom?(term, atoms) when is_atom(term), do: term in atoms

  defp contains_atom?(term, atoms) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_atom?(&1, atoms))

  defp contains_atom?(term, atoms) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_atom?(key, atoms) or contains_atom?(value, atoms)
      end)

  defp contains_atom?(term, atoms) when is_list(term),
    do: Enum.any?(term, &contains_atom?(&1, atoms))

  defp contains_atom?(_term, _atoms), do: false

  defp integer_arg(args, key, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: trunc(:math.pow(2, attempt) * 10)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(12)
end
