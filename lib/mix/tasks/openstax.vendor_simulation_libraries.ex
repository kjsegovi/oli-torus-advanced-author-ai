defmodule Mix.Tasks.Openstax.VendorSimulationLibraries do
  use Mix.Task

  @shortdoc "Copies audited simulation libraries from assets/node_modules into priv"

  @impl Mix.Task
  def run(_args) do
    root = File.cwd!()
    source_root = Path.join(root, "assets/node_modules")
    target_root = Path.join(root, "priv/openstax_simulation_libraries")

    copies = [
      {"chart.js/dist/chart.umd.js", "chart.js/chart.umd.js"},
      {"d3-array/dist/d3-array.min.js", "d3-array/d3-array.min.js"},
      {"d3-color/dist/d3-color.min.js", "d3-color/d3-color.min.js"},
      {"d3-dispatch/dist/d3-dispatch.min.js", "d3-dispatch/d3-dispatch.min.js"},
      {"d3-drag/dist/d3-drag.min.js", "d3-drag/d3-drag.min.js"},
      {"d3-ease/dist/d3-ease.min.js", "d3-ease/d3-ease.min.js"},
      {"d3-format/dist/d3-format.min.js", "d3-format/d3-format.min.js"},
      {"d3-interpolate/dist/d3-interpolate.min.js", "d3-interpolate/d3-interpolate.min.js"},
      {"d3-path/dist/d3-path.min.js", "d3-path/d3-path.min.js"},
      {"d3-scale/dist/d3-scale.min.js", "d3-scale/d3-scale.min.js"},
      {"d3-selection/dist/d3-selection.min.js", "d3-selection/d3-selection.min.js"},
      {"d3-shape/dist/d3-shape.min.js", "d3-shape/d3-shape.min.js"},
      {"d3-time/dist/d3-time.min.js", "d3-time/d3-time.min.js"},
      {"d3-time-format/dist/d3-time-format.min.js", "d3-time-format/d3-time-format.min.js"},
      {"d3-timer/dist/d3-timer.min.js", "d3-timer/d3-timer.min.js"},
      {"d3-transition/dist/d3-transition.min.js", "d3-transition/d3-transition.min.js"},
      {"d3-zoom/dist/d3-zoom.min.js", "d3-zoom/d3-zoom.min.js"},
      {"three/build/three.module.min.js", "three/three.module.min.js"}
    ]

    Enum.each(copies, fn {source, target} ->
      source = Path.join(source_root, source)
      target = Path.join(target_root, target)

      unless File.regular?(source) do
        Mix.raise("Missing #{source}; run yarn install in assets first")
      end

      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      Mix.shell().info("Vendored #{Path.relative_to_cwd(target)}")
    end)
  end
end
