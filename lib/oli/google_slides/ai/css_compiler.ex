defmodule Oli.GoogleSlides.AI.CSSCompiler do
  @moduledoc """
  Compiles structured, lesson-scoped style rules into CSS.

  Callers provide semantic class targets and declarations, never selectors or
  raw CSS. External URLs and `@import` are deliberately outside this API and
  may only come from `Oli.GoogleSlides.AI.Catalog` style profiles.
  """

  @target_pattern ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @integer_pattern ~r/\A-?\d+\z/
  @number_pattern ~r/\A-?(?:\d+(?:\.\d+)?|\.\d+)\z/
  @length_pattern ~r/\A-?(?:\d+(?:\.\d+)?|\.\d+)(?:px|rem|em|%|vh|vw|ch)?\z/i
  @color_pattern ~r/\A(?:#[0-9a-f]{3,8}|(?:rgb|rgba|hsl|hsla)\([0-9.,%\s+-]+\)|transparent|currentcolor|inherit)\z/i
  @font_family_pattern ~r/\A[a-z0-9 ,'"\-]+\z/i
  @grid_pattern ~r/\A[a-z0-9_\s.%(),-]+\z/i

  @property_types %{
    "align-content" =>
      {:enum, ~w(normal start end center stretch space-between space-around space-evenly)},
    "align-items" => {:enum, ~w(normal start end center stretch baseline flex-start flex-end)},
    "align-self" =>
      {:enum, ~w(auto normal start end center stretch baseline flex-start flex-end)},
    "background-color" => :color,
    "border-bottom-color" => :color,
    "border-bottom-left-radius" => :length,
    "border-bottom-right-radius" => :length,
    "border-bottom-style" => {:enum, ~w(none solid dashed dotted double)},
    "border-bottom-width" => :length,
    "border-color" => :color,
    "border-left-color" => :color,
    "border-left-style" => {:enum, ~w(none solid dashed dotted double)},
    "border-left-width" => :length,
    "border-radius" => :box_lengths,
    "border-right-color" => :color,
    "border-right-style" => {:enum, ~w(none solid dashed dotted double)},
    "border-right-width" => :length,
    "border-style" => {:enum, ~w(none solid dashed dotted double)},
    "border-top-color" => :color,
    "border-top-left-radius" => :length,
    "border-top-right-radius" => :length,
    "border-top-style" => {:enum, ~w(none solid dashed dotted double)},
    "border-top-width" => :length,
    "border-width" => :box_lengths,
    "bottom" => :length_or_auto,
    "box-sizing" => {:enum, ~w(content-box border-box)},
    "color" => :color,
    "column-gap" => :length,
    "display" => {:enum, ~w(block inline inline-block flex inline-flex grid inline-grid none)},
    "flex-basis" => :length_or_auto,
    "flex-direction" => {:enum, ~w(row row-reverse column column-reverse)},
    "flex-grow" => :non_negative_number,
    "flex-shrink" => :non_negative_number,
    "flex-wrap" => {:enum, ~w(nowrap wrap wrap-reverse)},
    "font-family" => :font_family,
    "font-size" => :length,
    "font-style" => {:enum, ~w(normal italic oblique)},
    "font-weight" => :font_weight,
    "gap" => :one_or_two_lengths,
    "grid-template-columns" => :grid_track_list,
    "grid-template-rows" => :grid_track_list,
    "height" => :dimension,
    "justify-content" =>
      {:enum,
       ~w(normal start end center stretch space-between space-around space-evenly flex-start flex-end)},
    "justify-items" => {:enum, ~w(normal start end center stretch baseline)},
    "justify-self" => {:enum, ~w(auto normal start end center stretch baseline)},
    "left" => :length_or_auto,
    "letter-spacing" => :length_or_normal,
    "line-height" => :line_height,
    "margin" => :box_lengths_or_auto,
    "margin-bottom" => :length_or_auto,
    "margin-left" => :length_or_auto,
    "margin-right" => :length_or_auto,
    "margin-top" => :length_or_auto,
    "max-height" => :dimension,
    "max-width" => :dimension,
    "min-height" => :dimension,
    "min-width" => :dimension,
    "object-fit" => {:enum, ~w(fill contain cover none scale-down)},
    "object-position" => :position_value,
    "opacity" => :opacity,
    "order" => :integer,
    "overflow" => {:enum, ~w(visible hidden clip scroll auto)},
    "overflow-x" => {:enum, ~w(visible hidden clip scroll auto)},
    "overflow-y" => {:enum, ~w(visible hidden clip scroll auto)},
    "padding" => :box_lengths,
    "padding-bottom" => :length,
    "padding-left" => :length,
    "padding-right" => :length,
    "padding-top" => :length,
    "position" => {:enum, ~w(static relative absolute sticky)},
    "right" => :length_or_auto,
    "row-gap" => :length,
    "text-align" => {:enum, ~w(start end left right center justify)},
    "text-decoration" => {:enum, ~w(none underline overline line-through)},
    "text-transform" => {:enum, ~w(none capitalize uppercase lowercase)},
    "top" => :length_or_auto,
    "vertical-align" => {:enum, ~w(baseline sub super text-top text-bottom middle top bottom)},
    "white-space" => {:enum, ~w(normal nowrap pre pre-wrap pre-line break-spaces)},
    "width" => :dimension,
    "z-index" => :integer
  }

  @type validation_error :: %{
          required(:path) => String.t(),
          required(:code) => String.t(),
          required(:message) => String.t()
        }

  @spec allowed_properties() :: [String.t()]
  def allowed_properties, do: @property_types |> Map.keys() |> Enum.sort()

  @spec compile([map()], keyword()) :: {:ok, String.t()} | {:error, [validation_error()]}
  def compile(rules, opts \\ []) do
    scope = opts |> Keyword.get(:scope, "lesson") |> to_string() |> String.downcase()

    with :ok <- validate_target(scope, "scope"),
         {:ok, normalized} <- normalize(rules) do
      css =
        normalized
        |> Enum.map(&compile_rule(&1, scope))
        |> Enum.join("\n\n")

      {:ok, css}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @spec validate([map()]) :: :ok | {:error, [validation_error()]}
  def validate(rules) do
    case normalize(rules) do
      {:ok, _normalized} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @spec normalize([map()]) :: {:ok, [map()]} | {:error, [validation_error()]}
  def normalize(rules) when is_list(rules) do
    {normalized, errors} =
      rules
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {rule, index}, {acc, errors} ->
        case normalize_rule(rule, index) do
          {:ok, normalized_rule} -> {[normalized_rule | acc], errors}
          {:error, rule_errors} -> {acc, rule_errors ++ errors}
        end
      end)

    case errors do
      [] -> {:ok, Enum.sort_by(normalized, & &1["target"])}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def normalize(_rules) do
    {:error, [error("styleRules", "invalid_type", "style rules must be a list")]}
  end

  defp normalize_rule(rule, index) when is_map(rule) do
    target = value(rule, "target")
    declarations = value(rule, "declarations")
    path = "styleRules[#{index}]"
    target_result = validate_target(target, "#{path}.target")
    declaration_result = normalize_declarations(declarations, "#{path}.declarations")

    case {target_result, declaration_result} do
      {:ok, {:ok, normalized_declarations}} ->
        {:ok, %{"target" => target, "declarations" => normalized_declarations}}

      _ ->
        errors =
          [target_result, declaration_result]
          |> Enum.flat_map(fn
            :ok -> []
            {:ok, _} -> []
            {:error, errors} when is_list(errors) -> errors
            {:error, error} -> [error]
          end)

        {:error, errors}
    end
  end

  defp normalize_rule(_rule, index) do
    {:error, [error("styleRules[#{index}]", "invalid_type", "each style rule must be an object")]}
  end

  defp normalize_declarations(declarations, path) when is_map(declarations) do
    {normalized, errors} =
      Enum.reduce(declarations, {%{}, []}, fn {property, raw_value}, {acc, errors} ->
        property = property |> to_string() |> String.trim() |> String.downcase()

        case css_value(raw_value) do
          {:ok, css_value} ->
            case validate_declaration(property, css_value, "#{path}.#{property}") do
              :ok -> {Map.put(acc, property, css_value), errors}
              {:error, declaration_error} -> {acc, [declaration_error | errors]}
            end

          :error ->
            declaration_error =
              error(
                "#{path}.#{property}",
                "invalid_type",
                "style values must be strings or numbers"
              )

            {acc, [declaration_error | errors]}
        end
      end)

    cond do
      map_size(declarations) == 0 ->
        {:error, [error(path, "required", "declarations cannot be empty")]}

      errors == [] ->
        {:ok, normalized}

      true ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_declarations(_declarations, path) do
    {:error, [error(path, "invalid_type", "declarations must be an object")]}
  end

  defp validate_target(target, path) when is_binary(target) do
    if Regex.match?(@target_pattern, target) do
      :ok
    else
      {:error,
       error(
         path,
         "invalid_target",
         "target must be a semantic class name, not a CSS selector"
       )}
    end
  end

  defp validate_target(_target, path) do
    {:error, error(path, "invalid_target", "target must be a semantic class name")}
  end

  defp validate_declaration(property, value, path) do
    case Map.fetch(@property_types, property) do
      :error ->
        {:error,
         error(path, "unsupported_property", "#{property} is not an allowed style property")}

      {:ok, type} ->
        cond do
          unsafe_value?(value) ->
            {:error,
             error(path, "unsafe_value", "style values cannot contain CSS, imports, or URLs")}

          valid_value?(type, value) ->
            :ok

          true ->
            {:error,
             error(path, "invalid_value", "#{inspect(value)} is not valid for #{property}")}
        end
    end
  end

  defp unsafe_value?(value) do
    downcased = String.downcase(value)

    String.contains?(value, [";", "{", "}", "\n", "\r", "/*", "*/"]) or
      String.contains?(downcased, [
        "@import",
        "url(",
        "expression(",
        "javascript:",
        "data:",
        "var("
      ])
  end

  defp valid_value?(:color, value), do: Regex.match?(@color_pattern, value)
  defp valid_value?(:integer, value), do: Regex.match?(@integer_pattern, value)
  defp valid_value?(:length, value), do: length?(value)
  defp valid_value?(:length_or_auto, value), do: length?(value) or value == "auto"
  defp valid_value?(:length_or_normal, value), do: length?(value) or value == "normal"

  defp valid_value?(:dimension, value),
    do: length?(value) or value in ~w(auto min-content max-content fit-content)

  defp valid_value?(:box_lengths, value), do: token_list?(value, 1..4, &length?/1)

  defp valid_value?(:box_lengths_or_auto, value),
    do: token_list?(value, 1..4, &(length?(&1) or &1 == "auto"))

  defp valid_value?(:one_or_two_lengths, value), do: token_list?(value, 1..2, &length?/1)

  defp valid_value?(:non_negative_number, value) do
    Regex.match?(@number_pattern, value) and numeric(value) >= 0
  end

  defp valid_value?(:opacity, value) do
    Regex.match?(@number_pattern, value) and numeric(value) >= 0 and numeric(value) <= 1
  end

  defp valid_value?(:font_family, value), do: Regex.match?(@font_family_pattern, value)

  defp valid_value?(:font_weight, value) do
    numeric_value = numeric(value)

    value in ~w(normal bold bolder lighter) or
      (Regex.match?(@integer_pattern, value) and numeric_value >= 100 and
         numeric_value <= 900 and rem(trunc(numeric_value), 100) == 0)
  end

  defp valid_value?(:line_height, value) do
    value == "normal" or length?(value) or Regex.match?(@number_pattern, value)
  end

  defp valid_value?(:grid_track_list, value), do: Regex.match?(@grid_pattern, value)

  defp valid_value?(:position_value, value) do
    token_list?(value, 1..2, fn token ->
      length?(token) or token in ~w(left right top bottom center)
    end)
  end

  defp valid_value?({:enum, values}, value), do: value in values
  defp valid_value?(_type, _value), do: false

  defp length?(value), do: Regex.match?(@length_pattern, value)

  defp token_list?(value, range, validator) do
    tokens = String.split(value, ~r/\s+/, trim: true)
    length(tokens) in range and Enum.all?(tokens, validator)
  end

  defp numeric(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> -1.0
    end
  end

  defp css_value(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp css_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp css_value(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp css_value(_value), do: :error

  defp compile_rule(%{"target" => target, "declarations" => declarations}, scope) do
    body =
      declarations
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {property, value} -> "  #{property}: #{value};" end)

    ".aa-import-#{scope} .#{target} {\n#{body}\n}"
  end

  defp value(map, "target"), do: Map.get(map, "target", Map.get(map, :target))

  defp value(map, "declarations"),
    do: Map.get(map, "declarations", Map.get(map, :declarations))

  defp error(path, code, message) do
    %{"path" => path, "code" => code, "message" => message}
  end
end
