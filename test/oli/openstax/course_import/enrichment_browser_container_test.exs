defmodule Oli.OpenStax.CourseImport.EnrichmentBrowserContainerTest do
  use ExUnit.Case, async: false

  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.{BrowserContainer, LocalContainer}

  test "validates typed CAPI samples, keyboard access, responsive layout, and fallbacks" do
    bundle = %{
      files: %{
        "index.html" => """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="description" content="A deterministic validator simulation.">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'">
            <title>Validator simulation</title>
            <link rel="stylesheet" href="styles.css">
            <script src="torus-capi-bridge.js"></script>
            <script src="app.js" defer></script>
          </head>
          <body>
            <main>
              <h1>Double a bounded value</h1>
              <label for="x">Input</label>
              <input id="x" type="range" min="0" max="10" value="1">
              <button id="apply" type="button">Apply value</button>
              <output id="value" aria-live="polite">2</output>
              <section data-simulation-text-alternative>
                <h2>Text alternative</h2>
                <p>The output is twice the input.</p>
              </section>
            </main>
          </body>
        </html>
        """,
        "styles.css" => """
        * { box-sizing: border-box; }
        body { margin: 0; max-width: 100%; font-family: sans-serif; }
        main { width: min(100%, 48rem); padding: 1rem; }
        input, button { display: block; margin: 1rem 0; max-width: 100%; }
        :focus-visible { outline: 3px solid #b45309; outline-offset: 2px; }
        @media (prefers-reduced-motion: reduce) { * { animation: none; transition: none; } }
        """,
        "app.js" => """
        (() => {
          'use strict';
          const input = document.getElementById('x');
          const output = document.getElementById('value');
          const emit = (value) => {
            output.value = String(value * 2);
            window.TorusCapi.emit('y', value * 2);
          };
          window.TorusCapi.onInput('x', (value) => {
            input.value = String(value);
            emit(value);
          });
          document.getElementById('apply').addEventListener('click', () => emit(Number(input.value)));
          window.addEventListener('torus-capi-ready', () => emit(Number(input.value)));
        })();
        """
      },
      manifest: %{"entrypoint" => "index.html", "library_ids" => []},
      system_library_manifest: %{},
      capi_manifest: %{
        "inputs" => [%{"key" => "x", "type" => "number"}],
        "outputs" => [%{"key" => "y", "type" => "number"}]
      }
    }

    opts = [
      sample_cases: [
        %{
          "inputs" => %{"x" => 3},
          "expected_outputs" => %{"y" => 6},
          "tolerance" => 0,
          "deterministic" => true
        }
      ],
      rendering_mode: "2d"
    ]

    if BrowserContainer.available?() do
      assert {:ok, _static} = LocalContainer.build_and_validate(bundle, opts)
      assert {:ok, validated} = BrowserContainer.build_and_validate(bundle, opts)
      assert validated.validation_payload["status"] == "passed"
      assert validated.validation_payload["browser"]["sample_cases_passed"]
      assert validated.validation_payload["browser"]["network_requests"] == []
    else
      assert {:error, :sandbox_unavailable} =
               BrowserContainer.build_and_validate(bundle, opts)
    end
  end
end
