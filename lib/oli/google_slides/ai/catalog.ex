defmodule Oli.GoogleSlides.AI.Catalog do
  @moduledoc """
  Versioned catalog of semantic parts and reviewed style profiles available to
  the Google Slides AI import workflow.

  The catalog is intentionally data-only. It does not load remote CSS or query
  an external documentation system at import time. URLs in a profile are the
  only external stylesheets the importer may select.
  """

  @version 1
  @default_theme "/css/delivery_adaptive_themes_default_light.css"

  @components %{
    "multiple_choice" => %{
      "semanticKey" => "multiple_choice",
      "partType" => "janus-mcq",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["mcq", "multiple-choice", "janus-mcq"]
    },
    "dropdown" => %{
      "semanticKey" => "dropdown",
      "partType" => "janus-dropdown",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["select", "janus-dropdown"]
    },
    "slider" => %{
      "semanticKey" => "slider",
      "partType" => "janus-slider",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["numeric_slider", "janus-slider"]
    },
    "text_slider" => %{
      "semanticKey" => "text_slider",
      "partType" => "janus-text-slider",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["text-slider", "janus-text-slider"]
    },
    "text_input" => %{
      "semanticKey" => "text_input",
      "partType" => "janus-input-text",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["short_answer", "text-entry", "janus-input-text"]
    },
    "number_input" => %{
      "semanticKey" => "number_input",
      "partType" => "janus-input-number",
      "kind" => "interaction",
      "automaticallyEvaluated" => true,
      "aliases" => ["numeric_input", "number-entry", "janus-input-number"]
    },
    "iframe" => %{
      "semanticKey" => "iframe",
      "partType" => "janus-capi-iframe",
      "kind" => "embed",
      "automaticallyEvaluated" => false,
      "aliases" => ["capi_iframe", "external_component", "janus-capi-iframe"]
    }
  }

  @content_part_kinds ~w(text list table image audio video chart word_art shape line iframe)

  # These profiles capture reviewed guidance from the ETX accessibility wiki.
  # A profile with selectionRequiresConfirmation intentionally has no guessed
  # product URL; an author/catalog update must resolve it first.
  @style_profiles %{
    "torus-default" => %{
      "key" => "torus-default",
      "label" => "Torus default light",
      "approvedStylesheets" => [@default_theme],
      "selectionRequiresConfirmation" => false
    },
    "biobeyond" => %{
      "key" => "biobeyond",
      "label" => "BioBeyond",
      "approvedStylesheets" => [
        @default_theme,
        "https://etx-css-assets.s3.us-west-2.amazonaws.com/biobeyond/style_biobeyond.css"
      ],
      "selectionRequiresConfirmation" => false
    },
    "critical-chemistry" => %{
      "key" => "critical-chemistry",
      "label" => "Critical Chemistry",
      "approvedStylesheets" => [
        @default_theme,
        "https://etx-css-assets.s3.us-west-2.amazonaws.com/critical-chem/style_critical-chem.css"
      ],
      "selectionRequiresConfirmation" => false
    },
    "habworlds-lesson" => %{
      "key" => "habworlds-lesson",
      "label" => "HabWorlds lesson or training",
      "approvedStylesheets" => [
        @default_theme,
        "https://etx-css-assets.s3.us-west-2.amazonaws.com/habworlds/style.css"
      ],
      "selectionRequiresConfirmation" => false
    },
    "habworlds-assessment" => %{
      "key" => "habworlds-assessment",
      "label" => "HabWorlds assessment",
      "approvedStylesheets" => [@default_theme],
      "selectionRequiresConfirmation" => true
    },
    "real-chemistry" => %{
      "key" => "real-chemistry",
      "label" => "REAL CHEM",
      "approvedStylesheets" => [
        @default_theme,
        "https://etx-css-assets.s3.us-west-2.amazonaws.com/gates-real-courses/real-chemistry/external-janus-components/style_rc-grouping.css"
      ],
      "selectionRequiresConfirmation" => false
    }
  }

  @component_aliases Enum.reduce(@components, %{}, fn {key, spec}, aliases ->
                       Enum.reduce([key | spec["aliases"]], aliases, fn alias_key, acc ->
                         Map.put(acc, alias_key, key)
                       end)
                     end)

  @profile_aliases %{
    "default" => "torus-default",
    "torus" => "torus-default",
    "critical-chem" => "critical-chemistry",
    "habworlds" => "habworlds-lesson",
    "real-chem" => "real-chemistry"
  }

  @spec version() :: pos_integer()
  def version, do: @version

  @spec components() :: [map()]
  def components do
    @components
    |> Map.values()
    |> Enum.sort_by(& &1["semanticKey"])
  end

  @spec component(term()) :: {:ok, map()} | {:error, :unsupported_component}
  def component(key) do
    with {:ok, normalized} <- normalize_component_key(key),
         %{} = component <- Map.get(@components, normalized) do
      {:ok, component}
    else
      _ -> {:error, :unsupported_component}
    end
  end

  @spec normalize_component_key(term()) ::
          {:ok, String.t()} | {:error, :unsupported_component}
  def normalize_component_key(key) when is_atom(key),
    do: normalize_component_key(Atom.to_string(key))

  def normalize_component_key(key) when is_binary(key) do
    normalized =
      key
      |> String.trim()
      |> String.downcase()
      |> String.replace(" ", "_")

    case Map.fetch(@component_aliases, normalized) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :unsupported_component}
    end
  end

  def normalize_component_key(_), do: {:error, :unsupported_component}

  @spec supported_component?(term()) :: boolean()
  def supported_component?(key), do: match?({:ok, _}, normalize_component_key(key))

  @spec automatically_evaluated?(term()) :: boolean()
  def automatically_evaluated?(key) do
    case component(key) do
      {:ok, %{"automaticallyEvaluated" => value}} -> value
      _ -> false
    end
  end

  @spec content_part_kinds() :: [String.t()]
  def content_part_kinds, do: @content_part_kinds

  @spec supported_content_part?(term()) :: boolean()
  def supported_content_part?(kind) when is_atom(kind),
    do: supported_content_part?(Atom.to_string(kind))

  def supported_content_part?(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(&(&1 in @content_part_kinds))
  end

  def supported_content_part?(_), do: false

  @spec style_profiles() :: [map()]
  def style_profiles do
    @style_profiles
    |> Map.values()
    |> Enum.sort_by(& &1["key"])
  end

  @spec style_profile(term()) :: {:ok, map()} | {:error, :unsupported_style_profile}
  def style_profile(key) when is_atom(key), do: style_profile(Atom.to_string(key))

  def style_profile(key) when is_binary(key) do
    normalized =
      key
      |> String.trim()
      |> String.downcase()
      |> then(&Map.get(@profile_aliases, &1, &1))

    case Map.fetch(@style_profiles, normalized) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :unsupported_style_profile}
    end
  end

  def style_profile(_), do: {:error, :unsupported_style_profile}

  @spec supported_style_profile?(term()) :: boolean()
  def supported_style_profile?(key), do: match?({:ok, _}, style_profile(key))

  @spec approved_stylesheet?(String.t()) :: boolean()
  def approved_stylesheet?(url) when is_binary(url) do
    Enum.any?(@style_profiles, fn {_key, profile} ->
      url in profile["approvedStylesheets"]
    end)
  end

  def approved_stylesheet?(_), do: false
end
