defmodule Oli.OpenStax.CourseImport.PlanTemplateCache do
  @moduledoc """
  Content-addressed cache for pristine, critic-approved v7 lesson templates.

  Lookups are exact across source, contracts, prompts, policies, features, and
  model snapshots. A distributed global transaction supplies the single-flight
  claim; a hit is rebound to current media and deterministically revalidated.
  """

  import Ecto.Query

  alias Oli.OpenStax.CourseImport.{Checks, ImportContract, PlanTemplate}
  alias Oli.Repo

  @spec fetch_or_generate(map(), String.t(), map(), keyword(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map(), :hit | :generated} | {:error, term()}
  def fetch_or_generate(lesson, mode, services, opts, generator)
      when is_map(lesson) and mode in ["basic", "advanced"] and is_map(services) and
             is_list(opts) and is_function(generator, 0) do
    if Keyword.get(opts, :plan_template_cache_enabled, true) and not guided_regeneration?(lesson) do
      identity = identity(lesson, mode, services, opts)

      :global.trans({__MODULE__, identity.cache_key}, fn ->
        case fetch(identity.cache_key, lesson) do
          {:ok, result} ->
            {:ok, result, :hit}

          :miss ->
            with {:ok, result} <- generator.() do
              case validate_approved(result, lesson, mode) do
                :ok ->
                  with {:ok, _template} <- store(identity, result) do
                    {:ok, put_in(result, [:metadata, "template_cache"], %{"status" => "stored"}),
                     :generated}
                  end

                {:error, _reason} ->
                  {:ok,
                   put_in(result, [:metadata, "template_cache"], %{
                     "status" => "not_stored",
                     "reason" => "not_fully_approved"
                   }), :generated}
              end
            end
        end
      end)
    else
      with {:ok, result} <- generator.() do
        {:ok, result, :generated}
      end
    end
  end

  defp guided_regeneration?(lesson) do
    Enum.any?(
      [Map.get(lesson, "repair_context"), Map.get(lesson, :repair_context)],
      &non_empty?/1
    )
  end

  defp non_empty?(value) when is_map(value), do: map_size(value) > 0
  defp non_empty?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty?(value) when is_list(value), do: value != []
  defp non_empty?(false), do: false
  defp non_empty?(nil), do: false
  defp non_empty?(_value), do: true

  def identity(lesson, mode, services, opts) do
    source_hash = hash(source_material(lesson))
    prompt_bundle_hash = hash(ImportContract.prompt_bundle_version())

    feature_policy_hash =
      hash(%{
        mode: mode,
        advanced: Keyword.get(opts, :advanced_enabled, true),
        simulations: Keyword.get(opts, :simulation_opportunities_enabled, false)
      })

    model_bundle_hash =
      services
      |> Enum.map(fn {role, service} ->
        model = Map.get(service, :primary_model) || %{}

        {to_string(role),
         %{
           provider: Map.get(model, :provider),
           model: Map.get(model, :model),
           snapshot: Map.get(model, :model_snapshot) || Map.get(model, :model)
         }}
      end)
      |> Enum.sort()
      |> hash()

    material = %{
      source_hash: source_hash,
      source_schema: ImportContract.source_schema_version(),
      plan_schema: ImportContract.plan_schema_version(),
      content_schema: ImportContract.content_schema_version(mode),
      prompt_bundle_hash: prompt_bundle_hash,
      quality_policy: ImportContract.quality_policy_version(),
      feature_policy_hash: feature_policy_hash,
      model_bundle_hash: model_bundle_hash,
      mode: mode
    }

    Map.put(material, :cache_key, hash(material))
  end

  defp fetch(cache_key, lesson) do
    case Repo.one(from template in PlanTemplate, where: template.cache_key == ^cache_key) do
      nil ->
        :miss

      template ->
        result = %{
          content_payload: rebind_media(template.content_payload, lesson),
          questions_payload: template.questions_payload,
          metadata:
            template.generation_metadata
            |> Map.put("template_cache", %{
              "status" => "hit",
              "template_id" => template.id,
              "approved_at" => template.approved_at
            })
        }

        mode = template.authoring_mode

        if valid?(result, lesson, mode), do: {:ok, result}, else: :miss
    end
  rescue
    _error -> :miss
  end

  defp store(identity, result) do
    attrs = %{
      cache_key: identity.cache_key,
      source_hash: identity.source_hash,
      authoring_mode: result.content_payload["authoring_mode"],
      source_schema_version: ImportContract.source_schema_version(),
      plan_schema_version: ImportContract.plan_schema_version(),
      content_schema_version: result.content_payload["schema_version"],
      prompt_bundle_hash: identity.prompt_bundle_hash,
      quality_policy_version: ImportContract.quality_policy_version(),
      feature_policy_hash: identity.feature_policy_hash,
      model_bundle_hash: identity.model_bundle_hash,
      content_payload: pristine(result.content_payload),
      questions_payload: pristine(result.questions_payload),
      generation_metadata: pristine(result.metadata),
      source_media_bindings: media_bindings(result.content_payload),
      approved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    %PlanTemplate{}
    |> PlanTemplate.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :cache_key,
      returning: true
    )
  end

  defp validate_approved(result, lesson, mode) do
    if valid?(result, lesson, mode), do: :ok, else: {:error, :unapproved_plan_template}
  end

  defp valid?(result, lesson, mode) do
    get_in(result, [:metadata, "quality_gate", "approved"]) == true and
      result.content_payload["authoring_mode"] == mode and
      result.content_payload["schema_version"] == ImportContract.content_schema_version(mode) and
      Checks.passed?(
        Checks.run(lesson, %{
          "content_payload" => result.content_payload,
          "questions_payload" => result.questions_payload,
          "generation_metadata" => result.metadata
        })
      )
  end

  defp source_material(lesson) do
    Map.take(lesson, [
      "title",
      "objective",
      "learning_objectives",
      "source_blocks",
      "source_evidence_links",
      "media",
      "attribution"
    ])
  end

  defp rebind_media(content, lesson) do
    current =
      lesson
      |> Map.get("media", [])
      |> List.wrap()
      |> Map.new(fn entry ->
        entry = stringify_keys(entry)
        {entry["source_media_id"] || entry["id"], entry}
      end)

    Map.update(content, "media", [], fn media ->
      Enum.map(List.wrap(media), fn entry ->
        entry = stringify_keys(entry)
        id = entry["source_media_id"] || entry["id"]

        case current[id] do
          nil ->
            entry

          binding ->
            Map.merge(entry, Map.take(binding, ~w(src url content_url alt caption credit)))
        end
      end)
    end)
  end

  defp media_bindings(content) do
    content
    |> Map.get("media", [])
    |> List.wrap()
    |> Enum.map(&Map.take(stringify_keys(&1), ~w(source_media_id id src url content_url)))
  end

  defp pristine(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> to_string(key) in ~w(project_id run_id lesson_id) end)
    |> Map.new(fn {key, item} -> {to_string(key), pristine(item)} end)
  end

  defp pristine(value) when is_list(value), do: Enum.map(value, &pristine/1)
  defp pristine(value), do: value

  defp hash(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp stringify_keys(_value), do: %{}
end
