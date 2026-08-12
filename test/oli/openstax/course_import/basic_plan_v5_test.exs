defmodule Oli.OpenStax.CourseImport.BasicPlanV5Test do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.BasicPlanV5

  test "hydrates every source AST block exactly once without model-authored rewriting" do
    lesson = lesson()

    candidate = %{
      "title" => "The Nature of Science",
      "orientation" => %{"overview" => "Use the source to examine scientific knowledge."},
      "content_groups" => [
        %{
          "id" => "observations",
          "title" => "Observations and explanations",
          "instructional_purpose" => "concept",
          "transition" => "Begin with what scientists observe.",
          "source_block_ids" => ["heading-1", "paragraph-1"]
        },
        %{
          "id" => "models",
          "title" => "Models change with evidence",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["paragraph-2", "figure-1"]
        }
      ],
      "question_slots" => [
        %{
          "id" => "checkpoint-models",
          "purpose" => "check_understanding",
          "placement_after_group_id" => "models",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["paragraph-2"],
          "recommended_types" => ["multiple_choice"]
        }
      ],
      "generated_alt_text" => [
        %{
          "source_media_id" => "figure-media-1",
          "alt" => "A model is revised as new observations are added."
        }
      ],
      "synthesis" => %{
        "heading" => "Bring the evidence together",
        "summary" => "Scientific explanations remain open to revision.",
        "takeaways" => ["Evidence can change scientific explanations."]
      }
    }

    assert {:ok, content} = BasicPlanV5.build(candidate, lesson, 1)
    assert content["schema_version"] == 5
    assert content["coverage_manifest"]["complete"]

    assert content["coverage_manifest"]["included_source_block_ids"] == [
             "heading-1",
             "paragraph-1",
             "paragraph-2",
             "figure-1"
           ]

    [first, second] = content["content_groups"]
    assert Enum.map(first["source_blocks"], & &1["id"]) == ["heading-1", "paragraph-1"]

    assert get_in(first, [
             "source_blocks",
             Access.at(1),
             "ast",
             Access.at(0),
             "children",
             Access.at(0),
             "text"
           ]) ==
             "Scientific knowledge is based on observations and explanations."

    assert [%{"alt_source" => "generated"} = media] = second["media"]
    assert media["alt"] == "A model is revised as new observations are added."
    assert hd(content["question_slots"])["placement_after_section_id"] == "models"
  end

  test "rejects omissions, duplicates, invented ids, and inaccessible figure descriptions" do
    candidate = %{
      "content_groups" => [
        %{
          "id" => "one",
          "title" => "One",
          "instructional_purpose" => "concept",
          "source_block_ids" => ["heading-1", "heading-1", "invented"]
        }
      ],
      "question_slots" => []
    }

    assert {:error, findings} = BasicPlanV5.build(candidate, lesson(), 1)
    codes = Enum.map(findings, & &1["code"])
    assert "missing_source_blocks" in codes
    assert "unknown_source_blocks" in codes
    assert "duplicate_source_blocks" in codes
    assert "missing_media_alt" in codes
    assert Enum.all?(findings, &(&1["severity"] == "hard_blocker"))
  end

  test "treats an ancestor AST as the authority for persisted semantic child rows" do
    parent = %{
      "id" => "callout-parent",
      "kind" => "callout",
      "text" => "Evidence can revise an explanation.",
      "source_locator" => %{"semantic_path" => [1]},
      "ast" => [
        %{
          "type" => "p",
          "children" => [%{"text" => "Evidence can revise an explanation."}]
        }
      ]
    }

    child = %{
      "id" => "callout-child",
      "kind" => "paragraph",
      "text" => "Evidence can revise an explanation.",
      "source_locator" => %{"semantic_path" => [1, "blocks", 1]},
      "ast" => [
        %{
          "type" => "p",
          "children" => [%{"text" => "Evidence can revise an explanation."}]
        }
      ]
    }

    lesson = %{
      "title" => "Nested callout",
      "source_objectives" => ["Explain how evidence affects explanations."],
      "source_blocks" => [parent, child],
      "source_media" => []
    }

    candidate = %{
      "content_groups" => [
        %{
          "id" => "callout",
          "title" => "Evidence and revision",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["callout-parent"]
        }
      ],
      "question_slots" => []
    }

    assert {:ok, content} = BasicPlanV5.build(candidate, lesson, 1)
    assert content["source_block_ids"] == ["callout-parent"]
    assert content["coverage_manifest"]["included_source_block_ids"] == ["callout-parent"]
    refute Jason.encode!(content) =~ "callout-child"
  end

  test "rejects generic or paragraph-only standalone example cards" do
    candidate = %{
      "content_groups" => [
        %{
          "id" => "thin-example",
          "title" => "Worked Example 1",
          "instructional_purpose" => "example",
          "source_block_ids" => ["heading-1", "paragraph-1", "paragraph-2", "figure-1"]
        }
      ],
      "question_slots" => [],
      "generated_alt_text" => [
        %{
          "source_media_id" => "figure-media-1",
          "alt" => "A model is revised as new observations are added."
        }
      ]
    }

    assert {:error, findings} = BasicPlanV5.build(candidate, lesson(), 1)
    codes = Enum.map(findings, & &1["code"])
    assert "generic_group_title" in codes
    assert "unsupported_card_purpose" in codes
  end

  test "rejects multiple checkpoint slots at the same conceptual boundary" do
    candidate = %{
      "content_groups" => [
        %{
          "id" => "models",
          "title" => "Models change with evidence",
          "instructional_purpose" => "concept",
          "source_block_ids" => ["heading-1", "paragraph-1", "paragraph-2", "figure-1"]
        }
      ],
      "question_slots" => [
        %{
          "placement_after_group_id" => "models",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["paragraph-1"],
          "recommended_types" => ["multiple_choice"]
        },
        %{
          "placement_after_group_id" => "models",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["paragraph-2"],
          "recommended_types" => ["short_answer"]
        }
      ],
      "generated_alt_text" => [
        %{
          "source_media_id" => "figure-media-1",
          "alt" => "A model is revised as new observations are added."
        }
      ]
    }

    assert {:error, findings} = BasicPlanV5.build(candidate, lesson(), 1)
    assert Enum.any?(findings, &(&1["code"] == "duplicate_question_boundaries"))
  end

  test "publishes the exact architect vocabulary and objective ids in the prompt contract" do
    contract = BasicPlanV5.prompt_contract(lesson())

    assert "reading" in contract["allowed_instructional_purposes"]
    assert contract["allowed_question_types"] == ["multiple_choice", "short_answer"]

    assert [%{"id" => "objective-1", "text" => objective}] =
             contract["objective_catalog"]

    assert objective == "Explain how evidence shapes scientific explanations."
  end

  test "normalizes architect metadata aliases without changing source content" do
    objective = "Explain how evidence shapes scientific explanations."

    candidate = %{
      "content_groups" => [
        %{
          "id" => "reading-flow",
          "title" => "How evidence changes explanations",
          "instructional_purpose" => "Introduce and explain the central concept",
          "source_block_ids" => ["heading-1", "paragraph-1", "paragraph-2", "figure-1"]
        }
      ],
      "question_slots" => [
        %{
          "placement_after_group_id" => "reading-flow",
          "objective_ids" => [objective],
          "evidence_block_ids" => ["paragraph-2"],
          "recommended_types" => ["conceptual explanation"]
        }
      ],
      "generated_alt_text" => [
        %{
          "source_media_id" => "figure-media-1",
          "alt" => "A model is revised as new observations are added."
        }
      ]
    }

    assert {:ok, content} = BasicPlanV5.build(candidate, lesson(), 1)
    assert hd(content["content_groups"])["instructional_purpose"] == "reading"

    assert %{
             "objective_ids" => ["objective-1"],
             "recommended_types" => ["short_answer"]
           } = hd(content["question_slots"])

    assert content["source_block_ids"] == [
             "heading-1",
             "paragraph-1",
             "paragraph-2",
             "figure-1"
           ]
  end

  test "merges a title-only group and records the source heading as lesson-title rendering" do
    candidate = %{
      "content_groups" => [
        %{
          "id" => "source-title",
          "title" => "The Nature of Science",
          "instructional_purpose" => "orientation",
          "source_block_ids" => ["heading-1"]
        },
        %{
          "id" => "evidence",
          "title" => "How evidence changes explanations",
          "instructional_purpose" => "reading",
          "source_block_ids" => ["paragraph-1", "paragraph-2", "figure-1"]
        }
      ],
      "question_slots" => [],
      "generated_alt_text" => [
        %{
          "source_media_id" => "figure-media-1",
          "alt" => "A model is revised as new observations are added."
        }
      ]
    }

    assert {:ok, content} = BasicPlanV5.build(candidate, lesson(), 1)
    assert [group] = content["content_groups"]
    assert group["id"] == "evidence"
    assert Enum.map(group["source_blocks"], & &1["id"]) == content["source_block_ids"]
    assert hd(group["source_blocks"])["rendering"] == "lesson_title"

    assert hd(content["coverage_manifest"]["dispositions"])["rendering"] ==
             "lesson_title"
  end

  defp lesson do
    %{
      "title" => "The Nature of Science",
      "source_objectives" => ["Explain how evidence shapes scientific explanations."],
      "source_evidence_links" => [
        "https://openstax.org/books/chemistry-2e/pages/1-2-the-scientific-method"
      ],
      "source_blocks" => [
        %{
          "id" => "heading-1",
          "kind" => "heading",
          "text" => "The Nature of Science",
          "ast" => [%{"type" => "h2", "children" => [%{"text" => "The Nature of Science"}]}]
        },
        %{
          "id" => "paragraph-1",
          "kind" => "paragraph",
          "text" => "Scientific knowledge is based on observations and explanations.",
          "ast" => [
            %{
              "type" => "p",
              "children" => [
                %{"text" => "Scientific knowledge is based on observations and explanations."}
              ]
            }
          ]
        },
        %{
          "id" => "paragraph-2",
          "kind" => "paragraph",
          "text" => "New evidence can lead scientists to revise a model.",
          "ast" => [
            %{
              "type" => "p",
              "children" => [%{"text" => "New evidence can lead scientists to revise a model."}]
            }
          ]
        },
        %{
          "id" => "figure-1",
          "kind" => "figure",
          "text" => "A model changes with evidence.",
          "ast" => [
            %{
              "type" => "img",
              "src" => "https://openstax.org/apps/image-cdn/model.png",
              "alt" => "",
              "children" => [%{"text" => ""}]
            }
          ]
        }
      ],
      "source_media" => [
        %{
          "id" => "figure-media-1",
          "source_media_id" => "figure-media-1",
          "source_block_id" => "figure-1",
          "src" => "https://openstax.org/apps/image-cdn/model.png",
          "caption" => "A scientific model changes when evidence no longer fits.",
          "credit" => "OpenStax",
          "rights_status" => "approved",
          "required" => true
        }
      ],
      "attribution" => %{"provider" => "OpenStax", "license" => "CC BY 4.0"}
    }
  end
end
