defmodule Oli.OpenStax.CourseImport.ModelRoutingPolicy do
  @moduledoc """
  Quality-first role routing for OpenStax v7.

  Terra remains the generation baseline and Sol remains the independent critic.
  Luna is enabled only for explicitly promoted roles. First-pass unattended
  requests use Flex; repairs and author-triggered work use the standard tier.
  """

  alias Oli.GenAI.Completions.ServiceConfig
  alias Oli.OpenStax.CourseImport.ImportContract

  @generation_model "gpt-5.6-terra"
  @critic_model "gpt-5.6-sol"
  @luna_model "gpt-5.6-luna"

  @role_env %{
    basic_content_architect: "OPENSTAX_CONTENT_ARCHITECT_MODEL",
    basic_content_critic: "OPENSTAX_CONTENT_CRITIC_MODEL",
    basic_question_writer: "OPENSTAX_QUESTION_WRITER_MODEL",
    basic_question_critic: "OPENSTAX_QUESTION_CRITIC_MODEL",
    advanced_experience_architect: "OPENSTAX_ADVANCED_ARCHITECT_MODEL",
    advanced_experience_critic: "OPENSTAX_ADVANCED_CRITIC_MODEL",
    advanced_activity_writer: "OPENSTAX_ADVANCED_ACTIVITY_WRITER_MODEL",
    advanced_activity_critic: "OPENSTAX_ADVANCED_ACTIVITY_CRITIC_MODEL",
    simulation_opportunity_designer: "OPENSTAX_SIMULATION_OPPORTUNITY_MODEL",
    simulation_opportunity_critic: "OPENSTAX_SIMULATION_OPPORTUNITY_CRITIC_MODEL",
    simulation_spec_designer: "OPENSTAX_SIMULATION_SPEC_MODEL",
    simulation_spec_critic: "OPENSTAX_SIMULATION_SPEC_CRITIC_MODEL",
    simulation_bundle_builder: "OPENSTAX_SIMULATION_BUILDER_MODEL",
    simulation_artifact_critic: "OPENSTAX_SIMULATION_ARTIFACT_CRITIC_MODEL",
    repair_patch_writer: "OPENSTAX_REPAIR_PATCH_MODEL"
  }

  @critic_roles MapSet.new([
                  :basic_content_critic,
                  :basic_question_critic,
                  :advanced_experience_critic,
                  :advanced_activity_critic,
                  :simulation_opportunity_critic,
                  :simulation_spec_critic,
                  :simulation_artifact_critic
                ])

  @luna_evaluation_order [
    :basic_question_writer,
    :repair_patch_writer,
    :simulation_opportunity_designer,
    :advanced_activity_writer,
    :basic_content_architect,
    :advanced_experience_architect
  ]

  @output_caps %{
    basic_content_architect: 12_000,
    basic_content_critic: 4_000,
    basic_question_writer: 10_000,
    basic_question_critic: 4_000,
    advanced_experience_architect: 12_000,
    advanced_experience_critic: 4_000,
    advanced_activity_writer: 12_000,
    advanced_activity_critic: 4_000,
    simulation_opportunity_designer: 12_000,
    simulation_opportunity_critic: 4_000,
    simulation_spec_designer: 12_000,
    simulation_spec_critic: 4_000,
    simulation_bundle_builder: 12_000,
    simulation_artifact_critic: 4_000,
    repair_patch_writer: 4_000
  }

  def luna_evaluation_order, do: @luna_evaluation_order

  @spec service_config(ServiceConfig.t(), atom(), keyword()) :: ServiceConfig.t()
  def service_config(base, role, opts \\ [])

  def service_config(%ServiceConfig{} = base, role, opts) when is_atom(role) do
    env = Keyword.get(opts, :env_getter, &System.get_env/1)
    model_name = configured_model(role, env)
    role_name = role |> Atom.to_string() |> String.replace("_", "-")
    cache_key = prompt_cache_key(role, Keyword.get(opts, :cache_material, "shared"))

    role_model = %{
      base.primary_model
      | name: "openstax-#{role_name}",
        model: model_name,
        service_tier: if(Keyword.get(opts, :first_pass, true), do: "flex", else: "default"),
        reasoning_effort: "medium",
        prompt_cache_key: cache_key,
        max_output_tokens: Map.get(@output_caps, role, 4_000)
    }

    %{
      base
      | name: "openstax-#{role_name}",
        primary_model: role_model,
        secondary_model: nil,
        backup_model: nil
    }
  end

  def service_config(service, _role, _opts) when is_map(service), do: service

  @spec for_attempt(ServiceConfig.t(), pos_integer(), atom(), term()) :: ServiceConfig.t()
  def for_attempt(%ServiceConfig{} = service, attempt, role, cache_material)
      when is_integer(attempt) and attempt > 0 do
    tier = if attempt == 1, do: "flex", else: "default"
    cache_key = prompt_cache_key(role, cache_material)

    %{
      service
      | primary_model: %{service.primary_model | service_tier: tier, prompt_cache_key: cache_key}
    }
  end

  def for_attempt(service, _attempt, _role, _cache_material) when is_map(service), do: service

  def standard(%ServiceConfig{} = service),
    do: %{service | primary_model: %{service.primary_model | service_tier: "default"}}

  def standard(service) when is_map(service), do: service

  def output_cap(role), do: Map.get(@output_caps, role, 4_000)

  @doc "Escalates one targeted generation/repair request to Terra on the standard tier."
  def escalate_to_terra(%ServiceConfig{} = service, role) when is_atom(role) do
    role_name = role |> Atom.to_string() |> String.replace("_", "-")

    %{
      service
      | name: "openstax-#{role_name}-terra-escalation",
        primary_model: %{
          service.primary_model
          | name: "openstax-#{role_name}-terra-escalation",
            model: @generation_model,
            service_tier: "default",
            reasoning_effort: "medium"
        }
    }
  end

  def escalate_to_terra(service, _role) when is_map(service), do: service

  def model_for(role, env \\ &System.get_env/1) do
    configured_model(role, env)
  end

  defp configured_model(role, env) do
    explicit = @role_env |> Map.get(role) |> then(&(&1 && env.(&1))) |> blank_to_nil()

    explicit ||
      cond do
        MapSet.member?(@critic_roles, role) -> @critic_model
        role in promoted_luna_roles(env) -> @luna_model
        true -> @generation_model
      end
  end

  defp promoted_luna_roles(env) do
    env.("OPENSTAX_V7_LUNA_ROLES")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn value ->
      Enum.filter(@luna_evaluation_order, &(Atom.to_string(&1) == value))
    end)
  end

  defp prompt_cache_key(role, material) do
    hash =
      {ImportContract.prompt_bundle_version(), role, canonical(material)}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "openstax-v7-#{role}-#{hash}"
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil
end
