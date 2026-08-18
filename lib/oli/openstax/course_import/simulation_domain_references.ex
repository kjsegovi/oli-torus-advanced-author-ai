defmodule Oli.OpenStax.CourseImport.SimulationDomainReferences do
  @moduledoc """
  Production calibration references for the six generated-simulation pilot domains.

  These contracts are deliberately deterministic. They give simulation designers,
  critics, browser acceptance, and author-facing previews a shared reference for the
  minimum scientific and instructional substance expected from a generated bundle.
  They are not learner content templates and do not execute learner-authored code.

  Call `build/3` with an approved research payload, then use `evaluate/2` to compare a
  generated bundle's CAPI observations with the reference sample cases.
  """

  @domains ~w(chemistry physics biology mathematics astronomy computer_science)

  @type domain :: String.t()

  @spec domains() :: [domain()]
  def domains, do: @domains

  @spec build(domain() | atom(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def build(domain, research, opts \\ [])

  def build(domain, research, opts) when is_map(research) and is_list(opts) do
    domain = normalize_domain(domain)
    research = stringify(research)
    research_hash = research["content_hash"]
    citation_urls = citation_urls(research)

    with true <- domain in @domains,
         true <- present?(research_hash),
         [_ | _] <- citation_urls do
      objective_ids = Keyword.get(opts, :objective_ids, ["objective-1"])
      id_prefix = Keyword.get(opts, :id_prefix, String.replace(domain, "_", "-"))
      authority_url = Keyword.get(opts, :authority_url, List.last(citation_urls))

      follow_up_activity_id =
        Keyword.get(opts, :native_follow_up_activity_id) ||
          "#{id_prefix}-simulation-follow-up"

      remediation_content_group_id =
        Keyword.get(opts, :remediation_content_group_id) ||
          "#{id_prefix}-simulation-remediation"

      if authority_url in citation_urls do
        definition = definition(domain, authority_url)

        spec =
          definition
          |> Map.merge(
            base_contract(
              domain,
              research_hash,
              objective_ids,
              follow_up_activity_id,
              remediation_content_group_id
            )
          )
          |> put_capi_input_defaults()
          |> Map.put(
            "sample_cases",
            sample_cases(domain, definition["sample_inputs"], definition["sample_tolerance"])
          )
          |> Map.delete("sample_inputs")
          |> Map.delete("sample_tolerance")

        {:ok, spec}
      else
        {:error, :authority_url_not_approved}
      end
    else
      false -> {:error, :invalid_reference_contract}
      [] -> {:error, :missing_approved_citation}
    end
  end

  def build(_, _, _), do: {:error, :invalid_reference_contract}

  @spec build!(domain() | atom(), map(), keyword()) :: map()
  def build!(domain, research, opts \\ []) do
    case build(domain, research, opts) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid simulation reference: #{inspect(reason)}"
    end
  end

  @doc "Evaluates one bounded reference model with string- or atom-keyed inputs."
  @spec evaluate(domain() | atom(), map()) :: {:ok, map()} | {:error, atom()}
  def evaluate(domain, inputs) when is_map(inputs) do
    domain = normalize_domain(domain)
    inputs = stringify(inputs)

    case domain do
      "chemistry" -> ideal_gas(inputs)
      "physics" -> constant_acceleration(inputs)
      "biology" -> logistic_population(inputs)
      "mathematics" -> central_difference(inputs)
      "astronomy" -> kepler_orbit(inputs)
      "computer_science" -> insertion_sort_state(inputs)
      _ -> {:error, :unsupported_domain}
    end
  rescue
    ArithmeticError -> {:error, :invalid_reference_inputs}
    FunctionClauseError -> {:error, :invalid_reference_inputs}
  end

  def evaluate(_, _), do: {:error, :invalid_reference_inputs}

  defp base_contract(
         domain,
         research_hash,
         objective_ids,
         follow_up_activity_id,
         remediation_content_group_id
       ) do
    %{
      "schema_version" => 1,
      "contract_profile" => "domain_reference_v1",
      "domain" => domain,
      "objective_ids" => objective_ids,
      "evidence_hash" => research_hash,
      "research_hash" => research_hash,
      "native_follow_up" => %{
        "activity_id" => follow_up_activity_id,
        "objective_ids" => objective_ids,
        "prompt" =>
          "Explain the observed relationship using numerical evidence and the model's stated assumptions."
      },
      "remediation" => %{
        "content_group_id" => remediation_content_group_id,
        "guidance" =>
          "Revisit the governing relationship, compare the prediction with the observation table, and retry the native follow-up."
      },
      "learner_code_execution" => false
    }
  end

  defp definition("chemistry", citation) do
    %{
      "title" => "Ideal-gas relationship explorer",
      "assumptions" => [
        "The gas is represented as ideal and at thermodynamic equilibrium.",
        "Temperature is absolute temperature in kelvin and the container volume is fixed for each observation."
      ],
      "limitations" => [
        "The ideal-gas relationship becomes less accurate for dense gases and near phase changes.",
        "The model does not represent intermolecular forces or molecular volume."
      ],
      "parameters" => [
        parameter("amount_mol", 0.1, 5.0, 1.0, 0.1, "mol"),
        parameter("volume_l", 1.0, 50.0, 24.465, 0.1, "L"),
        parameter("temperature_k", 200.0, 600.0, 298.15, 1.0, "K")
      ],
      "constants" => [
        constant("ideal_gas_constant", 8.314_462_618, "L*kPa/(mol*K)", citation)
      ],
      "model" => %{
        "kind" => "equation",
        "equations" => [
          equation(
            "ideal_gas_pressure",
            "pressure_kpa = amount_mol * ideal_gas_constant * temperature_k / volume_l",
            ~w(amount_mol volume_l temperature_k),
            ["pressure_kpa"]
          )
        ]
      },
      "sample_inputs" => [
        %{"amount_mol" => 1.0, "volume_l" => 24.465, "temperature_k" => 298.15},
        %{"amount_mol" => 2.0, "volume_l" => 10.0, "temperature_k" => 300.0},
        %{"amount_mol" => 0.5, "volume_l" => 20.0, "temperature_k" => 400.0}
      ],
      "sample_tolerance" => 0.01,
      "controls" => controls(~w(amount_mol volume_l temperature_k)),
      "observations" => [observation("pressure_kpa", "number_and_plot", "kPa")],
      "guided_tasks" => [
        task(
          "predict",
          "Predict pressure before changing volume while holding amount and temperature fixed."
        ),
        task("compare", "Halve volume and use the table to compare the pressure ratio."),
        task("qualify", "Explain why the prediction is conditional on the ideal-gas assumptions.")
      ],
      "misconception_handling" =>
        misconception(
          "Pressure and volume increase together when amount and temperature are fixed.",
          "Ask for the pressure ratio before and after halving volume.",
          "The computed table shows that pressure doubles when volume is halved under the stated conditions."
        ),
      "capi_manifest" =>
        capi(
          ~w(amount_mol volume_l temperature_k),
          [{"pressure_kpa", "number"}]
        ),
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" =>
        accessibility("A table lists amount, volume, temperature, and calculated pressure."),
      "algorithm" => bounded_algorithm("closed_form_equation", 12, 3)
    }
  end

  defp definition("physics", citation) do
    %{
      "title" => "Constant-acceleration motion explorer",
      "assumptions" => [
        "Motion is one-dimensional and acceleration is constant during the selected interval.",
        "Initial position is zero and one sign convention is used consistently."
      ],
      "limitations" => [
        "The model does not represent changing acceleration, drag, or multidimensional motion.",
        "A negative velocity denotes direction, not a negative speed magnitude."
      ],
      "parameters" => [
        parameter("initial_velocity_m_s", -30.0, 30.0, 2.0, 0.5, "m/s"),
        parameter("acceleration_m_s2", -10.0, 10.0, 3.0, 0.5, "m/s^2"),
        parameter("time_s", 0.0, 20.0, 4.0, 0.5, "s")
      ],
      "constants" => [constant("displacement_acceleration_factor", 0.5, "1", citation)],
      "model" => %{
        "kind" => "equation_system",
        "equations" => [
          equation(
            "velocity_update",
            "final_velocity_m_s = initial_velocity_m_s + acceleration_m_s2 * time_s",
            ~w(initial_velocity_m_s acceleration_m_s2 time_s),
            ["final_velocity_m_s"]
          ),
          equation(
            "displacement_update",
            "displacement_m = initial_velocity_m_s * time_s + 0.5 * acceleration_m_s2 * time_s^2",
            ~w(initial_velocity_m_s acceleration_m_s2 time_s),
            ["displacement_m"]
          )
        ]
      },
      "sample_inputs" => [
        %{"initial_velocity_m_s" => 0.0, "acceleration_m_s2" => 2.0, "time_s" => 5.0},
        %{"initial_velocity_m_s" => 10.0, "acceleration_m_s2" => -2.0, "time_s" => 3.0},
        %{"initial_velocity_m_s" => -4.0, "acceleration_m_s2" => 1.5, "time_s" => 4.0}
      ],
      "sample_tolerance" => 0.001,
      "controls" => controls(~w(initial_velocity_m_s acceleration_m_s2 time_s)),
      "observations" => [
        observation("final_velocity_m_s", "number_and_velocity_graph", "m/s"),
        observation("displacement_m", "number_and_position_graph", "m")
      ],
      "guided_tasks" => [
        task("predict", "Predict the velocity-time graph before advancing time."),
        task("signs", "Use two signed cases to distinguish direction from speed."),
        task(
          "explain",
          "Explain why equal time intervals change velocity by equal amounts, not keep velocity constant."
        )
      ],
      "misconception_handling" =>
        misconception(
          "Constant acceleration means constant velocity.",
          "Compare final velocity at two elapsed times with acceleration held fixed.",
          "The velocity changes linearly with time; it is the acceleration, not velocity, that remains constant."
        ),
      "capi_manifest" =>
        capi(
          ~w(initial_velocity_m_s acceleration_m_s2 time_s),
          [{"final_velocity_m_s", "number"}, {"displacement_m", "number"}]
        ),
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" =>
        accessibility(
          "A table lists time, signed velocity, and signed displacement for each observation."
        ),
      "algorithm" => bounded_algorithm("closed_form_equation_system", 20, 3)
    }
  end

  defp definition("biology", citation) do
    %{
      "title" => "Logistic population-growth explorer",
      "assumptions" => [
        "Growth rate and carrying capacity remain constant over the modeled interval.",
        "Population is represented continuously and begins above zero."
      ],
      "limitations" => [
        "Real populations have age structure, migration, stochastic events, and changing environments.",
        "Carrying capacity is a model parameter rather than a permanently fixed property."
      ],
      "parameters" => [
        parameter("initial_population", 10.0, 900.0, 100.0, 10.0, "organisms"),
        parameter("growth_rate_per_step", 0.01, 1.0, 0.2, 0.01, "1/step"),
        parameter("carrying_capacity", 100.0, 5_000.0, 1_000.0, 50.0, "organisms"),
        parameter("elapsed_steps", 0.0, 50.0, 10.0, 1.0, "step")
      ],
      "constants" => [constant("natural_exponential_base", :math.exp(1), "1", citation)],
      "model" => %{
        "kind" => "equation",
        "equations" => [
          equation(
            "continuous_logistic_growth",
            "population = K / (1 + ((K - N0) / N0) * exp(-r * t))",
            ~w(initial_population growth_rate_per_step carrying_capacity elapsed_steps),
            ["population"]
          )
        ]
      },
      "sample_inputs" => [
        %{
          "initial_population" => 100.0,
          "growth_rate_per_step" => 0.2,
          "carrying_capacity" => 1_000.0,
          "elapsed_steps" => 0.0
        },
        %{
          "initial_population" => 100.0,
          "growth_rate_per_step" => 0.2,
          "carrying_capacity" => 1_000.0,
          "elapsed_steps" => 10.0
        },
        %{
          "initial_population" => 400.0,
          "growth_rate_per_step" => 0.1,
          "carrying_capacity" => 1_000.0,
          "elapsed_steps" => 20.0
        }
      ],
      "sample_tolerance" => 0.01,
      "controls" =>
        controls(~w(initial_population growth_rate_per_step carrying_capacity elapsed_steps)),
      "observations" => [observation("population", "number_curve_and_table", "organisms")],
      "guided_tasks" => [
        task(
          "contrast",
          "Predict both an unlimited-growth curve and the bounded logistic curve."
        ),
        task(
          "capacity",
          "Locate when growth begins slowing as population approaches carrying capacity."
        ),
        task(
          "qualify",
          "Identify environmental changes that would make a fixed carrying capacity inappropriate."
        )
      ],
      "misconception_handling" =>
        misconception(
          "Population growth remains exponential under every condition.",
          "Compare equal time intervals when population is far below and near carrying capacity.",
          "The logistic curve slows as the population approaches carrying capacity because the limiting term decreases."
        ),
      "capi_manifest" =>
        capi(
          ~w(initial_population growth_rate_per_step carrying_capacity elapsed_steps),
          [{"population", "number"}]
        ),
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" =>
        accessibility(
          "A table reports elapsed step, predicted population, and distance from carrying capacity."
        ),
      "algorithm" => bounded_algorithm("closed_form_logistic_equation", 24, 4)
    }
  end

  defp definition("mathematics", citation) do
    %{
      "title" => "Central-difference derivative explorer",
      "assumptions" => [
        "The reference function is f(x) = x^3 and arithmetic uses finite decimal values.",
        "The step size h is positive and the estimate samples x-h and x+h symmetrically."
      ],
      "limitations" => [
        "A finite difference is an approximation and its behavior depends on the function and step size.",
        "Very small step sizes can introduce floating-point cancellation in software."
      ],
      "parameters" => [
        parameter("x", -10.0, 10.0, 2.0, 0.1, "1"),
        parameter("h", 0.001, 1.0, 0.5, 0.001, "1")
      ],
      "constants" => [constant("polynomial_power", 3, "1", citation)],
      "model" => %{
        "kind" => "equation_system",
        "equations" => [
          equation(
            "central_difference",
            "derivative_estimate = ((x + h)^3 - (x - h)^3) / (2h)",
            ~w(x h),
            ["derivative_estimate"]
          ),
          equation("symbolic_derivative", "exact_derivative = 3x^2", ["x"], ["exact_derivative"]),
          equation(
            "approximation_error",
            "absolute_error = abs(derivative_estimate - exact_derivative)",
            ~w(x h),
            ["absolute_error"]
          )
        ]
      },
      "sample_inputs" => [
        %{"x" => 2.0, "h" => 0.5},
        %{"x" => -1.0, "h" => 0.1},
        %{"x" => 0.0, "h" => 0.25}
      ],
      "sample_tolerance" => 0.000_001,
      "controls" => controls(~w(x h)),
      "observations" => [
        observation("derivative_estimate", "number_and_secant_plot", "1"),
        observation("exact_derivative", "number_and_tangent_plot", "1"),
        observation("absolute_error", "number", "1")
      ],
      "guided_tasks" => [
        task("predict", "Predict how reducing h changes the estimate before moving the control."),
        task(
          "compare",
          "Compare the central-difference estimate with the symbolic derivative at three x values."
        ),
        task(
          "explain",
          "Use the error observation to distinguish an average rate from the limiting instantaneous rate."
        )
      ],
      "misconception_handling" =>
        misconception(
          "An average rate over any interval is always identical to the instantaneous rate.",
          "Compare estimates at the same x with two positive step sizes.",
          "For the cubic reference, the finite central difference includes an h-squared error that shrinks as h decreases."
        ),
      "capi_manifest" =>
        capi(
          ~w(x h),
          [
            {"derivative_estimate", "number"},
            {"exact_derivative", "number"},
            {"absolute_error", "number"}
          ]
        ),
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" =>
        accessibility(
          "A table lists x, h, the central-difference estimate, exact derivative, and absolute error."
        ),
      "algorithm" => bounded_algorithm("central_difference", 30, 2)
    }
  end

  defp definition("astronomy", citation) do
    %{
      "title" => "Keplerian orbit interpretation explorer",
      "assumptions" => [
        "The central star has one solar mass and the orbit is an ideal two-body Keplerian ellipse.",
        "Semimajor axis is measured in astronomical units and period in Earth years."
      ],
      "limitations" => [
        "The model omits interactions with other bodies, relativistic effects, and stellar mass changes.",
        "The 3D view is an interpretation aid; the table is the authoritative equivalent observation."
      ],
      "parameters" => [
        parameter("semi_major_axis_au", 0.2, 10.0, 1.0, 0.1, "AU"),
        parameter("eccentricity", 0.0, 0.8, 0.2, 0.01, "1"),
        parameter("true_anomaly_deg", 0.0, 360.0, 0.0, 1.0, "deg")
      ],
      "constants" => [constant("central_mass_solar", 1.0, "solar_mass", citation)],
      "model" => %{
        "kind" => "equation_system",
        "equations" => [
          equation(
            "kepler_third_law",
            "period_years = sqrt(semi_major_axis_au^3 / central_mass_solar)",
            ["semi_major_axis_au"],
            ["period_years"]
          ),
          equation(
            "ellipse_radius",
            "orbital_radius_au = a(1-e^2)/(1+e*cos(true_anomaly_deg))",
            ~w(semi_major_axis_au eccentricity true_anomaly_deg),
            ["orbital_radius_au"]
          ),
          equation(
            "vis_viva_relative_speed",
            "relative_speed = sqrt(2/orbital_radius_au - 1/semi_major_axis_au)",
            ~w(semi_major_axis_au eccentricity true_anomaly_deg),
            ["relative_speed"]
          )
        ]
      },
      "sample_inputs" => [
        %{"semi_major_axis_au" => 1.0, "eccentricity" => 0.0, "true_anomaly_deg" => 0.0},
        %{"semi_major_axis_au" => 1.0, "eccentricity" => 0.2, "true_anomaly_deg" => 0.0},
        %{"semi_major_axis_au" => 4.0, "eccentricity" => 0.5, "true_anomaly_deg" => 180.0}
      ],
      "sample_tolerance" => 0.000_1,
      "controls" => controls(~w(semi_major_axis_au eccentricity true_anomaly_deg)),
      "observations" => [
        observation("period_years", "number_and_period_plot", "yr"),
        observation("orbital_radius_au", "number_and_orbit_table", "AU"),
        observation("relative_speed", "number_and_speed_plot", "relative")
      ],
      "guided_tasks" => [
        task("period", "Predict how orbital period changes when semimajor axis doubles."),
        task("speed", "Compare radius and relative speed at periapsis and apoapsis."),
        task(
          "fallback",
          "Use the equivalent table to justify the same claim shown by the 3D path."
        )
      ],
      "misconception_handling" =>
        misconception(
          "A planet moves at the same speed everywhere in an elliptical orbit.",
          "Compare the radius and relative-speed observations at zero and 180 degrees.",
          "The vis-viva observation is larger at the smaller orbital radius, so speed is not constant on an eccentric orbit."
        ),
      "capi_manifest" =>
        capi(
          ~w(semi_major_axis_au eccentricity true_anomaly_deg),
          [
            {"period_years", "number"},
            {"orbital_radius_au", "number"},
            {"relative_speed", "number"}
          ]
        ),
      "rendering_mode" => "3d",
      "library_ids" => ["three-0.185.1"],
      "accessibility" =>
        accessibility(
          "A synchronized table reports semimajor axis, eccentricity, anomaly, radius, period, and relative speed.",
          "If WebGL is unavailable, replace the orbit view with the synchronized table, a labeled 2D ellipse, and the same guided tasks."
        ),
      "algorithm" => bounded_algorithm("closed_form_keplerian_equations", 36, 3)
    }
  end

  defp definition("computer_science", citation) do
    %{
      "title" => "Bounded insertion-sort state explorer",
      "assumptions" => [
        "The learner selects one of three fixed short integer lists and an observation step.",
        "Insertion sort is traced deterministically in ascending order with zero-based item positions."
      ],
      "limitations" => [
        "The fixed cases illustrate state transitions but do not establish average-case performance.",
        "The model never accepts or executes learner-authored code."
      ],
      "parameters" => [
        parameter("case_id", 1, 3, 1, 1, "case"),
        parameter("step_index", 0, 5, 0, 1, "pass")
      ],
      "constants" => [constant("index_origin", 0, "index", citation)],
      "model" => %{
        "kind" => "bounded_algorithm",
        "algorithm_id" => "insertion_sort",
        "state_transition" =>
          "At pass i, shift larger values in the sorted prefix right and insert the key at the remaining position.",
        "invariant" =>
          "After pass i, positions 0 through i are sorted and contain the original prefix values."
      },
      "sample_inputs" => [
        %{"case_id" => 1, "step_index" => 0},
        %{"case_id" => 1, "step_index" => 2},
        %{"case_id" => 2, "step_index" => 4}
      ],
      "sample_tolerance" => 0,
      "controls" => [
        %{"parameter_id" => "case_id", "control" => "bounded_case_selector"},
        %{"parameter_id" => "step_index", "control" => "stepper"}
      ],
      "observations" => [
        observation("state", "labeled_array_and_trace_table", "sequence"),
        observation("comparisons", "integer", "comparison"),
        observation("moves", "integer", "move"),
        observation("sorted", "boolean", "1")
      ],
      "guided_tasks" => [
        task("predict", "Predict the state after the next bounded insertion pass."),
        task(
          "trace",
          "Use comparisons and moves to explain the transition from the previous state."
        ),
        task(
          "compare",
          "Compare two fixed cases and explain why correctness does not imply identical work."
        )
      ],
      "misconception_handling" =>
        misconception(
          "Every correct sorting method performs the same sequence of work.",
          "Compare the trace state and work counts for two fixed input orders.",
          "The final lists are both sorted, but their intermediate states and work counts differ."
        ),
      "capi_manifest" =>
        capi(
          ~w(case_id step_index),
          [
            {"state", "string"},
            {"comparisons", "number"},
            {"moves", "number"},
            {"sorted", "boolean"}
          ]
        ),
      "rendering_mode" => "2d",
      "library_ids" => [],
      "accessibility" =>
        accessibility(
          "A trace table names each pass, key, compared positions, moves, and resulting array state."
        ),
      "algorithm" => %{
        "id" => "insertion_sort",
        "max_steps" => 64,
        "max_items" => 5,
        "accepts_learner_code" => false,
        "pseudocode" => [
          "For each bounded position i from 1 through length minus 1, store the key.",
          "Shift larger values in the prefix one position right while counting comparisons and moves.",
          "Insert the key, record the state, and stop after the selected pass."
        ]
      }
    }
  end

  defp sample_cases(domain, inputs, tolerance) do
    Enum.map(inputs, fn input ->
      {:ok, outputs} = evaluate(domain, input)

      %{
        "id" => sample_id(domain, input),
        "inputs" => input,
        "expected_outputs" => outputs,
        "tolerance" => tolerance,
        "deterministic" => true
      }
    end)
  end

  defp ideal_gas(inputs) do
    with {:ok, amount} <- number(inputs, "amount_mol"),
         {:ok, volume} <- positive_number(inputs, "volume_l"),
         {:ok, temperature} <- positive_number(inputs, "temperature_k") do
      {:ok, %{"pressure_kpa" => amount * 8.314_462_618 * temperature / volume}}
    end
  end

  defp constant_acceleration(inputs) do
    with {:ok, initial_velocity} <- number(inputs, "initial_velocity_m_s"),
         {:ok, acceleration} <- number(inputs, "acceleration_m_s2"),
         {:ok, time} <- nonnegative_number(inputs, "time_s") do
      {:ok,
       %{
         "final_velocity_m_s" => initial_velocity + acceleration * time,
         "displacement_m" => initial_velocity * time + 0.5 * acceleration * time * time
       }}
    end
  end

  defp logistic_population(inputs) do
    with {:ok, initial} <- positive_number(inputs, "initial_population"),
         {:ok, rate} <- positive_number(inputs, "growth_rate_per_step"),
         {:ok, capacity} <- positive_number(inputs, "carrying_capacity"),
         {:ok, elapsed} <- nonnegative_number(inputs, "elapsed_steps"),
         true <- initial < capacity do
      population = capacity / (1 + (capacity - initial) / initial * :math.exp(-rate * elapsed))
      {:ok, %{"population" => population}}
    else
      false -> {:error, :invalid_reference_inputs}
      error -> error
    end
  end

  defp central_difference(inputs) do
    with {:ok, x} <- number(inputs, "x"),
         {:ok, h} <- positive_number(inputs, "h") do
      estimate = (:math.pow(x + h, 3) - :math.pow(x - h, 3)) / (2 * h)
      exact = 3 * x * x

      {:ok,
       %{
         "derivative_estimate" => estimate,
         "exact_derivative" => exact,
         "absolute_error" => abs(estimate - exact)
       }}
    end
  end

  defp kepler_orbit(inputs) do
    with {:ok, axis} <- positive_number(inputs, "semi_major_axis_au"),
         {:ok, eccentricity} <- nonnegative_number(inputs, "eccentricity"),
         {:ok, anomaly} <- number(inputs, "true_anomaly_deg"),
         true <- eccentricity < 1 do
      radians = anomaly * :math.pi() / 180
      radius = axis * (1 - eccentricity * eccentricity) / (1 + eccentricity * :math.cos(radians))

      {:ok,
       %{
         "period_years" => :math.sqrt(axis * axis * axis),
         "orbital_radius_au" => radius,
         "relative_speed" => :math.sqrt(2 / radius - 1 / axis)
       }}
    else
      false -> {:error, :invalid_reference_inputs}
      error -> error
    end
  end

  defp insertion_sort_state(inputs) do
    with {:ok, case_id} <- integer(inputs, "case_id"),
         {:ok, step_index} <- integer(inputs, "step_index"),
         {:ok, values} <- sorting_case(case_id),
         true <- step_index >= 0 do
      trace = insertion_trace(values)
      selected = Enum.at(trace, min(step_index, length(trace) - 1))
      {:ok, selected}
    else
      false -> {:error, :invalid_reference_inputs}
      error -> error
    end
  end

  defp sorting_case(1), do: {:ok, [4, 1, 3, 2]}
  defp sorting_case(2), do: {:ok, [1, 2, 3, 4, 5]}
  defp sorting_case(3), do: {:ok, [5, 4, 3, 2, 1]}
  defp sorting_case(_), do: {:error, :invalid_reference_inputs}

  defp insertion_trace(values) do
    initial = output_state(values, 0, 0)

    {_state, _comparisons, _moves, trace} =
      Enum.reduce(1..(length(values) - 1), {values, 0, 0, [initial]}, fn index,
                                                                         {state, comparisons,
                                                                          moves, trace} ->
        key = Enum.at(state, index)
        {prefix, tail} = Enum.split(state, index)
        {greater, retained} = Enum.split_while(Enum.reverse(prefix), &(&1 > key))
        new_prefix = Enum.reverse(retained) ++ [key] ++ Enum.reverse(greater)
        next_state = new_prefix ++ tl(tail)

        next_comparisons =
          comparisons + length(greater) + if(length(greater) < index, do: 1, else: 0)

        next_moves = moves + length(greater) + 1
        next_output = output_state(next_state, next_comparisons, next_moves)

        {next_state, next_comparisons, next_moves, trace ++ [next_output]}
      end)

    trace
  end

  defp output_state(values, comparisons, moves) do
    %{
      "state" => Enum.join(values, ","),
      "comparisons" => comparisons,
      "moves" => moves,
      "sorted" => values == Enum.sort(values)
    }
  end

  defp parameter(id, minimum, maximum, default, step, unit),
    do: %{
      "id" => id,
      "min" => minimum,
      "max" => maximum,
      "default" => default,
      "step" => step,
      "unit" => unit
    }

  defp constant(id, value, unit, citation),
    do: %{"id" => id, "value" => value, "unit" => unit, "citation_urls" => [citation]}

  defp equation(id, expression, parameter_ids, output_ids),
    do: %{
      "id" => id,
      "expression" => expression,
      "parameter_ids" => parameter_ids,
      "output_ids" => output_ids
    }

  defp controls(ids), do: Enum.map(ids, &%{"parameter_id" => &1, "control" => "bounded_slider"})

  defp observation(id, display, unit),
    do: %{"output_id" => id, "display" => display, "unit" => unit}

  defp task(id, prompt), do: %{"id" => id, "prompt" => prompt}

  defp misconception(target, evidence_prompt, corrective_feedback) do
    %{
      "target" => target,
      "prediction_prompt" => evidence_prompt,
      "corrective_feedback" => corrective_feedback
    }
  end

  defp capi(input_ids, outputs) do
    %{
      "inputs" => Enum.map(input_ids, &%{"key" => &1, "type" => "number"}),
      "outputs" => Enum.map(outputs, fn {key, type} -> %{"key" => key, "type" => type} end)
    }
  end

  defp put_capi_input_defaults(spec) do
    defaults = Map.new(spec["parameters"], &{&1["id"], &1["default"]})

    update_in(spec, ["capi_manifest", "inputs"], fn inputs ->
      Enum.map(inputs, fn input -> Map.put(input, "defaultValue", defaults[input["key"]]) end)
    end)
  end

  defp accessibility(table, webgl_fallback \\ nil) do
    %{
      "keyboard" => %{
        "completion" =>
          "Tab to each control; use arrow keys or the step buttons; activate tasks with Enter."
      },
      "text_or_table_alternative" => table,
      "reduced_motion" =>
        "Disable animated transitions and update the labeled final state immediately.",
      "color_independent_encoding" =>
        "Pair color with persistent labels, position, line patterns, and numeric values."
    }
    |> maybe_put("webgl_fallback", webgl_fallback)
  end

  defp bounded_algorithm(id, max_steps, max_items) do
    %{
      "id" => id,
      "max_steps" => max_steps,
      "max_items" => max_items,
      "accepts_learner_code" => false
    }
  end

  defp sample_id(domain, inputs) do
    digest =
      :crypto.hash(:sha256, Jason.encode!(inputs))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    "#{domain}-sample-#{digest}"
  end

  defp citation_urls(research) do
    research
    |> Map.get("proposed_sources", [])
    |> List.wrap()
    |> Enum.map(fn source -> stringify(source)["url"] end)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp number(inputs, key) do
    case inputs[key] do
      value when is_integer(value) or is_float(value) -> {:ok, value}
      _ -> {:error, :invalid_reference_inputs}
    end
  end

  defp positive_number(inputs, key) do
    with {:ok, value} <- number(inputs, key), true <- value > 0 do
      {:ok, value}
    else
      _ -> {:error, :invalid_reference_inputs}
    end
  end

  defp nonnegative_number(inputs, key) do
    with {:ok, value} <- number(inputs, key), true <- value >= 0 do
      {:ok, value}
    else
      _ -> {:error, :invalid_reference_inputs}
    end
  end

  defp integer(inputs, key) do
    case inputs[key] do
      value when is_integer(value) -> {:ok, value}
      value when is_float(value) and trunc(value) == value -> {:ok, trunc(value)}
      _ -> {:error, :invalid_reference_inputs}
    end
  end

  defp normalize_domain(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_domain()

  defp normalize_domain(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim() |> String.replace(~r/[\s-]+/, "_")

  defp normalize_domain(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
