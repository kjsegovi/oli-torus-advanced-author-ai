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
  def generate(%EnrichmentProposal{kind: "generated_simulation"} = proposal, opts) do
    spec = simulation_spec(opts)
    title = spec["title"] || proposal.resource_title || "Prediction and evidence explorer"
    rationale = proposal.instructional_rationale
    learner_task = proposal.learner_task
    capi_manifest = capi_manifest(opts)
    capi_binding = capi_binding(capi_manifest, spec)

    {:ok,
     %{
       files: %{
         "index.html" => index_html(title, rationale, learner_task, spec, capi_binding != nil),
         "styles.css" => styles(),
         "app.js" => javascript(capi_binding)
       },
       manifest: %{
         "entrypoint" => "index.html",
         "dependency_free" => true,
         "interaction" => "prediction_observation",
         "library_ids" => List.wrap(spec["library_ids"])
       },
       capi_manifest: capi_manifest,
       metadata: %{
         "runtime_profile" => "audited_static",
         "generator_name" => "local_prediction_explorer",
         "generator_version" => "1",
         "assessment_mode" => "native_torus_followup",
         "domain_model" => spec["domain"] || "author_review_required"
       }
     }}
  end

  def generate(%EnrichmentProposal{}, _opts), do: {:error, :not_generated_simulation}
  def generate(_, _opts), do: {:error, :invalid_input}

  defp index_html(title, rationale, learner_task, spec, capi?) do
    bridge = if capi?, do: ~s(<script src="torus-capi-bridge.js"></script>), else: ""
    controls = parameter_controls(spec)
    observations = observation_rows(spec)
    model_summary = model_summary(spec)
    guided_tasks = guided_tasks(spec)

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
        #{bridge}
        <script src="app.js" defer></script>
      </head>
      <body>
        <main>
          <p class="eyebrow">Prediction → observation → explanation</p>
          <h1>#{html_escape(title)}</h1>
          <p>#{html_escape(rationale)}</p>

          <fieldset>
            <legend>Before changing the setting, what do you predict?</legend>
            <label for="prediction">Choose a prediction</label>
            <select id="prediction" name="prediction">
              <option value="">Select one</option>
              <option value="increase">The response will increase</option>
              <option value="decrease">The response will decrease</option>
              <option value="same">The response will stay about the same</option>
            </select>
          </fieldset>

          <section aria-labelledby="explore-heading">
            <h2 id="explore-heading">Explore the bounded model</h2>
            <div class="controls">#{controls}</div>
            <p id="observation" role="status" aria-live="polite">Change a parameter and compare the calculated observations with your prediction.</p>
            <div class="table-wrap" role="region" aria-label="Calculated observations" tabindex="0">
              <table>
                <caption>Calculated observations</caption>
                <thead><tr><th scope="col">Observation</th><th scope="col">Value</th><th scope="col">Unit</th></tr></thead>
                <tbody>#{observations}</tbody>
              </table>
            </div>
          </section>

          <aside aria-labelledby="task-heading" data-simulation-text-alternative>
            <h2 id="task-heading">Your evidence task</h2>
            <p>#{html_escape(learner_task)}</p>
            #{guided_tasks}
            <h3>Model used</h3>
            <p>#{model_summary}</p>
            <p>Use the native lesson question after this exploration to explain what the evidence supports and where the stated model assumptions or limitations matter.</p>
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
    select { display: block; width: min(100%, 28rem); min-height: 2.75rem; margin-top: .4rem; }
    .controls { display: grid; gap: 1rem; }
    .control label { display: flex; flex-wrap: wrap; justify-content: space-between; gap: .5rem; font-weight: 650; }
    input[type='range'] { width: 100%; min-height: 2.75rem; }
    output { font-variant-numeric: tabular-nums; }
    .table-wrap { max-width: 100%; overflow-x: auto; }
    table { width: 100%; margin-top: 1rem; border-collapse: collapse; }
    caption { padding-bottom: .5rem; text-align: left; font-weight: 700; }
    th, td { padding: .55rem; border: 1px solid #cbd5e1; text-align: left; }
    td:nth-child(2) { font-variant-numeric: tabular-nums; }
    aside { border-color: #c4b5fd; background: #f5f3ff; }
    :focus-visible { outline: .2rem solid #f59e0b; outline-offset: .2rem; }
    @media (max-width: 32rem) { body { padding: .5rem; } main { border-radius: .5rem; } }
    @media (prefers-reduced-motion: reduce) { .meter span { transition: none; } }
    """
  end

  defp javascript(capi_binding) do
    capi_source = capi_source(capi_binding)

    """
    (() => {
      'use strict';
      const controls = [...document.querySelectorAll('[data-model-input]')];
      const observation = document.getElementById('observation');
      const state = #{capi_source.defaults};

      const calculate = (values) => {
        #{capi_source.calculate}
      };

      const render = () => {
        const values = calculate(state);
        controls.forEach((control) => {
          const output = document.querySelector(`[data-model-input-value="${control.dataset.key}"]`);
          if (output) output.value = control.value;
        });
        Object.entries(values).forEach(([key, value]) => {
          const output = document.querySelector(`[data-model-output="${key}"]`);
          if (output) output.textContent = formatValue(value);
        });
        observation.textContent = 'The observation table now reflects the selected bounded parameters. Compare it with your prediction.';
        #{capi_source.emit}
      };

      const formatValue = (value) => typeof value === 'number'
        ? Number(value.toFixed(6)).toString()
        : String(value);

      controls.forEach((control) => {
        control.addEventListener('input', () => {
          state[control.dataset.key] = Number(control.value);
          render();
        });
      });
      #{capi_source.listen}
      render();
    })();
    """
  end

  defp capi_manifest(opts) do
    case Keyword.get(opts, :simulation_spec) do
      %{spec_payload: %{"capi_manifest" => %{} = manifest}} -> manifest
      %{"capi_manifest" => %{} = manifest} -> manifest
      _ -> %{"inputs" => [], "outputs" => []}
    end
  end

  defp capi_binding(manifest, spec) do
    inputs =
      manifest["inputs"]
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and is_binary(&1["key"])))

    outputs =
      manifest["outputs"]
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and is_binary(&1["key"])))

    if inputs != [] and outputs != [] do
      defaults =
        spec["parameters"]
        |> List.wrap()
        |> Map.new(fn parameter -> {parameter["id"], parameter["default"]} end)

      %{
        domain: spec["domain"],
        inputs: Enum.map(inputs, & &1["key"]),
        outputs: Enum.map(outputs, & &1["key"]),
        defaults: defaults
      }
    end
  end

  defp capi_source(%{inputs: inputs, outputs: outputs, defaults: defaults} = binding) do
    listeners =
      Enum.map_join(inputs, "\n", fn input ->
        """
        window.TorusCapi.onInput(#{Jason.encode!(input)}, (value) => {
          state[#{Jason.encode!(input)}] = Number(value);
          const control = document.querySelector(`[data-model-input="#{input}"]`);
          if (control) control.value = String(value);
          render();
        });
        """
      end)

    emissions =
      Enum.map_join(outputs, "\n", fn output ->
        "if (Object.prototype.hasOwnProperty.call(values, #{Jason.encode!(output)})) window.TorusCapi.emit(#{Jason.encode!(output)}, values[#{Jason.encode!(output)}]);"
      end)

    %{
      defaults: Jason.encode!(defaults),
      calculate: domain_calculation_source(binding.domain, inputs, outputs),
      emit: "if (window.TorusCapi?.isReady()) { #{emissions} }",
      listen: """
      #{listeners}
      window.addEventListener('torus-capi-ready', render);
      """
    }
  end

  defp capi_source(nil),
    do: %{
      defaults: "{}",
      calculate: "return {};",
      emit: "",
      listen: ""
    }

  defp simulation_spec(opts) do
    case Keyword.get(opts, :simulation_spec) do
      %{spec_payload: %{} = spec} -> spec
      %{} = spec -> spec
      _ -> %{}
    end
  end

  defp parameter_controls(%{"parameters" => [_ | _] = parameters}) do
    Enum.map_join(parameters, "\n", fn parameter ->
      id = parameter["id"]
      label = humanize(id)
      unit = parameter["unit"] || if(parameter["unitless"] == true, do: "unitless", else: "")

      """
      <div class="control">
        <label for="model-input-#{html_escape(id)}">
          <span>#{html_escape(label)} (#{html_escape(unit)})</span>
          <output data-model-input-value="#{html_escape(id)}" for="model-input-#{html_escape(id)}">#{attribute_value(parameter["default"])}</output>
        </label>
        <input id="model-input-#{html_escape(id)}" data-model-input="#{html_escape(id)}" data-key="#{html_escape(id)}" type="range" min="#{attribute_value(parameter["min"])}" max="#{attribute_value(parameter["max"])}" step="#{attribute_value(parameter["step"])}" value="#{attribute_value(parameter["default"])}">
      </div>
      """
    end)
  end

  defp parameter_controls(_spec) do
    """
    <div class="control">
      <label for="model-input-setting"><span>Model setting (unitless)</span><output data-model-input-value="setting" for="model-input-setting">50</output></label>
      <input id="model-input-setting" data-model-input="setting" data-key="setting" type="range" min="0" max="100" step="1" value="50">
    </div>
    """
  end

  defp observation_rows(%{"observations" => [_ | _] = observations}) do
    Enum.map_join(observations, "\n", fn observation ->
      id = observation["output_id"]

      """
      <tr><th scope="row">#{html_escape(humanize(id))}</th><td data-model-output="#{html_escape(id)}">—</td><td>#{html_escape(observation["unit"] || "")}</td></tr>
      """
    end)
  end

  defp observation_rows(_spec),
    do:
      ~s(<tr><th scope="row">Response</th><td data-model-output="response">—</td><td>unitless</td></tr>)

  defp guided_tasks(%{"guided_tasks" => [_ | _] = tasks}) do
    items =
      Enum.map_join(tasks, "", fn task ->
        ~s(<li>#{html_escape(task["prompt"] || task["task"] || "Compare the observations.")}</li>)
      end)

    "<ol>#{items}</ol>"
  end

  defp guided_tasks(_spec), do: ""

  defp model_summary(spec) do
    equations =
      spec
      |> get_in(["model", "equations"])
      |> List.wrap()
      |> Enum.map(& &1["expression"])
      |> Enum.filter(&is_binary/1)

    summary =
      case equations do
        [] ->
          spec
          |> Map.get("assumptions", [])
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")

        equations ->
          "Calculated relationship: " <> Enum.join(equations, "; ")
      end

    html_escape(if(summary == "", do: "Use the bounded reviewed model contract.", else: summary))
  end

  defp domain_calculation_source("chemistry", _inputs, _outputs) do
    """
    const amount = Number(values.amount_mol);
    const volume = Number(values.volume_l);
    const temperature = Number(values.temperature_k);
    return { pressure_kpa: amount * 8.314462618 * temperature / volume };
    """
  end

  defp domain_calculation_source("physics", _inputs, _outputs) do
    """
    const initial = Number(values.initial_velocity_m_s);
    const acceleration = Number(values.acceleration_m_s2);
    const time = Number(values.time_s);
    return {
      final_velocity_m_s: initial + acceleration * time,
      displacement_m: initial * time + 0.5 * acceleration * time * time
    };
    """
  end

  defp domain_calculation_source("biology", _inputs, _outputs) do
    """
    const initial = Number(values.initial_population);
    const rate = Number(values.growth_rate_per_step);
    const capacity = Number(values.carrying_capacity);
    const elapsed = Number(values.elapsed_steps);
    return { population: capacity / (1 + ((capacity - initial) / initial) * Math.exp(-rate * elapsed)) };
    """
  end

  defp domain_calculation_source("mathematics", _inputs, _outputs) do
    """
    const x = Number(values.x);
    const h = Number(values.h);
    const estimate = (Math.pow(x + h, 3) - Math.pow(x - h, 3)) / (2 * h);
    const exact = 3 * x * x;
    return { derivative_estimate: estimate, exact_derivative: exact, absolute_error: Math.abs(estimate - exact) };
    """
  end

  defp domain_calculation_source("astronomy", _inputs, _outputs) do
    """
    const axis = Number(values.semi_major_axis_au);
    const eccentricity = Number(values.eccentricity);
    const radians = Number(values.true_anomaly_deg) * Math.PI / 180;
    const radius = axis * (1 - eccentricity * eccentricity) / (1 + eccentricity * Math.cos(radians));
    return {
      period_years: Math.sqrt(axis * axis * axis),
      orbital_radius_au: radius,
      relative_speed: Math.sqrt(2 / radius - 1 / axis)
    };
    """
  end

  defp domain_calculation_source("computer_science", _inputs, _outputs) do
    """
    const cases = { 1: [4, 1, 3, 2], 2: [1, 2, 3, 4, 5], 3: [5, 4, 3, 2, 1] };
    const working = [...cases[Math.trunc(Number(values.case_id))]];
    const trace = [{ state: working.join(','), comparisons: 0, moves: 0, sorted: working.every((value, index, items) => index === 0 || items[index - 1] <= value) }];
    let comparisons = 0;
    let moves = 0;
    for (let index = 1; index < working.length; index += 1) {
      const key = working[index];
      let cursor = index - 1;
      let shifted = 0;
      while (cursor >= 0 && working[cursor] > key) {
        working[cursor + 1] = working[cursor];
        cursor -= 1;
        shifted += 1;
      }
      comparisons += shifted + (shifted < index ? 1 : 0);
      moves += shifted + 1;
      working[cursor + 1] = key;
      trace.push({ state: working.join(','), comparisons, moves, sorted: working.every((value, itemIndex, items) => itemIndex === 0 || items[itemIndex - 1] <= value) });
    }
    return trace[Math.min(Math.max(0, Math.trunc(Number(values.step_index))), trace.length - 1)];
    """
  end

  defp domain_calculation_source(_domain, [input | _], [output | _]) do
    "return { #{Jason.encode!(output)}: Number(values[#{Jason.encode!(input)}]) };"
  end

  defp domain_calculation_source(_domain, _inputs, _outputs), do: "return {};"

  defp attribute_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp attribute_value(value) when is_binary(value), do: html_escape(value)
  defp attribute_value(_value), do: ""

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize(_value), do: "Model value"

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
