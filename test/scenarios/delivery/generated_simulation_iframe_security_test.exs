defmodule Oli.Scenarios.Delivery.GeneratedSimulationIframeSecurityTest do
  use Oli.DataCase

  alias Oli.Scenarios
  alias Oli.Scenarios.RuntimeOpts

  @scenario_path Path.join(
                   Path.dirname(__ENV__.file),
                   "generated_simulation_iframe_security.scenario.yaml"
                 )

  test "approved generated simulation iframe metadata survives delivery" do
    assert :ok = Scenarios.validate_file(@scenario_path)

    result = Scenarios.execute_file(@scenario_path, RuntimeOpts.build())

    assert result.errors == [], "Scenario errors: #{inspect(result.errors)}"

    failed_verifications =
      Enum.filter(result.verifications, fn verification -> verification.passed != true end)

    assert failed_verifications == [],
           "Scenario verification failures: #{inspect(failed_verifications)}"
  end
end
