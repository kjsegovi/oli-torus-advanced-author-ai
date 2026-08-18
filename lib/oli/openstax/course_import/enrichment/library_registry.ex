defmodule Oli.OpenStax.CourseImport.Enrichment.LibraryRegistry do
  @moduledoc """
  Audited system-owned library registry for generated simulation artifacts.

  Models select registry IDs only. Torus reads the vendored files, hashes them,
  and adds them after enforcing the smaller model-authored source limits.
  """

  @model_max_files 16
  @model_max_bytes 500_000
  @final_max_files 32
  @final_max_bytes 4_000_000

  @libraries %{
    "chartjs-4.4.0" => %{
      version: "4.4.0",
      source: "chart.js/chart.umd.js",
      target: "vendor/chartjs-4.4.0.js",
      rendering: :two_d,
      loading: :classic_script
    },
    "d3-scale-4.0.2" => %{
      version: "4.0.2",
      source: "d3-scale/d3-scale.min.js",
      target: "vendor/d3-scale-4.0.2.js",
      rendering: :two_d,
      loading: :classic_script,
      dependencies:
        ~w(d3-array-3.2.4 d3-format-3.1.0 d3-interpolate-3.0.1 d3-time-3.1.0 d3-time-format-4.1.0)
    },
    "d3-selection-3.0.0" => %{
      version: "3.0.0",
      source: "d3-selection/d3-selection.min.js",
      target: "vendor/d3-selection-3.0.0.js",
      rendering: :two_d,
      loading: :classic_script,
      dependencies: []
    },
    "d3-shape-3.2.0" => %{
      version: "3.2.0",
      source: "d3-shape/d3-shape.min.js",
      target: "vendor/d3-shape-3.2.0.js",
      rendering: :two_d,
      loading: :classic_script,
      dependencies: ~w(d3-path-3.1.0)
    },
    "d3-zoom-3.0.0" => %{
      version: "3.0.0",
      source: "d3-zoom/d3-zoom.min.js",
      target: "vendor/d3-zoom-3.0.0.js",
      rendering: :two_d,
      loading: :classic_script,
      dependencies:
        ~w(d3-dispatch-3.0.1 d3-drag-3.0.0 d3-interpolate-3.0.1 d3-selection-3.0.0 d3-transition-3.0.1)
    },
    "three-0.185.1" => %{
      version: "0.185.1",
      source: "three/three.module.min.js",
      target: "vendor/three-0.185.1.module.js",
      rendering: :three_d,
      loading: :static_module_import
    }
  }

  @support_libraries %{
    "d3-array-3.2.4" => %{
      version: "3.2.4",
      source: "d3-array/d3-array.min.js",
      target: "vendor/d3-array-3.2.4.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-color-3.1.0" => %{
      version: "3.1.0",
      source: "d3-color/d3-color.min.js",
      target: "vendor/d3-color-3.1.0.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-dispatch-3.0.1" => %{
      version: "3.0.1",
      source: "d3-dispatch/d3-dispatch.min.js",
      target: "vendor/d3-dispatch-3.0.1.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-drag-3.0.0" => %{
      version: "3.0.0",
      source: "d3-drag/d3-drag.min.js",
      target: "vendor/d3-drag-3.0.0.js",
      rendering: :two_d,
      dependencies: ~w(d3-dispatch-3.0.1 d3-selection-3.0.0)
    },
    "d3-ease-3.0.1" => %{
      version: "3.0.1",
      source: "d3-ease/d3-ease.min.js",
      target: "vendor/d3-ease-3.0.1.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-format-3.1.0" => %{
      version: "3.1.0",
      source: "d3-format/d3-format.min.js",
      target: "vendor/d3-format-3.1.0.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-interpolate-3.0.1" => %{
      version: "3.0.1",
      source: "d3-interpolate/d3-interpolate.min.js",
      target: "vendor/d3-interpolate-3.0.1.js",
      rendering: :two_d,
      dependencies: ~w(d3-color-3.1.0)
    },
    "d3-path-3.1.0" => %{
      version: "3.1.0",
      source: "d3-path/d3-path.min.js",
      target: "vendor/d3-path-3.1.0.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-time-3.1.0" => %{
      version: "3.1.0",
      source: "d3-time/d3-time.min.js",
      target: "vendor/d3-time-3.1.0.js",
      rendering: :two_d,
      dependencies: ~w(d3-array-3.2.4)
    },
    "d3-time-format-4.1.0" => %{
      version: "4.1.0",
      source: "d3-time-format/d3-time-format.min.js",
      target: "vendor/d3-time-format-4.1.0.js",
      rendering: :two_d,
      dependencies: ~w(d3-time-3.1.0)
    },
    "d3-timer-3.0.1" => %{
      version: "3.0.1",
      source: "d3-timer/d3-timer.min.js",
      target: "vendor/d3-timer-3.0.1.js",
      rendering: :two_d,
      dependencies: []
    },
    "d3-transition-3.0.1" => %{
      version: "3.0.1",
      source: "d3-transition/d3-transition.min.js",
      target: "vendor/d3-transition-3.0.1.js",
      rendering: :two_d,
      dependencies:
        ~w(d3-selection-3.0.0 d3-dispatch-3.0.1 d3-timer-3.0.1 d3-interpolate-3.0.1 d3-color-3.1.0 d3-ease-3.0.1)
    }
  }

  @all_libraries Map.merge(@libraries, @support_libraries)

  def ids, do: @libraries |> Map.keys() |> Enum.sort()
  def entries, do: @libraries

  def contract do
    Map.new(@libraries, fn {id, entry} ->
      load_order =
        [id]
        |> dependency_order()
        |> Enum.map(fn dependency_id ->
          dependency = Map.fetch!(@all_libraries, dependency_id)

          %{
            "artifact_path" => dependency.target,
            "loading" => Atom.to_string(Map.get(dependency, :loading, :classic_script))
          }
        end)

      {id,
       %{
         "version" => entry.version,
         "artifact_path" => entry.target,
         "rendering" => Atom.to_string(entry.rendering),
         "loading" => Atom.to_string(entry.loading),
         "load_order" => load_order
       }}
    end)
  end

  @spec validate_ids(term(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_ids(values, opts \\ []) do
    ids = values |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()
    unknown = Enum.reject(ids, &Map.has_key?(@libraries, &1))
    three_d_enabled = Keyword.get(opts, :three_d_enabled, false)

    cond do
      unknown != [] ->
        {:error, {:unknown_simulation_libraries, unknown}}

      not three_d_enabled and Enum.any?(ids, &three_d?/1) ->
        {:error, :three_d_generation_disabled}

      true ->
        {:ok, ids}
    end
  end

  @spec assemble(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def assemble(bundle, opts \\ [])

  def assemble(bundle, opts) when is_map(bundle) do
    files = bundle[:files] || bundle["files"]
    manifest = bundle[:manifest] || bundle["manifest"] || %{}
    library_ids = manifest[:library_ids] || manifest["library_ids"] || []

    with :ok <- validate_model_files(files),
         {:ok, ids} <- validate_ids(library_ids, opts),
         {:ok, system_files, system_manifest} <- load_libraries(ids, opts),
         assembled <- Map.merge(files, system_files),
         :ok <- validate_final_files(assembled) do
      {:ok,
       bundle
       |> Map.put(:files, assembled)
       |> Map.put(:system_library_manifest, system_manifest)
       |> Map.put(
         :manifest,
         manifest
         |> stringify_keys()
         |> Map.put("library_ids", ids)
         |> Map.put("runtime_network", "none")
       )}
    end
  end

  def assemble(_, _), do: {:error, :invalid_bundle}

  @spec validate_model_bundle(map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_model_bundle(bundle, opts \\ [])

  def validate_model_bundle(bundle, opts) when is_map(bundle) do
    files = bundle[:files] || bundle["files"]
    manifest = bundle[:manifest] || bundle["manifest"] || %{}
    library_ids = manifest[:library_ids] || manifest["library_ids"] || []

    with :ok <- validate_model_files(files),
         {:ok, ids} <- validate_ids(library_ids, opts) do
      {:ok, ids}
    end
  end

  def validate_model_bundle(_, _), do: {:error, :invalid_bundle}

  def trusted_file?(path, contents, manifest)
      when is_binary(path) and is_binary(contents) and is_map(manifest) do
    case manifest[path] do
      %{} = identity ->
        id = identity["id"] || identity[:id]
        hash = identity["sha256"] || identity[:sha256]

        case @all_libraries[id] do
          %{target: ^path} -> secure_equal?(hash, sha256(contents))
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def trusted_file?(_, _, _), do: false

  defp load_libraries(ids, opts) do
    root =
      Keyword.get(opts, :library_root) ||
        Application.get_env(
          :oli,
          :openstax_simulation_library_root,
          Path.join(:code.priv_dir(:oli), "openstax_simulation_libraries")
        )

    ids
    |> dependency_order()
    |> Enum.reduce_while({:ok, %{}, %{}}, fn id, {:ok, files, manifest} ->
      entry = Map.fetch!(@all_libraries, id)
      source = Path.join(root, entry.source)

      case File.read(source) do
        {:ok, contents} ->
          identity = %{
            "id" => id,
            "version" => entry.version,
            "sha256" => sha256(contents),
            "system_owned" => true
          }

          {:cont,
           {:ok, Map.put(files, entry.target, contents),
            Map.put(manifest, entry.target, identity)}}

        {:error, _reason} ->
          {:halt, {:error, {:simulation_library_unavailable, id}}}
      end
    end)
  end

  defp validate_model_files(files) when is_map(files) do
    size = total_bytes(files)

    cond do
      map_size(files) == 0 or map_size(files) > @model_max_files ->
        {:error, :model_bundle_file_limit_exceeded}

      size > @model_max_bytes ->
        {:error, :model_bundle_size_limit_exceeded}

      not Enum.all?(files, fn {path, contents} -> is_binary(path) and is_binary(contents) end) ->
        {:error, :invalid_bundle_file}

      true ->
        :ok
    end
  end

  defp validate_model_files(_), do: {:error, :invalid_bundle_files}

  defp validate_final_files(files) do
    cond do
      map_size(files) > @final_max_files -> {:error, :bundle_file_limit_exceeded}
      total_bytes(files) > @final_max_bytes -> {:error, :bundle_size_limit_exceeded}
      true -> :ok
    end
  end

  defp total_bytes(files),
    do: Enum.reduce(files, 0, fn {_path, contents}, total -> total + byte_size(contents) end)

  defp three_d?(id), do: get_in(@libraries, [id, :rendering]) == :three_d

  defp dependency_order(ids) do
    {ordered, _seen} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, accumulator ->
        append_with_dependencies(id, accumulator)
      end)

    ordered
  end

  defp append_with_dependencies(id, {ordered, seen}) do
    if MapSet.member?(seen, id) do
      {ordered, seen}
    else
      entry = Map.fetch!(@all_libraries, id)

      {ordered, seen} =
        Enum.reduce(Map.get(entry, :dependencies, []), {ordered, seen}, fn dependency,
                                                                           accumulator ->
          append_with_dependencies(dependency, accumulator)
        end)

      {ordered ++ [id], MapSet.put(seen, id)}
    end
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when is_binary(left) and byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp stringify_keys(_), do: %{}
end
