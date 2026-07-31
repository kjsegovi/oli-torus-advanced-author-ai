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

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.AIPlanner

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, id: job_id, attempt: job_attempt, max_attempts: max_attempts}) do
    attempt = job_attempt + integer_arg(args, "attempt_offset", 0)

    case CourseImport.claim_lesson_plan_job(args, attempt, job_id) do
      {:ok, :already_completed} ->
        :ok

      {:ok, claim} ->
        with {:ok, result} <- plan_lesson(claim),
             {:ok, _lesson, _run} <- CourseImport.complete_lesson_plan_job(args, result) do
          :ok
        else
          {:error, reason} -> retry_or_fail(args, attempt, max_attempts, reason)
        end

      {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
        {:discard, reason}

      {:error, reason} ->
        retry_or_fail(args, attempt, max_attempts, reason)
    end
  rescue
    exception ->
      retry_or_fail(
        args,
        job_attempt + integer_arg(args, "attempt_offset", 0),
        max_attempts,
        {:internal_exception, exception.__struct__}
      )
  end

  defp retry_or_fail(args, attempt, max_attempts, reason) do
    {disposition, category} = classify_failure(reason)

    if disposition == :transient and attempt < max_attempts do
      case CourseImport.retry_lesson_plan_job(args, attempt, category) do
        {:ok, _lesson, _run} ->
          {:error, category}

        {:error, reason} when reason in [:stale_lesson_planning_job, :not_found] ->
          {:discard, reason}

        {:error, _reason} ->
          {:error, category}
      end
    else
      _ = CourseImport.fail_lesson_plan_job(args, attempt, category)
      {:discard, category}
    end
  end

  defp plan_lesson(claim) do
    opts = [plan_schema_version: claim.plan_schema_version]

    case Application.get_env(:oli, :openstax_course_import_lesson_planner, AIPlanner) do
      planner when is_atom(planner) ->
        planner.plan(claim.source, claim.planning_position, opts)

      planner when is_function(planner, 3) ->
        planner.(claim.source, claim.planning_position, opts)

      _invalid ->
        {:error, {:ai_configuration_failed, :invalid_lesson_planner}}
    end
  end

  # Provider/network failures and malformed model responses are safe to retry.
  # Configuration, authorization, and missing source invariants need user or
  # operator action and should fail without repeatedly spending tokens.
  defp classify_failure({:ai_configuration_failed, reason}),
    do: {:permanent, configuration_category(reason)}

  defp classify_failure({:ai_planning_failed, reason}), do: classify_provider_failure(reason)
  defp classify_failure({:invalid_status, _, _}), do: {:permanent, :invalid_run_status}
  defp classify_failure(:invalid_lesson), do: {:permanent, :invalid_lesson}
  defp classify_failure(:missing_lesson_source), do: {:permanent, :missing_lesson_source}
  defp classify_failure(:missing_lesson_plan), do: {:permanent, :missing_lesson_plan}
  defp classify_failure({:internal_exception, _}), do: {:transient, :internal_exception}
  defp classify_failure(reason), do: classify_provider_failure(reason)

  defp classify_provider_failure(reason) do
    cond do
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

      contains_atom?(reason, [:timeout, :connect_timeout, :closed, :econnrefused, :enetunreach]) ->
        {:transient, :provider_timeout}

      contains_atom?(reason, [:invalid_json, :invalid_response, :invalid_execution_response]) ->
        {:transient, :invalid_provider_response}

      true ->
        {:transient, :unclassified_provider_failure}
    end
  end

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
  def timeout(_job), do: :timer.minutes(5)
end
