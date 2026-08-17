defmodule Oli.OpenStax.CourseImport.AIPlannerV6Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.AIPlanner
  alias Oli.OpenStax.CourseImport.V6Fixture, as: Fixture

  test "rejects every pre-v6 run before loading a provider" do
    assert {:error, {:unsupported_openstax_plan_schema, 4}} =
             AIPlanner.plan(Fixture.lesson(), 1,
               plan_schema_version: 4,
               service_config_loader: fn ->
                 flunk("legacy runs must stop before provider loading")
               end
             )
  end

  test "requires the deterministic current source AST" do
    assert {:error, {:current_source_ast_required, :start_a_new_import}} =
             AIPlanner.plan(%{"title" => "Missing AST", "source_blocks" => []}, 1,
               plan_schema_version: 6,
               service_config_loader: fn ->
                 flunk("missing source must stop before provider loading")
               end
             )

    assert {:error, {:current_source_ast_required, :start_a_new_import}} =
             AIPlanner.plan(
               %{"title" => "Old source", "source_blocks" => [%{"id" => "old", "text" => "x"}]},
               1,
               plan_schema_version: 6,
               service_config_loader: fn ->
                 flunk("legacy-shaped source must stop before provider loading")
               end
             )
  end
end
