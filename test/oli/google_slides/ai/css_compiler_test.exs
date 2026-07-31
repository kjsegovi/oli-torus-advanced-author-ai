defmodule Oli.GoogleSlides.AI.CSSCompilerTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.CSSCompiler

  test "compiles sorted declarations under a generated lesson scope" do
    rules = [
      %{
        "target" => "prompt",
        "declarations" => %{
          "font-size" => "1.25rem",
          "color" => "#123456",
          "margin-bottom" => "16px"
        }
      }
    ]

    assert {:ok, css} = CSSCompiler.compile(rules, scope: "run-42")

    assert css ==
             """
             .aa-import-run-42 .prompt {
               color: #123456;
               font-size: 1.25rem;
               margin-bottom: 16px;
             }
             """
             |> String.trim_trailing()
  end

  test "rejects selectors, global rules, imports, URLs, and unsupported properties" do
    assert {:error, selector_errors} =
             CSSCompiler.compile([
               %{"target" => "body > *", "declarations" => %{"color" => "#000"}}
             ])

    assert Enum.any?(selector_errors, &(&1["code"] == "invalid_target"))

    assert {:error, unsafe_errors} =
             CSSCompiler.compile([
               %{
                 "target" => "hero",
                 "declarations" => %{
                   "background-color" => "url(https://example.com/a.png)",
                   "animation" => "spin 1s"
                 }
               }
             ])

    assert Enum.any?(unsafe_errors, &(&1["code"] == "unsafe_value"))
    assert Enum.any?(unsafe_errors, &(&1["code"] == "unsupported_property"))
  end

  test "normalizes atom-keyed structured rules deterministically" do
    assert {:ok,
            [
              %{
                "target" => "card",
                "declarations" => %{"display" => "grid", "gap" => "1rem"}
              }
            ]} =
             CSSCompiler.normalize([
               %{target: "card", declarations: %{gap: "1rem", display: "grid"}}
             ])
  end
end
