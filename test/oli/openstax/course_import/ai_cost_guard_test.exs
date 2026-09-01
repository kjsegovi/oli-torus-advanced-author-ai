defmodule Oli.OpenStax.CourseImport.AICostGuardTest do
  use Oli.DataCase, async: false
  use Oban.Testing, repo: Oli.Repo

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    AICostGuard,
    AICostReservation,
    AIPricing,
    AIUsageEvent,
    AIUsageLedger
  }

  alias Oli.ScopedFeatureFlags

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax AI cost guard")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/cost-guard"
      )

    original = %{
      warning: Application.get_env(:oli, :openstax_ai_import_warning_cents),
      stop: Application.get_env(:oli, :openstax_ai_import_stop_cents),
      daily: Application.get_env(:oli, :openstax_ai_daily_stop_cents)
    }

    on_exit(fn ->
      Application.put_env(:oli, :openstax_ai_import_warning_cents, original.warning)
      Application.put_env(:oli, :openstax_ai_import_stop_cents, original.stop)
      Application.put_env(:oli, :openstax_ai_daily_stop_cents, original.daily)
    end)

    {:ok, run: run}
  end

  test "concurrent worst-case reservations cannot overrun the import ceiling", %{run: run} do
    Application.put_env(:oli, :openstax_ai_import_warning_cents, 0)
    Application.put_env(:oli, :openstax_ai_import_stop_cents, 10)
    Application.put_env(:oli, :openstax_ai_daily_stop_cents, 0)

    request = %{
      model: "gpt-5.6-terra",
      service_tier: "flex",
      input_tokens: 1_000,
      max_output_tokens: 12_000
    }

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          AICostGuard.reserve(
            %{run_id: run.id, request_key: "concurrent-#{index}", role: "architect"},
            request
          )
        end,
        ordered: false,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %AICostReservation{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:ai_cost_limit_exceeded, :import, _}}, &1)) == 1
  end

  test "a persisted successful response is replayed without a second reservation or charge", %{
    run: run
  } do
    context =
      AIUsageLedger.request_context(
        [run_id: run.id, planning_request_id: Ecto.UUID.generate()],
        :basic_content_architect
      )

    request = %{
      model: "gpt-5.6-terra",
      service_tier: "flex",
      input_tokens: 100,
      max_output_tokens: 12_000,
      request_payload_hash: "payload-a"
    }

    assert {:ok, :proceed} = AIUsageLedger.prepare(context, request)

    assert {:ok, _event} =
             AIUsageLedger.record(context, :ok, %{
               model: "gpt-5.6-terra",
               provider: "open_ai",
               service_tier: "flex",
               input_tokens: 100,
               output_tokens: 20,
               response_content: "{\"approved\":true}",
               request_id: "request-one",
               request_payload_hash: "payload-a"
             })

    assert {:ok, {:replay, replayed}} = AIUsageLedger.prepare(context, request)
    assert replayed.content == "{\"approved\":true}"
    assert replayed.metadata["cache_status"] == "durable_replay"
    assert Repo.aggregate(AICostReservation, :count) == 1
  end

  test "a changed payload hash proceeds with a new reservation", %{run: run} do
    context =
      AIUsageLedger.request_context(
        [run_id: run.id, planning_request_id: Ecto.UUID.generate()],
        :basic_content_architect
      )

    insert_successful_event(context, "payload-a")

    changed_request = %{
      model: "gpt-5.6-terra",
      service_tier: "flex",
      input_tokens: 100,
      max_output_tokens: 12_000,
      request_payload_hash: "payload-b"
    }

    assert {:ok, :proceed} = AIUsageLedger.prepare(context, changed_request)
    assert Repo.aggregate(AICostReservation, :count) == 1
  end

  test "a nil request or historical payload hash is never replayed", %{run: run} do
    request = %{
      model: "gpt-5.6-terra",
      service_tier: "flex",
      input_tokens: 100,
      max_output_tokens: 12_000,
      request_payload_hash: "payload-a"
    }

    context_with_historical_nil_hash =
      AIUsageLedger.request_context(
        [run_id: run.id, planning_request_id: Ecto.UUID.generate()],
        :basic_content_architect
      )

    insert_successful_event(context_with_historical_nil_hash, nil)

    assert {:ok, :proceed} =
             AIUsageLedger.prepare(context_with_historical_nil_hash, request)

    context_with_nil_request_hash =
      AIUsageLedger.request_context(
        [run_id: run.id, planning_request_id: Ecto.UUID.generate()],
        :basic_content_architect
      )

    insert_successful_event(context_with_nil_request_hash, "payload-a")

    request_with_nil_hash = %{request | request_payload_hash: nil}

    assert {:ok, :proceed} =
             AIUsageLedger.prepare(context_with_nil_request_hash, request_with_nil_hash)

    assert Repo.aggregate(AICostReservation, :count) == 2
  end

  defp insert_successful_event(context, request_payload_hash) do
    %AIUsageEvent{}
    |> AIUsageEvent.changeset(%{
      run_id: context[:run_id],
      role: context[:role],
      phase: to_string(context[:phase]),
      request_key: context[:request_key],
      request_payload_hash: request_payload_hash,
      response_payload: %{"content" => "{\"approved\":true}", "metadata" => %{}},
      pricing_version: AIPricing.pricing_version(),
      outcome: "succeeded"
    })
    |> Repo.insert!()
  end
end
