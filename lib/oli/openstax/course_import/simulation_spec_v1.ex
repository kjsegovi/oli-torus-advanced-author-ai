defmodule Oli.OpenStax.CourseImport.SimulationSpecV1 do
  @moduledoc "Deterministic scientific, CAPI, accessibility, and runtime contract for simulations."

  alias Oli.OpenStax.CourseImport.Enrichment.LibraryRegistry
  alias Oli.OpenStax.CourseImport.GeneratedSimulation
  alias Oli.OpenStax.CourseImport.SimulationDomainReferences

  @domains ~w(chemistry physics biology mathematics astronomy computer_science)
  @rendering_modes ~w(2d 3d)
  @max_algorithm_steps 10_000
  @max_algorithm_items 10_000

  @spec validate(map(), map(), keyword()) :: {:ok, map(), map()} | {:error, [map()]}
  def validate(spec, research, opts \\ [])

  def validate(spec, research, opts) when is_map(spec) and is_map(research) do
    spec = stringify(spec)
    research = stringify(research)
    domain = normalize_domain(spec["domain"])
    library_ids = normalize_strings(spec["library_ids"])
    rendering_mode = spec["rendering_mode"]
    sample_cases = maps(spec["sample_cases"])
    parameters = maps(spec["parameters"])
    controls = maps(spec["controls"])
    observations = maps(spec["observations"])
    constants = maps(spec["constants"])
    objective_ids = normalize_strings(spec["objective_ids"])
    research_hash = research["content_hash"]
    citation_urls = citation_urls(research)
    strict? = spec["contract_profile"] == "domain_reference_v1"

    findings =
      []
      |> require(domain in @domains, "unsupported_spec_domain", "$.domain")
      |> require(
        spec["evidence_hash"] == research_hash,
        "evidence_hash_mismatch",
        "$.evidence_hash"
      )
      |> require(
        spec["research_hash"] == research_hash,
        "research_hash_mismatch",
        "$.research_hash"
      )
      |> require(
        objective_ids != [],
        "missing_spec_objectives",
        "$.objective_ids"
      )
      |> require(nonempty_list?(spec["assumptions"]), "missing_assumptions", "$.assumptions")
      |> require(nonempty_list?(spec["limitations"]), "missing_limitations", "$.limitations")
      |> require(parameters != [], "missing_parameters", "$.parameters")
      |> require(sample_cases != [], "missing_sample_cases", "$.sample_cases")
      |> require(controls != [], "missing_controls", "$.controls")
      |> require(observations != [], "missing_observations", "$.observations")
      |> require(maps(spec["guided_tasks"]) != [], "missing_guided_tasks", "$.guided_tasks")
      |> require(
        present_contract?(spec["misconception_handling"]),
        "missing_misconception_handling",
        "$.misconception_handling"
      )
      |> require(
        present_contract?(spec["native_follow_up"]),
        "missing_native_follow_up",
        "$.native_follow_up"
      )
      |> require(
        present_contract?(spec["remediation"]),
        "missing_remediation",
        "$.remediation"
      )
      |> require(rendering_mode in @rendering_modes, "invalid_rendering_mode", "$.rendering_mode")
      |> Kernel.++(validate_opportunity_consistency(spec, domain, objective_ids, opts))
      |> Kernel.++(validate_parameters(parameters))
      |> Kernel.++(validate_constants(constants, citation_urls))
      |> Kernel.++(validate_mappings(parameters, controls, observations, spec["capi_manifest"]))
      |> Kernel.++(
        validate_sample_cases(sample_cases, parameters, spec["capi_manifest"], strict?)
      )
      |> Kernel.++(validate_model(domain, spec["model"], parameters, observations, strict?))
      |> Kernel.++(validate_instructional_contract(spec, objective_ids, strict?))
      |> Kernel.++(validate_algorithm(domain, spec["algorithm"]))
      |> Kernel.++(validate_accessibility(spec, rendering_mode))
      |> Kernel.++(validate_capi(spec["capi_manifest"]))
      |> Kernel.++(validate_libraries(library_ids, rendering_mode, opts))
      |> require(
        spec["learner_code_execution"] != true,
        "learner_code_execution_forbidden",
        "$.learner_code_execution"
      )

    case findings do
      [] ->
        normalized =
          spec
          |> Map.put("schema_version", 1)
          |> Map.put("domain", domain)
          |> Map.put("objective_ids", objective_ids)
          |> Map.put("library_ids", library_ids)
          |> Map.put("parameters", parameters)
          |> Map.put("sample_cases", sample_cases)

        {:ok, normalized,
         %{
           "status" => "passed",
           "sample_case_count" => length(sample_cases),
           "library_ids" => library_ids,
           "rendering_mode" => rendering_mode
         }}

      findings ->
        {:error, findings}
    end
  end

  def validate(_, _, _), do: {:error, [finding("invalid_simulation_spec", "$")]}

  def prompt_contract(research, opportunity, opts \\ []) do
    research = stringify(research)
    opportunity = stringify(opportunity)

    domain_reference =
      case SimulationDomainReferences.build(opportunity["domain"], research,
             objective_ids: normalize_strings(opportunity["objective_ids"]),
             id_prefix: opportunity["id"] || "generated-simulation",
             native_follow_up_activity_id:
               opportunity_identifier(opportunity, "native_follow_up_activity_id"),
             remediation_content_group_id:
               opportunity_identifier(opportunity, "remediation_content_group_id")
           ) do
        {:ok, reference} -> reference
        {:error, _reason} -> nil
      end

    %{
      "schema_version" => 1,
      "opportunity" => opportunity,
      "approved_research" => research,
      "domain_reference" => domain_reference,
      "supported_domains" => @domains,
      "library_registry" => LibraryRegistry.contract(),
      "three_d_enabled" => Keyword.get(opts, :three_d_enabled, false),
      "required_accessibility" => %{
        "keyboard" => true,
        "text_or_table_alternative" => true,
        "reduced_motion" => true,
        "color_independent" => true,
        "webgl_fallback_for_3d" => true
      },
      "algorithm_limits" => %{
        "max_steps" => @max_algorithm_steps,
        "max_items" => @max_algorithm_items,
        "learner_code_execution" => false
      },
      "required_contract_profile" => "domain_reference_v1",
      "minimum_deterministic_sample_cases" => 3,
      "required_routing_identifiers" => %{
        "native_follow_up" => "activity_id",
        "remediation" => "content_group_id"
      },
      "required_model_mapping" =>
        "Every parameter maps to one control and CAPI input; every model output maps to an observation, sample output, and typed CAPI output."
    }
  end

  defp validate_parameters(parameters) do
    Enum.flat_map(parameters, fn parameter ->
      id = parameter["id"]
      minimum = parameter["min"]
      maximum = parameter["max"]
      default = parameter["default"]
      step = parameter["step"]

      []
      |> require(present?(id), "invalid_parameter_id", "$.parameters")
      |> require(
        number?(minimum) and number?(maximum) and minimum < maximum,
        "invalid_parameter_range",
        "$.parameters.#{id}"
      )
      |> require(
        number?(default) and number?(minimum) and number?(maximum) and default >= minimum and
          default <= maximum,
        "invalid_parameter_default",
        "$.parameters.#{id}"
      )
      |> require(number?(step) and step > 0, "invalid_parameter_step", "$.parameters.#{id}")
      |> require(
        present?(parameter["unit"]) or parameter["unitless"] == true,
        "unsupported_parameter_unit",
        "$.parameters.#{id}"
      )
    end)
  end

  defp validate_constants(constants, citation_urls) do
    Enum.flat_map(constants, fn constant ->
      citations = normalize_strings(constant["citation_urls"])

      []
      |> require(present?(constant["id"]), "invalid_constant_id", "$.constants")
      |> require(number?(constant["value"]), "invalid_constant_value", "$.constants")
      |> require(citations != [], "uncited_constant", "$.constants.#{constant["id"]}")
      |> require(
        MapSet.subset?(MapSet.new(citations), MapSet.new(citation_urls)),
        "invented_constant_citation",
        "$.constants.#{constant["id"]}"
      )
    end)
  end

  defp validate_mappings(parameters, controls, observations, manifest) do
    parameter_ids = ids(parameters, "id")
    control_ids = ids(controls, "parameter_id")
    observation_ids = ids(observations, "output_id")
    manifest = stringify(manifest || %{})
    capi_input_ids = ids(maps(manifest["inputs"]), "key")
    capi_output_ids = ids(maps(manifest["outputs"]), "key")

    []
    |> require(unique_nonempty?(parameter_ids), "duplicate_parameter_id", "$.parameters")
    |> require(unique_nonempty?(control_ids), "duplicate_control_mapping", "$.controls")
    |> require(
      MapSet.new(control_ids) == MapSet.new(parameter_ids),
      "parameter_control_mapping_mismatch",
      "$.controls"
    )
    |> require(
      Enum.all?(controls, &present?(&1["control"])),
      "invalid_control_contract",
      "$.controls"
    )
    |> require(
      MapSet.new(capi_input_ids) == MapSet.new(parameter_ids),
      "parameter_capi_mapping_mismatch",
      "$.capi_manifest.inputs"
    )
    |> require(unique_nonempty?(observation_ids), "duplicate_output_id", "$.observations")
    |> require(
      MapSet.new(capi_output_ids) == MapSet.new(observation_ids),
      "observation_capi_mapping_mismatch",
      "$.capi_manifest.outputs"
    )
    |> require(
      Enum.all?(observations, &present?(&1["display"])),
      "invalid_observation_contract",
      "$.observations"
    )
  end

  defp validate_sample_cases(cases, parameters, manifest, strict?) do
    parameter_ids = ids(parameters, "id")
    parameter_lookup = Map.new(parameters, &{&1["id"], &1})
    manifest = stringify(manifest || %{})
    output_declarations = maps(manifest["outputs"])
    output_ids = ids(output_declarations, "key")
    output_types = Map.new(output_declarations, &{&1["key"], &1["type"]})

    case_findings =
      cases
      |> Enum.with_index()
      |> Enum.flat_map(fn {sample, index} ->
        inputs = if is_map(sample["inputs"]), do: stringify(sample["inputs"]), else: %{}

        outputs =
          if is_map(sample["expected_outputs"]),
            do: stringify(sample["expected_outputs"]),
            else: %{}

        path = "$.sample_cases[#{index}]"

        []
        |> require(is_map(sample["inputs"]), "invalid_sample_inputs", path <> ".inputs")
        |> require(
          is_map(sample["expected_outputs"]),
          "invalid_sample_outputs",
          path <> ".expected_outputs"
        )
        |> require(
          MapSet.new(Map.keys(inputs)) == MapSet.new(parameter_ids),
          "sample_parameter_mapping_mismatch",
          path <> ".inputs"
        )
        |> require(
          Enum.all?(inputs, fn {id, value} ->
            case parameter_lookup[id] do
              nil -> false
              parameter -> parameter_value_valid?(value, parameter)
            end
          end),
          "sample_parameter_out_of_range",
          path <> ".inputs"
        )
        |> require(
          MapSet.new(Map.keys(outputs)) == MapSet.new(output_ids),
          "sample_output_mapping_mismatch",
          path <> ".expected_outputs"
        )
        |> require(
          Enum.all?(outputs, fn {id, value} -> value_matches_type?(value, output_types[id]) end),
          "sample_output_type_mismatch",
          path <> ".expected_outputs"
        )
        |> require(
          number?(sample["tolerance"]) and sample["tolerance"] >= 0,
          "invalid_sample_tolerance",
          path <> ".tolerance"
        )
        |> require(
          sample["deterministic"] == true,
          "nondeterministic_sample_case",
          path
        )
      end)

    strict_findings =
      if strict? do
        []
        |> require(length(cases) >= 3, "insufficient_sample_cases", "$.sample_cases")
        |> require(
          cases |> Enum.map(& &1["inputs"]) |> Enum.uniq() |> length() == length(cases),
          "duplicate_sample_inputs",
          "$.sample_cases"
        )
        |> require(
          cases |> Enum.map(& &1["expected_outputs"]) |> Enum.uniq() |> length() > 1,
          "trivial_sample_outputs",
          "$.sample_cases"
        )
      else
        []
      end

    case_findings ++ strict_findings
  end

  defp validate_model(domain, model, parameters, observations, true) when is_map(model) do
    model = stringify(model)
    parameter_ids = MapSet.new(ids(parameters, "id"))
    output_ids = MapSet.new(ids(observations, "output_id"))

    if domain == "computer_science" do
      []
      |> require(
        model["kind"] == "bounded_algorithm",
        "invalid_domain_model_kind",
        "$.model.kind"
      )
      |> require(present?(model["algorithm_id"]), "missing_algorithm_id", "$.model.algorithm_id")
      |> require(
        present?(model["state_transition"]),
        "missing_state_transition",
        "$.model.state_transition"
      )
      |> require(present?(model["invariant"]), "missing_algorithm_invariant", "$.model.invariant")
    else
      equations = maps(model["equations"])

      mapped_parameters =
        equations |> Enum.flat_map(&normalize_strings(&1["parameter_ids"])) |> MapSet.new()

      mapped_outputs =
        equations |> Enum.flat_map(&normalize_strings(&1["output_ids"])) |> MapSet.new()

      []
      |> require(
        model["kind"] in ["equation", "equation_system"],
        "invalid_domain_model_kind",
        "$.model.kind"
      )
      |> require(equations != [], "missing_model_equations", "$.model.equations")
      |> require(
        Enum.all?(equations, &(present?(&1["id"]) and present?(&1["expression"]))),
        "invalid_model_equation",
        "$.model.equations"
      )
      |> require(
        mapped_parameters == parameter_ids,
        "equation_parameter_mapping_mismatch",
        "$.model.equations"
      )
      |> require(
        mapped_outputs == output_ids,
        "equation_output_mapping_mismatch",
        "$.model.equations"
      )
    end
  end

  defp validate_model(_domain, _model, _parameters, _observations, true),
    do: [finding("missing_domain_model", "$.model")]

  defp validate_model(_domain, _model, _parameters, _observations, false), do: []

  defp validate_instructional_contract(spec, objective_ids, true) do
    misconception = stringify(spec["misconception_handling"] || %{})
    follow_up = stringify(spec["native_follow_up"] || %{})
    remediation = stringify(spec["remediation"] || %{})
    guided_tasks = maps(spec["guided_tasks"])

    []
    |> require(
      present?(misconception["target"]) and present?(misconception["prediction_prompt"]) and
        present?(misconception["corrective_feedback"]),
      "invalid_misconception_contract",
      "$.misconception_handling"
    )
    |> require(
      valid_identifier?(follow_up["activity_id"]),
      "invalid_native_follow_up_id",
      "$.native_follow_up.activity_id"
    )
    |> require(
      MapSet.new(normalize_strings(follow_up["objective_ids"])) == MapSet.new(objective_ids),
      "native_follow_up_objective_mismatch",
      "$.native_follow_up.objective_ids"
    )
    |> require(
      present?(follow_up["prompt"]),
      "missing_native_follow_up_prompt",
      "$.native_follow_up.prompt"
    )
    |> require(
      valid_identifier?(remediation["content_group_id"]),
      "invalid_remediation_content_group_id",
      "$.remediation.content_group_id"
    )
    |> require(
      present?(remediation["guidance"]),
      "missing_remediation_guidance",
      "$.remediation.guidance"
    )
    |> require(
      length(guided_tasks) >= 3 and
        Enum.all?(guided_tasks, &(valid_identifier?(&1["id"]) and present?(&1["prompt"]))),
      "insufficient_guided_task_contract",
      "$.guided_tasks"
    )
  end

  defp validate_instructional_contract(_spec, _objective_ids, false), do: []

  defp validate_opportunity_consistency(spec, domain, objective_ids, opts) do
    opportunity = stringify(Keyword.get(opts, :opportunity, %{}))
    expected_domain = Keyword.get(opts, :expected_domain) || opportunity["domain"]

    allowed_objective_ids =
      Keyword.get(opts, :allowed_objective_ids) || opportunity["objective_ids"]

    expected_follow_up_id = opportunity_identifier(opportunity, "native_follow_up_activity_id")

    expected_remediation_id =
      opportunity_identifier(opportunity, "remediation_content_group_id")

    follow_up = stringify(spec["native_follow_up"] || %{})
    remediation = stringify(spec["remediation"] || %{})

    []
    |> require(
      is_nil(expected_domain) or normalize_domain(expected_domain) == domain,
      "simulation_domain_mismatch",
      "$.domain"
    )
    |> require(
      is_nil(allowed_objective_ids) or
        MapSet.subset?(
          MapSet.new(objective_ids),
          MapSet.new(normalize_strings(allowed_objective_ids))
        ),
      "simulation_objective_mismatch",
      "$.objective_ids"
    )
    |> require(
      is_nil(expected_follow_up_id) or follow_up["activity_id"] == expected_follow_up_id,
      "native_follow_up_placement_mismatch",
      "$.native_follow_up.activity_id"
    )
    |> require(
      is_nil(expected_remediation_id) or
        remediation["content_group_id"] == expected_remediation_id,
      "remediation_placement_mismatch",
      "$.remediation.content_group_id"
    )
  end

  defp opportunity_identifier(opportunity, key) do
    direct = opportunity[key]
    placement = stringify(opportunity["placement"] || %{})
    if present?(direct), do: direct, else: placement[key]
  end

  defp validate_algorithm("computer_science", algorithm) when is_map(algorithm) do
    algorithm = stringify(algorithm)

    []
    |> require(
      integer_in?(algorithm["max_steps"], 1, @max_algorithm_steps),
      "unbounded_algorithm_steps",
      "$.algorithm.max_steps"
    )
    |> require(
      integer_in?(algorithm["max_items"], 1, @max_algorithm_items),
      "unbounded_algorithm_items",
      "$.algorithm.max_items"
    )
    |> require(
      algorithm["accepts_learner_code"] != true,
      "learner_code_execution_forbidden",
      "$.algorithm.accepts_learner_code"
    )
  end

  defp validate_algorithm("computer_science", _),
    do: [finding("missing_bounded_algorithm", "$.algorithm")]

  defp validate_algorithm(_domain, _algorithm), do: []

  defp validate_accessibility(spec, rendering_mode) do
    accessibility = stringify(spec["accessibility"] || %{})

    []
    |> require(
      is_map(accessibility["keyboard"]) and map_size(accessibility["keyboard"]) > 0,
      "missing_keyboard_contract",
      "$.accessibility.keyboard"
    )
    |> require(
      present?(accessibility["text_or_table_alternative"]),
      "missing_text_alternative",
      "$.accessibility.text_or_table_alternative"
    )
    |> require(
      present?(accessibility["reduced_motion"]),
      "missing_reduced_motion",
      "$.accessibility.reduced_motion"
    )
    |> require(
      present?(accessibility["color_independent_encoding"]),
      "missing_color_independent_encoding",
      "$.accessibility.color_independent_encoding"
    )
    |> require(
      rendering_mode != "3d" or present?(accessibility["webgl_fallback"]),
      "missing_webgl_fallback",
      "$.accessibility.webgl_fallback"
    )
  end

  defp validate_capi(manifest) do
    case GeneratedSimulation.normalize_capi_manifest(manifest) do
      {:ok, normalized} ->
        if List.wrap(normalized[:outputs] || normalized["outputs"]) == [],
          do: [finding("missing_capi_outputs", "$.capi_manifest.outputs")],
          else: []

      {:error, _} ->
        [finding("invalid_capi_manifest", "$.capi_manifest")]
    end
  end

  defp validate_libraries(ids, rendering_mode, opts) do
    findings =
      case LibraryRegistry.validate_ids(ids, opts) do
        {:ok, _} -> []
        {:error, reason} -> [finding(format_reason(reason), "$.library_ids")]
      end

    if rendering_mode == "3d" and "three-0.185.1" not in ids,
      do: findings ++ [finding("three_required_for_3d", "$.library_ids")],
      else: findings
  end

  defp citation_urls(research) do
    research
    |> Map.get("proposed_sources", [])
    |> maps()
    |> Enum.map(& &1["url"])
    |> Enum.filter(&is_binary/1)
  end

  defp maps(values), do: values |> List.wrap() |> Enum.filter(&is_map/1) |> Enum.map(&stringify/1)

  defp ids(values, key),
    do: values |> Enum.map(& &1[key]) |> Enum.filter(&present?/1)

  defp unique_nonempty?(values), do: values != [] and length(values) == length(Enum.uniq(values))

  defp parameter_value_valid?(value, parameter) when is_integer(value) or is_float(value) do
    minimum = parameter["min"]
    maximum = parameter["max"]
    number?(minimum) and number?(maximum) and value >= minimum and value <= maximum
  end

  defp parameter_value_valid?(_, _), do: false

  defp value_matches_type?(value, "number"), do: number?(value)
  defp value_matches_type?(value, "string"), do: is_binary(value)
  defp value_matches_type?(value, "boolean"), do: is_boolean(value)
  defp value_matches_type?(value, type) when type in ["array", "array_point"], do: is_list(value)
  defp value_matches_type?(value, "enum"), do: is_binary(value)
  defp value_matches_type?(value, "math_expr"), do: is_binary(value)
  defp value_matches_type?(_, _), do: false

  defp normalize_strings(values),
    do:
      values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp normalize_domain(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim() |> String.replace(~r/[\s-]+/, "_")

  defp normalize_domain(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_domain()

  defp normalize_domain(_), do: nil

  defp require(findings, true, _code, _path), do: findings
  defp require(findings, false, code, path), do: findings ++ [finding(code, path)]

  defp finding(code, path),
    do: %{
      "code" => code,
      "path" => path,
      "severity" => "repair",
      "repair" => "Repair this SimulationSpecV1 contract violation."
    }

  defp integer_in?(value, min, max), do: is_integer(value) and value >= min and value <= max
  defp nonempty_list?(value), do: is_list(value) and value != []
  defp number?(value), do: is_integer(value) or is_float(value)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp present_contract?(value) when is_map(value), do: map_size(value) > 0
  defp present_contract?(value), do: present?(value)

  defp valid_identifier?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_-]{0,127}\z/, String.trim(value))

  defp valid_identifier?(_), do: false

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(_), do: "invalid_library_registry"

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
