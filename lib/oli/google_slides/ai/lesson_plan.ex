defmodule Oli.GoogleSlides.AI.LessonPlan do
  @moduledoc """
  Versioned semantic intermediate representation for a single imported lesson.

  A lesson plan is JSON-compatible and contains no Torus resource IDs or
  revision mutations. It is safe to persist while the AI and author refine the
  draft. Finalization only changes the plan status after strict validation.
  """

  alias Oli.GoogleSlides.AI.Catalog
  alias Oli.GoogleSlides.AI.CSSCompiler

  @current_version 1
  @kind "google_slides_lesson_plan"
  @key_pattern ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @statuses ~w(draft finalized)
  @layout_modes ~w(responsive pixel)
  @max_screens 150
  @max_parts_per_screen 40
  @max_total_parts 600
  @max_interactions_per_screen 8
  @max_total_interactions 150
  @max_adaptivity_rules_per_screen 40
  @max_variables 100
  @max_objectives 200
  @max_plan_bytes 1_500_000
  @default_evaluation_policy %{
    "maxAttempts" => 3,
    "onCorrect" => "navigate_next",
    "onIncorrect" => "retry_with_feedback",
    "revealAnswerAfterMaxAttempts" => true,
    "blankFeedback" => "Please provide an answer before continuing.",
    "exhaustedFeedback" =>
      "You've reached the maximum number of attempts. The correct answer is shown."
  }

  @type t :: %{String.t() => term()}
  @type validation_error :: %{required(String.t()) => String.t()}

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @spec default_evaluation_policy() :: map()
  def default_evaluation_policy, do: @default_evaluation_policy

  @spec new(map()) :: {:ok, t()} | {:error, [validation_error()]}
  def new(attrs \\ %{})

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    source_attrs = map_or_empty(attrs["source"])
    lesson_attrs = map_or_empty(attrs["lesson"])
    layout_attrs = map_or_empty(lesson_attrs["layout"])

    source =
      empty_source()
      |> put_present("presentationId", source_attrs["presentationId"] || attrs["presentationId"])
      |> put_present("revisionId", source_attrs["revisionId"] || attrs["revisionId"])
      |> put_present("fingerprint", source_attrs["fingerprint"] || attrs["fingerprint"])
      |> put_present("url", source_attrs["url"] || attrs["url"])

    layout =
      empty_layout()
      |> Map.merge(layout_attrs)
      |> put_present("mode", lesson_attrs["layoutMode"] || attrs["layoutMode"])
      |> put_present("styleProfile", lesson_attrs["styleProfile"] || attrs["styleProfile"])

    lesson =
      empty_lesson()
      |> Map.merge(lesson_attrs)
      |> put_present("key", lesson_attrs["key"] || attrs["lessonKey"])
      |> put_present("title", lesson_attrs["title"] || attrs["title"])
      |> Map.put("layout", layout)

    plan =
      empty_plan()
      |> Map.put("source", source)
      |> Map.put("lesson", lesson)

    validate(plan)
  end

  def new(_attrs) do
    {:error, [error("$", "invalid_type", "lesson plan attributes must be an object")]}
  end

  @spec normalize(map()) :: {:ok, t()} | {:error, [validation_error()]}
  def normalize(plan) when is_map(plan) do
    plan = stringify_keys(plan)
    schema_version = integer_version(plan["schemaVersion"])

    cond do
      schema_version != @current_version ->
        {:error,
         [
           error(
             "schemaVersion",
             "unsupported_version",
             "lesson plan schema version #{inspect(plan["schemaVersion"])} is not supported"
           )
         ]}

      plan["kind"] not in [nil, @kind] ->
        {:error, [error("kind", "invalid_value", "lesson plan kind must be #{@kind}")]}

      true ->
        normalized =
          empty_plan()
          |> deep_merge(plan)
          |> Map.put("schemaVersion", @current_version)
          |> Map.put("kind", @kind)
          |> Map.update!("source", &normalize_source/1)
          |> Map.update!("lesson", &normalize_lesson/1)
          |> Map.update!("objectives", &normalize_objectives/1)
          |> Map.update!("variables", &list_or_original/1)
          |> Map.update!("blockers", &list_or_original/1)
          |> Map.update!("warnings", &list_or_original/1)
          |> Map.update!("assumptions", &list_or_original/1)

        {:ok, normalized}
    end
  end

  def normalize(_plan) do
    {:error, [error("$", "invalid_type", "lesson plan must be an object")]}
  end

  @spec validate(map(), keyword()) :: {:ok, t()} | {:error, [validation_error()]}
  def validate(plan, opts \\ []) do
    mode = Keyword.get(opts, :mode, :draft)

    with {:ok, normalized} <- normalize(plan) do
      errors =
        []
        |> validate_plan_shape(normalized)
        |> validate_plan_limits(normalized)
        |> validate_source(normalized["source"], mode)
        |> validate_lesson(normalized["lesson"], mode)
        |> validate_objectives(normalized["objectives"], mode)
        |> validate_variables(normalized["variables"], mode)
        |> validate_cross_references(normalized, mode)
        |> validate_blockers(normalized["blockers"], mode)
        |> validate_review_metadata(normalized["warnings"], normalized["assumptions"])
        |> Enum.reverse()

      case errors do
        [] -> {:ok, normalized}
        _ -> {:error, errors}
      end
    end
  end

  @spec valid?(map(), keyword()) :: boolean()
  def valid?(plan, opts \\ []), do: match?({:ok, _}, validate(plan, opts))

  @spec finalize(map()) :: {:ok, t()} | {:error, [validation_error()]}
  def finalize(plan) do
    with {:ok, normalized} <- validate(plan, mode: :final) do
      {:ok, Map.put(normalized, "status", "finalized")}
    end
  end

  @spec put_blocker(t(), map()) :: t()
  def put_blocker(plan, blocker) when is_map(plan) and is_map(blocker) do
    blocker = stringify_keys(blocker)
    code = blocker["code"] || "needs_author_input"
    target = blocker["target"] || "lesson"
    key = blocker["key"] || "#{code}:#{target}"

    normalized =
      %{
        "key" => key,
        "code" => code,
        "target" => target,
        "message" => blocker["message"] || "Author input is required",
        "sourceRefs" => normalize_source_refs(blocker["sourceRefs"])
      }
      |> put_present("details", blocker["details"])

    blockers =
      plan
      |> Map.get("blockers", [])
      |> Enum.reject(&(&1["key"] == key))
      |> Kernel.++([normalized])

    Map.put(plan, "blockers", blockers)
  end

  @spec resolve_blocker(t(), String.t()) :: t()
  def resolve_blocker(plan, blocker_key) when is_map(plan) and is_binary(blocker_key) do
    Map.update(plan, "blockers", [], fn blockers ->
      Enum.reject(blockers, &(&1["key"] == blocker_key))
    end)
  end

  @spec put_warning(t(), map()) :: t()
  def put_warning(plan, warning) when is_map(plan) and is_map(warning) do
    warning = stringify_keys(warning)
    code = warning["code"] || "review_recommended"
    target = warning["target"] || "lesson"
    key = warning["key"] || "#{code}:#{target}"

    normalized =
      %{
        "key" => key,
        "code" => code,
        "target" => target,
        "message" => warning["message"] || "Review is recommended",
        "sourceRefs" => normalize_source_refs(warning["sourceRefs"])
      }

    warnings =
      plan
      |> Map.get("warnings", [])
      |> Enum.reject(&(&1["key"] == key))
      |> Kernel.++([normalized])

    Map.put(plan, "warnings", warnings)
  end

  @spec put_assumption(t(), map()) :: t()
  def put_assumption(plan, assumption) when is_map(plan) and is_map(assumption) do
    assumption = stringify_keys(assumption)
    key = assumption["key"]

    normalized = %{
      "key" => key,
      "message" => assumption["message"],
      "sourceRefs" => normalize_source_refs(assumption["sourceRefs"])
    }

    assumptions =
      plan
      |> Map.get("assumptions", [])
      |> Enum.reject(&(key && &1["key"] == key))
      |> Kernel.++([normalized])

    Map.put(plan, "assumptions", assumptions)
  end

  defp empty_plan do
    %{
      "schemaVersion" => @current_version,
      "catalogVersion" => Catalog.version(),
      "kind" => @kind,
      "status" => "draft",
      "source" => empty_source(),
      "lesson" => empty_lesson(),
      "objectives" => %{"mapped" => [], "proposed" => []},
      "variables" => [],
      "blockers" => [],
      "warnings" => [],
      "assumptions" => []
    }
  end

  defp empty_source do
    %{
      "presentationId" => nil,
      "revisionId" => nil,
      "fingerprint" => nil,
      "url" => nil
    }
  end

  defp empty_lesson do
    %{
      "key" => "lesson",
      "title" => nil,
      "layout" => empty_layout(),
      "screens" => []
    }
  end

  defp empty_layout do
    %{
      "mode" => "responsive",
      "styleProfile" => "torus-default",
      "canvas" => nil,
      "styleRules" => []
    }
  end

  defp normalize_source(source) when is_map(source), do: deep_merge(empty_source(), source)
  defp normalize_source(source), do: source

  defp normalize_lesson(lesson) when is_map(lesson) do
    lesson = deep_merge(empty_lesson(), lesson)

    lesson
    |> Map.update!("layout", fn
      layout when is_map(layout) ->
        layout = deep_merge(empty_layout(), layout)

        case Catalog.style_profile(layout["styleProfile"]) do
          {:ok, profile} -> Map.put(layout, "styleProfile", profile["key"])
          {:error, _} -> layout
        end

      other ->
        other
    end)
    |> Map.update!("screens", fn
      screens when is_list(screens) -> Enum.map(screens, &normalize_screen/1)
      other -> other
    end)
  end

  defp normalize_lesson(lesson), do: lesson

  defp normalize_screen(screen) when is_map(screen) do
    %{
      "key" => nil,
      "title" => nil,
      "sourceRefs" => [],
      "parts" => [],
      "interactions" => [],
      "adaptivity" => []
    }
    |> deep_merge(screen)
    |> Map.update!("sourceRefs", &normalize_source_refs/1)
    |> Map.update!("parts", &list_or_original/1)
    |> Map.update!("interactions", fn
      interactions when is_list(interactions) ->
        Enum.map(interactions, &normalize_interaction/1)

      other ->
        other
    end)
    |> Map.update!("adaptivity", &list_or_original/1)
  end

  defp normalize_screen(screen), do: screen

  defp normalize_interaction(interaction) when is_map(interaction) do
    interaction =
      case Catalog.normalize_component_key(interaction["componentKey"]) do
        {:ok, component_key} -> Map.put(interaction, "componentKey", component_key)
        {:error, _} -> interaction
      end

    interaction
    |> Map.put_new("explicit", false)
    |> Map.put_new("sourceEvidence", [])
    |> Map.put_new("correctResponseEvidence", [])
    |> Map.put_new("correctResponseSource", nil)
    |> Map.put_new("status", "ready")
    |> Map.put_new("manualGrading", false)
    |> Map.put_new("scoring", %{"mode" => "formative", "points" => 0})
    |> Map.put_new("evaluationPolicy", @default_evaluation_policy)
    |> Map.put_new("feedback", %{
      "static" => %{},
      "runtimeAi" => %{
        "recommended" => false,
        "enabled" => false,
        "authorOptIn" => false,
        "staticFallbackKey" => nil
      }
    })
    |> Map.update!("sourceEvidence", &normalize_source_refs/1)
    |> Map.update!("correctResponseEvidence", &normalize_source_refs/1)
  end

  defp normalize_interaction(interaction), do: interaction

  defp normalize_objectives(objectives) when is_map(objectives) do
    %{"mapped" => [], "proposed" => []}
    |> deep_merge(objectives)
    |> Map.update!("mapped", &list_or_original/1)
    |> Map.update!("proposed", &list_or_original/1)
  end

  defp normalize_objectives(objectives), do: objectives

  defp validate_plan_shape(errors, plan) do
    errors
    |> require_enum(plan["status"], @statuses, "status")
    |> require_catalog_version(plan["catalogVersion"])
    |> require_map(plan["source"], "source")
    |> require_map(plan["lesson"], "lesson")
    |> require_map(plan["objectives"], "objectives")
    |> require_list(plan["variables"], "variables")
    |> require_list(plan["blockers"], "blockers")
    |> require_list(plan["warnings"], "warnings")
    |> require_list(plan["assumptions"], "assumptions")
  end

  defp validate_plan_limits(errors, plan) do
    screens = get_in(plan, ["lesson", "screens"]) || []

    total_parts =
      Enum.reduce(List.wrap(screens), 0, fn
        screen, total when is_map(screen) -> total + length(List.wrap(screen["parts"]))
        _screen, total -> total
      end)

    total_interactions =
      Enum.reduce(List.wrap(screens), 0, fn
        screen, total when is_map(screen) -> total + length(List.wrap(screen["interactions"]))
        _screen, total -> total
      end)

    errors =
      errors
      |> require_max_count(screens, @max_screens, "lesson.screens")
      |> require_max_value(total_parts, @max_total_parts, "lesson.screens.parts")
      |> require_max_value(
        total_interactions,
        @max_total_interactions,
        "lesson.screens.interactions"
      )
      |> require_max_count(plan["variables"], @max_variables, "variables")
      |> require_max_count(
        get_in(plan, ["objectives", "mapped"]),
        @max_objectives,
        "objectives.mapped"
      )
      |> require_max_count(
        get_in(plan, ["objectives", "proposed"]),
        @max_objectives,
        "objectives.proposed"
      )

    errors =
      screens
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.reduce(errors, fn
        {screen, index}, acc when is_map(screen) ->
          acc
          |> require_max_count(
            screen["parts"],
            @max_parts_per_screen,
            "lesson.screens[#{index}].parts"
          )
          |> require_max_count(
            screen["interactions"],
            @max_interactions_per_screen,
            "lesson.screens[#{index}].interactions"
          )
          |> require_max_count(
            screen["adaptivity"],
            @max_adaptivity_rules_per_screen,
            "lesson.screens[#{index}].adaptivity"
          )

        {_screen, _index}, acc ->
          acc
      end)

    encoded_size =
      case Jason.encode(plan) do
        {:ok, encoded} -> byte_size(encoded)
        {:error, _reason} -> @max_plan_bytes + 1
      end

    require_max_value(errors, encoded_size, @max_plan_bytes, "$")
  end

  defp require_catalog_version(errors, version) do
    if version == Catalog.version() do
      errors
    else
      [
        error(
          "catalogVersion",
          "unsupported_version",
          "lesson plan catalog version must be #{Catalog.version()}"
        )
        | errors
      ]
    end
  end

  defp validate_source(errors, source, mode) when is_map(source) do
    if mode == :final do
      errors
      |> require_non_empty_string(source["presentationId"], "source.presentationId")
      |> require_non_empty_string(source["fingerprint"], "source.fingerprint")
    else
      errors
    end
  end

  defp validate_source(errors, _source, _mode), do: errors

  defp validate_lesson(errors, lesson, mode) when is_map(lesson) do
    errors =
      errors
      |> require_key(lesson["key"], "lesson.key")
      |> require_map(lesson["layout"], "lesson.layout")
      |> require_list(lesson["screens"], "lesson.screens")

    errors =
      if mode == :final do
        errors
        |> require_non_empty_string(lesson["title"], "lesson.title")
        |> require_non_empty_list(lesson["screens"], "lesson.screens")
      else
        errors
      end

    errors
    |> validate_layout(lesson["layout"])
    |> validate_screens(lesson["screens"], mode)
  end

  defp validate_lesson(errors, _lesson, _mode), do: errors

  defp validate_layout(errors, layout) when is_map(layout) do
    errors =
      errors
      |> require_enum(layout["mode"], @layout_modes, "lesson.layout.mode")
      |> validate_style_profile(layout["styleProfile"])
      |> require_list(layout["styleRules"], "lesson.layout.styleRules")

    errors =
      case layout["styleRules"] do
        rules when is_list(rules) ->
          case CSSCompiler.validate(rules) do
            :ok -> errors
            {:error, css_errors} -> Enum.reverse(css_errors) ++ errors
          end

        _ ->
          errors
      end

    case layout do
      %{"mode" => "pixel", "canvas" => canvas} ->
        validate_canvas(errors, canvas)

      _ ->
        errors
    end
  end

  defp validate_layout(errors, _layout), do: errors

  defp validate_canvas(errors, canvas) when is_map(canvas) do
    errors
    |> require_positive_number(canvas["width"], "lesson.layout.canvas.width")
    |> require_positive_number(canvas["height"], "lesson.layout.canvas.height")
  end

  defp validate_canvas(errors, _canvas) do
    [error("lesson.layout.canvas", "required", "pixel layout requires a canvas") | errors]
  end

  defp validate_style_profile(errors, profile_key) do
    case Catalog.style_profile(profile_key) do
      {:ok, _profile} ->
        errors

      {:error, _} ->
        [
          error(
            "lesson.layout.styleProfile",
            "unsupported",
            "style profile is not in the reviewed catalog"
          )
          | errors
        ]
    end
  end

  defp validate_screens(errors, screens, mode) when is_list(screens) do
    errors =
      duplicate_errors(
        errors,
        screens,
        &map_key(&1, "key"),
        "lesson.screens",
        "screen key"
      )

    screens
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {screen, index}, acc ->
      validate_screen(acc, screen, index, mode)
    end)
  end

  defp validate_screens(errors, _screens, _mode), do: errors

  defp validate_screen(errors, screen, index, mode) when is_map(screen) do
    path = "lesson.screens[#{index}]"

    errors =
      errors
      |> require_key(screen["key"], "#{path}.key")
      |> require_non_empty_string(screen["title"], "#{path}.title")
      |> require_list(screen["sourceRefs"], "#{path}.sourceRefs")
      |> require_list(screen["parts"], "#{path}.parts")
      |> require_list(screen["interactions"], "#{path}.interactions")
      |> require_list(screen["adaptivity"], "#{path}.adaptivity")

    errors =
      if mode == :final do
        require_non_empty_list(errors, screen["sourceRefs"], "#{path}.sourceRefs")
      else
        errors
      end

    interaction_keys =
      case screen["interactions"] do
        interactions when is_list(interactions) ->
          interactions
          |> Enum.filter(&is_map/1)
          |> Enum.map(& &1["key"])
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    errors
    |> validate_parts(screen["parts"], path, mode)
    |> validate_interactions(screen["interactions"], path, mode)
    |> validate_screen_interaction_policy(screen["interactions"], path, mode)
    |> validate_adaptivity(screen["adaptivity"], path, interaction_keys, mode)
  end

  defp validate_screen(errors, _screen, index, _mode) do
    [error("lesson.screens[#{index}]", "invalid_type", "screen must be an object") | errors]
  end

  defp validate_parts(errors, parts, screen_path, mode) when is_list(parts) do
    errors =
      duplicate_errors(
        errors,
        parts,
        &map_key(&1, "key"),
        "#{screen_path}.parts",
        "part key"
      )

    parts
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {part, index}, acc when is_map(part) ->
        path = "#{screen_path}.parts[#{index}]"

        acc =
          acc
          |> require_key(part["key"], "#{path}.key")
          |> validate_part_kind(part["kind"], "#{path}.kind")
          |> require_list(part["sourceRefs"], "#{path}.sourceRefs")
          |> require_map(part["accessibility"], "#{path}.accessibility")
          |> require_map(part["layout"], "#{path}.layout")

        acc =
          if mode == :final do
            require_non_empty_list(acc, part["sourceRefs"], "#{path}.sourceRefs")
          else
            acc
          end

        acc
        |> validate_part_accessibility(part, path, mode)
        |> validate_part_contract(part, path, mode)

      {_part, index}, acc ->
        [error("#{screen_path}.parts[#{index}]", "invalid_type", "part must be an object") | acc]
    end)
  end

  defp validate_parts(errors, _parts, _screen_path, _mode), do: errors

  defp validate_part_kind(errors, kind, path) do
    if Catalog.supported_content_part?(kind) do
      errors
    else
      [error(path, "unsupported", "content part kind is not in the reviewed catalog") | errors]
    end
  end

  defp validate_part_accessibility(errors, %{"kind" => "image"} = part, path, :final) do
    accessibility = map_or_empty(part["accessibility"])
    require_non_empty_string(errors, accessibility["altText"], "#{path}.accessibility.altText")
  end

  defp validate_part_accessibility(errors, %{"kind" => "video"} = part, path, :final) do
    accessibility = map_or_empty(part["accessibility"])
    require_non_empty_string(errors, accessibility["captions"], "#{path}.accessibility.captions")
  end

  defp validate_part_accessibility(
         errors,
         %{"kind" => kind, "content" => %{"sourceObjectId" => object_id}} = part,
         path,
         :final
       )
       when kind in ["chart", "shape", "line", "word_art"] and
              is_binary(object_id) and object_id != "" do
    if graphic_requires_alt?(kind, part["content"]) do
      accessibility = map_or_empty(part["accessibility"])
      require_non_empty_string(errors, accessibility["altText"], "#{path}.accessibility.altText")
    else
      errors
    end
  end

  defp validate_part_accessibility(errors, _part, _path, _mode), do: errors

  defp graphic_requires_alt?("word_art", _content), do: false

  defp graphic_requires_alt?("shape", content) when is_map(content),
    do: not present_string?(content["text"])

  defp graphic_requires_alt?(kind, _content), do: kind in ["chart", "line"]

  defp validate_part_contract(errors, part, path, mode) do
    content = part["content"]

    errors =
      errors
      |> require_map(content, "#{path}.content")
      |> validate_content_payload(part["kind"], content, "#{path}.content")

    if mode == :final and is_map(content) do
      case part["kind"] do
        "image" ->
          require_non_empty_string(
            errors,
            content["sourceObjectId"],
            "#{path}.content.sourceObjectId"
          )

        "video" ->
          errors
          |> require_non_empty_string(
            content["sourceObjectId"],
            "#{path}.content.sourceObjectId"
          )
          |> require_safe_media_url(
            get_in(part, ["accessibility", "captions"]),
            "#{path}.accessibility.captions"
          )

        "audio" ->
          errors
          |> require_safe_media_url(content["src"], "#{path}.content.src")
          |> validate_optional_safe_media_url(
            get_in(part, ["accessibility", "captions"]),
            "#{path}.accessibility.captions"
          )
          |> require_non_empty_string(
            get_in(part, ["accessibility", "transcript"]),
            "#{path}.accessibility.transcript"
          )

        "iframe" ->
          require_safe_https_url(errors, content["src"], "#{path}.content.src")

        _ ->
          errors
      end
    else
      errors
    end
  end

  defp validate_content_payload(errors, _kind, content, _path) when not is_map(content),
    do: errors

  defp validate_content_payload(errors, "text", content, path) do
    errors
    |> reject_unknown_keys(content, ~w(text tag role), path)
    |> require_non_empty_string(content["text"], "#{path}.text")
    |> validate_optional_enum(content["tag"], ~w(p h1 h2 h3 h4 h5 h6), "#{path}.tag")
    |> validate_optional_enum(content["role"], ~w(p h1 h2 h3 h4 h5 h6), "#{path}.role")
  end

  defp validate_content_payload(errors, "list", content, path) do
    items = content["items"]

    errors =
      errors
      |> reject_unknown_keys(content, ~w(items listType), path)
      |> require_non_empty_list(items, "#{path}.items")
      |> validate_optional_enum(content["listType"], ~w(ul ol), "#{path}.listType")

    if is_list(items) and Enum.all?(items, &present_string?/1) do
      errors
    else
      [
        error("#{path}.items", "invalid_value", "list items must be non-empty strings")
        | errors
      ]
    end
  end

  defp validate_content_payload(errors, "table", content, path) do
    rows = content["rows"]

    errors =
      errors
      |> reject_unknown_keys(content, ["rows"], path)
      |> require_non_empty_list(rows, "#{path}.rows")

    cond do
      not is_list(rows) ->
        errors

      length(rows) > 200 ->
        [error("#{path}.rows", "limit_exceeded", "tables may contain at most 200 rows") | errors]

      Enum.all?(rows, &valid_table_row?/1) ->
        errors

      true ->
        [
          error(
            "#{path}.rows",
            "invalid_value",
            "table rows must contain at most 30 scalar cells"
          )
          | errors
        ]
    end
  end

  defp validate_content_payload(errors, "word_art", content, path) do
    errors
    |> reject_unknown_keys(content, ~w(sourceObjectId text), path)
    |> require_non_empty_string(content["text"], "#{path}.text")
  end

  defp validate_content_payload(errors, kind, content, path)
       when kind in ["chart", "shape", "line"] do
    errors =
      reject_unknown_keys(errors, content, ~w(sourceObjectId text), path)

    if present_string?(content["sourceObjectId"]) or present_string?(content["text"]) do
      errors
    else
      [
        error(
          path,
          "required",
          "graphic content requires a source object identifier or source-grounded text"
        )
        | errors
      ]
    end
  end

  defp validate_content_payload(errors, "image", content, path) do
    reject_unknown_keys(errors, content, ~w(sourceObjectId mimeType), path)
  end

  defp validate_content_payload(errors, "video", content, path) do
    reject_unknown_keys(errors, content, ~w(sourceObjectId mimeType), path)
  end

  defp validate_content_payload(errors, "audio", content, path) do
    reject_unknown_keys(errors, content, ~w(src mimeType), path)
  end

  defp validate_content_payload(errors, "iframe", content, path) do
    reject_unknown_keys(errors, content, ~w(src allowScrolling), path)
  end

  defp validate_content_payload(errors, _kind, _content, _path), do: errors

  defp validate_optional_enum(errors, nil, _allowed, _path), do: errors

  defp validate_optional_enum(errors, value, allowed, path),
    do: require_enum(errors, value, allowed, path)

  defp valid_table_row?(row) when is_list(row) and row != [] and length(row) <= 30,
    do: Enum.all?(row, &table_scalar?/1)

  defp valid_table_row?(_row), do: false

  defp table_scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: true

  defp table_scalar?(_value), do: false

  defp validate_interactions(errors, interactions, screen_path, mode)
       when is_list(interactions) do
    errors =
      duplicate_errors(
        errors,
        interactions,
        &map_key(&1, "key"),
        "#{screen_path}.interactions",
        "interaction key"
      )

    interactions
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {interaction, index}, acc when is_map(interaction) ->
        path = "#{screen_path}.interactions[#{index}]"

        acc
        |> require_key(interaction["key"], "#{path}.key")
        |> require_true(
          interaction["explicit"],
          "#{path}.explicit",
          "only explicit source interactions are allowed"
        )
        |> require_non_empty_list(interaction["sourceEvidence"], "#{path}.sourceEvidence")
        |> require_list(
          interaction["correctResponseEvidence"],
          "#{path}.correctResponseEvidence"
        )
        |> validate_component(interaction["componentKey"], "#{path}.componentKey")
        |> require_boolean(interaction["manualGrading"], "#{path}.manualGrading")
        |> validate_scoring(interaction["scoring"], path)
        |> require_map(interaction["configuration"], "#{path}.configuration")
        |> require_map(interaction["evaluationPolicy"], "#{path}.evaluationPolicy")
        |> require_map(interaction["feedback"], "#{path}.feedback")
        |> validate_interaction_contract(interaction, path, mode)
        |> validate_evaluation_policy(interaction, path, mode)
        |> validate_correct_response(interaction, path, mode)
        |> validate_static_feedback(interaction, path, mode)
        |> validate_runtime_ai(interaction["feedback"], path, mode)

      {_interaction, index}, acc ->
        [
          error(
            "#{screen_path}.interactions[#{index}]",
            "invalid_type",
            "interaction must be an object"
          )
          | acc
        ]
    end)
  end

  defp validate_interactions(errors, _interactions, _screen_path, _mode), do: errors

  defp validate_screen_interaction_policy(errors, interactions, path, :final)
       when is_list(interactions) do
    automatically_evaluated =
      Enum.count(interactions, fn interaction ->
        is_map(interaction) and Catalog.automatically_evaluated?(interaction["componentKey"])
      end)

    runtime_ai_enabled =
      Enum.count(interactions, fn interaction ->
        is_map(interaction) and get_in(interaction, ["feedback", "runtimeAi", "enabled"]) == true
      end)

    errors =
      if automatically_evaluated <= 1 do
        errors
      else
        [
          error(
            "#{path}.interactions",
            "unsupported",
            "import v1 supports one automatically evaluated interaction per screen; split the source into additional screens"
          )
          | errors
        ]
      end

    if runtime_ai_enabled <= 1 do
      errors
    else
      [
        error(
          "#{path}.interactions",
          "unsupported",
          "only one runtime AI feedback configuration is supported per screen"
        )
        | errors
      ]
    end
  end

  defp validate_screen_interaction_policy(errors, _interactions, _path, _mode), do: errors

  defp validate_component(errors, component_key, path) do
    case Catalog.component(component_key) do
      {:ok, _component} ->
        errors

      {:error, _} ->
        [error(path, "unsupported", "component is not in the reviewed catalog") | errors]
    end
  end

  defp validate_scoring(errors, scoring, path) when is_map(scoring) do
    mode = scoring["mode"]
    points = scoring["points"]

    errors = require_enum(errors, mode, ["formative"], "#{path}.scoring.mode")

    cond do
      not is_number(points) or points < 0 ->
        [
          error("#{path}.scoring.points", "invalid_value", "scoring points cannot be negative")
          | errors
        ]

      mode == "formative" and points != 0 ->
        [
          error(
            "#{path}.scoring.points",
            "invalid_value",
            "formative interactions must have zero points"
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_scoring(errors, _scoring, path) do
    [error("#{path}.scoring", "invalid_type", "scoring must be an object") | errors]
  end

  defp validate_interaction_contract(errors, interaction, path, mode) do
    component = interaction["componentKey"]
    configuration = interaction["configuration"]

    errors =
      if mode == :final do
        require_non_empty_string(errors, interaction["prompt"], "#{path}.prompt")
      else
        errors
      end

    errors =
      if mode == :final and Catalog.automatically_evaluated?(component) and
           interaction["manualGrading"] == true do
        [
          error(
            "#{path}.manualGrading",
            "unsupported",
            "the importer cannot safely compile manual grading for this component"
          )
          | errors
        ]
      else
        errors
      end

    errors =
      if mode == :final and
           get_in(interaction, ["feedback", "runtimeAi", "enabled"]) == true and
           not Catalog.automatically_evaluated?(component) do
        [
          error(
            "#{path}.feedback.runtimeAi.enabled",
            "unsupported",
            "runtime AI feedback requires an automatically evaluated interaction"
          )
          | errors
        ]
      else
        errors
      end

    if is_map(configuration) do
      validate_component_configuration(errors, component, configuration, interaction, path, mode)
    else
      errors
    end
  end

  defp validate_component_configuration(
         errors,
         "multiple_choice",
         configuration,
         interaction,
         path,
         mode
       ) do
    validate_option_configuration(
      errors,
      configuration["choices"],
      interaction["correctResponse"],
      "#{path}.configuration.choices",
      path,
      mode
    )
  end

  defp validate_component_configuration(
         errors,
         "dropdown",
         configuration,
         interaction,
         path,
         mode
       ) do
    options = configuration["optionLabels"] || configuration["choices"]

    validate_option_configuration(
      errors,
      options,
      interaction["correctResponse"],
      "#{path}.configuration.optionLabels",
      path,
      mode
    )
  end

  defp validate_component_configuration(
         errors,
         "text_slider",
         configuration,
         interaction,
         path,
         mode
       ) do
    options = configuration["sliderOptionLabels"] || configuration["choices"]

    validate_option_configuration(
      errors,
      options,
      interaction["correctResponse"],
      "#{path}.configuration.sliderOptionLabels",
      path,
      mode
    )
  end

  defp validate_component_configuration(
         errors,
         "slider",
         configuration,
         interaction,
         path,
         mode
       ) do
    min = configuration["min"]
    max = configuration["max"]
    step = configuration["step"]
    response = response_value(interaction["correctResponse"])

    errors =
      errors
      |> require_number(min, "#{path}.configuration.min")
      |> require_number(max, "#{path}.configuration.max")
      |> require_positive_number(step, "#{path}.configuration.step")

    errors =
      if is_number(min) and is_number(max) and min < max do
        errors
      else
        [
          error(
            "#{path}.configuration.max",
            "invalid_value",
            "slider maximum must be greater than its minimum"
          )
          | errors
        ]
      end

    if (mode == :final or not is_nil(interaction["correctResponse"])) and
         (not is_number(response) or not is_number(min) or not is_number(max) or response < min or
            response > max) do
      [
        error(
          "#{path}.correctResponse",
          "invalid_value",
          "slider correct response must be a number within the configured range"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_component_configuration(
         errors,
         "number_input",
         _configuration,
         interaction,
         path,
         mode
       ) do
    if mode != :final and is_nil(interaction["correctResponse"]) do
      errors
    else
      validate_number_input_response(errors, interaction, path)
    end
  end

  defp validate_component_configuration(
         errors,
         "text_input",
         _configuration,
         interaction,
         path,
         mode
       ) do
    if mode != :final and is_nil(interaction["correctResponse"]) do
      errors
    else
      validate_text_input_response(errors, interaction, path)
    end
  end

  defp validate_component_configuration(
         errors,
         "iframe",
         configuration,
         _interaction,
         path,
         _mode
       ) do
    if safe_https_url?(configuration["src"]) do
      errors
    else
      [
        error(
          "#{path}.configuration.src",
          "unsafe_url",
          "iframe source must be an absolute HTTPS URL"
        )
        | errors
      ]
    end
  end

  defp validate_component_configuration(
         errors,
         _component,
         _configuration,
         _interaction,
         _path,
         _mode
       ),
       do: errors

  defp validate_number_input_response(errors, interaction, path) do
    if is_number(response_value(interaction["correctResponse"])) do
      errors
    else
      [
        error(
          "#{path}.correctResponse",
          "invalid_type",
          "number input correct response must be numeric"
        )
        | errors
      ]
    end
  end

  defp validate_text_input_response(errors, interaction, path) do
    case interaction["correctResponse"] do
      response when is_binary(response) ->
        require_non_empty_string(errors, response, "#{path}.correctResponse")

      %{} = response ->
        errors
        |> require_non_empty_string(
          response["mustContain"],
          "#{path}.correctResponse.mustContain"
        )
        |> validate_optional_non_negative_integer(
          response["minimumLength"],
          "#{path}.correctResponse.minimumLength"
        )
        |> validate_optional_string(
          response["mustNotContain"],
          "#{path}.correctResponse.mustNotContain"
        )

      _ ->
        [
          error(
            "#{path}.correctResponse",
            "invalid_type",
            "text input correct response must be text or reviewed text criteria"
          )
          | errors
        ]
    end
  end

  defp validate_option_configuration(errors, options, response, options_path, path, mode) do
    valid_options? =
      is_list(options) and length(options) >= 2 and
        Enum.all?(options, &present_string?/1) and
        length(Enum.uniq(options)) == length(options)

    errors =
      if valid_options? do
        errors
      else
        [
          error(
            options_path,
            "invalid_value",
            "must contain at least two unique non-empty option labels"
          )
          | errors
        ]
      end

    if (mode == :final or not is_nil(response)) and
         (not valid_options? or not valid_option_response?(response, options)) do
      [
        error(
          "#{path}.correctResponse",
          "invalid_value",
          "correct response must identify one configured option by zero-based index or exact label"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp valid_option_response?(response, options) when is_list(options) do
    case response do
      index when is_integer(index) -> index >= 0 and index < length(options)
      %{"index" => index} when is_integer(index) -> index >= 0 and index < length(options)
      label when is_binary(label) -> label in options
      _ -> false
    end
  end

  defp valid_option_response?(_response, _options), do: false

  defp validate_correct_response(errors, interaction, path, :final) do
    if Catalog.automatically_evaluated?(interaction["componentKey"]) and
         interaction["manualGrading"] != true do
      errors =
        if is_nil(interaction["correctResponse"]) do
          [
            error(
              "#{path}.correctResponse",
              "required",
              "automatically evaluated interactions require a confirmed correct response"
            )
            | errors
          ]
        else
          errors
        end

      errors =
        require_enum(
          errors,
          interaction["correctResponseSource"],
          ["source_evidence", "author_answer"],
          "#{path}.correctResponseSource"
        )

      if interaction["correctResponseSource"] == "source_evidence" do
        require_non_empty_list(
          errors,
          interaction["correctResponseEvidence"],
          "#{path}.correctResponseEvidence"
        )
      else
        errors
      end
    else
      errors
    end
  end

  defp validate_correct_response(errors, _interaction, _path, _mode), do: errors

  defp validate_static_feedback(errors, interaction, path, :final) do
    if Catalog.automatically_evaluated?(interaction["componentKey"]) do
      static = get_in(interaction, ["feedback", "static"])

      errors =
        if is_map(static) do
          errors
        else
          [
            error("#{path}.feedback.static", "invalid_type", "static feedback must be an object")
            | errors
          ]
        end

      errors
      |> require_feedback(static, "correct", "#{path}.feedback.static.correct")
      |> require_feedback(static, "incorrect", "#{path}.feedback.static.incorrect")
    else
      errors
    end
  end

  defp validate_static_feedback(errors, _interaction, _path, _mode), do: errors

  defp validate_evaluation_policy(errors, interaction, path, :final) do
    if Catalog.automatically_evaluated?(interaction["componentKey"]) do
      policy = interaction["evaluationPolicy"]

      if is_map(policy) do
        errors
        |> reject_unknown_keys(
          policy,
          ~w(maxAttempts onCorrect onIncorrect revealAnswerAfterMaxAttempts blankFeedback exhaustedFeedback),
          "#{path}.evaluationPolicy"
        )
        |> validate_policy_attempts(policy["maxAttempts"], "#{path}.evaluationPolicy.maxAttempts")
        |> require_enum(
          policy["onCorrect"],
          ["navigate_next"],
          "#{path}.evaluationPolicy.onCorrect"
        )
        |> require_enum(
          policy["onIncorrect"],
          ["retry_with_feedback"],
          "#{path}.evaluationPolicy.onIncorrect"
        )
        |> require_true(
          policy["revealAnswerAfterMaxAttempts"],
          "#{path}.evaluationPolicy.revealAnswerAfterMaxAttempts",
          "the reviewed v1 evaluation policy must reveal the answer after the final attempt"
        )
        |> require_non_empty_string(
          policy["blankFeedback"],
          "#{path}.evaluationPolicy.blankFeedback"
        )
        |> require_non_empty_string(
          policy["exhaustedFeedback"],
          "#{path}.evaluationPolicy.exhaustedFeedback"
        )
      else
        errors
      end
    else
      errors
    end
  end

  defp validate_evaluation_policy(errors, _interaction, _path, _mode), do: errors

  defp validate_policy_attempts(errors, attempts, _path)
       when is_integer(attempts) and attempts >= 1 and attempts <= 10,
       do: errors

  defp validate_policy_attempts(errors, _attempts, path),
    do: [error(path, "invalid_value", "must be an integer from 1 through 10") | errors]

  defp require_feedback(errors, feedback, key, path) when is_map(feedback) do
    if feedback_present?(feedback[key]) do
      errors
    else
      [error(path, "required", "reviewed static feedback is required") | errors]
    end
  end

  defp require_feedback(errors, _feedback, _key, path),
    do: [error(path, "required", "reviewed static feedback is required") | errors]

  defp validate_runtime_ai(errors, feedback, path, :final) when is_map(feedback) do
    case feedback["runtimeAi"] do
      %{"enabled" => true} = runtime_ai ->
        fallback_key = runtime_ai["staticFallbackKey"]

        errors =
          errors
          |> require_true(
            runtime_ai["authorOptIn"],
            "#{path}.feedback.runtimeAi.authorOptIn",
            "runtime AI feedback requires author opt-in"
          )
          |> require_enum(
            runtime_ai["optInSource"],
            ["author_answer"],
            "#{path}.feedback.runtimeAi.optInSource"
          )
          |> require_non_empty_string(
            fallback_key,
            "#{path}.feedback.runtimeAi.staticFallbackKey"
          )
          |> require_non_empty_string(
            runtime_ai["prompt"],
            "#{path}.feedback.runtimeAi.prompt"
          )

        static_feedback = feedback["static"]

        if is_binary(fallback_key) and is_map(static_feedback) and
             present_string?(static_feedback[fallback_key]) do
          errors
        else
          [
            error(
              "#{path}.feedback.runtimeAi.staticFallbackKey",
              "unknown_reference",
              "static fallback key must reference reviewed static feedback"
            )
            | errors
          ]
        end

      _ ->
        errors
    end
  end

  defp validate_runtime_ai(errors, _feedback, _path, _mode), do: errors

  defp validate_adaptivity(errors, rules, screen_path, interaction_keys, mode)
       when is_list(rules) do
    errors =
      duplicate_errors(
        errors,
        rules,
        &map_key(&1, "key"),
        "#{screen_path}.adaptivity",
        "adaptivity key"
      )

    rules
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {rule, index}, acc when is_map(rule) ->
        path = "#{screen_path}.adaptivity[#{index}]"
        condition = rule["condition"]

        acc =
          acc
          |> require_key(rule["key"], "#{path}.key")
          |> require_map(condition, "#{path}.condition")
          |> require_map(rule["action"], "#{path}.action")
          |> require_list(rule["sourceRefs"], "#{path}.sourceRefs")
          |> validate_adaptivity_max_attempt(rule["maxAttempt"], path)

        acc =
          if mode == :final do
            require_non_empty_list(acc, rule["sourceRefs"], "#{path}.sourceRefs")
          else
            acc
          end

        interaction_key =
          if is_map(condition), do: condition["interactionKey"]

        acc =
          if is_nil(interaction_key) or MapSet.member?(interaction_keys, interaction_key) do
            acc
          else
            [
              error(
                "#{path}.condition.interactionKey",
                "unknown_reference",
                "adaptivity references an interaction that is not on this screen"
              )
              | acc
            ]
          end

        validate_adaptivity_contract(acc, rule, path)

      {_rule, index}, acc ->
        [
          error(
            "#{screen_path}.adaptivity[#{index}]",
            "invalid_type",
            "adaptivity rule must be an object"
          )
          | acc
        ]
    end)
  end

  defp validate_adaptivity(errors, _rules, _screen_path, _interaction_keys, _mode), do: errors

  defp validate_adaptivity_contract(errors, %{"condition" => condition, "action" => action}, path)
       when is_map(condition) and is_map(action) do
    outcome = condition["outcome"]
    option = condition["option"]
    action_type = action["type"]

    errors =
      errors
      |> reject_unknown_keys(
        condition,
        ~w(outcome interactionKey option maxAttempt),
        "#{path}.condition"
      )
      |> reject_unknown_keys(
        action,
        ~w(type target message variableKey value maxAttempt),
        "#{path}.action"
      )
      |> require_enum(outcome, ~w(correct incorrect), "#{path}.condition.outcome")
      |> require_enum(
        action_type,
        ~w(navigate feedback set_variable increment_variable),
        "#{path}.action.type"
      )

    case action_type do
      "navigate" ->
        require_non_empty_string(errors, action["target"], "#{path}.action.target")

      "feedback" ->
        errors
        |> require_non_empty_string(action["message"], "#{path}.action.message")
        |> require_present(
          option,
          "#{path}.condition.option",
          "specific feedback requires an explicit incorrect option"
        )
        |> require_value(
          outcome,
          "incorrect",
          "#{path}.condition.outcome",
          "specific feedback can only be attached to an incorrect response"
        )

      "set_variable" ->
        errors
        |> require_key(action["variableKey"], "#{path}.action.variableKey")
        |> require_present(
          action["value"],
          "#{path}.action.value",
          "setting a variable requires a value"
        )
        |> prohibit_option(option, path)

      "increment_variable" ->
        errors
        |> require_key(action["variableKey"], "#{path}.action.variableKey")
        |> require_number(action["value"], "#{path}.action.value")
        |> prohibit_option(option, path)

      _ ->
        errors
    end
  end

  defp validate_adaptivity_contract(errors, _rule, _path), do: errors

  defp validate_adaptivity_max_attempt(errors, nil, _path), do: errors

  defp validate_adaptivity_max_attempt(errors, max_attempt, _path)
       when is_integer(max_attempt) and max_attempt >= 1 and max_attempt <= 10,
       do: errors

  defp validate_adaptivity_max_attempt(errors, _max_attempt, path) do
    [
      error(
        "#{path}.maxAttempt",
        "invalid_value",
        "maximum attempts must be an integer from 1 through 10"
      )
      | errors
    ]
  end

  defp prohibit_option(errors, nil, _path), do: errors

  defp prohibit_option(errors, _option, path) do
    [
      error(
        "#{path}.condition.option",
        "unsupported",
        "variable mutations cannot be scoped to an option in this importer"
      )
      | errors
    ]
  end

  defp validate_objectives(errors, objectives, mode) when is_map(objectives) do
    errors =
      errors
      |> require_list(objectives["mapped"], "objectives.mapped")
      |> require_list(objectives["proposed"], "objectives.proposed")

    errors
    |> validate_mapped_objectives(objectives["mapped"], mode)
    |> validate_proposed_objectives(objectives["proposed"], mode)
  end

  defp validate_objectives(errors, _objectives, _mode), do: errors

  defp validate_mapped_objectives(errors, objectives, mode) when is_list(objectives) do
    errors =
      duplicate_errors(
        errors,
        objectives,
        &map_key(&1, "objectiveId"),
        "objectives.mapped",
        "objective id"
      )

    objectives
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {objective, index}, acc when is_map(objective) ->
        path = "objectives.mapped[#{index}]"

        acc =
          acc
          |> require_identifier(objective["objectiveId"], "#{path}.objectiveId")
          |> require_list(objective["screenKeys"], "#{path}.screenKeys")
          |> require_list(objective["sourceRefs"], "#{path}.sourceRefs")

        if mode == :final do
          acc
          |> require_non_empty_list(objective["screenKeys"], "#{path}.screenKeys")
          |> require_non_empty_list(objective["sourceRefs"], "#{path}.sourceRefs")
        else
          acc
        end

      {_objective, index}, acc ->
        [
          error("objectives.mapped[#{index}]", "invalid_type", "objective must be an object")
          | acc
        ]
    end)
  end

  defp validate_mapped_objectives(errors, _objectives, _mode), do: errors

  defp validate_proposed_objectives(errors, objectives, mode) when is_list(objectives) do
    errors =
      duplicate_errors(
        errors,
        objectives,
        &map_key(&1, "key"),
        "objectives.proposed",
        "objective key"
      )

    objectives
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {objective, index}, acc when is_map(objective) ->
        acc =
          acc
          |> require_key(objective["key"], "objectives.proposed[#{index}].key")
          |> require_non_empty_string(
            objective["title"],
            "objectives.proposed[#{index}].title"
          )
          |> require_list(objective["screenKeys"], "objectives.proposed[#{index}].screenKeys")
          |> require_list(objective["sourceRefs"], "objectives.proposed[#{index}].sourceRefs")
          |> require_boolean(objective["confirmed"], "objectives.proposed[#{index}].confirmed")

        acc =
          if mode == :final do
            acc
            |> require_non_empty_list(
              objective["screenKeys"],
              "objectives.proposed[#{index}].screenKeys"
            )
            |> require_non_empty_list(
              objective["sourceRefs"],
              "objectives.proposed[#{index}].sourceRefs"
            )
          else
            acc
          end

        cond do
          mode == :final and objective["confirmed"] != true ->
            [
              error(
                "objectives.proposed[#{index}].confirmed",
                "author_confirmation_required",
                "new objectives require author confirmation"
              )
              | acc
            ]

          mode == :final and objective["confirmationSource"] != "author_answer" ->
            [
              error(
                "objectives.proposed[#{index}].confirmationSource",
                "author_confirmation_required",
                "new objectives require a trusted author confirmation"
              )
              | acc
            ]

          true ->
            acc
        end

      {_objective, index}, acc ->
        [
          error("objectives.proposed[#{index}]", "invalid_type", "objective must be an object")
          | acc
        ]
    end)
  end

  defp validate_proposed_objectives(errors, _objectives, _mode), do: errors

  defp validate_variables(errors, variables, mode) when is_list(variables) do
    errors =
      duplicate_errors(errors, variables, &map_key(&1, "key"), "variables", "variable key")

    variables
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {variable, index}, acc when is_map(variable) ->
        path = "variables[#{index}]"

        acc =
          acc
          |> require_key(variable["key"], "#{path}.key")
          |> require_enum(
            variable["type"],
            ~w(boolean string number integer),
            "#{path}.type"
          )
          |> require_list(variable["sourceRefs"], "#{path}.sourceRefs")
          |> validate_variable_initial_value(variable, path)

        if mode == :final do
          acc
          |> require_non_empty_list(variable["sourceRefs"], "#{path}.sourceRefs")
          |> require_non_empty_string(variable["purpose"], "#{path}.purpose")
        else
          acc
        end

      {_variable, index}, acc ->
        [error("variables[#{index}]", "invalid_type", "variable must be an object") | acc]
    end)
  end

  defp validate_variables(errors, _variables, _mode), do: errors

  defp validate_cross_references(errors, plan, _mode) do
    screens = get_in(plan, ["lesson", "screens"]) || []

    screen_keys =
      screens
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["key"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    variables_by_key =
      (plan["variables"] || [])
      |> Enum.filter(&is_map/1)
      |> Map.new(&{&1["key"], &1})

    errors
    |> validate_objective_screen_references(plan["objectives"] || %{}, screen_keys)
    |> validate_adaptivity_references(screens, screen_keys, variables_by_key)
  end

  defp validate_objective_screen_references(errors, objectives, screen_keys) do
    Enum.reduce(["mapped", "proposed"], errors, fn group, acc ->
      (objectives[group] || [])
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {objective, objective_index}, nested when is_map(objective) ->
          (objective["screenKeys"] || [])
          |> Enum.with_index()
          |> Enum.reduce(nested, fn {screen_key, screen_index}, inner ->
            if MapSet.member?(screen_keys, screen_key) do
              inner
            else
              [
                error(
                  "objectives.#{group}[#{objective_index}].screenKeys[#{screen_index}]",
                  "unknown_reference",
                  "objective references a screen that is not in this lesson"
                )
                | inner
              ]
            end
          end)

        {_objective, _objective_index}, nested ->
          nested
      end)
    end)
  end

  defp validate_adaptivity_references(errors, screens, screen_keys, variables_by_key) do
    screens
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {screen, screen_index}, acc when is_map(screen) ->
        (screen["adaptivity"] || [])
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {rule, rule_index}, nested when is_map(rule) ->
            path = "lesson.screens[#{screen_index}].adaptivity[#{rule_index}]"
            action = map_or_empty(rule["action"])

            nested
            |> validate_navigation_reference(action, path, screen_keys)
            |> validate_variable_action_reference(action, path, variables_by_key)

          {_rule, _rule_index}, nested ->
            nested
        end)

      {_screen, _screen_index}, acc ->
        acc
    end)
  end

  defp validate_navigation_reference(
         errors,
         %{"type" => "navigate", "target" => target},
         path,
         keys
       ) do
    if target == "next" or MapSet.member?(keys, target) do
      errors
    else
      [
        error(
          "#{path}.action.target",
          "unknown_reference",
          "navigation target must be next or a screen in this lesson"
        )
        | errors
      ]
    end
  end

  defp validate_navigation_reference(errors, _action, _path, _keys), do: errors

  defp validate_variable_action_reference(
         errors,
         %{"type" => type, "variableKey" => variable_key} = action,
         path,
         variables_by_key
       )
       when type in ["set_variable", "increment_variable"] do
    case Map.get(variables_by_key, variable_key) do
      nil ->
        [
          error(
            "#{path}.action.variableKey",
            "unknown_reference",
            "adaptivity references an undeclared lesson variable"
          )
          | errors
        ]

      variable ->
        validate_variable_action_value(errors, type, action["value"], variable, path)
    end
  end

  defp validate_variable_action_reference(errors, _action, _path, _variables_by_key),
    do: errors

  defp validate_variable_action_value(errors, "increment_variable", value, variable, path) do
    if variable["type"] in ["number", "integer"] and is_number(value) do
      errors
    else
      [
        error(
          "#{path}.action.value",
          "invalid_type",
          "increment actions require a numeric lesson variable and numeric amount"
        )
        | errors
      ]
    end
  end

  defp validate_variable_action_value(errors, "set_variable", value, variable, path) do
    valid? =
      case {variable["type"], value} do
        {"boolean", value} -> is_boolean(value)
        {"string", value} -> is_binary(value)
        {"integer", value} -> is_integer(value)
        {"number", value} -> is_number(value)
        _ -> false
      end

    if valid? do
      errors
    else
      [
        error(
          "#{path}.action.value",
          "invalid_type",
          "set action value must match the declared lesson variable type"
        )
        | errors
      ]
    end
  end

  defp validate_variable_initial_value(errors, %{"initialValue" => nil}, _path), do: errors

  defp validate_variable_initial_value(errors, variable, path) do
    valid? =
      case {variable["type"], variable["initialValue"]} do
        {"boolean", value} -> is_boolean(value)
        {"string", value} -> is_binary(value)
        {"integer", value} -> is_integer(value)
        {"number", value} -> is_number(value)
        _ -> false
      end

    if valid? do
      errors
    else
      [
        error(
          "#{path}.initialValue",
          "invalid_type",
          "initial value must match the declared variable type"
        )
        | errors
      ]
    end
  end

  defp validate_blockers(errors, blockers, mode) when is_list(blockers) do
    blockers
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {blocker, index}, acc when is_map(blocker) ->
        acc =
          acc
          |> require_non_empty_string(blocker["key"], "blockers[#{index}].key")
          |> require_non_empty_string(blocker["code"], "blockers[#{index}].code")
          |> require_non_empty_string(blocker["message"], "blockers[#{index}].message")
          |> require_list(blocker["sourceRefs"], "blockers[#{index}].sourceRefs")

        if mode == :final do
          [
            error(
              "blockers.#{blocker["key"] || "unresolved"}",
              "unresolved_blocker",
              blocker["message"] || "author input is required"
            )
            | acc
          ]
        else
          acc
        end

      {_blocker, index}, acc ->
        [error("blockers[#{index}]", "invalid_type", "blocker must be an object") | acc]
    end)
  end

  defp validate_blockers(errors, _blockers, _mode), do: errors

  defp validate_review_metadata(errors, warnings, assumptions) do
    errors
    |> validate_review_items(warnings, "warnings")
    |> validate_review_items(assumptions, "assumptions")
  end

  defp validate_review_items(errors, items, path) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {item, index}, acc when is_map(item) ->
        acc
        |> require_non_empty_string(item["key"], "#{path}[#{index}].key")
        |> require_non_empty_string(item["message"], "#{path}[#{index}].message")
        |> require_list(item["sourceRefs"], "#{path}[#{index}].sourceRefs")

      {_item, index}, acc ->
        [error("#{path}[#{index}]", "invalid_type", "review item must be an object") | acc]
    end)
  end

  defp validate_review_items(errors, _items, _path), do: errors

  defp duplicate_errors(errors, items, key_fun, path, label) when is_list(items) do
    {_seen, errors} =
      items
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), errors}, fn {item, index}, {seen, acc} ->
        key = key_fun.(item)

        cond do
          is_nil(key) ->
            {seen, acc}

          MapSet.member?(seen, key) ->
            {seen, [error("#{path}[#{index}].key", "duplicate", "#{label} must be unique") | acc]}

          true ->
            {MapSet.put(seen, key), acc}
        end
      end)

    errors
  end

  defp require_map(errors, value, _path) when is_map(value), do: errors

  defp require_map(errors, _value, path),
    do: [error(path, "invalid_type", "must be an object") | errors]

  defp require_list(errors, value, _path) when is_list(value), do: errors

  defp require_list(errors, _value, path),
    do: [error(path, "invalid_type", "must be a list") | errors]

  defp require_non_empty_list(errors, value, _path) when is_list(value) and value != [],
    do: errors

  defp require_non_empty_list(errors, _value, path),
    do: [error(path, "required", "cannot be empty") | errors]

  defp require_max_count(errors, value, max, _path)
       when is_list(value) and length(value) <= max,
       do: errors

  defp require_max_count(errors, value, max, path) when is_list(value) do
    [
      error(
        path,
        "limit_exceeded",
        "cannot contain more than #{max} entries"
      )
      | errors
    ]
  end

  defp require_max_count(errors, _value, _max, _path), do: errors

  defp require_max_value(errors, value, max, _path) when is_integer(value) and value <= max,
    do: errors

  defp require_max_value(errors, _value, max, path) do
    [
      error(
        path,
        "limit_exceeded",
        "exceeds the importer safety limit of #{max}"
      )
      | errors
    ]
  end

  defp require_non_empty_string(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      [error(path, "required", "must be a non-empty string") | errors]
    else
      errors
    end
  end

  defp require_non_empty_string(errors, _value, path),
    do: [error(path, "required", "must be a non-empty string") | errors]

  defp require_key(errors, value, path) when is_binary(value) do
    if Regex.match?(@key_pattern, value) do
      errors
    else
      [error(path, "invalid_key", "must be a stable lowercase semantic key") | errors]
    end
  end

  defp require_key(errors, _value, path),
    do: [error(path, "invalid_key", "must be a stable lowercase semantic key") | errors]

  defp require_identifier(errors, value, _path)
       when (is_binary(value) and value != "") or (is_integer(value) and value > 0),
       do: errors

  defp require_identifier(errors, _value, path),
    do: [error(path, "required", "must be a resource identifier") | errors]

  defp require_enum(errors, value, allowed, path) do
    if value in allowed do
      errors
    else
      [error(path, "invalid_value", "must be one of #{Enum.join(allowed, ", ")}") | errors]
    end
  end

  defp require_positive_number(errors, value, _path) when is_number(value) and value > 0,
    do: errors

  defp require_positive_number(errors, _value, path),
    do: [error(path, "invalid_value", "must be a positive number") | errors]

  defp require_number(errors, value, _path) when is_number(value), do: errors

  defp require_number(errors, _value, path),
    do: [error(path, "invalid_type", "must be a number") | errors]

  defp require_safe_media_url(errors, value, path),
    do: require_safe_https_url(errors, value, path)

  defp validate_optional_safe_media_url(errors, value, _path) when value in [nil, ""],
    do: errors

  defp validate_optional_safe_media_url(errors, value, path),
    do: require_safe_media_url(errors, value, path)

  defp require_safe_https_url(errors, value, path) do
    if safe_https_url?(value) do
      errors
    else
      [error(path, "unsafe_url", "must be an absolute HTTPS URL") | errors]
    end
  end

  defp require_boolean(errors, value, _path) when is_boolean(value), do: errors

  defp require_boolean(errors, _value, path),
    do: [error(path, "invalid_type", "must be a boolean") | errors]

  defp require_true(errors, true, _path, _message), do: errors

  defp require_true(errors, _value, path, message),
    do: [error(path, "required", message) | errors]

  defp require_present(errors, nil, path, message),
    do: [error(path, "required", message) | errors]

  defp require_present(errors, "", path, message), do: [error(path, "required", message) | errors]
  defp require_present(errors, _value, _path, _message), do: errors

  defp require_value(errors, value, value, _path, _message), do: errors

  defp require_value(errors, _actual, _expected, path, message),
    do: [error(path, "invalid_value", message) | errors]

  defp validate_optional_non_negative_integer(errors, nil, _path), do: errors

  defp validate_optional_non_negative_integer(errors, value, _path)
       when is_integer(value) and value >= 0,
       do: errors

  defp validate_optional_non_negative_integer(errors, _value, path),
    do: [error(path, "invalid_value", "must be a non-negative integer") | errors]

  defp validate_optional_string(errors, nil, _path), do: errors
  defp validate_optional_string(errors, value, _path) when is_binary(value), do: errors

  defp validate_optional_string(errors, _value, path),
    do: [error(path, "invalid_type", "must be a string") | errors]

  defp reject_unknown_keys(errors, value, allowed, path) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.reduce(errors, fn key, acc ->
      [
        error(
          "#{path}.#{key}",
          "unsupported",
          "field is not part of the supported semantic adaptivity contract"
        )
        | acc
      ]
    end)
  end

  defp reject_unknown_keys(errors, _value, _allowed, _path), do: errors

  defp feedback_present?(value) when is_binary(value), do: present_string?(value)
  defp feedback_present?(%{"message" => message}), do: present_string?(message)
  defp feedback_present?(_value), do: false

  defp response_value(%{"value" => value}), do: value
  defp response_value(value), do: value

  defp safe_https_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp safe_https_url?(_url), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp normalize_source_refs(nil), do: []

  defp normalize_source_refs(refs) when is_list(refs) do
    Enum.map(refs, fn
      ref when is_map(ref) -> stringify_keys(ref)
      ref when is_binary(ref) -> %{"slideId" => ref}
      ref when is_integer(ref) -> %{"slideIndex" => ref}
      ref -> %{"reference" => to_string(ref)}
    end)
  end

  defp normalize_source_refs(ref) when is_map(ref), do: [stringify_keys(ref)]
  defp normalize_source_refs(ref), do: normalize_source_refs([ref])

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp list_or_original(value) when is_list(value), do: value
  defp list_or_original(value), do: value

  defp integer_version(nil), do: @current_version
  defp integer_version(version) when is_integer(version), do: version

  defp integer_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_version(_version), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp map_key(map, key) when is_map(map), do: map[key]
  defp map_key(_value, _key), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp error(path, code, message) do
    %{"path" => path, "code" => code, "message" => message}
  end
end
