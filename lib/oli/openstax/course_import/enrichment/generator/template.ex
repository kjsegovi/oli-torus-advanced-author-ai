defmodule Oli.OpenStax.CourseImport.Enrichment.Generator.Template do
  @moduledoc """
  Produces a local, dependency-free prediction-and-observation exploration.

  This deterministic adapter is intended for local canaries and environments
  that need a safe fallback without a remote code-generation provider. It does
  not claim to model a domain-specific equation; the proposal rationale and
  learner task frame a low-stakes evidence exploration that is followed by
  native Torus checks.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Generator

  alias Oli.OpenStax.CourseImport.EnrichmentProposal

  @impl true
  def available?, do: true

  @impl true
  def runtime_profile, do: :audited_static

  @impl true
  def generate(%EnrichmentProposal{kind: "generated_simulation"} = proposal, _opts) do
    title = proposal.resource_title || "Prediction and evidence explorer"
    rationale = proposal.instructional_rationale
    learner_task = proposal.learner_task

    {:ok,
     %{
       files: %{
         "index.html" => index_html(title, rationale, learner_task),
         "styles.css" => styles(),
         "app.js" => javascript()
       },
       manifest: %{
         "entrypoint" => "index.html",
         "dependency_free" => true,
         "interaction" => "prediction_observation"
       },
       capi_manifest: %{"inputs" => [], "outputs" => []},
       metadata: %{
         "generator_name" => "local_prediction_explorer",
         "generator_version" => "1",
         "assessment_mode" => "native_torus_followup",
         "domain_model" => "author_review_required"
       }
     }}
  end

  def generate(%EnrichmentProposal{}, _opts), do: {:error, :not_generated_simulation}
  def generate(_, _opts), do: {:error, :invalid_input}

  defp index_html(title, rationale, learner_task) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="description" content="Make a prediction, vary a bounded model setting, and record an evidence-based observation.">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'">
        <title>#{html_escape(title)}</title>
        <link rel="stylesheet" href="styles.css">
        <script src="app.js" defer></script>
      </head>
      <body>
        <main>
          <p class="eyebrow">Prediction → observation → explanation</p>
          <h1>#{html_escape(title)}</h1>
          <p>#{html_escape(rationale)}</p>

          <fieldset>
            <legend>Before changing the setting, what do you predict?</legend>
            <label for="prediction-increase"><input id="prediction-increase" type="radio" name="prediction" value="increase"> The response will increase</label>
            <label for="prediction-decrease"><input id="prediction-decrease" type="radio" name="prediction" value="decrease"> The response will decrease</label>
            <label for="prediction-same"><input id="prediction-same" type="radio" name="prediction" value="same"> The response will stay about the same</label>
          </fieldset>

          <section aria-labelledby="explore-heading">
            <h2 id="explore-heading">Explore the bounded setting</h2>
            <label for="model-setting">Model setting: <output id="setting-value" for="model-setting">50</output></label>
            <input id="model-setting" type="range" min="0" max="100" step="1" value="50">
            <div class="meter" aria-hidden="true"><span id="meter-fill"></span></div>
            <p id="observation" role="status" aria-live="polite">The model is at its midpoint. Move the slider and compare the response.</p>
          </section>

          <aside aria-labelledby="task-heading">
            <h2 id="task-heading">Your evidence task</h2>
            <p>#{html_escape(learner_task)}</p>
            <p>Use the native lesson question after this exploration to explain what the evidence supports and what this generic workspace cannot establish.</p>
          </aside>
        </main>
      </body>
    </html>
    """
  end

  defp styles do
    """
    :root { color-scheme: light; font-family: system-ui, sans-serif; color: #172554; background: #f8fafc; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: clamp(1rem, 4vw, 2rem); }
    main { width: min(100%, 56rem); margin: 0 auto; background: white; border: 1px solid #bfdbfe; border-radius: 1rem; padding: clamp(1rem, 4vw, 2rem); box-shadow: 0 1rem 2rem rgb(15 23 42 / 8%); }
    h1, h2 { line-height: 1.2; }
    .eyebrow { color: #0369a1; font-size: .78rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
    fieldset, section, aside { margin-top: 1.25rem; padding: 1rem; border: 1px solid #cbd5e1; border-radius: .75rem; }
    fieldset label { display: block; margin-top: .65rem; }
    input[type='radio'] { margin-right: .5rem; }
    input[type='range'] { width: 100%; min-height: 2.75rem; }
    .meter { height: 1rem; overflow: hidden; border-radius: 999px; background: #e2e8f0; }
    .meter span { display: block; width: 50%; height: 100%; background: linear-gradient(90deg, #0284c7, #7c3aed); transition: width 120ms ease-out; }
    aside { border-color: #c4b5fd; background: #f5f3ff; }
    :focus-visible { outline: .2rem solid #f59e0b; outline-offset: .2rem; }
    @media (max-width: 32rem) { body { padding: .5rem; } main { border-radius: .5rem; } }
    @media (prefers-reduced-motion: reduce) { .meter span { transition: none; } }
    """
  end

  defp javascript do
    """
    (() => {
      'use strict';
      const slider = document.getElementById('model-setting');
      const output = document.getElementById('setting-value');
      const fill = document.getElementById('meter-fill');
      const observation = document.getElementById('observation');

      const render = () => {
        const value = Number(slider.value);
        output.value = String(value);
        fill.style.width = `${value}%`;
        observation.textContent = value < 35
          ? 'The setting is in the lower range. Compare this response with your prediction.'
          : value > 65
            ? 'The setting is in the upper range. Compare this response with your prediction.'
            : 'The setting is near the midpoint. Test a more extreme value to gather contrasting evidence.';
      };

      slider.addEventListener('input', render);
      render();
    })();
    """
  end

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html_escape(_value), do: ""
end
