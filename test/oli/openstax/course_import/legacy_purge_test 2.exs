defmodule Oli.OpenStax.CourseImport.LegacyPurgeTest do
  use Oli.DataCase, async: false

  alias Oli.OpenStax.CourseImport.LegacyPurge

  test "is idempotent when the local database contains no legacy runs" do
    assert {:ok, first} = LegacyPurge.purge_all(environment: :test)
    assert first == %{projects: 0, runs: 0, resources: 0, activities: 0}

    assert {:ok, second} = LegacyPurge.purge_all(environment: :test)
    assert second == first
  end

  test "refuses to inspect or mutate production data" do
    assert {:error, :legacy_purge_forbidden} =
             LegacyPurge.purge_all(environment: :prod)
  end
end
