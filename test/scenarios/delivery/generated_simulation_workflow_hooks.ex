defmodule Oli.Scenarios.Delivery.GeneratedSimulationWorkflowHooks do
  @moduledoc """
  Drives one seeded Advanced v7 simulation through the real governance,
  validation, compiler, authoring, publication, and delivery boundaries.

  Oli.Scenarios does not yet expose OpenStax import directives, so this hook is
  the narrow adapter between scenario-owned project data and the production
  import contexts. It does not use factories, fixtures, provider mocks, or
  direct lifecycle-state updates.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Oli.Authoring.Editing.ActivityEditor

  alias Oli.OpenStax.CourseImport.{
    AdvancedPlanV7,
    AuthoringCompiler,
    Compiler,
    Enrichment,
    EnrichmentProposal,
    EnrichmentResearchSet,
    Lesson,
    LessonPlan,
    LessonSource,
    Run,
    SimulationDomainReferences,
    SimulationSpecV1,
    SourceBlock,
    SourceSection,
    Unit
  }

  alias Oli.OpenStax.CourseImport.Enrichment.{
    ArtifactCritic,
    Generator.Template,
    LibraryRegistry
  }

  alias Oli.OpenStax.CourseImport.Enrichment.Sandbox.{BrowserContainer, LocalContainer}
  alias Oli.Publishing
  alias Oli.Repo
  alias Oli.Resources
  alias Oli.Scenarios.DirectiveTypes.ExecutionState

  @project_name "generated_simulation_project"
  @page_title "Observe Gas Pressure"
  @activity_virtual_id "approved_gas_pressure_simulation"
  @source_url "https://openstax.org/books/chemistry-2e/pages/9-2-relating-pressure-volume-amount-and-temperature-the-ideal-gas-law"
  @authority_url "https://physics.nist.gov/cuu/Constants/"
  @storage_origin "https://simulations.example.edu"

  def generate_validate_and_attach(%ExecutionState{} = state) do
    built_project = Map.fetch!(state.projects, @project_name)
    project = built_project.project
    author = state.current_author
    page_revision = Map.fetch!(built_project.rev_by_title, @page_title)

    source = imported_source!(project, author, built_project.root.resource.id)
    content = advanced_content!(source.lesson_payload)
    plan = persist_approved_plan!(source.lesson, content)

    proposal = create_opportunity!(source.run, source.lesson)

    assert {:error, :research_approval_required} =
             Enrichment.begin_spec_generation(proposal.id)

    {proposal, research} = research_and_approve!(proposal, author)
    spec = design_spec!(proposal, research)

    assert {:error, :stale_simulation_spec} =
             Enrichment.begin_artifact_generation(proposal.id, %{
               simulation_spec_id: spec.id,
               simulation_spec_hash: String.duplicate("0", 64)
             })

    artifact = generate_validate_and_approve!(proposal, research, spec, author)
    compiled = compile!(source.run, source.unit, source.lesson, plan, artifact)

    updated_state = attach_compiled_lesson(state, built_project, page_revision, compiled)

    source.run
    |> Run.update_changeset(%{
      status: :completed,
      result: %{"lesson_count" => 1, "generated_simulation_count" => 1},
      finished_at: DateTime.utc_now()
    })
    |> Repo.update!()

    updated_state
  end

  defp imported_source!(project, author, target_resource_id) do
    now = DateTime.utc_now()

    run =
      %Run{}
      |> Run.create_changeset(%{
        project_id: project.id,
        author_id: author.id,
        target_root_container_resource_id: target_resource_id,
        status: :awaiting_lesson_approval,
        source_url: @source_url,
        book_slug: "chemistry-2e",
        source_schema_version: 4,
        plan_schema_version: 7,
        lesson_planning_strategy: :parallel_v1,
        started_at: now
      })
      |> Repo.insert!()

    unit =
      %Unit{}
      |> Unit.changeset(%{
        run_id: run.id,
        unit_name: "Gases",
        order: 1,
        status: "approved",
        source_sections_count: 1,
        selected: true
      })
      |> Repo.insert!()

    lesson =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        order: 1,
        planning_position: 1,
        title: "Relating Gas Pressure and Volume",
        source_sections: [@source_url],
        source_objectives: ["Use evidence to relate gas pressure and volume."],
        plan_mode: "advanced",
        status: "approved",
        selected: true,
        source_word_count: 1_260,
        source_evidence_links: [@source_url],
        source_coverage: %{"complete" => true},
        last_plan_version: 1,
        approved_by_author_id: author.id,
        approved_at: now,
        planning_state: "completed",
        planning_finished_at: now
      })
      |> Repo.insert!()

    source_text =
      "Analyze pressure and volume data, calculate a ratio, compare predictions with observations, and explain which relationship the evidence supports."

    section =
      %SourceSection{}
      |> SourceSection.changeset(%{
        run_id: run.id,
        canonical_url: @source_url,
        section_slug: "9-2-gas-law",
        title: "Relating Pressure, Volume, Amount, and Temperature",
        order: 1,
        chapter_id: "9",
        chapter_order: 9,
        section_order: 2,
        learning_objectives: lesson.source_objectives,
        normalized_word_count: 1_260,
        content_hash: hash(source_text),
        retrieved_at: now,
        source_coverage: %{"complete" => true}
      })
      |> Repo.insert!()

    blocks =
      [
        {"gas-evidence", "paragraph", source_text},
        {"gas-investigation", "exercise",
         "First predict the pressure change, then vary volume, record the result, and interpret the evidence."}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{source_key, kind, text}, order} ->
        block =
          %SourceBlock{}
          |> SourceBlock.changeset(%{
            run_id: run.id,
            source_section_id: section.id,
            source_key: source_key,
            order: order,
            heading_path: [section.title],
            block_kind: kind,
            normalized_text: text,
            source_locator: %{"url" => @source_url},
            token_estimate: 40,
            content_hash: hash(text)
          })
          |> Repo.insert!()

        %LessonSource{}
        |> LessonSource.changeset(%{
          run_id: run.id,
          lesson_id: lesson.id,
          source_block_id: block.id,
          order: order,
          purpose: "instruction"
        })
        |> Repo.insert!()

        block
      end)

    lesson_payload = %{
      "title" => lesson.title,
      "source_objectives" => lesson.source_objectives,
      "source_sections" => lesson.source_sections,
      "source_evidence_links" => lesson.source_evidence_links,
      "source_blocks" =>
        Enum.map(blocks, fn block ->
          %{
            "id" => block.source_key,
            "kind" => block.block_kind,
            "text" => block.normalized_text,
            "ast" => [
              %{"type" => "p", "children" => [%{"text" => block.normalized_text}]}
            ]
          }
        end),
      "source_media" => []
    }

    %{run: run, unit: unit, lesson: lesson, lesson_payload: lesson_payload}
  end

  defp advanced_content!(lesson_payload) do
    slots =
      Enum.map(1..4, fn index ->
        %{
          "id" => "gas-slot-#{index}",
          "stage_id" => if(index == 4, do: "synthesis-stage", else: "investigation"),
          "purpose" => "Use imported gas evidence in step #{index}.",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["gas-evidence", "gas-investigation"],
          "recommended_types" => ["multiple_choice"],
          "remediation_content_group_id" => "gas-evidence-group",
          "estimated_minutes" => 11
        }
      end)

    architecture_candidate = %{
      "title" => lesson_payload["title"],
      "orientation" => %{
        "overview" =>
          "Predict how pressure changes, test the bounded model, and explain the evidence."
      },
      "content_groups" => [
        %{
          "id" => "gas-evidence-group",
          "title" => "Pressure and volume evidence",
          "instructional_purpose" => "evidence",
          "source_block_ids" => ["gas-evidence"]
        },
        %{
          "id" => "gas-investigation-group",
          "title" => "Prediction and investigation evidence",
          "instructional_purpose" => "application",
          "source_block_ids" => ["gas-investigation"]
        }
      ],
      "question_slots" => [],
      "generated_alt_text" => [],
      "synthesis" => %{
        "heading" => "Explain the relationship",
        "summary" => "Reconcile the prediction with the observed pressure and volume evidence.",
        "takeaways" => ["A model claim must remain tied to observed evidence."]
      },
      "experience_blueprint" => %{
        "driving_question" => "How does volume affect pressure in this bounded gas model?",
        "stages" => [
          %{
            "id" => "investigation",
            "title" => "Predict, investigate, and explain",
            "purpose" => "Use the source relationship in a bounded investigation.",
            "presentation_pattern" => "predict_observe_explain",
            "roles" =>
              ~w(orientation prediction investigation observation evidence interpretation transfer synthesis),
            "introduction" => %{
              "heading" => "Turn the gas relationship into a testable prediction",
              "body" =>
                "Use the imported pressure-volume relationship to predict a direction of change before comparing calculated observations.",
              "evidence_block_ids" => ["gas-evidence", "gas-investigation"]
            },
            "guidance" => gas_guidance(),
            "native_follow_up_slot_id" => "gas-slot-1",
            "items" =>
              [
                %{"kind" => "content_group", "ref_id" => "gas-evidence-group"},
                %{"kind" => "content_group", "ref_id" => "gas-investigation-group"}
              ] ++
                Enum.map(1..3, fn index ->
                  %{"kind" => "activity_slot", "ref_id" => "gas-slot-#{index}"}
                end)
          },
          %{
            "id" => "synthesis-stage",
            "title" => "Rejoin and explain",
            "purpose" => "Rejoin both evidence pathways for a shared explanation.",
            "presentation_pattern" => "guided_reading",
            "roles" => ["synthesis"],
            "introduction" => %{
              "heading" => "Compare what each pathway established",
              "body" =>
                "Use the evidence from the selected pathway to explain the shared pressure-volume relationship.",
              "evidence_block_ids" => ["gas-evidence", "gas-investigation"]
            },
            "guidance" => [],
            "native_follow_up_slot_id" => "gas-slot-4",
            "items" => [%{"kind" => "activity_slot", "ref_id" => "gas-slot-4"}]
          }
        ],
        "activity_slots" => slots,
        "branch_sets" => [
          %{
            "id" => "gas-evidence-path",
            "decision_activity_slot_id" => "gas-slot-1",
            "objective_ids" => ["objective-1"],
            "rejoin_stage_id" => "synthesis-stage",
            "pathways" => [
              %{
                "choice_id" => "supported",
                "label" => "Follow the matching-evidence path",
                "target_content_group_id" => "gas-evidence-group",
                "feedback" => "Inspect where the prediction and measured relationship agree.",
                "evidence_block_ids" => ["gas-evidence"]
              },
              %{
                "choice_id" => "unsupported",
                "label" => "Investigate the conflicting-evidence path",
                "target_content_group_id" => "gas-investigation-group",
                "feedback" => "Test why the evidence challenges the original prediction.",
                "evidence_block_ids" => ["gas-investigation"]
              }
            ]
          }
        ]
      }
    }

    activities =
      Enum.map(1..4, fn index ->
        %{
          "id" => "gas-activity-#{index}",
          "slot_id" => "gas-slot-#{index}",
          "context" => "The imported source compares a prediction with observed gas evidence.",
          "prompt" => "Which conclusion is supported in investigation step #{index}?",
          "interaction_type" => "multiple_choice",
          "choices" => [
            %{
              "id" => "supported",
              "text" => "Use the observed pressure and volume evidence.",
              "correct" => true
            },
            %{
              "id" => "unsupported",
              "text" => "Keep the prediction even when the evidence conflicts.",
              "correct" => false,
              "feedback" => "The conclusion must use the observed evidence."
            }
          ],
          "correct_feedback" => "The response uses the imported evidence.",
          "incorrect_feedback" => "Compare the prediction with the observed values.",
          "allow_not_sure" => true,
          "hint" => "Look for agreement between the prediction and observation.",
          "remediation_content_group_id" => "gas-evidence-group",
          "objective_ids" => ["objective-1"],
          "evidence_block_ids" => ["gas-evidence", "gas-investigation"]
        }
      end)

    {:ok, architecture} =
      AdvancedPlanV7.build_architecture(architecture_candidate, lesson_payload, 1)

    {:ok, content} =
      AdvancedPlanV7.attach_activities(
        architecture,
        %{"activities" => activities},
        lesson_payload
      )

    content
  end

  defp gas_guidance do
    [
      {"prediction", "Commit to a pressure prediction",
       "Predict how pressure changes when volume is halved while amount and temperature stay fixed."},
      {"observation", "Record the calculated evidence",
       "Record amount, volume, temperature, and pressure with units for each bounded case."},
      {"interpretation", "Interpret the pressure ratio",
       "Compare the pressure ratio with the volume ratio and identify the supported relationship."},
      {"transfer", "Test a changed condition",
       "Hold two variables fixed, change a third, and predict whether the prior relationship still applies."},
      {"synthesis", "Qualify the gas-model claim",
       "Explain the observed relationship and identify where the ideal-gas assumptions limit the conclusion."}
    ]
    |> Enum.map(fn {kind, heading, body} ->
      %{
        "kind" => kind,
        "heading" => heading,
        "body" => body,
        "evidence_block_ids" => ["gas-evidence", "gas-investigation"]
      }
    end)
  end

  defp persist_approved_plan!(lesson, content) do
    %LessonPlan{}
    |> LessonPlan.changeset(%{
      lesson_id: lesson.id,
      version: 1,
      content_payload: content,
      questions_payload: %{"items" => []},
      generation_metadata: %{"pipeline" => "advanced_v7_seeded_scenario"},
      checks_snapshot: %{"quality_gate" => "passed", "confidence" => 1.0},
      created_by: "system",
      approved_by_user: true,
      approved_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp create_opportunity!(run, lesson) do
    {:ok, proposal} =
      Enrichment.create_proposal(run.id, lesson.id, %{
        kind: "generated_simulation",
        rank: 1,
        instructional_rationale:
          "Make the source pressure-volume relationship observable before the native follow-up.",
        objective_ids: ["objective-1"],
        source_evidence: %{"block_ids" => ["gas-evidence", "gas-investigation"]},
        placement: %{"stage_id" => "investigation"},
        learner_task: "Predict, vary the bounded setting, and explain the observation.",
        metadata: %{
          "planner_id" => "gas-pressure-volume-v1",
          "domain" => "chemistry",
          "research_query" => "authoritative evidence for gas pressure and volume",
          "misconception_target" => "Pressure and volume always increase together",
          "expected_instructional_value" => "Connect prediction, observation, and explanation."
        }
      })

    proposal
  end

  defp research_and_approve!(proposal, author) do
    accessed_at = DateTime.utc_now()

    sources = [
      %{"url" => @source_url, "title" => "OpenStax Chemistry 2e gas relationships"},
      %{"url" => @authority_url, "title" => "NIST physical constants"}
    ]

    claims = [
      %{
        "paraphrase" =>
          "The bounded model must state its variables, units, assumptions, and evidence limits.",
        "citation_urls" => [@source_url, @authority_url]
      }
    ]

    source_hash = hash(sources)
    content_hash = hash(%{"sources" => sources, "claims" => claims})

    assert {:ok, _running} = Enrichment.mark_research_running(proposal.id)

    assert {:ok, reviewable} =
             Enrichment.record_research_result(
               proposal.id,
               {:ok,
                %{
                  evidence: %{
                    "retrieved_sources" => sources,
                    "proposed_sources" => sources,
                    "claims" => claims,
                    "search_count" => 1,
                    "source_count" => 2,
                    "provider" => "scenario_seed",
                    "model" => "audited-static",
                    "provider_usage" => %{
                      "input_tokens" => 0,
                      "output_tokens" => 0,
                      "searches" => 1
                    },
                    "source_hash" => source_hash,
                    "content_hash" => content_hash,
                    "accessed_at" => DateTime.to_iso8601(accessed_at)
                  }
                }}
             )

    research =
      Repo.one!(
        from(record in EnrichmentResearchSet,
          where: record.proposal_id == ^proposal.id and record.status == "evidence_review"
        )
      )

    assert reviewable.state == "evidence_review"

    assert {:ok, approved} =
             Enrichment.approve_evidence(
               proposal.id,
               research.id,
               research.content_hash,
               author
             )

    {Repo.get!(EnrichmentProposal, proposal.id), approved}
  end

  defp design_spec!(proposal, research) do
    research_contract = %{
      "content_hash" => research.content_hash,
      "proposed_sources" => research.proposed_sources,
      "claims" => research.claims
    }

    candidate =
      SimulationDomainReferences.build!("chemistry", research_contract,
        objective_ids: ["objective-1"],
        authority_url: @authority_url,
        id_prefix: "gas-pressure-volume",
        native_follow_up_activity_id: "gas-activity-1",
        remediation_content_group_id: "gas-evidence-group"
      )

    assert {:ok, normalized, validation} =
             SimulationSpecV1.validate(candidate, research_contract)

    assert normalized["contract_profile"] == "domain_reference_v1"
    assert length(normalized["sample_cases"]) == 3
    assert get_in(normalized, ["model", "equations"]) != []

    assert Enum.all?(normalized["sample_cases"], fn sample ->
             Map.has_key?(sample["expected_outputs"], "pressure_kpa")
           end)

    assert {:ok, designing} = Enrichment.begin_spec_generation(proposal.id)

    assert {:ok, ready} =
             Enrichment.record_spec_result(
               designing.id,
               {:ok,
                %{
                  spec: normalized,
                  content_hash: hash(normalized),
                  provider: "scenario_seed",
                  model: "audited-static",
                  prompt_version: "simulation-spec-v1",
                  repair_count: 0,
                  criticism: %{"approved" => true, "confidence" => 1.0, "findings" => []},
                  validation: validation,
                  history: [%{"attempt" => 1, "status" => "accepted"}]
                }}
             )

    ready
  end

  defp generate_validate_and_approve!(proposal, research, spec, author) do
    assert {:ok, artifact} =
             Enrichment.begin_artifact_generation(proposal.id, %{
               generator_name: "local_prediction_explorer",
               generator_version: "1",
               simulation_spec_id: spec.id,
               simulation_spec_hash: spec.content_hash
             })

    assert {:ok, generated} =
             Template.generate(proposal, simulation_spec: spec, research_set: research)

    assert {:ok, assembled} = LibraryRegistry.assemble(generated, three_d_enabled: false)

    validation_opts = [
      simulation_spec: spec.spec_payload,
      sample_cases: spec.spec_payload["sample_cases"],
      rendering_mode: spec.spec_payload["rendering_mode"]
    ]

    {validator, browser_validated?} =
      if BrowserContainer.available?(),
        do: {BrowserContainer, true},
        else: {LocalContainer, false}

    assert {:ok, validated} = validator.build_and_validate(assembled, validation_opts)
    assert {:ok, criticism} = ArtifactCritic.review(spec, research, generated, validated)
    assert criticism["approved"]

    storage_key =
      "generated-simulations/artifacts/#{artifact.id}/v#{artifact.version}/sha256/#{validated.content_hash}/index.html"

    payload = %{
      generator_name: "local_prediction_explorer",
      generator_version: "1",
      generation_metadata: %{
        "runtime_profile" => "audited_static",
        "browser_validated" => browser_validated?,
        "artifact_criticism" => criticism
      },
      bundle_manifest: validated.bundle_manifest,
      capi_manifest: validated.capi_manifest,
      accessibility_metadata: validated.accessibility_metadata,
      validation_status: "passed",
      validation_version: 1,
      validation_payload: validated.validation_payload,
      content_hash: validated.content_hash,
      byte_size: validated.byte_size,
      storage_provider: "scenario_content_addressed",
      storage_key: storage_key,
      storage_origin: @storage_origin
    }

    assert {:ok, _intent} = Enrichment.record_artifact_staging_intent(artifact.id, payload)

    assert {:ok, preview} =
             Enrichment.record_artifact_generation_result(
               artifact.id,
               {:ok, Map.put(payload, :storage_state, "staged")}
             )

    assert {:ok, approved} =
             Enrichment.approve_artifact(
               preview.id,
               preview.version,
               preview.content_hash,
               author
             )

    approved
  end

  defp compile!(run, unit, lesson, plan, artifact) do
    proposal =
      Repo.one!(
        from(proposal in EnrichmentProposal,
          where: proposal.id == ^artifact.proposal_id,
          preload: [:research_sets, :simulation_specs, :simulation_artifacts]
        )
      )

    run = %{
      run
      | units: [%{unit | lessons: [%{lesson | plans: [plan]}]}],
        enrichment_proposals: [proposal]
    }

    url =
      "#{@storage_origin}/generated-simulations/artifacts/#{artifact.id}/v#{artifact.version}/sha256/#{artifact.content_hash}/index.html"

    assert {:ok, %{"units" => [%{"lessons" => [compiled]}]}} =
             Compiler.dry_run(run,
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: false,
               generated_simulation_origins: [@storage_origin],
               simulation_artifact_url_resolver: fn resolved ->
                 if resolved.id == artifact.id, do: {:ok, url}, else: {:error, :not_found}
               end
             )

    assert {:ok, %{"units" => [%{"lessons" => [native_fallback]}]}} =
             Compiler.dry_run(run,
               generated_simulation_delivery_enabled: true,
               generated_simulation_kill_switch: true,
               generated_simulation_origins: [@storage_origin],
               simulation_artifact_url_resolver: fn _resolved ->
                 raise "the delivery kill switch must not resolve an artifact URL"
               end
             )

    refute Jason.encode!(native_fallback) =~ "generated_simulation"
    assert length(native_fallback["activities"]) >= 4

    compiled
  end

  defp attach_compiled_lesson(state, built_project, page_revision, compiled) do
    {activity_ids, activities, virtual_ids} =
      compiled["activities"]
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, state.activities, state.activity_virtual_ids}, fn {spec, index},
                                                                             {ids, activities,
                                                                              virtual_ids} ->
        {:ok, {revision, _resource}} =
          ActivityEditor.create(
            built_project.project.slug,
            spec["activity_type_slug"],
            state.current_author,
            spec["model"],
            [],
            "embedded",
            spec["title"] || "Generated simulation workflow activity #{index}"
          )

        activities =
          Map.put(activities, {@project_name, revision.title}, revision)

        virtual_ids =
          if Jason.encode!(spec["model"]) =~ "generated_simulation" do
            Map.put(virtual_ids, {@project_name, @activity_virtual_id}, revision)
          else
            virtual_ids
          end

        {Map.put(ids, spec["key"], revision.resource_id), activities, virtual_ids}
      end)

    assert Map.has_key?(virtual_ids, {@project_name, @activity_virtual_id})

    assert {:ok, page_content} =
             AuthoringCompiler.realize_page(compiled["page_content_template"], activity_ids)

    assert {:ok, updated_page} =
             Resources.update_revision(page_revision, %{content: page_content, graded: false})

    assert {:ok, _published_resource} =
             Publishing.upsert_published_resource(built_project.working_pub, updated_page)

    updated_project = %{
      built_project
      | rev_by_title: Map.put(built_project.rev_by_title, @page_title, updated_page)
    }

    %{
      state
      | projects: Map.put(state.projects, @project_name, updated_project),
        activities: activities,
        activity_virtual_ids: virtual_ids
    }
  end

  defp hash(value) when is_binary(value), do: sha256(value)
  defp hash(value), do: value |> Jason.encode!() |> sha256()

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
