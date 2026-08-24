defmodule Oli.OpenStax.CourseImport.Enrichment.Generator.UntrustedGenerated do
  @moduledoc """
  GPT-5.6 Sol source generator for approved, immutable simulation contracts.

  The returned source remains untrusted. It can only become previewable after
  Torus injects registered libraries and the CAPI bridge, then records a passed
  isolated-browser validation result on an immutable artifact version.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Generator

  alias Oli.GenAI.Completions.{Message, RegisteredModel, ServiceConfig}
  alias Oli.GenAI.Execution

  alias Oli.OpenStax.CourseImport.{
    AIUsageLedger,
    EnrichmentProposal,
    EnrichmentResearchSet,
    GeneratedSimulation,
    ModelRoutingPolicy,
    SimulationSpec
  }

  alias Oli.OpenStax.CourseImport.Enrichment.LibraryRegistry

  @prompt_version "simulation-bundle-v1"
  @default_model "gpt-5.6-sol"
  @max_candidates 2

  @impl true
  def available? do
    Application.get_env(:oli, :openstax_generated_enrichment_enabled, false) == true and
      present?(System.get_env("OPENAI_API_KEY"))
  end

  @impl true
  def runtime_profile, do: :untrusted_generated

  @impl true
  def generate(%EnrichmentProposal{kind: "generated_simulation"} = proposal, opts) do
    with %SimulationSpec{} = spec <- Keyword.get(opts, :simulation_spec),
         %EnrichmentResearchSet{} = research <- Keyword.get(opts, :research_set),
         :ok <- validate_scope(proposal, spec, research),
         {:ok, bundle, usage, repair_count, history} <-
           build_source(spec, research, opts, 1, Keyword.get(opts, :repair), []) do
      {:ok,
       Map.put(bundle, :metadata, %{
         "generator_name" => "openai_untrusted_generated",
         "generator_version" => @prompt_version,
         "runtime_profile" => "untrusted_generated",
         "provider" => "open_ai",
         "model" => model_name(opts),
         "provider_usage" => stringify(usage),
         "source_repair_count" => repair_count,
         "source_generation_history" => history,
         "prompt_version" => @prompt_version,
         "simulation_spec_id" => spec.id,
         "simulation_spec_hash" => spec.content_hash,
         "research_set_id" => research.id,
         "research_hash" => research.content_hash
       })}
    else
      nil -> {:error, :approved_simulation_spec_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_generation_contract}
    end
  rescue
    _exception -> {:error, :generator_failed}
  end

  def generate(%EnrichmentProposal{}, _opts), do: {:error, :not_generated_simulation}
  def generate(_, _opts), do: {:error, :invalid_input}

  defp build_source(spec, research, opts, attempt, repair, history) do
    with {:ok, candidate, usage} <-
           request_bundle(spec, research, Keyword.put(opts, :repair, repair)) do
      case normalize_bundle(candidate, spec) do
        {:ok, bundle} ->
          {:ok, bundle, usage, attempt - 1,
           history ++
             [
               %{
                 "attempt" => attempt,
                 "provider_usage" => stringify(usage),
                 "status" => "accepted"
               }
             ]}

        {:error, reason} when attempt < @max_candidates ->
          finding = repair_finding(reason)

          build_source(
            spec,
            research,
            opts,
            attempt + 1,
            %{candidate: candidate, findings: [finding]},
            history ++
              [
                %{
                  "attempt" => attempt,
                  "provider_usage" => stringify(usage),
                  "status" => "repair",
                  "findings" => [finding]
                }
              ]
          )

        {:error, reason} ->
          {:error, {:simulation_bundle_source_exhausted, repair_finding(reason)}}
      end
    end
  end

  defp repair_finding({code, details}) when is_atom(code),
    do: %{"code" => Atom.to_string(code), "details" => stringify(details)}

  defp repair_finding(code) when is_atom(code), do: %{"code" => Atom.to_string(code)}
  defp repair_finding(_), do: %{"code" => "invalid_generated_bundle_contract"}

  defp validate_scope(proposal, spec, research) do
    if spec.status == "approved" and research.status == "approved" and
         spec.proposal_id == proposal.id and research.proposal_id == proposal.id and
         spec.research_set_id == research.id and spec.evidence_hash == research.content_hash and
         is_binary(spec.content_hash) do
      :ok
    else
      {:error, :stale_generation_contract}
    end
  end

  defp request_bundle(spec, research, opts) do
    builder_contract =
      %{
        "approved_simulation_spec" => spec.spec_payload,
        "approved_spec_hash" => spec.content_hash,
        "approved_research" => %{
          "content_hash" => research.content_hash,
          "claims" => research.claims,
          "sources" => research.proposed_sources
        },
        "library_registry" => LibraryRegistry.contract(),
        "fixed_file_contract" => %{
          "entrypoint" => "index.html",
          "required_csp" =>
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'",
          "maximum_files" => 16,
          "maximum_bytes" => 500_000,
          "runtime_network" => "none"
        },
        "typed_capi_manifest" => spec.spec_payload["capi_manifest"]
      }
      |> maybe_put_author_feedback(Keyword.get(opts, :author_feedback))

    messages = [
      Message.new(:system, """
      Build one accessible, deterministic, zero-network browser simulation from the supplied
      approved contract. Return JSON only with files, manifest, and capi_manifest. Do not add
      facts, constants, citations, dependencies, dynamic imports, postMessage calls, network or
      storage APIs, learner code execution, inline scripts, inline event handlers, or remote URLs.
      Reference registered library IDs in manifest.library_ids; never include vendor library files.
      Load classic-script registry paths in the registry-provided order before generated scripts.
      Use only the registry-provided static module path for a module import. Do not invent paths.
      Use the exact CAPI manifest. The entrypoint is index.html. Include keyboard-visible focus,
      reduced-motion behavior, mobile layout, text/table alternative, and WebGL fallback required
      by the spec. Model-authored source is limited to 16 files and 500000 bytes.
      """),
      Message.new(
        :user,
        Jason.encode!(builder_contract)
      )
    ]

    messages =
      case Keyword.get(opts, :repair) do
        %{candidate: candidate, findings: findings} ->
          messages ++
            [
              Message.new(:assistant, Jason.encode!(source_contract(candidate))),
              Message.new(
                :user,
                Jason.encode!(%{
                  "required_action" =>
                    "Repair every deterministic validation or independent critic finding. Return the complete replacement bundle.",
                  "findings" => sanitize_repair_findings(findings)
                })
              )
            ]

        _ ->
          messages
      end

    service = Keyword.get(opts, :service) || service()

    service =
      ModelRoutingPolicy.service_config(service, :simulation_bundle_builder,
        first_pass: is_nil(Keyword.get(opts, :repair))
      )

    execution = Keyword.get(opts, :execution_fun, &Execution.generate_with_metadata/4)

    context =
      AIUsageLedger.request_context(opts, :simulation_bundle_builder, %{
        candidate_number: if(is_nil(Keyword.get(opts, :repair)), do: 1, else: 2),
        operation_id: Keyword.get(opts, :operation_id),
        cost_scope: :simulation
      })

    result =
      case Function.info(execution, :arity) do
        {:arity, 3} -> execution.(context, messages, service)
        _ -> execution.(context, messages, [], service)
      end

    with {:ok, %{content: raw, metadata: metadata}} <- result,
         {:ok, decoded} <- Jason.decode(strip_code_fence(raw)),
         true <- is_map(decoded) do
      {:ok, decoded, metadata || %{}}
    else
      false -> {:error, :invalid_provider_response}
      {:error, reason} -> {:error, {:provider_failed, reason}}
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp normalize_bundle(candidate, spec) do
    candidate = stringify(candidate)
    files = candidate["files"]
    manifest = stringify(candidate["manifest"] || %{})
    capi = candidate["capi_manifest"]
    required_capi = spec.spec_payload["capi_manifest"]
    required_ids = spec.spec_payload["library_ids"] |> List.wrap() |> Enum.sort()
    supplied_ids = manifest["library_ids"] |> List.wrap() |> Enum.sort()

    with true <- is_map(files) and map_size(files) > 0,
         true <- manifest["entrypoint"] == "index.html",
         true <- supplied_ids == required_ids,
         {:ok, _ids} <- LibraryRegistry.validate_ids(supplied_ids, three_d_enabled: true),
         true <- no_system_files?(files),
         {:ok, normalized_capi} <- GeneratedSimulation.normalize_capi_manifest(capi),
         {:ok, normalized_required_capi} <-
           GeneratedSimulation.normalize_capi_manifest(required_capi),
         true <- normalized_capi == normalized_required_capi,
         {:ok, _ids} <-
           LibraryRegistry.validate_model_bundle(
             %{files: files, manifest: manifest, capi_manifest: normalized_capi},
             three_d_enabled: true
           ) do
      {:ok,
       %{
         files: files,
         manifest: manifest,
         capi_manifest: normalized_capi
       }}
    else
      false -> {:error, :invalid_generated_bundle_contract}
      {:error, _} = error -> error
      _ -> {:error, :invalid_generated_bundle_contract}
    end
  end

  defp no_system_files?(files) do
    Enum.all?(files, fn {path, contents} ->
      is_binary(path) and is_binary(contents) and
        not String.starts_with?(String.downcase(path), "vendor/") and
        path != "torus-capi-bridge.js"
    end)
  end

  defp source_contract(candidate) when is_map(candidate) do
    candidate
    |> stringify()
    |> Map.take(["files", "manifest", "capi_manifest"])
  end

  defp source_contract(_), do: %{}

  defp maybe_put_author_feedback(contract, feedback)
       when is_binary(feedback) and feedback != "" do
    Map.put(contract, "author_guidance", %{
      "instruction" => String.slice(feedback, 0, 2_000),
      "authority" =>
        "Use this only to refine presentation and interaction. The approved specification and evidence remain authoritative."
    })
  end

  defp maybe_put_author_feedback(contract, _feedback), do: contract

  defp sanitize_repair_findings(findings) do
    findings
    |> List.wrap()
    |> Enum.take(30)
    |> Enum.map(fn
      %{} = finding ->
        finding
        |> stringify()
        |> Map.take([
          "category",
          "code",
          "path",
          "severity",
          "repair",
          "message",
          "details"
        ])
        |> bound_repair_finding()

      finding when is_atom(finding) ->
        %{"code" => Atom.to_string(finding)}

      finding when is_binary(finding) ->
        %{"code" => String.slice(finding, 0, 200)}

      _ ->
        %{"code" => "bundle_validation_failed"}
    end)
  end

  defp bound_repair_finding(finding) do
    Map.new(finding, fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, 1_000)}
      {key, value} when is_map(value) -> {key, bound_repair_details(value)}
      {key, value} -> {key, value}
    end)
  end

  defp bound_repair_details(details) do
    details
    |> Enum.take(20)
    |> Map.new(fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, 500)}
      {key, value} when is_map(value) -> {key, bound_repair_details(value)}
      {key, value} when is_list(value) -> {key, Enum.take(value, 20)}
      entry -> entry
    end)
  end

  defp service do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    model = %RegisteredModel{
      id: -1,
      name: "openstax-simulation-bundle-builder",
      provider: :open_ai,
      model: model_name([]),
      url_template: System.get_env("OPENAI_API_URL") || "https://api.openai.com",
      api_key: api_key,
      secondary_api_key: System.get_env("OPENAI_ORG_KEY"),
      timeout: 30_000,
      recv_timeout: 180_000,
      pool_class: :slow,
      routing_breaker_error_rate_threshold: 0.0,
      routing_breaker_429_threshold: 0.0,
      routing_breaker_latency_p95_ms: 0
    }

    %ServiceConfig{id: -1, name: "openstax-simulation-bundle-builder", primary_model: model}
  end

  defp model_name(opts),
    do:
      Keyword.get(opts, :model) || System.get_env("OPENSTAX_SIMULATION_BUILDER_MODEL") ||
        @default_model

  defp strip_code_fence(content),
    do:
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
