defmodule Oli.OpenStax.CourseImport.Enrichment.Sandbox.BrowserContainer do
  @moduledoc """
  Runs static validation followed by the Torus Chromium validation image.

  The browser container has no network namespace, credentials, or writable
  root filesystem. It records screenshots, a DOM snapshot, an accessibility
  report, CAPI sample results, overflow checks, reduced-motion behavior, and a
  no-WebGL fallback result for the artifact critic and author review.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Sandbox

  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.LocalContainer

  @default_image "torus/openstax-simulation-validator:1"
  @max_findings 30
  @max_message_bytes 500

  @impl true
  def available? do
    with true <- LocalContainer.available?(),
         executable when is_binary(executable) <- System.find_executable(runtime()),
         {_output, 0} <-
           System.cmd(executable, ["image", "inspect", image()], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def build_and_validate(bundle, opts) when is_map(bundle) and is_list(opts) do
    with {:ok, statically_validated} <- LocalContainer.build_and_validate(bundle, opts),
         {:ok, browser_payload} <- run_browser(statically_validated.files, bundle, opts) do
      {:ok,
       Map.update!(statically_validated, :validation_payload, fn static_payload ->
         %{
           "status" => "passed",
           "validator" => "browser_container_v1",
           "static" => static_payload,
           "browser" => browser_payload
         }
       end)}
    end
  rescue
    _exception -> {:error, :browser_validation_failed}
  end

  def build_and_validate(_, _), do: {:error, :invalid_input}

  defp run_browser(files, bundle, opts) do
    with true <- available?(),
         {:ok, directory} <- Briefly.create(type: :directory),
         :ok <- write_files(Path.join(directory, "bundle"), files),
         :ok <- File.mkdir_p(Path.join(directory, "results")),
         :ok <- write_contract(directory, bundle, opts),
         :ok <- prepare_permissions(directory) do
      try do
        args = [
          "run",
          "--rm",
          "--pull",
          "never",
          "--network",
          "none",
          "--read-only",
          "--cap-drop",
          "ALL",
          "--security-opt",
          "no-new-privileges",
          "--pids-limit",
          "128",
          "--memory",
          "512m",
          "--cpus",
          "1",
          "--tmpfs",
          "/tmp:rw,noexec,nosuid,size=64m",
          "--mount",
          "type=bind,source=#{directory},target=/work",
          Keyword.get(opts, :browser_image, image()),
          "/work/bundle",
          "/work/contract.json",
          "/work/results"
        ]

        case run_with_timeout(runtime(), args, Keyword.get(opts, :browser_timeout_ms, 30_000)) do
          {:ok, {output, status}} ->
            case read_result(directory) do
              {:error, :browser_result_unavailable} -> execution_failure(status, output)
              result -> result
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.rm_rf(directory)
      end
    else
      false -> {:error, :sandbox_unavailable}
      {:error, _} = error -> error
    end
  end

  defp write_contract(directory, bundle, opts) do
    contract = %{
      "seed" => Keyword.get(opts, :seed, 17_041),
      "sample_cases" => Keyword.get(opts, :sample_cases, []),
      "simulation_spec" => Keyword.get(opts, :simulation_spec, %{}),
      "rendering_mode" => Keyword.get(opts, :rendering_mode, "2d"),
      "capi_manifest" => bundle[:capi_manifest] || bundle["capi_manifest"] || %{}
    }

    File.write(Path.join(directory, "contract.json"), Jason.encode!(contract), [:binary])
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, :ok, fn {path, contents}, :ok ->
      destination = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, contents, [:binary]) do
        {:cont, :ok}
      else
        {:error, _reason} -> {:halt, {:error, :bundle_write_failed}}
      end
    end)
  end

  defp read_result(directory) do
    path = Path.join([directory, "results", "validation.json"])

    with {:ok, contents} <- File.read(path),
         {:ok, payload} <- Jason.decode(contents),
         {:ok, payload} <- attach_critic_artifacts(payload, directory) do
      classify_result(payload)
    else
      _ -> {:error, :browser_result_unavailable}
    end
  end

  @doc false
  def classify_result(payload) when is_map(payload) do
    findings = result_findings(payload)

    if payload["status"] == "passed" and findings == [] do
      {:ok, payload}
    else
      {:error,
       %{
         code: :browser_acceptance_failed,
         stage: :browser_validation,
         retryable: false,
         findings: findings,
         validation_payload: %{
           "status" => "failed",
           "validator" => "browser_container_v1",
           "browser" => compact_browser_payload(payload),
           "findings" => findings
         }
       }}
    end
  end

  def classify_result(_), do: {:error, :browser_result_unavailable}

  defp execution_failure(status, output) do
    message = bounded_message(output)

    finding = %{
      "category" => "container",
      "code" => "browser_validator_process_failed",
      "message" => "Browser validator exited before producing a result.",
      "details" => %{"exit_status" => status, "output" => message}
    }

    {:error,
     %{
       code: :browser_validator_process_failed,
       stage: :browser_validation,
       retryable: false,
       findings: [finding],
       validation_payload: %{
         "status" => "failed",
         "validator" => "browser_container_v1",
         "findings" => [finding]
       }
     }}
  end

  defp result_findings(payload) do
    []
    |> add_message_findings(
      payload["network_requests"] |> List.wrap() |> Enum.map(&sanitized_url/1),
      "network",
      "network_request",
      fn url -> %{"url" => url} end
    )
    |> add_message_findings(payload["console_errors"], "console", "console_error")
    |> add_message_findings(payload["page_errors"], "page", "page_error")
    |> add_failed_check(
      payload["capi_handshake"] == "passed",
      "capi",
      "capi_handshake_failed",
      %{"observed" => payload["capi_handshake"]}
    )
    |> add_sample_findings(payload)
    |> add_failed_check(
      payload["keyboard"] == "passed",
      "keyboard",
      "keyboard_path_failed",
      %{"observed" => payload["keyboard"]}
    )
    |> add_failed_check(
      payload["focus_visible"] == true,
      "focus",
      "focus_not_visible",
      %{"observed" => payload["focus_visible"]}
    )
    |> add_a11y_findings(payload)
    |> add_failed_check(
      payload["desktop_overflow"] == false,
      "overflow",
      "desktop_overflow",
      %{"viewport" => "desktop", "observed" => payload["desktop_overflow"]}
    )
    |> add_failed_check(
      payload["mobile_overflow"] == false,
      "overflow",
      "mobile_overflow",
      %{"viewport" => "mobile", "observed" => payload["mobile_overflow"]}
    )
    |> add_failed_check(
      payload["reduced_motion"] == "passed",
      "motion",
      "reduced_motion_failed",
      %{"observed" => payload["reduced_motion"]}
    )
    |> add_failed_check(
      payload["webgl_fallback"] == "passed",
      "webgl",
      "webgl_fallback_failed",
      %{"observed" => payload["webgl_fallback"]}
    )
    |> maybe_add_runtime_failure(payload["failure"])
    |> Enum.take(@max_findings)
  end

  defp add_message_findings(findings, values, category, code, details_fun \\ fn _ -> %{} end) do
    values
    |> List.wrap()
    |> Enum.take(10)
    |> Enum.reduce(findings, fn value, acc ->
      acc ++
        [
          %{
            "category" => category,
            "code" => code,
            "message" => bounded_message(value),
            "details" => bounded_value(details_fun.(value))
          }
        ]
    end)
  end

  defp add_failed_check(findings, true, _category, _code, _details), do: findings

  defp add_failed_check(findings, false, category, code, details) do
    findings ++
      [
        %{
          "category" => category,
          "code" => code,
          "message" => String.replace(code, "_", " "),
          "details" => bounded_value(details)
        }
      ]
  end

  defp add_sample_findings(findings, payload) do
    failed =
      payload["sample_results"]
      |> List.wrap()
      |> Enum.filter(&(&1["passed"] != true))
      |> Enum.take(10)

    findings =
      Enum.reduce(failed, findings, fn sample, acc ->
        acc ++
          [
            %{
              "category" => "sample",
              "code" => "capi_sample_failed",
              "message" => "CAPI sample case did not match the approved expectation.",
              "details" =>
                bounded_value(%{
                  "sample_index" => sample["index"],
                  "expected" => sample["expected"],
                  "actual" => sample["actual"],
                  "tolerance" => sample["tolerance"]
                })
            }
          ]
      end)

    add_failed_check(
      findings,
      payload["sample_cases_passed"] == true or failed != [],
      "sample",
      "capi_sample_contract_failed",
      %{"observed" => payload["sample_cases_passed"]}
    )
  end

  defp add_a11y_findings(findings, payload) do
    detailed = payload["a11y_findings"] |> List.wrap() |> Enum.take(10)

    if detailed == [] do
      add_failed_check(
        findings,
        payload["serious_or_critical_a11y"] == 0,
        "accessibility",
        "serious_or_critical_accessibility_findings",
        %{"count" => payload["serious_or_critical_a11y"]}
      )
    else
      Enum.reduce(detailed, findings, fn item, acc ->
        acc ++
          [
            %{
              "category" => "accessibility",
              "code" => "axe_#{bounded_identifier(item["id"])}",
              "severity" => bounded_identifier(item["impact"]),
              "message" => bounded_message(item["help"]),
              "details" => bounded_value(Map.take(item, ["node_count", "targets"]))
            }
          ]
      end)
    end
  end

  defp maybe_add_runtime_failure(findings, failure) when is_binary(failure) and failure != "" do
    findings ++
      [
        %{
          "category" => "runtime",
          "code" => "browser_runtime_failed",
          "message" => bounded_message(failure),
          "details" => %{}
        }
      ]
  end

  defp maybe_add_runtime_failure(findings, _failure), do: findings

  defp compact_browser_payload(payload) do
    payload
    |> Map.take([
      "status",
      "seed",
      "network_requests",
      "console_errors",
      "page_errors",
      "capi_handshake",
      "sample_cases_passed",
      "sample_results",
      "keyboard",
      "focus_visible",
      "serious_or_critical_a11y",
      "a11y_findings",
      "desktop_overflow",
      "mobile_overflow",
      "reduced_motion",
      "webgl_fallback",
      "failure"
    ])
    |> bounded_value()
  end

  defp bounded_value(value) when is_map(value) do
    value
    |> Enum.take(30)
    |> Map.new(fn {key, item} -> {bounded_identifier(key), bounded_value(item)} end)
  end

  defp bounded_value(value) when is_list(value),
    do: value |> Enum.take(30) |> Enum.map(&bounded_value/1)

  defp bounded_value(value) when is_binary(value), do: bounded_message(value)
  defp bounded_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp bounded_value(value), do: bounded_message(inspect(value))

  defp bounded_identifier(value), do: value |> to_string() |> String.slice(0, 100)

  defp bounded_message(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n\t]+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_message_bytes)
  end

  defp sanitized_url(value) do
    case URI.parse(to_string(value)) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        %{uri | userinfo: nil, query: nil, fragment: nil}
        |> URI.to_string()
        |> bounded_message()

      _ ->
        "invalid-url"
    end
  end

  defp attach_critic_artifacts(payload, directory) do
    screenshots =
      payload
      |> Map.get("screenshots", [])
      |> Enum.flat_map(fn filename ->
        path = Path.join([directory, "results", filename])

        case File.read(path) do
          {:ok, contents} when byte_size(contents) <= 1_500_000 ->
            [
              %{
                "name" => filename,
                "mime_type" => "image/png",
                "data_base64" => Base.encode64(contents),
                "sha256" => sha256(contents)
              }
            ]

          _ ->
            []
        end
      end)

    traces =
      payload
      |> Map.get("traces", [])
      |> Enum.flat_map(fn filename ->
        path = Path.join([directory, "results", filename])

        case File.read(path) do
          {:ok, contents} when byte_size(contents) <= 250_000 ->
            [%{"name" => filename, "content" => contents, "sha256" => sha256(contents)}]

          _ ->
            []
        end
      end)

    {:ok,
     Map.put(payload, "critic_artifacts", %{
       "screenshots" => screenshots,
       "traces" => traces
     })}
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp prepare_permissions(directory) do
    bundle = Path.join(directory, "bundle")
    results = Path.join(directory, "results")

    with :ok <- File.chmod(directory, 0o755),
         :ok <- File.chmod(bundle, 0o755),
         :ok <- File.chmod(results, 0o777),
         :ok <- File.chmod(Path.join(directory, "contract.json"), 0o444) do
      bundle
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reduce_while(:ok, fn path, :ok ->
        mode = if File.dir?(path), do: 0o555, else: 0o444

        case File.chmod(path, mode) do
          :ok -> {:cont, :ok}
          {:error, _reason} -> {:halt, {:error, :bundle_permission_failed}}
        end
      end)
    end
  end

  defp run_with_timeout(executable, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(executable, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :sandbox_timeout}
      {:exit, _reason} -> {:error, :sandbox_failed}
    end
  end

  defp runtime,
    do: Application.get_env(:oli, :openstax_enrichment_container_runtime, "docker")

  defp image,
    do: Application.get_env(:oli, :openstax_enrichment_browser_image, @default_image)
end
