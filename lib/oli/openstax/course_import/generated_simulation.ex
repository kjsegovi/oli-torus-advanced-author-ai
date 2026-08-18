defmodule Oli.OpenStax.CourseImport.GeneratedSimulation do
  @moduledoc """
  Resolves an approved generated-simulation proposal into trusted iframe data.

  Planner-authored content supplies only a proposal id. Artifact records and
  their URLs come from trusted application services (or explicit test
  resolvers), and are revalidated here before they enter an Adaptive Author
  model.
  """

  alias Oli.OpenStax.CourseImport.Enrichment
  alias Oli.OpenStax.CourseImport.Enrichment.Origin

  @security_profile "generated_simulation"
  @max_capi_declarations 32
  @hash_pattern ~r/\A[0-9a-f]{64}\z/i
  @capi_types %{
    "number" => 1,
    "string" => 2,
    "array" => 3,
    "boolean" => 4,
    "enum" => 5,
    "math_expr" => 6,
    "array_point" => 7
  }

  @type part_spec :: %{required(String.t()) => term()}

  @spec resolve(String.t(), keyword()) :: {:ok, part_spec()} | {:error, term()}
  def resolve(proposal_id, opts \\ [])

  def resolve(proposal_id, opts) when is_binary(proposal_id) and is_list(opts) do
    proposal_id = String.trim(proposal_id)

    with :ok <- require_delivery_enabled(opts),
         true <- proposal_id != "",
         {:ok, artifact} <- resolve_artifact(proposal_id, opts),
         :ok <- validate_artifact(artifact, proposal_id),
         {:ok, artifact_url} <- resolve_artifact_url(artifact, opts),
         :ok <- validate_storage_url(artifact, artifact_url, opts),
         {:ok, capi} <- normalize_capi_manifest(value(artifact, :capi_manifest)),
         {:ok, accessibility} <- normalize_accessibility(artifact) do
      {:ok, build_part_spec(artifact, proposal_id, artifact_url, capi, accessibility)}
    else
      false -> {:error, :invalid_enrichment_proposal_id}
      {:error, _} = error -> error
      _ -> {:error, :generated_simulation_artifact_invalid}
    end
  end

  def resolve(_, _), do: {:error, :invalid_enrichment_proposal_id}

  defp require_delivery_enabled(opts) do
    enabled =
      Keyword.get(
        opts,
        :generated_simulation_delivery_enabled,
        Application.get_env(:oli, :openstax_generated_simulation_delivery_enabled, false)
      )

    kill_switch =
      Keyword.get(
        opts,
        :generated_simulation_kill_switch,
        Application.get_env(:oli, :openstax_generated_simulation_kill_switch, true)
      )

    if enabled and not kill_switch,
      do: :ok,
      else: {:error, :generated_simulation_delivery_disabled}
  end

  defp resolve_artifact(proposal_id, opts) do
    case Keyword.get(opts, :simulation_artifact_resolver) do
      resolver when is_function(resolver, 1) -> normalize_resolver_result(resolver.(proposal_id))
      nil -> default_artifact_resolver(proposal_id)
      _ -> {:error, :simulation_artifact_resolver_unavailable}
    end
  rescue
    _exception -> {:error, :simulation_artifact_resolution_failed}
  end

  defp default_artifact_resolver(proposal_id) do
    if Code.ensure_loaded?(Enrichment) and
         function_exported?(Enrichment, :resolve_approved_artifact, 1) do
      proposal_id
      |> Enrichment.resolve_approved_artifact()
      |> normalize_resolver_result()
    else
      {:error, :simulation_artifact_resolver_unavailable}
    end
  end

  defp normalize_resolver_result({:ok, artifact}) when is_map(artifact), do: {:ok, artifact}
  defp normalize_resolver_result({:error, reason}), do: {:error, reason}
  defp normalize_resolver_result(_), do: {:error, :simulation_artifact_resolution_failed}

  defp resolve_artifact_url(artifact, opts) do
    result =
      case Keyword.get(opts, :simulation_artifact_url_resolver) do
        resolver when is_function(resolver, 1) -> resolver.(artifact)
        resolver when is_function(resolver, 2) -> resolver.(artifact, opts)
        nil -> default_artifact_url_resolver(artifact, opts)
        _ -> {:error, :simulation_artifact_url_resolver_unavailable}
      end

    case result do
      {:ok, url} when is_binary(url) -> {:ok, String.trim(url)}
      url when is_binary(url) -> {:ok, String.trim(url)}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :simulation_artifact_url_resolution_failed}
    end
  rescue
    _exception -> {:error, :simulation_artifact_url_resolution_failed}
  end

  defp default_artifact_url_resolver(artifact, opts) do
    cond do
      Code.ensure_loaded?(Enrichment) and function_exported?(Enrichment, :artifact_url, 2) ->
        Enrichment.artifact_url(
          artifact,
          Keyword.put_new(
            opts,
            :allow_local_http,
            Application.get_env(:oli, :env) == :dev
          )
        )

      is_binary(value(artifact, :url)) ->
        {:ok, value(artifact, :url)}

      true ->
        {:error, :simulation_artifact_url_resolver_unavailable}
    end
  end

  defp validate_artifact(artifact, proposal_id) do
    artifact_id = value(artifact, :id)
    artifact_proposal_id = value(artifact, :proposal_id)
    version = value(artifact, :version)
    content_hash = value(artifact, :content_hash)
    storage_key = value(artifact, :storage_key)
    storage_origin = value(artifact, :storage_origin)
    storage_state = value(artifact, :storage_state)
    validation_status = validation_status(artifact)
    bundle_manifest = value(artifact, :bundle_manifest) || value(artifact, :manifest)

    cond do
      value(artifact, :status) != "approved" ->
        {:error, :simulation_artifact_not_approved}

      artifact_proposal_id != proposal_id ->
        {:error, :simulation_artifact_proposal_mismatch}

      not (is_binary(artifact_id) and String.trim(artifact_id) != "") ->
        {:error, :simulation_artifact_identity_invalid}

      not (is_integer(version) and version > 0) ->
        {:error, :simulation_artifact_version_invalid}

      not (is_binary(content_hash) and Regex.match?(@hash_pattern, content_hash)) ->
        {:error, :simulation_artifact_hash_invalid}

      not (is_binary(storage_key) and hash_in_path?(storage_key, content_hash)) ->
        {:error, :simulation_artifact_storage_key_invalid}

      storage_state not in ["staged", "promoted"] ->
        {:error, :simulation_artifact_storage_state_invalid}

      not valid_origin?(storage_origin) ->
        {:error, :simulation_artifact_storage_origin_invalid}

      not is_map(bundle_manifest) ->
        {:error, :simulation_artifact_manifest_invalid}

      validation_status != "passed" ->
        {:error, :simulation_artifact_validation_failed}

      true ->
        :ok
    end
  end

  defp validation_status(artifact) do
    value(artifact, :validation_status) ||
      artifact
      |> value(:validation_payload)
      |> case do
        payload when is_map(payload) -> map_value(payload, "status")
        _ -> nil
      end
  end

  defp validate_storage_url(artifact, url, opts) do
    content_hash = value(artifact, :content_hash)
    artifact_origin = normalize_origin(value(artifact, :storage_origin))
    url_origin = normalize_origin(url)
    configured_origins = trusted_origins(opts)

    cond do
      is_nil(url_origin) or url_origin != artifact_origin ->
        {:error, :simulation_artifact_url_origin_mismatch}

      configured_origins == [] or artifact_origin not in configured_origins ->
        {:error, :simulation_artifact_origin_untrusted}

      not hash_in_path?(URI.parse(url).path || "", content_hash) ->
        {:error, :simulation_artifact_url_not_content_addressed}

      true ->
        :ok
    end
  end

  defp trusted_origins(opts) do
    opts
    |> Keyword.get(
      :generated_simulation_origins,
      Application.get_env(:oli, :generated_simulation_origins, [])
    )
    |> List.wrap()
    |> Enum.map(&normalize_origin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_origin(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil}
      when is_binary(host) and host != "" ->
        if secure_origin?(scheme, host) do
          normalized_port =
            case {scheme, port} do
              {"https", 443} -> nil
              {"http", 80} -> nil
              {_scheme, value} -> value
            end

          authority = if is_integer(normalized_port), do: "#{host}:#{normalized_port}", else: host
          "#{scheme}://#{String.downcase(authority)}"
        end

      _ ->
        nil
    end
  end

  defp normalize_origin(_), do: nil

  defp valid_origin?(origin), do: not is_nil(normalize_origin(origin))

  defp secure_origin?("https", _host), do: true

  defp secure_origin?("http", host),
    do: Origin.local_loopback_host?(host)

  defp secure_origin?(_, _), do: false

  defp hash_in_path?(path, hash) when is_binary(path) and is_binary(hash),
    do: String.contains?(String.downcase(path), String.downcase(hash))

  defp hash_in_path?(_, _), do: false

  @doc "Validates and normalizes the typed CAPI contract shared by sandboxing and compilation."
  @spec normalize_capi_manifest(term()) :: {:ok, map()} | {:error, term()}
  def normalize_capi_manifest(nil), do: {:ok, %{inputs: [], outputs: [], config_data: []}}
  def normalize_capi_manifest(manifest) when manifest == %{}, do: normalize_capi_manifest(nil)

  def normalize_capi_manifest(manifest) when is_map(manifest) do
    with {:ok, inputs} <- normalize_declarations(map_value(manifest, "inputs"), :input),
         {:ok, outputs} <- normalize_declarations(map_value(manifest, "outputs"), :output),
         :ok <- validate_declaration_count(inputs, outputs),
         :ok <- validate_unique_declarations(inputs, outputs) do
      {:ok,
       %{
         inputs: inputs,
         outputs: outputs,
         config_data: Enum.map(inputs ++ outputs, & &1.config_data)
       }}
    end
  end

  def normalize_capi_manifest(_), do: {:error, :simulation_capi_manifest_invalid}

  defp normalize_declarations(nil, _direction), do: {:ok, []}

  defp normalize_declarations(declarations, direction) when is_list(declarations) do
    declarations
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {declaration, index}, {:ok, normalized} ->
      case normalize_declaration(declaration, direction) do
        {:ok, item} ->
          {:cont, {:ok, normalized ++ [item]}}

        {:error, reason} ->
          {:halt, {:error, {:simulation_capi_declaration_invalid, index, reason}}}
      end
    end)
  end

  defp normalize_declarations(_, _), do: {:error, :simulation_capi_manifest_invalid}

  defp normalize_declaration(declaration, direction) when is_map(declaration) do
    key = map_value(declaration, "key") || map_value(declaration, "name")
    type = normalize_capi_type(map_value(declaration, "type"))

    allowed_values =
      map_value(declaration, "allowed_values") || map_value(declaration, "allowedValues")

    with true <- valid_capi_key?(key),
         true <- not is_nil(type),
         :ok <- validate_allowed_values(type, allowed_values),
         {:ok, default_value} <- declaration_default(declaration, type, allowed_values),
         :ok <- validate_default_value(type, default_value, allowed_values),
         {:ok, branching} <-
           normalize_capi_branching(declaration, direction, type, allowed_values) do
      normalized =
        %{"key" => String.trim(key), "type" => type}
        |> maybe_put("defaultValue", default_value)
        |> maybe_put("allowedValues", allowed_values)
        |> maybe_put("branching", branching)

      config_data = %{
        "key" => String.trim(key),
        "type" => Map.fetch!(@capi_types, type),
        "value" => default_value,
        "readonly" => direction == :output,
        "writeonly" => false
      }

      {:ok, %{key: String.trim(key), declaration: normalized, config_data: config_data}}
    else
      false -> {:error, :invalid_key_or_type}
      {:error, _} = error -> error
    end
  end

  defp normalize_declaration(_, _), do: {:error, :invalid_declaration}

  defp valid_capi_key?(key) when is_binary(key) do
    normalized = String.trim(key)

    byte_size(normalized) <= 128 and
      Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_.:-]*\z/, normalized) and
      normalized not in ["constructor", "prototype", "__proto__"]
  end

  defp valid_capi_key?(_), do: false

  defp normalize_capi_type(type) when is_atom(type), do: normalize_capi_type(Atom.to_string(type))

  defp normalize_capi_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      type when is_map_key(@capi_types, type) -> type
      _ -> nil
    end
  end

  defp normalize_capi_type(_), do: nil

  defp validate_allowed_values("enum", values)
       when is_list(values) and values != [] do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, :invalid_allowed_values}
  end

  defp validate_allowed_values("enum", _), do: {:error, :missing_allowed_values}

  defp validate_allowed_values(_type, nil), do: :ok

  defp validate_allowed_values(_type, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, :invalid_allowed_values}
  end

  defp validate_allowed_values(_type, _), do: {:error, :invalid_allowed_values}

  defp declaration_default(declaration, type, allowed_values) do
    keys = ["default_value", "defaultValue", "default", "value"]

    value =
      Enum.find_value(keys, fn key ->
        if has_map_key?(declaration, key), do: {:found, map_value(declaration, key)}
      end)

    case value do
      {:found, value} -> {:ok, value}
      nil -> {:ok, default_for_type(type, allowed_values)}
    end
  end

  defp default_for_type("number", _), do: 0
  defp default_for_type("string", _), do: ""
  defp default_for_type("boolean", _), do: false
  defp default_for_type(type, _) when type in ["array", "array_point"], do: []
  defp default_for_type("enum", [first | _]), do: first
  defp default_for_type("math_expr", _), do: ""

  defp validate_default_value("number", value, _),
    do: if(is_number(value), do: :ok, else: {:error, :invalid_default_value})

  defp validate_default_value(type, value, _)
       when type in ["string", "math_expr"],
       do: if(is_binary(value), do: :ok, else: {:error, :invalid_default_value})

  defp validate_default_value("boolean", value, _),
    do: if(is_boolean(value), do: :ok, else: {:error, :invalid_default_value})

  defp validate_default_value(type, value, _)
       when type in ["array", "array_point"],
       do: if(is_list(value), do: :ok, else: {:error, :invalid_default_value})

  defp validate_default_value("enum", value, allowed_values),
    do: if(value in allowed_values, do: :ok, else: {:error, :invalid_default_value})

  defp normalize_capi_branching(declaration, direction, type, allowed_values) do
    branching = map_value(declaration, "branching")

    case {direction, branching} do
      {_direction, nil} ->
        {:ok, nil}

      {:input, _branching} ->
        {:error, :input_branching_forbidden}

      {:output, %{} = branch} ->
        operator = normalize_branch_operator(map_value(branch, "operator"))
        remediation_section_id = map_value(branch, "remediation_section_id")
        feedback = map_value(branch, "feedback")
        value_present? = has_map_key?(branch, "value")
        value = map_value(branch, "value")

        with true <- not is_nil(operator),
             true <- value_present?,
             :ok <- validate_default_value(type, value, allowed_values),
             true <- valid_capi_key?(remediation_section_id),
             true <- is_nil(feedback) or (is_binary(feedback) and byte_size(feedback) <= 1_000) do
          {:ok,
           %{
             "operator" => operator,
             "value" => value,
             "remediation_section_id" => remediation_section_id
           }
           |> maybe_put("feedback", feedback)}
        else
          _ -> {:error, :invalid_output_branching}
        end

      _ ->
        {:error, :invalid_output_branching}
    end
  end

  defp normalize_branch_operator(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "equal" -> "equal"
      "not_equal" -> "notEqual"
      "notequal" -> "notEqual"
      "greater_than" -> "greaterThan"
      "greaterthan" -> "greaterThan"
      "greater_than_or_equal" -> "greaterThanInclusive"
      "greaterthaninclusive" -> "greaterThanInclusive"
      "less_than" -> "lessThan"
      "lessthan" -> "lessThan"
      "less_than_or_equal" -> "lessThanInclusive"
      "lessthaninclusive" -> "lessThanInclusive"
      _ -> nil
    end
  end

  defp normalize_branch_operator(_value), do: nil

  defp validate_unique_declarations(inputs, outputs) do
    keys = Enum.map(inputs ++ outputs, & &1.key)

    if length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, :duplicate_simulation_capi_key}
  end

  defp validate_declaration_count(inputs, outputs) do
    if length(inputs) + length(outputs) <= @max_capi_declarations,
      do: :ok,
      else: {:error, :simulation_capi_declaration_limit_exceeded}
  end

  defp normalize_accessibility(artifact) do
    metadata = value(artifact, :accessibility_metadata)
    title = if is_map(metadata), do: map_value(metadata, "title")
    description = if is_map(metadata), do: map_value(metadata, "description")

    if present_text?(title) and present_text?(description) do
      {:ok, %{title: String.trim(title), description: String.trim(description)}}
    else
      {:error, :simulation_artifact_accessibility_invalid}
    end
  end

  defp build_part_spec(artifact, proposal_id, artifact_url, capi, accessibility) do
    content_hash = String.downcase(value(artifact, :content_hash))

    %{
      "src" => artifact_url,
      "title" => accessibility.title,
      "description" => accessibility.description,
      "allowScrolling" => false,
      "securityProfile" => @security_profile,
      "artifactIdentity" => %{
        "proposalId" => proposal_id,
        "artifactId" => value(artifact, :id),
        "version" => value(artifact, :version),
        "contentHash" => content_hash,
        "storageOrigin" => normalize_origin(value(artifact, :storage_origin))
      },
      "capiInputs" => Enum.map(capi.inputs, & &1.declaration),
      "capiOutputs" => Enum.map(capi.outputs, & &1.declaration),
      "configData" => capi.config_data
    }
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp has_map_key?(map, key) do
    Map.has_key?(map, key) or
      try do
        Map.has_key?(map, String.to_existing_atom(key))
      rescue
        ArgumentError -> false
      end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""
end
