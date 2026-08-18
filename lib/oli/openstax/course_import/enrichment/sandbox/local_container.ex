defmodule Oli.OpenStax.CourseImport.Enrichment.Sandbox.LocalContainer do
  @moduledoc """
  Validates assembled simulation bundles in a disposable local container.

  The container receives a read-only bundle mount, no network, no credentials,
  no Linux capabilities, a read-only root filesystem, and bounded CPU, memory,
  process, and temporary-storage resources. Static validation runs before the
  container starts so prohibited browser APIs and unsafe resource references
  never reach artifact storage.
  """

  @behaviour Oli.OpenStax.CourseImport.Enrichment.Sandbox

  alias Oli.OpenStax.CourseImport.Enrichment.LibraryRegistry
  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.CapiBridge

  @default_image "torus/openstax-simulation-validator:1"
  @max_files 32
  @max_file_bytes 2_000_000
  @max_bundle_bytes 4_000_000
  @allowed_extensions ~w(.html .css .js .json .svg)
  @required_csp_directives %{
    "default-src" => ["'none'"],
    "connect-src" => ["'none'"],
    "object-src" => ["'none'"],
    "form-action" => ["'none'"],
    "base-uri" => ["'none'"],
    "frame-src" => ["'none'"],
    "worker-src" => ["'none'"]
  }
  @allowed_csp_directives %{
    "default-src" => MapSet.new(["'none'"]),
    "connect-src" => MapSet.new(["'none'"]),
    "object-src" => MapSet.new(["'none'"]),
    "form-action" => MapSet.new(["'none'"]),
    "base-uri" => MapSet.new(["'none'"]),
    "frame-src" => MapSet.new(["'none'"]),
    "worker-src" => MapSet.new(["'none'"]),
    "script-src" => MapSet.new(["'self'"]),
    "style-src" => MapSet.new(["'self'", "'unsafe-inline'"]),
    "img-src" => MapSet.new(["'self'"]),
    "font-src" => MapSet.new(["'none'", "'self'"]),
    "media-src" => MapSet.new(["'none'", "'self'"]),
    "manifest-src" => MapSet.new(["'none'", "'self'"])
  }
  @prohibited_javascript [
    ~r/\bfetch\s*\(/i,
    ~r/\bXMLHttpRequest\b/i,
    ~r/\bWebSocket\b/i,
    ~r/\bEventSource\b/i,
    ~r/\bsendBeacon\b/i,
    ~r/\bserviceWorker\b/i,
    ~r/\bSharedWorker\b/i,
    ~r/\bWorker\s*\(/i,
    ~r/\beval\s*\(/i,
    ~r/\bFunction\s*\(/i,
    ~r/\bdocument\.cookie\b/i,
    ~r/\blocalStorage\b/i,
    ~r/\bsessionStorage\b/i,
    ~r/\bindexedDB\b/i,
    ~r/(?:\b(?:window|document|self|top|parent)\s*\.\s*)?\blocation\b/i,
    ~r/\bhistory\s*\.\s*(?:pushState|replaceState)\s*\(/i,
    ~r/\b(?:window\s*\.\s*)?open\s*\(/i,
    ~r/\.\s*href\s*=/i,
    ~r/\bcreateElement\s*\(/i,
    ~r/\bdocument\s*\.\s*write(?:ln)?\s*\(/i,
    ~r/\bpostMessage\s*\(/i,
    ~r/\bimport\s*\(/i
  ]

  @impl true
  def available? do
    with executable when is_binary(executable) <- System.find_executable(runtime()),
         {:ok, {_output, 0}} <-
           run_with_timeout(executable, ["info", "--format", "{{.ServerVersion}}"], 2_000),
         {:ok, {_output, 0}} <-
           run_with_timeout(executable, ["image", "inspect", image()], 2_000) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def build_and_validate(bundle, opts) when is_map(bundle) and is_list(opts) do
    with {:ok, files} <- normalize_files(bundle),
         {:ok, files, capi_manifest} <-
           CapiBridge.prepare(files, bundle[:capi_manifest] || bundle["capi_manifest"]),
         system_manifest <-
           bundle[:system_library_manifest] || bundle["system_library_manifest"] || %{},
         :ok <- validate_file_set(files),
         :ok <- validate_system_libraries(files, system_manifest),
         {:ok, document} <- validate_html(files),
         :ok <- validate_javascript(files, capi_manifest, system_manifest),
         :ok <- validate_stylesheets(files),
         {:ok, accessibility} <- accessibility_metadata(document),
         {:ok, validation_payload} <- run_disposable_container(files, opts) do
      content_hash = content_hash(files)

      {:ok,
       %{
         files: files,
         content_hash: content_hash,
         byte_size:
           Enum.reduce(files, 0, fn {_path, contents}, total -> total + byte_size(contents) end),
         bundle_manifest: %{
           "entrypoint" => "index.html",
           "files" => files |> Map.keys() |> Enum.sort(),
           "content_hash" => content_hash,
           "library_ids" =>
             bundle
             |> then(&(&1[:manifest] || &1["manifest"] || %{}))
             |> then(&(&1[:library_ids] || &1["library_ids"] || [])),
           "system_libraries" => system_manifest,
           "runtime_network" => "none"
         },
         validation_payload: validation_payload,
         accessibility_metadata: accessibility,
         capi_manifest: capi_manifest
       }}
    end
  rescue
    _exception -> {:error, :sandbox_validation_failed}
  end

  def build_and_validate(_, _), do: {:error, :invalid_input}

  defp normalize_files(bundle) do
    case bundle[:files] || bundle["files"] do
      files when is_map(files) ->
        normalized =
          Map.new(files, fn
            {path, contents} when is_binary(path) and is_binary(contents) ->
              {String.trim(path), contents}

            {path, _contents} ->
              {to_string(path), :invalid}
          end)

        if Enum.all?(normalized, fn {_path, contents} -> is_binary(contents) end),
          do: {:ok, normalized},
          else: {:error, :invalid_bundle_file}

      _ ->
        {:error, :invalid_bundle_files}
    end
  end

  defp validate_file_set(files) do
    total_bytes = Enum.reduce(files, 0, fn {_path, value}, total -> total + byte_size(value) end)

    cond do
      map_size(files) == 0 or map_size(files) > @max_files ->
        {:error, :bundle_file_limit_exceeded}

      not Map.has_key?(files, "index.html") ->
        {:error, :missing_simulation_entrypoint}

      total_bytes > @max_bundle_bytes ->
        {:error, :bundle_size_limit_exceeded}

      Enum.any?(files, fn {path, contents} ->
        not safe_relative_path?(path) or Path.extname(path) not in @allowed_extensions or
            byte_size(contents) > @max_file_bytes
      end) ->
        {:error, :invalid_bundle_file}

      true ->
        :ok
    end
  end

  defp validate_html(files) do
    with {:ok, document} <- Floki.parse_document(files["index.html"]),
         :ok <- require_single_present(document, "html[lang]", :missing_document_language),
         :ok <- require_single_present(document, "head title", :missing_accessible_title),
         :ok <- require_meta(document, "description", :missing_accessible_description),
         :ok <- require_meta(document, "viewport", :missing_responsive_viewport),
         :ok <- validate_content_security_policy(document),
         :ok <- reject_prohibited_elements(document),
         :ok <- reject_inline_event_handlers(document),
         :ok <- validate_resource_references(document),
         :ok <- validate_script_elements(document, files),
         :ok <- validate_images(document),
         :ok <- validate_controls(document) do
      {:ok, document}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_simulation_html}
    end
  end

  defp require_single_present(document, selector, error) do
    case Floki.find(document, selector) do
      [node] ->
        if present_text?(Floki.text(node)) or selector == "html[lang]",
          do: :ok,
          else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp require_meta(document, name, error) do
    document
    |> Floki.find("meta[name='#{name}']")
    |> Enum.any?(fn node -> present_text?(Floki.attribute(node, "content") |> List.first()) end)
    |> if(do: :ok, else: {:error, error})
  end

  defp validate_content_security_policy(document) do
    with {:ok, policy} <- early_head_csp(document),
         {:ok, directives} <- parse_csp(policy),
         true <- required_csp_directives?(directives),
         true <- allowed_csp_directives?(directives),
         true <- script_policy_matches_document?(directives, document) do
      :ok
    else
      _ -> {:error, :unsafe_content_security_policy}
    end
  end

  defp early_head_csp(document) do
    all_csp_nodes =
      document
      |> Floki.find("meta[http-equiv]")
      |> Enum.filter(&csp_meta?/1)

    with [csp_node] <- all_csp_nodes,
         [{"head", _attributes, children}] <- Floki.find(document, "head"),
         csp_index when is_integer(csp_index) <- Enum.find_index(children, &(&1 == csp_node)),
         first_active_index <- Enum.find_index(children, &active_head_node?/1),
         true <- is_nil(first_active_index) or csp_index < first_active_index,
         policy when is_binary(policy) <-
           csp_node |> Floki.attribute("content") |> List.first() do
      {:ok, policy}
    else
      _ -> {:error, :unsafe_content_security_policy}
    end
  end

  defp csp_meta?(node) do
    node
    |> Floki.attribute("http-equiv")
    |> List.first()
    |> to_string()
    |> String.downcase() == "content-security-policy"
  end

  defp active_head_node?({tag, _attributes, _children})
       when tag in ["script", "style", "link", "img", "object", "embed", "iframe"],
       do: true

  defp active_head_node?(_node), do: false

  defp parse_csp(policy) do
    policy
    |> String.downcase()
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn raw_directive, {:ok, directives} ->
      case String.split(String.trim(raw_directive), ~r/\s+/, trim: true) do
        [name | sources] when sources != [] ->
          if Map.has_key?(directives, name) do
            {:halt, {:error, :duplicate_csp_directive}}
          else
            {:cont, {:ok, Map.put(directives, name, sources)}}
          end

        _ ->
          {:halt, {:error, :invalid_csp_directive}}
      end
    end)
  end

  defp required_csp_directives?(directives) do
    Enum.all?(@required_csp_directives, fn {name, sources} ->
      Map.get(directives, name) == sources
    end)
  end

  defp allowed_csp_directives?(directives) do
    Enum.all?(directives, fn {name, sources} ->
      case Map.fetch(@allowed_csp_directives, name) do
        {:ok, allowed} -> MapSet.subset?(MapSet.new(sources), allowed)
        :error -> false
      end
    end)
  end

  defp script_policy_matches_document?(directives, document) do
    if Floki.find(document, "script") == [] do
      true
    else
      Map.get(directives, "script-src") == ["'self'"]
    end
  end

  defp reject_prohibited_elements(document) do
    meta_refresh? =
      document
      |> Floki.find("meta[http-equiv]")
      |> Enum.any?(fn node ->
        node
        |> Floki.attribute("http-equiv")
        |> List.first()
        |> to_string()
        |> String.downcase() == "refresh"
      end)

    if Floki.find(document, "iframe, object, embed, form, base") == [] and not meta_refresh?,
      do: :ok,
      else: {:error, :prohibited_html_element}
  end

  defp reject_inline_event_handlers(document) do
    event_handler? =
      document
      |> Floki.find("*")
      |> Enum.any?(fn {_tag, attributes, _children} ->
        Enum.any?(attributes, fn {name, _value} ->
          name |> String.downcase() |> String.starts_with?("on")
        end)
      end)

    if event_handler?, do: {:error, :inline_script_forbidden}, else: :ok
  end

  defp validate_script_elements(document, files) do
    valid? =
      Enum.all?(Floki.find(document, "script"), fn script ->
        src = script |> Floki.attribute("src") |> List.first()

        present_text?(src) and String.trim(Floki.text(script)) == "" and
          safe_relative_path?(src) and Path.extname(src) == ".js" and Map.has_key?(files, src)
      end)

    if valid?, do: :ok, else: {:error, :inline_script_forbidden}
  end

  defp validate_resource_references(document) do
    unsafe? =
      document
      |> Floki.find("[src], [href]")
      |> Enum.any?(fn node ->
        ["src", "href"]
        |> Enum.flat_map(&Floki.attribute(node, &1))
        |> Enum.any?(&unsafe_resource_reference?/1)
      end)

    if unsafe?, do: {:error, :external_resource_reference}, else: :ok
  end

  defp unsafe_resource_reference?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    normalized != "" and not String.starts_with?(normalized, "#") and
      (String.starts_with?(normalized, [
         "http:",
         "https:",
         "//",
         "javascript:",
         "data:",
         "blob:"
       ]) or
         not safe_relative_path?(normalized))
  end

  defp unsafe_resource_reference?(_), do: true

  defp validate_images(document) do
    if Enum.all?(Floki.find(document, "img"), &(Floki.attribute(&1, "alt") != [])),
      do: :ok,
      else: {:error, :image_alt_text_missing}
  end

  defp validate_controls(document) do
    labels =
      document
      |> Floki.find("label[for]")
      |> Enum.flat_map(&Floki.attribute(&1, "for"))
      |> MapSet.new()

    buttons_valid? =
      Enum.all?(Floki.find(document, "button"), fn button ->
        present_text?(Floki.text(button)) or present_attribute?(button, "aria-label") or
          present_attribute?(button, "title")
      end)

    inputs_valid? =
      Enum.all?(Floki.find(document, "input, select, textarea"), fn control ->
        id = Floki.attribute(control, "id") |> List.first()

        present_attribute?(control, "aria-label") or
          present_attribute?(control, "aria-labelledby") or
          (present_text?(id) and MapSet.member?(labels, id))
      end)

    if buttons_valid? and inputs_valid?, do: :ok, else: {:error, :control_name_missing}
  end

  defp validate_system_libraries(files, manifest) when is_map(manifest) do
    vendor_files = files |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "vendor/"))

    valid? =
      map_size(manifest) == length(vendor_files) and
        Enum.all?(vendor_files, fn path ->
          LibraryRegistry.trusted_file?(path, files[path], manifest)
        end) and
        Enum.all?(manifest, fn {path, _identity} ->
          is_binary(path) and Map.has_key?(files, path) and String.starts_with?(path, "vendor/")
        end)

    if valid?, do: :ok, else: {:error, :untrusted_system_library}
  end

  defp validate_system_libraries(_files, _manifest),
    do: {:error, :untrusted_system_library}

  defp validate_javascript(files, capi_manifest, system_manifest) do
    javascript =
      files
      |> Enum.reject(fn {path, contents} ->
        CapiBridge.trusted_file?(path, contents, capi_manifest) or
          LibraryRegistry.trusted_file?(path, contents, system_manifest)
      end)
      |> Enum.filter(fn {path, _contents} -> Path.extname(path) == ".js" end)
      |> Enum.map_join("\n", &elem(&1, 1))

    if Enum.any?(@prohibited_javascript, &Regex.match?(&1, javascript)),
      do: {:error, :prohibited_browser_api},
      else: :ok
  end

  defp validate_stylesheets(files) do
    unsafe? =
      files
      |> Enum.filter(fn {path, _contents} -> Path.extname(path) in [".css", ".html"] end)
      |> Enum.any?(fn {_path, contents} ->
        Regex.match?(~r/@import\b|url\s*\(\s*["']?(?:https?:|\/\/|data:text\/html)/i, contents)
      end)

    if unsafe?, do: {:error, :unsafe_stylesheet_resource}, else: :ok
  end

  defp accessibility_metadata(document) do
    title = document |> Floki.find("head title") |> Floki.text() |> String.trim()

    description =
      document
      |> Floki.find("meta[name='description']")
      |> List.first()
      |> case do
        nil -> nil
        node -> node |> Floki.attribute("content") |> List.first()
      end

    if present_text?(title) and present_text?(description),
      do: {:ok, %{"title" => title, "description" => String.trim(description)}},
      else: {:error, :accessibility_metadata_missing}
  end

  defp run_disposable_container(files, opts) do
    with true <- available?(),
         {:ok, directory} <- Briefly.create(type: :directory),
         :ok <- write_bundle(directory, files) do
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
          "64",
          "--memory",
          "512m",
          "--cpus",
          "1",
          "--tmpfs",
          "/tmp:rw,noexec,nosuid,size=16m",
          "--mount",
          "type=bind,source=#{directory},target=/bundle,readonly",
          "--entrypoint",
          "sh",
          Keyword.get(opts, :image, image()),
          "-eu",
          "-c",
          "test -f /bundle/index.html; test \"$(find /bundle -type f | wc -l)\" -le #{@max_files}; test -z \"$(find /bundle -type l -print -quit)\"; find /bundle -type f -name '*.js' -exec node --check {} ';'"
        ]

        case run_with_timeout(runtime(), args, Keyword.get(opts, :timeout_ms, 30_000)) do
          {:ok, {_output, 0}} ->
            {:ok,
             %{
               "status" => "passed",
               "validator" => "local_container_v2",
               "network" => "none",
               "resource_limits" => %{
                 "memory" => "512m",
                 "cpus" => "1",
                 "pids" => 64
               },
               "checks" => [
                 "structure",
                 "content_security_policy",
                 "accessibility_metadata",
                 "responsive_viewport",
                 "javascript_syntax",
                 "resource_limits",
                 "prohibited_apis"
               ]
             }}

          {:ok, {_output, _status}} ->
            {:error, :sandbox_build_failed}

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

  defp write_bundle(directory, files) do
    Enum.reduce_while(files, :ok, fn {path, contents}, :ok ->
      destination = Path.join(directory, path)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.write(destination, contents, [:binary]) do
        {:cont, :ok}
      else
        {:error, _reason} -> {:halt, {:error, :bundle_write_failed}}
      end
    end)
  end

  defp run_with_timeout(executable, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(executable, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :sandbox_timeout}
      {:exit, _reason} -> {:error, :sandbox_failed}
    end
  end

  defp content_hash(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn {path, contents} -> path <> <<0>> <> contents <> <<0>> end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_relative_path?(path) when is_binary(path) do
    normalized = path |> Path.expand("/bundle") |> Path.relative_to("/bundle")

    path != "" and Path.type(path) != :absolute and path == normalized and
      not String.contains?(path, ["\\", <<0>>])
  end

  defp safe_relative_path?(_), do: false

  defp present_attribute?(node, attribute) do
    node |> Floki.attribute(attribute) |> List.first() |> present_text?()
  end

  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp runtime,
    do: Application.get_env(:oli, :openstax_enrichment_container_runtime, "docker")

  defp image,
    do: Application.get_env(:oli, :openstax_enrichment_sandbox_image, @default_image)
end
