defmodule Oli.OpenStax.CourseImport.CriticResultCache do
  @moduledoc "Durable exact cache for fully normalized critic decisions."

  alias Oli.OpenStax.CourseImport.{CriticResult, ImportContract}
  alias Oli.Repo

  def key(kind, payload, prompt, service_config) do
    model = Map.get(service_config, :primary_model) || %{}

    %{
      kind: kind,
      source_contract_hash: hash(payload["source_contract"] || %{}),
      candidate_hash: hash(Map.delete(payload, "source_contract")),
      critic_policy: ImportContract.quality_policy_version(),
      prompt_hash: hash(prompt),
      model_snapshot: Map.get(model, :model_snapshot) || Map.get(model, :model)
    }
    |> hash()
  end

  def get(key) do
    case Repo.get_by(CriticResult, cache_key: key) do
      %CriticResult{} = cached ->
        now = DateTime.utc_now()
        cached |> CriticResult.changeset(%{last_used_at: now}) |> Repo.update()
        {:ok, cached.result}

      nil ->
        :miss
    end
  end

  def put(key, value) when is_binary(key) and is_map(value) do
    now = DateTime.utc_now()

    %CriticResult{}
    |> CriticResult.changeset(%{cache_key: key, result: value, last_used_at: now})
    |> Repo.insert(
      on_conflict: [set: [result: value, last_used_at: now, updated_at: now]],
      conflict_target: :cache_key
    )
    |> case do
      {:ok, _cached} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def clear do
    Repo.delete_all(CriticResult)
    :ok
  end

  defp hash(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
