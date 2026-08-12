defmodule Oli.OpenStax.CourseImport.BasicPlanV5 do
  @moduledoc """
  Server-owned schema v5 contract for source-faithful Basic pages.

  The model chooses organization, instructional purpose, figure placement, and
  checkpoint opportunities. The server hydrates every referenced source block
  from the deterministic AST, builds exact coverage, and rejects omissions,
  duplicates, invented references, or inaccessible required media.
  """

  @schema_version 5
  @allowed_purposes ~w(orientation reading concept evidence example application synthesis reference)
  @allowed_question_types ~w(multiple_choice short_answer)
  @structural_block_kinds ~w(objectives callout footnotes)
  @generic_group_titles [
    ~r/^worked\s+example(?:\s+\d+)?$/i,
    ~r/^example(?:\s+\d+)?$/i,
    ~r/^apply\s+what\s+you\s+learned(?:\s+\d+)?$/i,
    ~r/^core\s+concept(?:\s+\d+)?$/i
  ]

  @type finding :: %{required(String.t()) => term()}

  @spec build(map(), map(), pos_integer()) :: {:ok, map()} | {:error, [finding()]}
  def build(candidate, lesson, lesson_index)
      when is_map(candidate) and is_map(lesson) and is_integer(lesson_index) and
             lesson_index > 0 do
    candidate = candidate_content(candidate)
    blocks = lesson |> normalized_blocks() |> mark_lesson_title_block(lesson["title"])
    media = normalized_media(lesson)
    objectives = source_objectives(lesson)
    objective_catalog = objective_catalog(objectives, blocks)

    groups =
      candidate["content_groups"]
      |> normalize_groups()
      |> merge_lesson_title_only_groups(blocks)
      |> sanitize_transitions(blocks)

    findings =
      validate_groups(groups, blocks) ++
        validate_slots(candidate["question_slots"], groups, blocks, objective_catalog) ++
        validate_media(candidate["generated_alt_text"], media)

    case findings do
      [] ->
        generated_alt = generated_alt_map(candidate["generated_alt_text"])
        hydrated_groups = hydrate_groups(groups, blocks, media, generated_alt)
        slots = normalize_slots(candidate["question_slots"], objective_catalog)
        all_ids = Enum.map(blocks, & &1["id"])

        {:ok,
         %{
           "schema_version" => @schema_version,
           "authoring_mode" => "basic",
           "title" =>
             present(candidate["title"]) || lesson["title"] || "OpenStax lesson #{lesson_index}",
           "objective" => List.first(objectives),
           "learning_objectives" => objectives,
           "objective_catalog" => objective_catalog,
           "orientation" => %{
             "overview" =>
               present(get_in(candidate, ["orientation", "overview"])) ||
                 present(candidate["overview"]) ||
                 source_overview(blocks)
           },
           "narrative" =>
             present(get_in(candidate, ["orientation", "overview"])) ||
               present(candidate["overview"]) || source_overview(blocks),
           "content_groups" => hydrated_groups,
           "question_slots" => slots,
           "instructional_sections" => compatibility_sections(hydrated_groups),
           "media" => hydrate_media(media, hydrated_groups, generated_alt),
           "synthesis" => normalize_synthesis(candidate["synthesis"], blocks),
           "key_takeaways" => synthesis_takeaways(candidate["synthesis"]),
           "source_evidence_links" => normalize_strings(lesson["source_evidence_links"]),
           "source_block_ids" => all_ids,
           "coverage_manifest" => coverage_manifest(blocks, hydrated_groups),
           "attribution" => normalized_attribution(lesson),
           "advanced_blueprint" => %{"screens" => [], "remediation_paths" => []},
           "v5_contract" => %{
             "source_ast_authority" => "deterministic_extractor",
             "organization_authority" => "content_architect",
             "coverage_strategy" => "exact_source_block_disposition",
             "structural_block_kinds" => @structural_block_kinds
           }
         }}

      findings ->
        {:error, findings}
    end
  end

  def build(_candidate, _lesson, _lesson_index),
    do:
      {:error,
       [
         finding(
           "invalid_v5_candidate",
           "$",
           "The content architect must return one JSON object."
         )
       ]}

  @spec prompt_contract(map()) :: map()
  def prompt_contract(lesson) when is_map(lesson) do
    blocks = lesson |> normalized_blocks() |> mark_lesson_title_block(lesson["title"])

    %{
      "schema_version" => @schema_version,
      "lesson_title" => lesson["title"],
      "source_objectives" => source_objectives(lesson),
      "objective_catalog" => objective_catalog(source_objectives(lesson), blocks),
      "allowed_instructional_purposes" => @allowed_purposes,
      "allowed_question_types" => @allowed_question_types,
      "source_blocks" =>
        Enum.map(blocks, fn block ->
          %{
            "id" => block["id"],
            "kind" => block["kind"],
            "heading_path" => block["heading_path"] || [],
            "text" => block["text"],
            "has_ast" => List.wrap(block["ast"]) != [],
            "source_section_title" => block["source_section_title"]
          }
        end),
      "source_media" =>
        lesson
        |> normalized_media()
        |> Enum.map(
          &Map.take(&1, ~w(id source_block_id alt caption credit rights_status status required))
        )
    }
  end

  @doc "Returns the exact non-overlapping source AST blocks governed by schema v5."
  @spec source_blocks(map()) :: [map()]
  def source_blocks(lesson) when is_map(lesson),
    do: lesson |> normalized_blocks() |> mark_lesson_title_block(lesson["title"])

  def source_blocks(_lesson), do: []

  @spec hard_blockers([finding()]) :: [finding()]
  def hard_blockers(findings),
    do: Enum.filter(List.wrap(findings), &(&1["severity"] == "hard_blocker"))

  defp candidate_content(%{"content_payload" => %{} = content}), do: content
  defp candidate_content(candidate), do: candidate

  defp normalized_blocks(lesson) do
    lesson
    |> Map.get("source_blocks", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      block when is_map(block) ->
        id = block["id"] || block[:id]

        if present(id) do
          semantic_payload = get_in(block, ["metadata", "semantic_payload"]) || %{}

          [
            semantic_payload
            |> stringify_map()
            |> Map.merge(stringify_map(block))
            |> Map.put("id", id)
            |> Map.put("kind", block["kind"] || block[:kind] || "paragraph")
            |> Map.put("text", block["text"] || block[:text] || block["normalized_text"] || "")
            |> Map.update("ast", fallback_ast(block), &normalize_ast(&1, block))
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
    |> reject_ast_covered_descendants()
  end

  defp reject_ast_covered_descendants(blocks) do
    ast_parents =
      Enum.filter(blocks, fn block ->
        is_list(block["ast"]) and block["ast"] != [] and semantic_path(block) != []
      end)

    Enum.reject(blocks, fn block ->
      child_path = semantic_path(block)

      child_path != [] and
        Enum.any?(ast_parents, fn parent ->
          parent["id"] != block["id"] and proper_path_prefix?(semantic_path(parent), child_path)
        end)
    end)
  end

  defp semantic_path(block) do
    get_in(block, ["source_locator", "semantic_path"])
    |> List.wrap()
  end

  defp proper_path_prefix?(parent, child) when length(parent) < length(child),
    do: Enum.take(child, length(parent)) == parent

  defp proper_path_prefix?(_parent, _child), do: false

  defp fallback_ast(block) do
    case present(block["text"] || block[:text] || block["normalized_text"]) do
      nil -> []
      text -> [%{"type" => "p", "children" => [%{"text" => text}]}]
    end
  end

  defp normalize_ast(ast, block) when is_map(ast), do: normalize_ast([ast], block)

  defp normalize_ast(ast, block) when is_list(ast) do
    case Enum.filter(ast, &is_map/1) do
      [] -> fallback_ast(block)
      nodes -> nodes
    end
  end

  defp normalize_ast(_ast, block), do: fallback_ast(block)

  defp normalized_media(lesson) do
    lesson
    |> Map.get("source_media", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      media when is_map(media) ->
        media = stringify_map(media)
        id = media["source_media_id"] || media["id"]

        if present(id) do
          semantic_payload = get_in(media, ["metadata", "semantic_payload"]) || %{}
          source_block_id = media["source_block_id"] || semantic_payload["source_block_id"]

          [
            semantic_payload
            |> stringify_map()
            |> Map.merge(media)
            |> Map.put("id", id)
            |> Map.put("source_media_id", id)
            |> Map.put("source_block_id", source_block_id)
          ]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp normalize_groups(groups) do
    groups
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map(fn {group, index} ->
      group = stringify_map(group)

      %{
        "id" => present(group["id"]) || "content-group-#{index}",
        "title" => present(group["title"]),
        "instructional_purpose" =>
          canonical_group_purpose(group["instructional_purpose"] || group["purpose"]),
        "transition" => present(group["transition"]),
        "source_block_ids" => normalize_source_block_ids(group["source_block_ids"])
      }
    end)
  end

  defp validate_groups(groups, blocks) do
    available = MapSet.new(blocks, & &1["id"])
    blocks_by_id = Map.new(blocks, &{&1["id"], &1})
    assigned = Enum.flat_map(groups, & &1["source_block_ids"])
    assigned_set = MapSet.new(assigned)

    structural_findings =
      groups
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {group, index} ->
        []
        |> maybe_finding(
          is_nil(group["title"]),
          "missing_group_title",
          "$.content_groups[#{index}].title",
          "Every content group needs a descriptive learner-facing heading."
        )
        |> maybe_finding(
          generic_group_title?(group["title"]),
          "generic_group_title",
          "$.content_groups[#{index}].title",
          "Use a descriptive heading tied to the source concept, not a numbered template label."
        )
        |> maybe_finding(
          group["instructional_purpose"] not in @allowed_purposes,
          "invalid_group_purpose",
          "$.content_groups[#{index}].instructional_purpose",
          "Use exactly one of: #{Enum.join(@allowed_purposes, ", ")}."
        )
        |> maybe_finding(
          group["source_block_ids"] == [],
          "empty_content_group",
          "$.content_groups[#{index}].source_block_ids",
          "Every content group must contain at least one source block."
        )
        |> maybe_finding(
          unsupported_card_purpose?(group, blocks_by_id),
          "unsupported_card_purpose",
          "$.content_groups[#{index}].instructional_purpose",
          "Example and application cards must organize a genuine source example, exercise, or concepts-in-practice callout. Keep brief explanatory source blocks in the reading flow."
        )
      end)

    missing = MapSet.difference(available, assigned_set) |> MapSet.to_list()
    unknown = MapSet.difference(assigned_set, available) |> MapSet.to_list()
    duplicates = (assigned -- Enum.uniq(assigned)) |> Enum.uniq()

    structural_findings ++
      list_finding(
        missing,
        "missing_source_blocks",
        "$.content_groups",
        "Every source block must be assigned exactly once"
      ) ++
      list_finding(
        unknown,
        "unknown_source_blocks",
        "$.content_groups",
        "Only extracted source block IDs may be used"
      ) ++
      list_finding(
        duplicates,
        "duplicate_source_blocks",
        "$.content_groups",
        "A source block may appear in only one content group"
      ) ++
      if(groups == [],
        do: [
          finding(
            "missing_content_groups",
            "$.content_groups",
            "At least one content group is required."
          )
        ],
        else: []
      )
  end

  defp validate_slots(raw_slots, groups, blocks, objectives) do
    slots = normalize_slots(raw_slots, objectives)
    group_ids = MapSet.new(groups, & &1["id"])
    block_ids = MapSet.new(blocks, & &1["id"])
    objective_ids = MapSet.new(objectives, & &1["id"])

    placement_duplicates =
      slots
      |> Enum.map(& &1["placement_after_group_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    slot_findings =
      slots
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {slot, index} ->
        []
        |> maybe_finding(
          not MapSet.member?(group_ids, slot["placement_after_group_id"]),
          "invalid_question_placement",
          "$.question_slots[#{index}].placement_after_group_id",
          "Question slots must follow an existing content group."
        )
        |> maybe_finding(
          slot["evidence_block_ids"] == [] or
            Enum.any?(slot["evidence_block_ids"], &(not MapSet.member?(block_ids, &1))),
          "invalid_question_evidence",
          "$.question_slots[#{index}].evidence_block_ids",
          "Question evidence must reference one or more extracted source blocks."
        )
        |> maybe_finding(
          Enum.any?(slot["objective_ids"], &(not MapSet.member?(objective_ids, &1))),
          "invalid_question_objectives",
          "$.question_slots[#{index}].objective_ids",
          "Question objective IDs must come from the source objective catalog: #{Enum.join(MapSet.to_list(objective_ids), ", ")}."
        )
        |> maybe_finding(
          Enum.any?(slot["recommended_types"], &(&1 not in @allowed_question_types)),
          "invalid_question_type",
          "$.question_slots[#{index}].recommended_types",
          "Use only: #{Enum.join(@allowed_question_types, ", ")}."
        )
      end)

    slot_findings ++
      list_finding(
        placement_duplicates,
        "duplicate_question_boundaries",
        "$.question_slots",
        "Use at most one consolidated checkpoint slot at each conceptual boundary"
      )
  end

  defp generic_group_title?(nil), do: false

  defp generic_group_title?(title),
    do: Enum.any?(@generic_group_titles, &Regex.match?(&1, title))

  defp unsupported_card_purpose?(
         %{"instructional_purpose" => purpose, "source_block_ids" => source_block_ids},
         blocks_by_id
       )
       when purpose in ["example", "application"] do
    not Enum.any?(source_block_ids, fn id ->
      blocks_by_id
      |> Map.get(id, %{})
      |> card_worthy_source?(purpose)
    end)
  end

  defp unsupported_card_purpose?(_group, _blocks_by_id), do: false

  defp card_worthy_source?(%{"kind" => kind}, "example")
       when kind in ["example", "exercise", "worked_example"],
       do: true

  defp card_worthy_source?(%{"kind" => kind}, "application")
       when kind in ["exercise", "problem", "application"],
       do: true

  defp card_worthy_source?(%{"kind" => "callout", "callout_type" => type}, purpose)
       when purpose in ["example", "application"] and
              type in ["example", "concepts_in_practice", "problem", "exercise"],
       do: true

  defp card_worthy_source?(_block, _purpose), do: false

  defp validate_media(raw_generated_alt, media) do
    generated = generated_alt_map(raw_generated_alt)

    media
    |> Enum.flat_map(fn asset ->
      id = asset["id"]
      required? = asset["required"] == true
      status = asset["status"]
      rights = asset["rights_status"]
      alt = present(asset["alt"] || asset["alt_text"] || generated[id])

      []
      |> maybe_finding(
        is_nil(alt),
        "missing_media_alt",
        "$.generated_alt_text.#{id}",
        "Every retained figure needs source or critic-approved generated alt text."
      )
      |> maybe_finding(
        required? and status in ["failed", "missing", "blocked"],
        "required_media_unavailable",
        "$.source_media.#{id}",
        "Required media must be importable before approval."
      )
      |> maybe_finding(
        required? and rights in ["blocked", "conflicted"],
        "required_media_rights_conflict",
        "$.source_media.#{id}",
        "Required media has unresolved rights or safety restrictions."
      )
    end)
  end

  defp normalize_slots(slots, objective_catalog) do
    slots
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map(fn {slot, index} ->
      slot = stringify_map(slot)

      %{
        "id" => present(slot["id"]) || "question-slot-#{index}",
        "purpose" => present(slot["purpose"]) || "check_understanding",
        "placement_after_group_id" =>
          present(slot["placement_after_group_id"] || slot["placement_after_section_id"]),
        "placement_after_section_id" =>
          present(slot["placement_after_group_id"] || slot["placement_after_section_id"]),
        "objective_ids" => normalize_objective_ids(slot["objective_ids"], objective_catalog),
        "evidence_block_ids" => normalize_strings(slot["evidence_block_ids"]),
        "recommended_types" =>
          normalize_question_types(slot["recommended_types"] || slot["question_types"])
      }
    end)
  end

  defp hydrate_groups(groups, blocks, media, generated_alt) do
    blocks_by_id = Map.new(blocks, &{&1["id"], &1})

    Enum.map(groups, fn group ->
      group_blocks = Enum.map(group["source_block_ids"], &Map.fetch!(blocks_by_id, &1))
      group_media = media_for_blocks(media, group["source_block_ids"])

      group
      |> Map.put("source_blocks", group_blocks)
      |> Map.put("media", hydrate_media(group_media, [group], generated_alt))
      |> Map.put("source_word_count", word_count(Enum.map_join(group_blocks, " ", & &1["text"])))
    end)
  end

  defp hydrate_media(media, groups, generated_alt) do
    placement_by_block =
      groups
      |> Enum.flat_map(fn group -> Enum.map(group["source_block_ids"], &{&1, group["id"]}) end)
      |> Map.new()

    Enum.map(media, fn asset ->
      source_alt = present(asset["alt"] || asset["alt_text"])
      generated = present(generated_alt[asset["id"]])

      asset
      |> Map.put("alt", source_alt || generated)
      |> Map.put("alt_text", source_alt || generated)
      |> Map.put("alt_source", if(source_alt, do: "source", else: "generated"))
      |> Map.put("placement_after_section_id", placement_by_block[asset["source_block_id"]])
    end)
  end

  defp media_for_blocks(media, block_ids) do
    block_ids = MapSet.new(block_ids)
    Enum.filter(media, &MapSet.member?(block_ids, &1["source_block_id"]))
  end

  defp compatibility_sections(groups) do
    Enum.map(groups, fn group ->
      %{
        "id" => group["id"],
        "title" => group["title"],
        "heading" => group["title"],
        "instructional_purpose" => group["instructional_purpose"],
        "explanation" => Enum.map_join(group["source_blocks"], "\n\n", & &1["text"]),
        "source_block_ids" => group["source_block_ids"],
        "evidence_block_ids" => group["source_block_ids"],
        "source_evidence_links" =>
          group["source_blocks"]
          |> Enum.map(& &1["source_section_url"])
          |> normalize_strings(),
        "media_ids" => Enum.map(group["media"], & &1["id"]),
        "key_takeaways" => [],
        "callouts" => [],
        "examples" => []
      }
    end)
  end

  defp coverage_manifest(blocks, groups) do
    group_by_block =
      groups
      |> Enum.flat_map(fn group -> Enum.map(group["source_block_ids"], &{&1, group["id"]}) end)
      |> Map.new()

    dispositions =
      Enum.map(blocks, fn block ->
        %{
          "source_block_id" => block["id"],
          "disposition" => "included",
          "content_group_id" => Map.fetch!(group_by_block, block["id"]),
          "rendering" =>
            block["rendering"] ||
              if(block["kind"] in @structural_block_kinds,
                do: "structural",
                else: "source_ast"
              )
        }
      end)

    %{
      "strategy" => "exact_ast_coverage",
      "complete" => true,
      "available_source_block_ids" => Enum.map(blocks, & &1["id"]),
      "included_source_block_ids" => Enum.map(blocks, & &1["id"]),
      "missing_source_block_ids" => [],
      "duplicate_source_block_ids" => [],
      "dispositions" => dispositions
    }
  end

  defp objective_catalog(objectives, blocks) do
    evidence_ids = Enum.map(blocks, & &1["id"])

    objectives
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} ->
      %{"id" => "objective-#{index}", "text" => text, "evidence_block_ids" => evidence_ids}
    end)
  end

  defp source_objectives(lesson) do
    objectives = normalize_strings(lesson["source_objectives"] || lesson["learning_objectives"])

    case objectives do
      [] -> ["Explain the source lesson's central concepts and supporting evidence."]
      values -> values
    end
  end

  defp source_overview(blocks) do
    blocks
    |> Enum.reject(&(&1["kind"] in ~w(heading objectives footnotes caption)))
    |> Enum.map(&present(&1["text"]))
    |> Enum.reject(&is_nil/1)
    |> List.first()
    |> case do
      nil -> "Read the source material and connect its central ideas to the lesson objectives."
      text -> text
    end
  end

  defp normalize_synthesis(value, blocks) do
    value = stringify_map(value)

    %{
      "heading" => present(value["heading"]) || "Bring the ideas together",
      "summary" => present(value["summary"]) || source_overview(Enum.reverse(blocks)),
      "takeaways" => normalize_strings(value["takeaways"])
    }
  end

  defp synthesis_takeaways(value),
    do: value |> stringify_map() |> Map.get("takeaways", []) |> normalize_strings()

  defp generated_alt_map(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      value = stringify_map(value)
      id = value["source_media_id"] || value["id"]
      alt = present(value["alt"] || value["alt_text"])
      if not is_nil(present(id)) and not is_nil(alt), do: [{id, alt}], else: []
    end)
    |> Map.new()
  end

  defp normalized_attribution(lesson) do
    case stringify_map(lesson["attribution"]) do
      attribution when map_size(attribution) > 0 ->
        attribution

      _ ->
        %{
          "provider" => "OpenStax",
          "source_title" => lesson["title"],
          "source_urls" => normalize_strings(lesson["source_evidence_links"]),
          "license" => "CC BY 4.0",
          "license_type" => "cc_by",
          "license_url" => "https://creativecommons.org/licenses/by/4.0/"
        }
    end
  end

  defp list_finding([], _code, _path, _message), do: []

  defp list_finding(ids, code, path, message),
    do: [finding(code, path, "#{message}: #{Enum.join(ids, ", ")}.")]

  defp maybe_finding(findings, false, _code, _path, _message), do: findings

  defp maybe_finding(findings, true, code, path, message),
    do: findings ++ [finding(code, path, message)]

  defp finding(code, path, message),
    do: %{"severity" => "hard_blocker", "code" => code, "path" => path, "message" => message}

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_value), do: nil

  defp mark_lesson_title_block(blocks, lesson_title) do
    {marked, _found?} =
      Enum.map_reduce(blocks, false, fn block, found? ->
        if not found? and block["kind"] == "heading" and
             equivalent_heading?(block["text"], lesson_title) do
          {Map.put(block, "rendering", "lesson_title"), true}
        else
          {block, found?}
        end
      end)

    marked
  end

  defp merge_lesson_title_only_groups(groups, blocks) do
    lesson_title_ids =
      blocks
      |> Enum.filter(&(&1["rendering"] == "lesson_title"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    do_merge_lesson_title_only_groups(groups, lesson_title_ids)
  end

  defp do_merge_lesson_title_only_groups([group, next | rest], lesson_title_ids) do
    ids = group["source_block_ids"]

    if ids != [] and Enum.all?(ids, &MapSet.member?(lesson_title_ids, &1)) do
      merged_next =
        Map.update!(next, "source_block_ids", fn next_ids -> ids ++ next_ids end)

      do_merge_lesson_title_only_groups([merged_next | rest], lesson_title_ids)
    else
      [group | do_merge_lesson_title_only_groups([next | rest], lesson_title_ids)]
    end
  end

  defp do_merge_lesson_title_only_groups(groups, _lesson_title_ids), do: groups

  defp sanitize_transitions(groups, blocks) do
    blocks_by_id = Map.new(blocks, &{&1["id"], &1})

    Enum.map(groups, fn group ->
      transition = group["transition"]

      source_text =
        group["source_block_ids"]
        |> Enum.map_join(" ", &(blocks_by_id[&1] || %{})["text"])

      if generic_transition?(transition) or duplicates_source?(transition, source_text),
        do: Map.put(group, "transition", nil),
        else: group
    end)
  end

  defp generic_transition?(nil), do: false

  defp generic_transition?(transition) do
    normalized = normalized_text(transition)

    Enum.any?(
      [
        "begin with",
        "move from",
        "extend the view",
        "close with",
        "consult the source",
        "review the source",
        "the following section"
      ],
      &String.starts_with?(normalized, &1)
    )
  end

  defp duplicates_source?(nil, _source_text), do: false

  defp duplicates_source?(transition, source_text) do
    transition = normalized_text(transition)
    source_text = normalized_text(source_text)
    String.length(transition) >= 24 and String.contains?(source_text, transition)
  end

  defp equivalent_heading?(left, right),
    do: heading_key(left) != "" and heading_key(left) == heading_key(right)

  defp heading_key(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^[:alnum:]]/u, "")

  defp heading_key(_value), do: ""

  defp canonical_group_purpose(value) do
    normalized = normalized_token(value)

    cond do
      normalized in @allowed_purposes ->
        normalized

      normalized in ["normal_reading", "normal_reading_flow", "read", "explanation"] ->
        "reading"

      token_matches?(normalized, ~w(read introduc explain definition overview)) ->
        "reading"

      token_matches?(normalized, ~w(observ evidence data)) ->
        "evidence"

      token_matches?(normalized, ~w(example demonstrat worked)) ->
        "example"

      token_matches?(normalized, ~w(apply application practice exercise problem cause_effect)) ->
        "application"

      token_matches?(normalized, ~w(synth summary connect conclusion)) ->
        "synthesis"

      token_matches?(normalized, ~w(reference table equation formula)) ->
        "reference"

      token_matches?(normalized, ~w(orient)) ->
        "orientation"

      token_matches?(normalized, ~w(concept)) ->
        "concept"

      true ->
        present(value)
    end
  end

  defp normalize_objective_ids(values, objective_catalog) do
    by_text =
      Map.new(objective_catalog, fn objective ->
        {normalized_text(objective["text"]), objective["id"]}
      end)

    allowed_ids = MapSet.new(objective_catalog, & &1["id"])

    values
    |> normalize_strings()
    |> Enum.map(fn value ->
      if MapSet.member?(allowed_ids, value),
        do: value,
        else: by_text[normalized_text(value)] || value
    end)
    |> Enum.uniq()
  end

  defp normalize_question_types(values) do
    values
    |> normalize_strings()
    |> Enum.map(fn value ->
      case normalized_token(value) do
        type when type in @allowed_question_types ->
          type

        type when type in ["mcq", "multiple_choice_question"] ->
          "multiple_choice"

        type when type in ["constructed_response", "free_response", "open_response"] ->
          "short_answer"

        type
        when type in [
               "conceptual_explanation",
               "cause_and_effect",
               "cause_effect",
               "explanation"
             ] ->
          "short_answer"

        _ ->
          value
      end
    end)
    |> Enum.uniq()
  end

  defp normalized_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalized_token(_value), do: nil

  defp normalized_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalized_text(_value), do: ""

  defp token_matches?(value, fragments) when is_binary(value),
    do: Enum.any?(fragments, &String.contains?(value, &1))

  defp token_matches?(_value, _fragments), do: false

  defp normalize_strings(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> if present(value), do: [String.trim(value)], else: []
      _ -> []
    end)
    |> Enum.uniq()
  end

  # Retain duplicates until validation so exact coverage can reject repeated
  # source content instead of normalizing the evidence away.
  defp normalize_source_block_ids(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> if present(value), do: [String.trim(value)], else: []
      _ -> []
    end)
  end

  defp stringify_map(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)

  defp stringify_map(_value), do: %{}

  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()
end
