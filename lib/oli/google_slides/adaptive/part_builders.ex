defmodule Oli.GoogleSlides.Adaptive.PartBuilders do
  @moduledoc """
  Builds janus part JSON for adaptive screens from parsed slide content.
  """

  alias Oli.GoogleSlides.Util

  @transparent_palette %{
    "backgroundColor" => "rgba(255,255,255,0)",
    "borderColor" => "rgba(255,255,255,0)",
    "borderRadius" => 0,
    "borderStyle" => "solid",
    "borderWidth" => "0.1px",
    "useHtmlProps" => true
  }

  @default_palette %{
    "fillColor" => 1.6777215e7,
    "fillAlpha" => 0.0,
    "lineColor" => 1.6777215e7,
    "lineAlpha" => 0.0,
    "lineThickness" => 0.1,
    "lineStyle" => 0.0
  }

  @spec text_flow(String.t(), :h1 | :h2 | :h3 | :h4 | :h5 | :h6 | :p, keyword()) :: map()
  def text_flow(text, tag \\ :p, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    width = Keyword.get(opts, :width, 960)
    height = text_flow_height(tag)

    %{
      "id" => Util.new_id("text"),
      "type" => "janus-text-flow",
      "custom" => %{
        "customCssClass" => "",
        "height" => height,
        "maxScore" => 1,
        "nodes" => text_nodes(tag, text),
        "overrideHeight" => false,
        "overrideWidth" => true,
        "palette" => @transparent_palette,
        "requiresManualGrading" => false,
        "visible" => true,
        "width" => 100,
        "responsiveLayoutWidth" => width,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec list_flow([String.t()], :ul | :ol | String.t(), keyword()) :: map()
  def list_flow(items, list_type \\ :ul, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    width = Keyword.get(opts, :width, 960)
    tag = if list_type in [:ol, "ol"], do: "ol", else: "ul"
    height = max(length(items) * 28, 48)

    %{
      "id" => Util.new_id("text"),
      "type" => "janus-text-flow",
      "custom" => %{
        "customCssClass" => "",
        "height" => height,
        "maxScore" => 1,
        "nodes" => [list_nodes(tag, items)],
        "overrideHeight" => false,
        "overrideWidth" => true,
        "palette" => @transparent_palette,
        "requiresManualGrading" => false,
        "visible" => true,
        "width" => 100,
        "responsiveLayoutWidth" => width,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec iframe_part(map(), keyword()) :: map()
  def iframe_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    height = Keyword.get(opts, :height, 320)

    %{
      "id" => Util.new_id("iframe"),
      "type" => "janus-capi-iframe",
      "custom" => %{
        "allowScrolling" => Map.get(spec, "allowScrolling", false),
        "configData" => [],
        "customCssClass" => "",
        "height" => height,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "responsiveLayoutWidth" => 960,
        "src" => Map.get(spec, "src", ""),
        "width" => 100,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec video_part(String.t(), keyword()) :: map()
  def video_part(src, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    height = Keyword.get(opts, :height, 280)

    %{
      "id" => Util.new_id("video"),
      "type" => "janus-video",
      "custom" => %{
        "alt" => Keyword.get(opts, :alt, "Slide video"),
        "autoPlay" => false,
        "customCssClass" => "",
        "enableReplay" => true,
        "enabled" => true,
        "endTime" => 0,
        "height" => height,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "responsiveLayoutWidth" => 960,
        "src" => src,
        "startTime" => 0,
        "subtitles" => Keyword.get(opts, :subtitles, []),
        "triggerCheck" => false,
        "width" => 100,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec audio_part(String.t(), keyword()) :: map()
  def audio_part(src, opts \\ []) do
    y = Keyword.get(opts, :y, 0)

    %{
      "id" => Util.new_id("audio"),
      "type" => "janus-audio",
      "custom" => %{
        "autoPlay" => false,
        "customCssClass" => "",
        "enableReplay" => true,
        "enabled" => true,
        "endTime" => 0,
        "height" => Keyword.get(opts, :height, 54),
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "responsiveLayoutWidth" => 960,
        "src" => src,
        "startTime" => 0,
        "subtitles" => Keyword.get(opts, :subtitles, []),
        "transcript" => %{
          "transcriptText" => Keyword.get(opts, :transcript_text, ""),
          "transcriptFile" => Keyword.get(opts, :transcript_file, "")
        },
        "triggerCheck" => false,
        "width" => 100,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec image_part(String.t(), keyword()) :: map()
  def image_part(src, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    height = Keyword.get(opts, :height, 200)

    %{
      "id" => Util.new_id("image"),
      "type" => "janus-image",
      "custom" => %{
        "alt" => Keyword.get(opts, :alt, "Slide image"),
        "customCssClass" => "",
        "height" => height,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "src" => src,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0
      }
    }
  end

  @spec mcq_part(map(), keyword()) :: map()
  def mcq_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    label = Map.get(spec, "label", "Select one")
    choices = Map.get(spec, "choices", ["Option 1", "Option 2"])
    correct_index = Map.get(spec, "correct", 0)

    mcq_items =
      choices
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        %{
          "scoreValue" => if(index == correct_index, do: 1, else: 0),
          "nodes" => text_nodes(:p, choice)
        }
      end)

    %{
      "id" => Util.new_id("mcq"),
      "type" => "janus-mcq",
      "custom" => %{
        "customCssClass" => "",
        "height" => 100,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "overrideHeight" => false,
        "layoutType" => "verticalLayout",
        "verticalGap" => 0,
        "showLabel" => true,
        "label" => label,
        "multipleSelection" => false,
        "randomize" => false,
        "showNumbering" => false,
        "enabled" => true,
        "mcqItems" => mcq_items,
        "correctAnswer" => correct_index,
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again.")
      }
    }
  end

  @spec dropdown_part(map(), keyword()) :: map()
  def dropdown_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    options = Map.get(spec, "optionLabels", ["Option 1", "Option 2"])
    correct_index = Map.get(spec, "correct", 0)

    %{
      "id" => Util.new_id("dropdown"),
      "type" => "janus-dropdown",
      "custom" => %{
        "customCssClass" => "",
        "height" => 80,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "enabled" => true,
        "showLabel" => true,
        "label" => Map.get(spec, "label", "Select one"),
        "prompt" => Map.get(spec, "prompt", "Select an option"),
        "optionLabels" => options,
        "correctAnswer" => correct_index,
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again."),
        "commonErrorFeedback" => []
      }
    }
  end

  @spec slider_part(map(), keyword()) :: map()
  def slider_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)

    %{
      "id" => Util.new_id("slider"),
      "type" => "janus-slider",
      "custom" => %{
        "customCssClass" => "",
        "height" => 80,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "enabled" => true,
        "showLabel" => true,
        "label" => Map.get(spec, "label", "Slider (Numeric)"),
        "showDataTip" => true,
        "showValueLabels" => true,
        "showTicks" => true,
        "invertScale" => false,
        "minimum" => Map.get(spec, "min", 0),
        "maximum" => Map.get(spec, "max", 100),
        "snapInterval" => Map.get(spec, "step", 1),
        "answer" => %{"correct" => Map.get(spec, "correct", 0)},
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again.")
      }
    }
  end

  @spec text_slider_part(map(), keyword()) :: map()
  def text_slider_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    options = Map.get(spec, "sliderOptionLabels", ["Off", "On"])
    maximum = max(length(options) - 1, 0)
    correct = Map.get(spec, "correct", 0)

    %{
      "id" => Util.new_id("text_slider"),
      "type" => "janus-text-slider",
      "custom" => %{
        "customCssClass" => "",
        "height" => 80,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "enabled" => true,
        "showLabel" => true,
        "label" => Map.get(spec, "label", "Slider"),
        "showValueLabels" => true,
        "showTicks" => true,
        "sliderOptionLabels" => options,
        "minimum" => 0,
        "maximum" => maximum,
        "snapInterval" => 1,
        "answer" => %{"range" => false, "correctAnswer" => correct},
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again.")
      }
    }
  end

  @spec input_text_part(map(), keyword()) :: map()
  def input_text_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)
    correct_answer = Map.get(spec, "correctAnswer", %{})

    %{
      "id" => Util.new_id("input_text"),
      "type" => "janus-input-text",
      "custom" => %{
        "customCssClass" => "",
        "height" => 80,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "enabled" => true,
        "showLabel" => true,
        "label" => Map.get(spec, "label", "Input"),
        "prompt" => Map.get(spec, "prompt", "enter some text"),
        "fontSize" => 12,
        "correctAnswer" => %{
          "minimumLength" => Map.get(correct_answer, "minimumLength", 1),
          "mustContain" => Map.get(correct_answer, "mustContain", ""),
          "mustNotContain" => Map.get(correct_answer, "mustNotContain", "")
        },
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again.")
      }
    }
  end

  @spec input_number_part(map(), keyword()) :: map()
  def input_number_part(spec, opts \\ []) do
    y = Keyword.get(opts, :y, 0)

    %{
      "id" => Util.new_id("input_number"),
      "type" => "janus-input-number",
      "custom" => %{
        "customCssClass" => "",
        "height" => 80,
        "maxScore" => 1,
        "requiresManualGrading" => false,
        "width" => 100,
        "responsiveLayoutWidth" => 960,
        "x" => 0,
        "y" => y,
        "z" => 0,
        "enabled" => true,
        "showLabel" => true,
        "label" => Map.get(spec, "label", "Number"),
        "prompt" => Map.get(spec, "prompt", "enter a number"),
        "unitsLabel" => Map.get(spec, "unitsLabel", ""),
        "showIncrementArrows" => false,
        "enableScrollIncrement" => false,
        "answer" => %{"correctAnswer" => Map.get(spec, "correct", 0)},
        "correctFeedback" => Map.get(spec, "correctFeedback", "Correct!"),
        "incorrectFeedback" => Map.get(spec, "incorrectFeedback", "Incorrect, please try again.")
      }
    }
  end

  @spec authoring_part(map()) :: map()
  def authoring_part(%{"id" => id, "type" => type}) do
    base = %{
      "id" => id,
      "type" => type,
      "owner" => "aa_import_layout",
      "inherited" => false
    }

    if type in [
         "janus-mcq",
         "janus-slider",
         "janus-text-slider",
         "janus-dropdown",
         "janus-input-number",
         "janus-input-text"
       ] do
      base
      |> Map.put("gradingApproach", "automatic")
      |> Map.put("outOf", 1)
    else
      base
    end
  end

  @spec feedback_text_part(String.t()) :: map()
  def feedback_text_part(msg) do
    %{
      "id" => Util.new_id("feedback_text"),
      "type" => "janus-text-flow",
      "custom" => %{
        "nodes" => text_nodes(:p, msg),
        "x" => 10,
        "y" => 10,
        "z" => 0,
        "width" => 330,
        "height" => 22,
        "palette" => @default_palette,
        "customCssClass" => ""
      }
    }
  end

  defp text_nodes(tag, text) do
    tag_str = if is_atom(tag), do: Atom.to_string(tag), else: tag

    [
      %{
        "tag" => tag_str,
        "children" => [
          %{
            "tag" => "span",
            "style" => %{},
            "children" => [
              %{"tag" => "text", "text" => text, "children" => []}
            ]
          }
        ],
        "style" => %{}
      }
    ]
  end

  defp list_nodes(tag, items) do
    %{
      "tag" => tag,
      "style" => %{},
      "children" => Enum.map(items, &list_item_node/1)
    }
  end

  defp list_item_node(text) do
    %{
      "tag" => "li",
      "style" => %{},
      "children" => [
        %{
          "tag" => "span",
          "style" => %{},
          "children" => [
            %{"tag" => "text", "text" => text, "children" => []}
          ]
        }
      ]
    }
  end

  defp text_flow_height(:h1), do: 36
  defp text_flow_height(:h2), do: 32
  defp text_flow_height(:h3), do: 28
  defp text_flow_height(:h4), do: 22
  defp text_flow_height(:h5), do: 20
  defp text_flow_height(:h6), do: 18
  defp text_flow_height(:p), do: 96
  defp text_flow_height("h" <> _), do: 24
  defp text_flow_height(_), do: 96
end
