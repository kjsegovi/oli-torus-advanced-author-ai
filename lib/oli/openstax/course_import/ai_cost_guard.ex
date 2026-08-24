defmodule Oli.OpenStax.CourseImport.AICostGuard do
  @moduledoc "Transactional internal circuit breaker for OpenStax AI spend."

  import Ecto.Query

  require Logger

  alias Oli.OpenStax.CourseImport.{AICostReservation, AIPricing, Run}
  alias Oli.Repo

  @microdollars_per_cent 10_000
  @default_lesson_limit_cents 300
  @default_simulation_limit_cents 1_000
  @default_import_warning_cents 10_000
  @default_import_stop_cents 20_000
  @default_daily_stop_cents 100_000

  @spec reserve(map(), map()) :: {:ok, AICostReservation.t()} | {:error, term()}
  def reserve(context, request) when is_map(context) and is_map(request) do
    if enabled?() and is_binary(context[:run_id]) and is_binary(context[:request_key]) do
      reserve_guarded(context, request)
    else
      {:ok, nil}
    end
  end

  def reserve(_context, _request), do: {:ok, nil}

  @spec settle(map(), non_neg_integer(), :succeeded | :failed) :: :ok | {:error, term()}
  def settle(context, actual_microdollars, outcome)
      when is_map(context) and is_integer(actual_microdollars) and actual_microdollars >= 0 do
    if is_binary(context[:request_key]) do
      status = if outcome == :succeeded, do: "settled", else: "released"
      now = DateTime.utc_now()

      AICostReservation
      |> where([reservation], reservation.request_key == ^context[:request_key])
      |> Repo.update_all(
        set: [
          status: status,
          actual_microdollars: actual_microdollars,
          settled_at: now,
          updated_at: now
        ]
      )

      :ok
    else
      :ok
    end
  rescue
    error -> {:error, error}
  end

  defp reserve_guarded(context, request) do
    reserved =
      AIPricing.estimate_max_microdollars(request[:model], request[:service_tier], %{
        input_tokens: request[:input_tokens] || 0,
        max_output_tokens: request[:max_output_tokens] || 0,
        regional_processing: request[:regional_processing] == true
      })

    Repo.transaction(fn ->
      Repo.one!(from(run in Run, where: run.id == ^context[:run_id], lock: "FOR UPDATE"))

      existing =
        Repo.one(
          from(reservation in AICostReservation,
            where: reservation.request_key == ^context[:request_key],
            lock: "FOR UPDATE"
          )
        )

      case existing do
        %AICostReservation{status: "settled"} ->
          Repo.rollback(:ai_response_already_settled)

        %AICostReservation{status: "reserved"} = reservation ->
          reservation

        %AICostReservation{} = reservation ->
          :ok = enforce_limits(context, reserved, reservation.id)

          reservation
          |> AICostReservation.changeset(%{
            status: "reserved",
            reserved_microdollars: reserved,
            actual_microdollars: 0,
            settled_at: nil,
            metadata: reservation_metadata(request)
          })
          |> Repo.update!()

        nil ->
          :ok = enforce_limits(context, reserved, nil)

          %AICostReservation{}
          |> AICostReservation.changeset(%{
            run_id: context[:run_id],
            lesson_id: context[:lesson_id],
            request_key: context[:request_key],
            role: context[:role] || "unknown",
            model: request[:model] || "unknown",
            service_tier: to_string(request[:service_tier] || "standard"),
            reserved_microdollars: reserved,
            metadata: reservation_metadata(request)
          })
          |> Repo.insert!()
      end
    end)
    |> case do
      {:ok, reservation} -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enforce_limits(context, reserved, excluded_id) do
    lesson_limit =
      if context[:cost_scope] == :simulation,
        do:
          configured_limit(:openstax_ai_simulation_limit_cents, @default_simulation_limit_cents),
        else: configured_limit(:openstax_ai_lesson_limit_cents, @default_lesson_limit_cents)

    import_warning =
      configured_limit(:openstax_ai_import_warning_cents, @default_import_warning_cents)

    import_stop = configured_limit(:openstax_ai_import_stop_cents, @default_import_stop_cents)
    daily_stop = configured_limit(:openstax_ai_daily_stop_cents, @default_daily_stop_cents)

    run_total = reserved_total(run_id: context[:run_id], excluded_id: excluded_id)

    lesson_total =
      if is_binary(context[:lesson_id]),
        do: reserved_total(lesson_id: context[:lesson_id], excluded_id: excluded_id),
        else: 0

    daily_total = reserved_total(inserted_after: start_of_day(), excluded_id: excluded_id)

    cond do
      lesson_limit > 0 and lesson_total + reserved > lesson_limit ->
        Repo.rollback(
          {:ai_cost_limit_exceeded, :lesson, limit_details(lesson_total, reserved, lesson_limit)}
        )

      import_stop > 0 and run_total + reserved > import_stop ->
        Repo.rollback(
          {:ai_cost_limit_exceeded, :import, limit_details(run_total, reserved, import_stop)}
        )

      daily_stop > 0 and daily_total + reserved > daily_stop ->
        Repo.rollback(
          {:ai_cost_limit_exceeded, :daily, limit_details(daily_total, reserved, daily_stop)}
        )

      true ->
        maybe_warn(context, run_total, reserved, import_warning)
        :ok
    end
  end

  defp reserved_total(filters) do
    query =
      from(reservation in AICostReservation,
        where: reservation.status in ["reserved", "settled"],
        select:
          coalesce(
            sum(
              fragment(
                "CASE WHEN ? = 'reserved' THEN ? ELSE ? END",
                reservation.status,
                reservation.reserved_microdollars,
                reservation.actual_microdollars
              )
            ),
            0
          )
      )

    query =
      Enum.reduce(filters, query, fn
        {:run_id, value}, query ->
          where(query, [reservation], reservation.run_id == ^value)

        {:lesson_id, value}, query ->
          where(query, [reservation], reservation.lesson_id == ^value)

        {:inserted_after, value}, query ->
          where(query, [reservation], reservation.inserted_at >= ^value)

        {:excluded_id, nil}, query ->
          query

        {:excluded_id, value}, query ->
          where(query, [reservation], reservation.id != ^value)
      end)

    query
    |> Repo.one()
    |> integer_total()
  end

  defp integer_total(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer_total(value) when is_integer(value), do: value
  defp integer_total(_value), do: 0

  defp maybe_warn(context, current, reserved, threshold) do
    if threshold > 0 and current < threshold and current + reserved >= threshold do
      Logger.warning(
        "OpenStax import #{context[:run_id]} crossed the internal AI cost warning threshold"
      )

      :telemetry.execute(
        [:oli, :openstax, :course_import, :ai_cost_warning],
        %{projected_microdollars: current + reserved},
        %{run_id: context[:run_id], lesson_id: context[:lesson_id]}
      )
    end
  end

  defp limit_details(current, reserved, limit),
    do: %{
      current_microdollars: current,
      reserved_microdollars: reserved,
      limit_microdollars: limit
    }

  defp reservation_metadata(request) do
    %{
      "input_tokens" => request[:input_tokens] || 0,
      "max_output_tokens" => request[:max_output_tokens] || 0,
      "pricing_version" => AIPricing.pricing_version()
    }
  end

  defp configured_limit(key, default_cents) do
    :oli
    |> Application.get_env(key, default_cents)
    |> normalize_cents(default_cents)
    |> Kernel.*(@microdollars_per_cent)
  end

  defp normalize_cents(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_cents(_value, default), do: default

  defp enabled?, do: Application.get_env(:oli, :openstax_ai_cost_guard_enabled, true) == true

  defp start_of_day do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
