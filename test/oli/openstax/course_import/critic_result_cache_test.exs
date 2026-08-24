defmodule Oli.OpenStax.CourseImport.CriticResultCacheTest do
  use Oli.DataCase, async: false

  alias Oli.OpenStax.CourseImport.{CriticResult, CriticResultCache}

  test "normalized critic results survive beyond process-local memory" do
    key = "critic-#{Ecto.UUID.generate()}"
    result = %{"approved" => true, "confidence" => 0.99, "findings" => []}

    assert :miss = CriticResultCache.get(key)
    assert :ok = CriticResultCache.put(key, result)

    task = Task.async(fn -> CriticResultCache.get(key) end)
    assert {:ok, ^result} = Task.await(task)
    assert Repo.get_by!(CriticResult, cache_key: key).result == result
  end
end
