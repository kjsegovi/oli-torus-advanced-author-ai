defmodule Oli.OpenStax.CourseImport.ImportContract do
  @moduledoc """
  The single executable OpenStax importer contract.

  Persisted historical runs remain readable, but only the current contract can
  start, resume, regenerate, approve, compile, or apply content.
  """

  @source_schema_version 4
  @plan_schema_version 7
  @content_schema_version 7
  @planning_strategy :parallel_v1
  @prompt_bundle_version "openstax-v7-2026-08-19"
  @quality_policy_version "openstax-v7-quality-1"

  @type contract :: %{
          source_schema_version: pos_integer(),
          plan_schema_version: pos_integer(),
          basic_content_schema_version: pos_integer(),
          advanced_content_schema_version: pos_integer(),
          planning_strategy: atom(),
          prompt_bundle_version: String.t(),
          quality_policy_version: String.t()
        }

  @spec current() :: contract()
  def current do
    %{
      source_schema_version: @source_schema_version,
      plan_schema_version: @plan_schema_version,
      basic_content_schema_version: @content_schema_version,
      advanced_content_schema_version: @content_schema_version,
      planning_strategy: @planning_strategy,
      prompt_bundle_version: @prompt_bundle_version,
      quality_policy_version: @quality_policy_version
    }
  end

  def source_schema_version, do: @source_schema_version
  def plan_schema_version, do: @plan_schema_version
  def content_schema_version(_mode), do: @content_schema_version
  def planning_strategy, do: @planning_strategy
  def prompt_bundle_version, do: @prompt_bundle_version
  def quality_policy_version, do: @quality_policy_version

  @spec current_run?(map()) :: boolean()
  def current_run?(run) when is_map(run) do
    source = Map.get(run, :source_schema_version) || Map.get(run, "source_schema_version")
    plan = Map.get(run, :plan_schema_version) || Map.get(run, "plan_schema_version")
    strategy = Map.get(run, :lesson_planning_strategy) || Map.get(run, "lesson_planning_strategy")

    source == @source_schema_version and plan == @plan_schema_version and
      strategy in [@planning_strategy, Atom.to_string(@planning_strategy)]
  end

  def current_run?(_run), do: false

  @spec ensure_current_run(map()) :: :ok | {:error, tuple()}
  def ensure_current_run(run) do
    if current_run?(run) do
      :ok
    else
      source = map_value(run, :source_schema_version)
      plan = map_value(run, :plan_schema_version)

      {:error,
       {:unsupported_openstax_schema_contract, source, plan, :historical_run_is_read_only}}
    end
  end

  @spec current_content?(map()) :: boolean()
  def current_content?(content) when is_map(content) do
    mode = Map.get(content, "authoring_mode") || Map.get(content, :authoring_mode)
    version = Map.get(content, "schema_version") || Map.get(content, :schema_version)
    mode in ["basic", "advanced"] and version == @content_schema_version
  end

  def current_content?(_content), do: false

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_map, _key), do: nil
end
