defmodule Oli.GoogleSlides.ImportWorkflow.ObjectiveCatalogTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.ImportWorkflow.ObjectiveCatalog

  test "accepts only current project objectives and canonicalizes their titles" do
    plan = %{
      "objectives" => %{
        "mapped" => [
          %{
            "objectiveId" => "42",
            "title" => "Model-authored title",
            "screenKeys" => ["screen_one"]
          }
        ],
        "proposed" => []
      }
    }

    catalog = [%{"objectiveId" => "42", "title" => "Explain membrane transport"}]

    assert {:ok, canonical} = ObjectiveCatalog.canonicalize(plan, catalog)

    assert get_in(canonical, ["objectives", "mapped", Access.at(0), "title"]) ==
             "Explain membrane transport"
  end

  test "rejects an objective identifier outside the current project catalog" do
    plan = %{
      "objectives" => %{
        "mapped" => [%{"objectiveId" => "invented", "title" => "Invented"}],
        "proposed" => []
      }
    }

    assert {:error, {:invalid_mapped_objective, "invented"}} =
             ObjectiveCatalog.canonicalize(plan, [
               %{"objectiveId" => "42", "title" => "Explain membrane transport"}
             ])
  end
end
