defmodule Oli.OpenStax.CourseImport.AIPlannerTest do
  use ExUnit.Case, async: true

  alias Oli.GenAI.Completions.ServiceConfig
  alias Oli.OpenStax.CourseImport.AIPlanner

  defp lesson do
    %{
      "title" => "Algorithms",
      "source_excerpt" => "Algorithms are precise step-by-step procedures for solving problems.",
      "source_sections" => ["https://openstax.org/books/test/pages/algorithms"],
      "source_evidence_links" => ["https://openstax.org/books/test/pages/algorithms"],
      "source_objectives" => ["Define an algorithm"]
    }
  end

  test "uses the deterministic planner only when no feature service is configured" do
    assert {:ok, result} =
             AIPlanner.plan(lesson(), 1,
               service_config_loader: fn ->
                 {:error, {:missing_feature_config, "no global config"}}
               end
             )

    assert result.created_by == "system"
    assert result.metadata == %{strategy: :deterministic}
    assert result.payload["content_payload"]["narrative"] != ""
    assert length(result.payload["content_payload"]["instructional_sections"]) >= 2
    assert length(result.payload["content_payload"]["worked_examples"]) >= 1
    assert length(result.payload["content_payload"]["key_takeaways"]) >= 3
  end

  test "preserves schema v2 when an existing run resumes" do
    assert {:ok, result} =
             AIPlanner.plan(lesson(), 1,
               plan_schema_version: 2,
               service_config_loader: fn -> {:error, :not_configured} end
             )

    assert result.payload["content_payload"]["schema_version"] == 2
    assert result.created_by == "system"
  end

  test "preserves legacy schema v2 Advanced responses without a V3 blueprint" do
    response = %{
      "plan_mode" => "advanced",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Compare algorithmic strategies"],
          "narrative" => "Learners compare algorithmic strategies for a familiar problem."
        }),
      "questions_payload" => %{
        "items" => [
          %{"id" => "legacy-q1", "prompt" => "Compare two strategies."},
          %{"id" => "legacy-q2", "prompt" => "When would you use each strategy?"}
        ]
      }
    }

    assert {:ok, result} =
             AIPlanner.plan(lesson(), 1,
               plan_schema_version: 2,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "legacy-model"}}}
               end
             )

    assert result.plan_mode == "advanced"
    assert result.payload["content_payload"]["schema_version"] == 2

    assert result.payload["content_payload"]["advanced_blueprint"] == %{
             "screens" => [],
             "remediation_paths" => []
           }
  end

  test "uses Oli.GenAI's configured execution seam and records AI provenance" do
    service_config = %ServiceConfig{id: 9}

    response = %{
      "plan_mode" => "advanced",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => [
            "Define an algorithm",
            "Apply an algorithm to a problem"
          ],
          "narrative" => "Learners compare a problem with a precise algorithmic procedure.",
          "advanced_blueprint" => advanced_blueprint(),
          "estimated_minutes" => 18
        }),
      "questions_payload" => %{
        "items" => [
          %{"id" => "ai-q1", "prompt" => "What makes an algorithm precise?"},
          %{"id" => "ai-q2", "prompt" => "Describe an algorithm for a familiar task."}
        ]
      }
    }

    execution_fun = fn request_ctx, messages, ^service_config ->
      send(self(), {:ai_request, request_ctx, messages})
      {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
    end

    assert {:ok, result} =
             AIPlanner.plan(lesson(), 2,
               service_config_loader: fn -> {:ok, service_config} end,
               execution_fun: execution_fun
             )

    assert result.created_by == "ai"
    assert result.plan_mode == "advanced"
    assert result.metadata == %{model: "test-model"}
    assert result.payload["questions_payload"]["items"] |> length() == 2
    assert result.payload["content_payload"]["schema_version"] == 3
    assert length(result.payload["content_payload"]["instructional_sections"]) == 2

    assert Enum.all?(
             result.payload["questions_payload"]["items"],
             &(length(&1["answer_keywords"]) >= 1 and is_binary(&1["remediation"]))
           )

    assert_received {:ai_request, %{feature: :openstax_course_import, lesson_index: 2}, messages}
    assert Enum.any?(messages, &(&1.role == :system and &1.content =~ "Return JSON only"))
  end

  test "rejects an Advanced label without a meaningful adaptive blueprint" do
    response = %{
      "plan_mode" => "advanced",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Compare algorithmic strategies"],
          "narrative" => "Learners compare two algorithmic strategies."
        }),
      "questions_payload" => %{
        "items" => [
          %{"id" => "ai-q1", "prompt" => "Compare the two strategies."},
          %{"id" => "ai-q2", "prompt" => "When would you use each strategy?"}
        ]
      }
    }

    assert {:error, {:ai_planning_failed, :invalid_advanced_blueprint}} =
             AIPlanner.plan(lesson(), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )
  end

  test "rejects Advanced screens that have no unambiguous remediation target" do
    orphaned_check = %{
      "id" => "orphaned-check",
      "kind" => "check",
      "prompt" => "Which procedure is precise?",
      "interaction_type" => "multiple_choice",
      "choices" => [
        %{
          "id" => "precise",
          "text" => "A finite sequence with unambiguous steps",
          "correct" => true,
          "feedback" => "The procedure is precise."
        },
        %{
          "id" => "vague",
          "text" => "A suggestion with unspecified operations",
          "correct" => false,
          "feedback" => "The operations must be specified."
        }
      ],
      "correct_choice_id" => "precise",
      "evidence_block_ids" => []
    }

    blueprint = update_in(advanced_blueprint(), ["screens"], &(&1 ++ [orphaned_check]))

    response = %{
      "plan_mode" => "advanced",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Compare algorithmic strategies"],
          "narrative" => "Learners compare two algorithmic strategies.",
          "advanced_blueprint" => blueprint
        }),
      "questions_payload" => %{
        "items" => [
          %{"id" => "ai-q1", "prompt" => "Compare the two strategies."},
          %{"id" => "ai-q2", "prompt" => "When would you use each strategy?"}
        ]
      }
    }

    assert {:error, {:ai_planning_failed, :invalid_advanced_blueprint}} =
             AIPlanner.plan(lesson(), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )
  end

  test "enforces the stable structured-source authoring mode recommendation" do
    adaptive_lesson = %{
      "title" => "Choose a search strategy",
      "source_objectives" => ["Compare alternatives and select a search strategy"],
      "source_blocks" => [
        %{
          "id" => "search-case",
          "kind" => "exercise",
          "text" =>
            "Choose between alternative strategies for this scenario. A common error is to ignore the input constraint."
        }
      ]
    }

    assert {:error, {:ai_planning_failed, :authoring_mode_mismatch}} =
             AIPlanner.plan(adaptive_lesson, 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 {:ok,
                  %{
                    content: Jason.encode!(%{"plan_mode" => "basic"}),
                    metadata: %{model: "test-model"}
                  }}
               end
             )
  end

  test "uses the existing OPENAI_API_KEY environment route when no feature config exists" do
    response = %{
      "plan_mode" => "basic",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Define an algorithm"],
          "narrative" => "Learners connect a precise procedure to a familiar problem."
        }),
      "questions_payload" => %{
        "items" => [
          %{"prompt" => "What makes a procedure an algorithm?"},
          %{"prompt" => "Give an example of an algorithm."}
        ]
      }
    }

    env = %{
      "OPENAI_API_KEY" => "test-key-never-sent",
      "OPENAI_MODEL" => "test-openai-model"
    }

    execution_fun = fn _request_ctx, _messages, service_config ->
      assert service_config.name == "openstax-course-import-env"
      assert service_config.primary_model.model == "test-openai-model"
      assert service_config.primary_model.api_key == "test-key-never-sent"

      {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-openai-model"}}}
    end

    assert {:ok, result} =
             AIPlanner.plan(lesson(), 1,
               feature_config_loader: fn ->
                 {:error, {:missing_feature_config, "no global config"}}
               end,
               env_getter: &Map.get(env, &1),
               execution_fun: execution_fun
             )

    assert result.created_by == "ai"
    assert result.metadata == %{model: "test-openai-model"}
  end

  test "does not replace a configured-provider failure with deterministic content" do
    assert {:error, {:ai_planning_failed, :timeout}} =
             AIPlanner.plan(lesson(), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ -> {:error, :timeout} end
             )
  end

  test "includes every structured source block in the AI prompt instead of taking a prefix" do
    source_blocks =
      Enum.map(1..130, fn index ->
        %{
          "id" => "block-#{index}",
          "kind" => "paragraph",
          "heading_path" => ["Topic #{index}"],
          "text" => "Source evidence for topic #{index}."
        }
      end)

    response = %{
      "plan_mode" => "basic",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Explain the complete source"],
          "narrative" => "Learners connect evidence from across the complete source.",
          "instructional_sections" => [
            %{
              "heading" => "Beginning of the source",
              "explanation" =>
                "The first part of the source establishes evidence learners can use to identify the central idea, connect it to the lesson objective, and explain why the idea matters.",
              "evidence_block_ids" => ["block-1"]
            },
            %{
              "heading" => "End of the source",
              "explanation" =>
                "The final part of the source extends that evidence so learners can compare ideas across the complete lesson, synthesize the relationship, and support a conclusion.",
              "evidence_block_ids" => ["block-130"]
            }
          ]
        }),
      "questions_payload" => %{
        "items" => [
          %{
            "prompt" => "What evidence supports the first topic?",
            "evidence_block_ids" => ["block-1"]
          },
          %{
            "prompt" => "What evidence supports the final topic?",
            "evidence_block_ids" => ["block-130"]
          }
        ]
      }
    }

    assert {:ok, result} =
             AIPlanner.plan(Map.put(lesson(), "source_blocks", source_blocks), 2,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, messages, _ ->
                 prompt = Enum.find(messages, &(&1.role == :user)).content
                 assert prompt =~ ~s("id":"block-1")
                 assert prompt =~ ~s("id":"block-130")
                 assert prompt =~ ~s("authoring_mode_recommendation":)
                 assert prompt =~ ~s("strategy":"pedagogical_mix_v2")
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )

    assert Enum.map(
             result.payload["content_payload"]["instructional_sections"],
             & &1["evidence_block_ids"]
           ) == [["block-1"], ["block-130"]]
  end

  test "includes typed persisted callout metadata and its complete body in the AI prompt" do
    callout_body =
      "Targeted advertising uses browsing history and computational models to personalize messages, creating ethical questions about consent, transparency, and responsible data use."

    source_blocks = [
      %{
        "id" => "targeted-advertising",
        "kind" => "callout",
        "heading_path" => ["Data Science"],
        "text" => "Global Issues in Technology Targeted Advertising",
        "metadata" => %{
          "semantic_payload" => %{
            "callout_type" => "global_issue",
            "title" => "Global Issues in Technology",
            "subtitle" => "Targeted Advertising",
            "callout_body" => callout_body
          }
        }
      }
    ]

    response = %{
      "plan_mode" => "basic",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Evaluate responsible uses of data"],
          "narrative" =>
            "Learners evaluate how targeted advertising uses data and why transparent, responsible use matters.",
          "instructional_sections" => [
            %{
              "heading" => "How targeted advertising uses data",
              "explanation" =>
                "Targeted advertising combines browsing history with computational models to choose personalized messages. The connection between collected evidence and a model's output lets learners identify what information shapes the result.",
              "evidence_block_ids" => ["targeted-advertising"]
            },
            %{
              "heading" => "Responsible decisions",
              "explanation" =>
                "Consent and transparency help people understand how their information is being used. A responsible decision therefore weighs personalization against privacy, explains the model's role, and makes data practices visible.",
              "evidence_block_ids" => ["targeted-advertising"]
            }
          ],
          "worked_examples" => [
            %{
              "title" => "Audit a personalized message",
              "scenario" =>
                "A service uses browsing history to select a personalized advertisement.",
              "steps" => [
                "Identify the browsing evidence used by the model.",
                "Evaluate whether consent and data use are transparent."
              ],
              "conclusion" =>
                "The audit connects personalization to responsible and transparent data use.",
              "evidence_block_ids" => ["targeted-advertising"]
            }
          ]
        }),
      "questions_payload" => %{
        "items" => [
          reflection_response("q1", "targeted-advertising"),
          reflection_response("q2", "targeted-advertising")
        ]
      }
    }

    assert {:ok, result} =
             AIPlanner.plan(Map.put(lesson(), "source_blocks", source_blocks), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, messages, _ ->
                 prompt = Enum.find(messages, &(&1.role == :user)).content

                 assert prompt =~ ~s("callout_type":"global_issue")
                 assert prompt =~ ~s("title":"Global Issues in Technology")
                 assert prompt =~ ~s("subtitle":"Targeted Advertising")
                 assert prompt =~ callout_body

                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )

    assert result.created_by == "ai"
  end

  test "fails visibly when complete source evidence cannot fit the safe prompt limit" do
    oversized_block = %{
      "id" => "oversized-block",
      "kind" => "paragraph",
      "heading_path" => ["Oversized source"],
      "text" => List.duplicate("evidence", 30_000) |> Enum.join(" ")
    }

    assert {:error,
            {:ai_planning_failed,
             {:source_prompt_limit_exceeded, %{measure: :bytes, actual: actual, limit: 80_000}}}} =
             AIPlanner.plan(Map.put(lesson(), "source_blocks", [oversized_block]), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 flunk("the provider must not be called with silently truncated evidence")
               end
             )

    assert actual > 80_000
  end

  test "builds LessonPlanV3 from block evidence and hydrates server-issued media" do
    service_config = %ServiceConfig{id: 11}

    source_blocks =
      Enum.map(1..4, fn index ->
        %{
          "id" => "block-#{index}",
          "kind" => "paragraph",
          "heading_path" => ["Concept #{index}"],
          "text" =>
            "Concept #{index} explains how computing evidence supports a disciplinary application."
        }
      end)

    rich_lesson =
      lesson()
      |> Map.put("source_blocks", source_blocks)
      |> Map.put("source_word_count", 1_300)
      |> Map.put("source_media", [
        %{
          "id" => "figure-1",
          "source_url" => "https://openstax.org/apps/image-cdn/v1/example",
          "alt" => "A data visualization used to compare disciplinary evidence.",
          "caption" => "A disciplinary data visualization.",
          "credit" => "OpenStax figure credit",
          "rights_status" => "approved",
          "evidence_block_ids" => ["block-2"]
        }
      ])

    instructional_sections =
      Enum.map(1..4, fn index ->
        %{
          "id" => "section-#{index}",
          "heading" => "Concept #{index}",
          "explanation" =>
            "This explanation develops concept #{index} with enough source-grounded detail to teach how computing evidence supports a disciplinary application and why the relationship matters.",
          "evidence_block_ids" => ["block-#{index}"]
        }
      end)

    response = %{
      "plan_mode" => "basic",
      "content_payload" =>
        rich_content(%{
          "learning_objectives" => ["Define an algorithm"],
          "narrative" => "Learners investigate computing across disciplinary applications.",
          "opening_hook" => "How can the same computing idea change several fields?",
          "why_this_matters" => "Computing connects evidence and decisions across disciplines.",
          "instructional_sections" => instructional_sections,
          "worked_examples" => [
            %{
              "title" => "Compare two applications",
              "scenario" => "Two disciplines use the same computing method differently.",
              "steps" => ["Identify the shared method.", "Compare the evidence in each use."],
              "conclusion" => "The method transfers while its evidence and constraints change.",
              "evidence_block_ids" => ["block-1", "block-2"]
            }
          ],
          "media" => [
            %{
              "source_media_id" => "figure-1",
              "placement_after_section_id" => "section-2"
            }
          ]
        }),
      "questions_payload" => %{
        "items" => [
          multiple_choice_response("q1", "block-1"),
          multiple_choice_response("q2", "block-2"),
          reflection_response("q3", "block-3"),
          reflection_response("q4", "block-4")
        ]
      }
    }

    assert {:ok, result} =
             AIPlanner.plan(rich_lesson, 2,
               service_config_loader: fn -> {:ok, service_config} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )

    content = result.payload["content_payload"]
    assert content["schema_version"] == 3
    assert content["source_block_ids"] == Enum.map(source_blocks, & &1["id"])
    assert [%{"source_media_id" => "figure-1", "alt" => alt}] = content["media"]
    assert alt =~ "data visualization"
    assert Enum.all?(content["instructional_sections"], &(&1["evidence_block_ids"] != []))
  end

  test "rejects a narrative-only AI response instead of creating another thin lesson" do
    response = %{
      "plan_mode" => "basic",
      "content_payload" => %{
        "learning_objectives" => ["Define an algorithm"],
        "narrative" => "This lesson introduces algorithms."
      },
      "questions_payload" => %{
        "items" => [
          %{"prompt" => "What is an algorithm?"},
          %{"prompt" => "Give an example of an algorithm."}
        ]
      }
    }

    assert {:error, {:ai_planning_failed, :invalid_instructional_sections}} =
             AIPlanner.plan(lesson(), 1,
               service_config_loader: fn -> {:ok, %ServiceConfig{id: 1}} end,
               execution_fun: fn _, _, _ ->
                 {:ok, %{content: Jason.encode!(response), metadata: %{model: "test-model"}}}
               end
             )
  end

  defp rich_content(overrides) do
    Map.merge(
      %{
        "instructional_sections" => [
          %{
            "heading" => "What makes a procedure an algorithm",
            "explanation" =>
              "An algorithm gives a finite and unambiguous sequence of steps that transforms a stated input into the intended output for a defined problem."
          },
          %{
            "heading" => "Applying a procedure",
            "explanation" =>
              "To apply an algorithm, identify the input, follow each operation in order, and check whether the resulting output satisfies the original problem."
          }
        ],
        "worked_examples" => [
          %{
            "title" => "Following a sorting procedure",
            "scenario" => "Arrange a small list by repeatedly comparing neighboring values.",
            "steps" => [
              "Compare the first neighboring pair.",
              "Swap values that appear in the wrong order."
            ],
            "conclusion" =>
              "Repeating the defined comparison and swap steps eventually orders the list."
          }
        ],
        "key_takeaways" => [
          "Algorithms contain precise ordered steps.",
          "Inputs are transformed into expected outputs.",
          "A result should be checked against the original problem."
        ]
      },
      overrides
    )
  end

  defp multiple_choice_response(id, block_id) do
    %{
      "id" => id,
      "prompt" => "Which explanation is best supported by this concept?",
      "type" => "multiple_choice",
      "choices" => [
        %{"id" => "#{id}-a", "text" => "The supported explanation", "correct" => true},
        %{"id" => "#{id}-b", "text" => "An unsupported explanation", "correct" => false}
      ],
      "evidence_block_ids" => [block_id]
    }
  end

  defp reflection_response(id, block_id) do
    %{
      "id" => id,
      "prompt" => "Apply the concept to another discipline.",
      "type" => "short_answer",
      "answer_keywords" => ["concept", "evidence"],
      "evidence_block_ids" => [block_id]
    }
  end

  defp advanced_blueprint do
    %{
      "screens" => [
        %{
          "id" => "choose-procedure",
          "kind" => "decision",
          "title" => "Choose the precise procedure",
          "prompt" => "Which procedure is a precise algorithm?",
          "interaction_type" => "multiple_choice",
          "choices" => [
            %{
              "id" => "precise",
              "text" => "A finite sequence with unambiguous steps",
              "correct" => true,
              "feedback" => "The steps are finite and unambiguous."
            },
            %{
              "id" => "vague",
              "text" => "A suggestion that leaves every operation unspecified",
              "correct" => false,
              "feedback" => "An algorithm must specify each operation precisely."
            }
          ],
          "correct_choice_id" => "precise",
          "placement_after_section_id" => "section-1",
          "remediation_section_id" => "section-1",
          "evidence_block_ids" => []
        }
      ],
      "remediation_paths" => [
        %{
          "from_question_id" => "choose-procedure",
          "to_section_id" => "section-1",
          "misconception" => "A vague suggestion is not a precise algorithm."
        }
      ]
    }
  end
end
