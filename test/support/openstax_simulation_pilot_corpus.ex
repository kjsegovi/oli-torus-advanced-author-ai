defmodule Oli.OpenStax.CourseImport.SimulationPilotCorpus do
  @moduledoc """
  Curated, deterministic source snapshots for the Advanced v6 pilot.

  The snapshots are concise paraphrases of the cited OpenStax sections rather
  than copied pages. They preserve the domain-specific concepts, learner work,
  and canonical provenance needed to calibrate routing without making tests
  depend on network access or mutable upstream HTML.
  """

  alias Oli.OpenStax.CourseImport.SimulationDomainReferences

  @golden_lessons [
    %{
      domain: "chemistry",
      title: "The Ideal Gas Law",
      source_url:
        "https://openstax.org/books/chemistry-2e/pages/9-2-relating-pressure-volume-amount-and-temperature-the-ideal-gas-law",
      objective:
        "Use the ideal gas relationship to predict how pressure, volume, amount, and temperature vary.",
      concept:
        "The ideal gas model relates pressure, volume, amount, and absolute temperature. A useful investigation holds selected variables constant, calculates the predicted response, and compares the model with tabulated observations.",
      task:
        "Calculate pressure for several bounded volume values, graph the results, compare ratios, and explain which evidence supports an inverse relationship and where the model has limitations."
    },
    %{
      domain: "chemistry",
      title: "Factors That Affect Reaction Rates",
      source_url:
        "https://openstax.org/books/chemistry-2e/pages/12-2-factors-affecting-reaction-rates",
      objective:
        "Analyze how concentration, temperature, surface area, and catalysts influence reaction rate.",
      concept:
        "Collision-based reasoning connects reaction rate with concentration, temperature, reactant contact, and activation energy. Evidence tables distinguish a variable that changes collision frequency from a catalyst that changes the available pathway.",
      task:
        "Compare controlled trials, calculate relative rates, graph rate against one variable, identify the best-supported causal claim, and explain uncertainty in the experimental evidence."
    },
    %{
      domain: "physics",
      title: "Motion Equations for Constant Acceleration in One Dimension",
      source_url:
        "https://openstax.org/books/college-physics-2e/pages/2-5-motion-equations-for-constant-acceleration-in-one-dimension",
      objective:
        "Select and apply constant-acceleration equations while interpreting signs, units, and graphs.",
      concept:
        "For one-dimensional motion with constant acceleration, displacement, time, initial velocity, and final velocity are connected by a bounded set of equations. Position-time and velocity-time evidence reveal whether a chosen model is consistent.",
      task:
        "Calculate missing motion quantities for multiple cases, graph velocity over time, compare predictions with a data table, and explain how sign conventions affect the interpretation."
    },
    %{
      domain: "physics",
      title: "Resistors in Series and Parallel",
      source_url:
        "https://openstax.org/books/college-physics-2e/pages/21-1-resistors-in-series-and-parallel",
      objective:
        "Model current, voltage, and equivalent resistance in series and parallel circuits.",
      concept:
        "Series components share current while voltage changes across elements; parallel branches share voltage while current divides. Equivalent resistance and conservation relationships provide evidence for checking a circuit model.",
      task:
        "Calculate equivalent resistance and branch quantities, compare two circuit arrangements, graph a bounded voltage-current relationship, and justify each conclusion with conservation evidence."
    },
    %{
      domain: "biology",
      title: "Environmental Limits to Population Growth",
      source_url:
        "https://openstax.org/books/biology-2e/pages/45-3-environmental-limits-to-population-growth",
      objective:
        "Compare exponential and logistic population models using evidence about limiting factors and carrying capacity.",
      concept:
        "Population growth can approximate an exponential pattern when resources are abundant and a logistic pattern as limiting factors become important. Carrying capacity is a model parameter whose interpretation depends on environmental evidence.",
      task:
        "Calculate growth across bounded time steps, graph exponential and logistic predictions, compare them with observations, and explain which limiting-factor claim the evidence supports."
    },
    %{
      domain: "biology",
      title: "Enzymes",
      source_url: "https://openstax.org/books/biology-2e/pages/6-5-enzymes",
      objective:
        "Interpret evidence about enzyme activity, activation energy, temperature, pH, and substrate concentration.",
      concept:
        "Enzymes change reaction pathways without being consumed, while temperature, pH, and substrate conditions influence observed activity. A bounded activity curve supports comparisons but does not by itself identify every molecular mechanism.",
      task:
        "Calculate normalized activity from a data table, graph activity against one condition, compare ranges, and explain how the evidence distinguishes an optimum from denaturation or saturation."
    },
    %{
      domain: "mathematics",
      title: "The Derivative as a Function",
      source_url:
        "https://openstax.org/books/calculus-volume-1/pages/3-2-the-derivative-as-a-function",
      objective:
        "Construct and interpret a derivative function from difference quotients, formulas, and graphs.",
      concept:
        "A derivative assigns an instantaneous rate of change to each input where the limit exists. Difference quotients, tangent slopes, and the graph of the original function provide related evidence for the derivative model.",
      task:
        "Calculate difference quotients at several inputs, graph the estimated derivative, compare the result with a symbolic rule, and explain uncertainty near a point where behavior changes."
    },
    %{
      domain: "mathematics",
      title: "Continuous Probability Functions",
      source_url:
        "https://openstax.org/books/introductory-statistics/pages/5-1-continuous-probability-functions",
      objective:
        "Use a probability density model to calculate and interpret probabilities over intervals.",
      concept:
        "For a continuous random variable, probability is represented by area over an interval and total density area equals one. Point probability and interval probability have different interpretations in the model.",
      task:
        "Calculate areas for several intervals, graph the density and selected regions, compare complementary events, and explain how the visual evidence supports the probability calculation."
    },
    %{
      domain: "astronomy",
      title: "Orbits in the Solar System",
      source_url:
        "https://openstax.org/books/astronomy-2e/pages/3-1-the-laws-of-planetary-motion",
      objective:
        "Use orbital evidence and Kepler's laws to interpret planetary motion and period-distance relationships.",
      concept:
        "Planetary paths are modeled as ellipses with the Sun at a focus, swept area relates to elapsed time, and orbital period varies systematically with semimajor axis. Observations let learners compare a geometric orbit with a constant-speed misconception.",
      task:
        "Calculate and graph bounded period-distance cases, compare positions along an elliptical path, interpret an observation table, and explain which evidence contradicts constant orbital speed."
    },
    %{
      domain: "astronomy",
      title: "Spectroscopy in Astronomy",
      source_url: "https://openstax.org/books/astronomy-2e/pages/5-3-spectroscopy-in-astronomy",
      objective:
        "Interpret continuous, emission, and absorption spectra as evidence about astronomical sources.",
      concept:
        "Spectral patterns connect wavelength with energy and reveal properties of emitting or absorbing matter. Line position, intensity, and shift are distinct observations that support different inferences about composition and motion.",
      task:
        "Compare labeled spectra, calculate a bounded wavelength shift, graph intensity by wavelength, match evidence to a source model, and explain limitations in the interpretation."
    },
    %{
      domain: "computer_science",
      title: "Sorting Algorithms",
      source_url:
        "https://openstax.org/books/introduction-computer-science/pages/7-4-sorting-algorithms",
      objective:
        "Trace and compare bounded sorting algorithms using state changes, comparisons, and swaps.",
      concept:
        "Sorting procedures transform the same input through different sequences of comparisons and moves. A trace table makes intermediate state visible and supports comparison of correctness and bounded work rather than executing learner code.",
      task:
        "Trace two algorithms on short lists, calculate comparisons and swaps, graph work by input size for bounded cases, and explain which evidence supports each efficiency claim."
    },
    %{
      domain: "computer_science",
      title: "Linked Data Structures",
      source_url:
        "https://openstax.org/books/introduction-computer-science/pages/9-2-linked-lists",
      objective:
        "Model linked-list traversal and bounded insertion or removal through node and reference state transitions.",
      concept:
        "A linked structure represents sequence through node references rather than adjacent storage positions. Diagrams and trace tables expose how head, current, and next references change during traversal and update operations.",
      task:
        "Trace a bounded list operation step by step, calculate visited nodes, compare insertion locations, graph state transitions, and explain which invariant is supported by the final structure."
    }
  ]

  @pilot_cases [
    %{
      domain: "chemistry",
      title: "Ideal-gas relationship explorer",
      authority_url: "https://physics.nist.gov/cuu/Constants/",
      parameter_id: "volume_l",
      output_id: "pressure_kpa",
      learner_task: "Predict how pressure changes as a bounded volume setting changes.",
      misconception: "Pressure and volume always increase together.",
      rendering_mode: "2d",
      library_ids: []
    },
    %{
      domain: "physics",
      title: "Constant-acceleration motion explorer",
      authority_url: "https://physics.nist.gov/cuu/Units/",
      parameter_id: "time_s",
      output_id: "final_velocity_m_s",
      learner_task: "Predict and compare motion states at bounded elapsed times.",
      misconception: "Constant acceleration means constant velocity.",
      rendering_mode: "2d",
      library_ids: []
    },
    %{
      domain: "biology",
      title: "Logistic population-growth explorer",
      authority_url: "https://www.ncbi.nlm.nih.gov/books/",
      parameter_id: "initial_population",
      output_id: "population",
      learner_task: "Compare bounded population states with a limiting-factor prediction.",
      misconception: "Population growth remains exponential under every condition.",
      rendering_mode: "2d",
      library_ids: []
    },
    %{
      domain: "mathematics",
      title: "Central-difference derivative explorer",
      authority_url: "https://dlmf.nist.gov/",
      parameter_id: "x",
      output_id: "derivative_estimate",
      learner_task:
        "Compare bounded difference-quotient observations with a derivative prediction.",
      misconception: "Average and instantaneous rates are always identical.",
      rendering_mode: "2d",
      library_ids: []
    },
    %{
      domain: "astronomy",
      title: "Keplerian orbit interpretation explorer",
      authority_url: "https://science.nasa.gov/solar-system/orbits-and-keplers-laws/",
      parameter_id: "true_anomaly_deg",
      output_id: "relative_speed",
      learner_task:
        "Compare bounded orbital positions and interpret the corresponding observation.",
      misconception: "An orbiting planet moves at the same speed everywhere in its orbit.",
      rendering_mode: "3d",
      library_ids: ["three-0.185.1"]
    },
    %{
      domain: "computer_science",
      title: "Bounded insertion-sort state explorer",
      authority_url: "https://dl.acm.org/",
      parameter_id: "step_index",
      output_id: "state",
      learner_task:
        "Trace bounded sorting steps and compare state changes without executing learner code.",
      misconception: "Every correct sorting method performs the same sequence of work.",
      rendering_mode: "2d",
      library_ids: []
    }
  ]

  def golden_lessons do
    Enum.map(@golden_lessons, &build_lesson/1)
  end

  def pilot_cases do
    lessons_by_domain = Map.new(golden_lessons(), &{&1["domain"], &1})

    Enum.map(@pilot_cases, fn pilot ->
      lesson = Map.fetch!(lessons_by_domain, pilot.domain)

      pilot
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("lesson", lesson)
      |> Map.put("source_url", lesson["source_url"])
    end)
  end

  def research_contract(pilot) do
    sources = [
      %{"url" => pilot["source_url"], "title" => "OpenStax source lesson"},
      %{"url" => pilot["authority_url"], "title" => "External authoritative source"}
    ]

    claims = [
      %{
        "paraphrase" =>
          "The pilot must state bounded variables, assumptions, evidence, and model limitations.",
        "citation_urls" => Enum.map(sources, & &1["url"])
      }
    ]

    %{
      "content_hash" => hash(%{"sources" => sources, "claims" => claims}),
      "proposed_sources" => sources,
      "claims" => claims
    }
  end

  def spec_contract(pilot, research) do
    SimulationDomainReferences.build!(pilot["domain"], research,
      objective_ids: ["objective-1"],
      authority_url: pilot["authority_url"],
      id_prefix: "pilot-#{String.replace(pilot["domain"], "_", "-")}"
    )
  end

  defp build_lesson(entry) do
    prefix = entry.domain <> "-" <> slug(entry.title)
    source_id = prefix <> "-source"
    task_id = prefix <> "-task"

    %{
      "domain" => entry.domain,
      "title" => entry.title,
      "source_url" => entry.source_url,
      "source_word_count" => 1_260,
      "source_objectives" => [entry.objective],
      "source_blocks" => [
        block(source_id, "paragraph", entry.concept, entry.source_url),
        block(task_id, "exercise", entry.task, entry.source_url)
      ],
      "expected_evidence_block_ids" => [source_id, task_id]
    }
  end

  defp block(id, kind, text, source_url) do
    %{
      "id" => id,
      "kind" => kind,
      "text" => text,
      "source_locator" => %{"url" => source_url},
      "ast" => [%{"type" => "p", "children" => [%{"text" => text}]}]
    }
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp hash(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
