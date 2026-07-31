defmodule Oli.GoogleSlides.AI.ImportPlan do
  @moduledoc """
  Compatibility envelope for one or many Google Slides lesson plans.

  Legacy single-plan values remain valid and are returned unchanged. A split
  import uses a versioned `google_slides_lesson_plan_set` envelope containing
  two to ten independently valid lesson plans.
  """

  alias Oli.GoogleSlides.AI.LessonPlan

  @kind "google_slides_lesson_plan_set"
  @schema_version 1
  @max_lessons 10
  @max_screens 150
  @max_parts 600
  @max_interactions 150
  @max_bytes 1_500_000

  @type t :: map()

  @spec lessons(map() | nil) :: [map()]
  def lessons(nil), do: []
  def lessons(%{"kind" => @kind, "lessons" => lessons}) when is_list(lessons), do: lessons
  def lessons(%{} = legacy_plan), do: [legacy_plan]
  def lessons(_value), do: []

  @spec multi?(map() | nil) :: boolean()
  def multi?(%{"kind" => @kind}), do: true
  def multi?(_plan), do: false

  @spec new_set([map()]) :: {:ok, t()} | {:error, [map()]}
  def new_set(plans) when is_list(plans) do
    validate(%{
      "schemaVersion" => @schema_version,
      "kind" => @kind,
      "lessons" => plans
    })
  end

  def new_set(_plans), do: {:error, [error("lessons", "invalid_type", "lessons must be a list")]}

  @spec validate(map(), keyword()) :: {:ok, map()} | {:error, [map()]}
  def validate(plan, opts \\ [])

  def validate(%{"kind" => @kind} = envelope, opts) do
    mode = Keyword.get(opts, :mode, :draft)
    plans = envelope["lessons"]

    errors =
      []
      |> require_version(envelope["schemaVersion"])
      |> require_lesson_count(plans)
      |> validate_lessons(plans, mode)
      |> validate_global_keys(plans)
      |> validate_totals(plans)
      |> validate_envelope_size(envelope)
      |> Enum.reverse()

    case errors do
      [] ->
        {:ok,
         %{
           "schemaVersion" => @schema_version,
           "kind" => @kind,
           "lessons" => Enum.map(plans, &normalize_lesson!/1)
         }}

      errors ->
        {:error, errors}
    end
  end

  def validate(%{} = legacy_plan, opts), do: LessonPlan.validate(legacy_plan, opts)

  def validate(_plan, _opts),
    do: {:error, [error("$", "invalid_type", "import plan must be an object")]}

  @spec finalize(map()) :: {:ok, map()} | {:error, [map()]}
  def finalize(%{"kind" => @kind} = envelope) do
    finalized =
      envelope
      |> lessons()
      |> Enum.map(&LessonPlan.finalize/1)

    case Enum.find(finalized, &match?({:error, _}, &1)) do
      nil ->
        plans = Enum.map(finalized, fn {:ok, plan} -> plan end)
        new_set(plans)

      {:error, errors} ->
        {:error, errors}
    end
  end

  def finalize(%{} = legacy_plan), do: LessonPlan.finalize(legacy_plan)

  @spec map_lessons(map(), (map(), non_neg_integer() -> map())) :: map()
  def map_lessons(%{"kind" => @kind} = envelope, fun) when is_function(fun, 2) do
    Map.update!(envelope, "lessons", fn plans ->
      plans
      |> Enum.with_index()
      |> Enum.map(fn {plan, index} -> fun.(plan, index) end)
    end)
  end

  def map_lessons(%{} = legacy_plan, fun) when is_function(fun, 2), do: fun.(legacy_plan, 0)

  @spec replace_lesson(map() | nil, non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def replace_lesson(nil, 0, plan), do: {:ok, plan}

  def replace_lesson(%{"kind" => @kind} = envelope, index, plan)
      when is_integer(index) and index >= 0 do
    plans = envelope["lessons"] || []

    if index < length(plans) do
      {:ok, Map.put(envelope, "lessons", List.replace_at(plans, index, plan))}
    else
      {:error, :lesson_index_out_of_range}
    end
  end

  def replace_lesson(%{} = _legacy_plan, 0, plan), do: {:ok, plan}
  def replace_lesson(_envelope, _index, _plan), do: {:error, :lesson_index_out_of_range}

  defp require_version(errors, @schema_version), do: errors

  defp require_version(errors, _version),
    do: [
      error("schemaVersion", "unsupported_version", "unsupported import-plan version") | errors
    ]

  defp require_lesson_count(errors, plans)
       when is_list(plans) and length(plans) >= 2 and length(plans) <= @max_lessons,
       do: errors

  defp require_lesson_count(errors, _plans) do
    [
      error("lessons", "invalid_count", "a split import must contain two to ten lessons")
      | errors
    ]
  end

  defp validate_lessons(errors, plans, mode) when is_list(plans) do
    plans
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {plan, index}, acc ->
      case LessonPlan.validate(plan, mode: mode) do
        {:ok, _plan} ->
          acc

        {:error, plan_errors} ->
          Enum.reduce(plan_errors, acc, fn plan_error, nested ->
            [
              Map.update(plan_error, "path", "lessons[#{index}]", &"lessons[#{index}].#{&1}")
              | nested
            ]
          end)
      end
    end)
  end

  defp validate_lessons(errors, _plans, _mode), do: errors

  defp validate_global_keys(errors, plans) when is_list(plans) do
    lesson_keys = Enum.map(plans, &get_in(&1, ["lesson", "key"]))

    screen_keys =
      Enum.flat_map(plans, fn plan ->
        plan
        |> get_in(["lesson", "screens"])
        |> List.wrap()
        |> Enum.map(& &1["key"])
      end)

    variable_keys =
      Enum.flat_map(plans, fn plan ->
        Enum.map(plan["variables"] || [], & &1["key"])
      end)

    pathway_keys =
      Enum.flat_map(plans, fn plan ->
        plan
        |> get_in(["lesson", "screens"])
        |> List.wrap()
        |> Enum.flat_map(fn screen ->
          Enum.map(screen["adaptivity"] || [], & &1["key"])
        end)
      end)

    errors
    |> duplicate_key_error(lesson_keys, "lessons", "lesson keys must be unique")
    |> duplicate_key_error(
      screen_keys,
      "lessons.screens",
      "screen keys must be unique across the import"
    )
    |> duplicate_key_error(
      variable_keys,
      "lessons.variables",
      "variable keys must be unique across the import"
    )
    |> duplicate_key_error(
      pathway_keys,
      "lessons.screens.adaptivity",
      "pathway rule keys must be unique across the import"
    )
  end

  defp validate_global_keys(errors, _plans), do: errors

  defp duplicate_key_error(errors, keys, path, message) do
    present = Enum.filter(keys, &(is_binary(&1) and &1 != ""))

    if length(present) == MapSet.size(MapSet.new(present)) do
      errors
    else
      [error(path, "duplicate_key", message) | errors]
    end
  end

  defp validate_totals(errors, plans) when is_list(plans) do
    {screens, parts, interactions} =
      Enum.reduce(plans, {0, 0, 0}, fn plan, {screen_count, part_count, interaction_count} ->
        lesson_screens = get_in(plan, ["lesson", "screens"]) |> List.wrap()

        {
          screen_count + length(lesson_screens),
          part_count +
            Enum.reduce(lesson_screens, 0, &(length(List.wrap(&1["parts"])) + &2)),
          interaction_count +
            Enum.reduce(lesson_screens, 0, &(length(List.wrap(&1["interactions"])) + &2))
        }
      end)

    errors
    |> maximum(screens, @max_screens, "lessons.screens")
    |> maximum(parts, @max_parts, "lessons.screens.parts")
    |> maximum(interactions, @max_interactions, "lessons.screens.interactions")
  end

  defp validate_totals(errors, _plans), do: errors

  defp maximum(errors, value, maximum, _path) when value <= maximum, do: errors

  defp maximum(errors, value, maximum, path) do
    [error(path, "limit_exceeded", "#{value} exceeds the import limit of #{maximum}") | errors]
  end

  defp validate_envelope_size(errors, envelope) do
    bytes = envelope |> Jason.encode!() |> byte_size()

    if bytes <= @max_bytes do
      errors
    else
      [error("$", "limit_exceeded", "import plan exceeds #{@max_bytes} bytes") | errors]
    end
  end

  defp normalize_lesson!(plan) do
    {:ok, normalized} = LessonPlan.validate(plan)
    normalized
  end

  defp error(path, code, message),
    do: %{"path" => path, "code" => code, "message" => message}
end
