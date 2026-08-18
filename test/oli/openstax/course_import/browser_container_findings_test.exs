defmodule Oli.OpenStax.CourseImport.BrowserContainerFindingsTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.BrowserContainer

  test "returns bounded structured findings for every browser acceptance category" do
    payload =
      passing_payload()
      |> Map.merge(%{
        "status" => "failed",
        "network_requests" => ["https://example.test/data?token=not-retained"],
        "console_errors" => ["console exploded\nwith details"],
        "page_errors" => ["page exploded"],
        "capi_handshake" => "failed",
        "sample_cases_passed" => false,
        "sample_results" => [
          %{
            "index" => 2,
            "passed" => false,
            "expected" => %{"pressure" => 2.0},
            "actual" => %{"pressure" => 3.0},
            "tolerance" => 0.01
          }
        ],
        "keyboard" => "failed",
        "focus_visible" => false,
        "serious_or_critical_a11y" => 1,
        "a11y_findings" => [
          %{
            "id" => "button-name",
            "impact" => "serious",
            "help" => "Buttons must have discernible text",
            "node_count" => 1,
            "targets" => [["#run"]]
          }
        ],
        "desktop_overflow" => true,
        "mobile_overflow" => true,
        "reduced_motion" => "failed",
        "webgl_fallback" => "failed",
        "failure" => "frame did not finish"
      })

    assert {:error,
            %{
              code: :browser_acceptance_failed,
              validation_payload: %{"findings" => findings}
            }} = BrowserContainer.classify_result(payload)

    codes = MapSet.new(findings, & &1["code"])

    for code <- ~w(
      network_request console_error page_error capi_handshake_failed capi_sample_failed
      keyboard_path_failed focus_not_visible axe_button-name desktop_overflow mobile_overflow
      reduced_motion_failed webgl_fallback_failed browser_runtime_failed
    ) do
      assert MapSet.member?(codes, code)
    end

    network = Enum.find(findings, &(&1["code"] == "network_request"))
    assert network["details"]["url"] == "https://example.test/data"
    refute inspect(findings) =~ "not-retained"

    sample = Enum.find(findings, &(&1["code"] == "capi_sample_failed"))
    assert sample["details"]["sample_index"] == 2
    assert sample["details"]["expected"] == %{"pressure" => 2.0}
    assert sample["details"]["actual"] == %{"pressure" => 3.0}
  end

  test "accepts a passing browser payload without manufacturing findings" do
    assert {:ok, payload} = BrowserContainer.classify_result(passing_payload())
    assert payload["status"] == "passed"
  end

  defp passing_payload do
    %{
      "status" => "passed",
      "network_requests" => [],
      "console_errors" => [],
      "page_errors" => [],
      "capi_handshake" => "passed",
      "sample_cases_passed" => true,
      "sample_results" => [%{"index" => 0, "passed" => true}],
      "keyboard" => "passed",
      "focus_visible" => true,
      "serious_or_critical_a11y" => 0,
      "a11y_findings" => [],
      "desktop_overflow" => false,
      "mobile_overflow" => false,
      "reduced_motion" => "passed",
      "webgl_fallback" => "passed"
    }
  end
end
