defmodule Oli.OpenStax.CourseImport.EnrichmentTest do
  use Oli.DataCase, async: false

  alias Oli.OpenStax.CourseImport

  alias Oli.OpenStax.CourseImport.{
    Enrichment,
    EnrichmentProposal,
    Lesson,
    LessonPlan,
    Run,
    SimulationArtifact,
    Unit
  }

  alias Oli.OpenStax.CourseImport.Enrichment.{Generator, Research, Sandbox}
  alias Oli.OpenStax.CourseImport.Worker.SimulationGenerationWorker
  alias Oli.Repo

  defmodule FakeStorage do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

    @impl true
    def available?, do: true

    @impl true
    def stage(_artifact, _bundle, _opts), do: {:error, :not_used}

    @impl true
    def prepare(_artifact, _bundle, _opts), do: {:error, :not_used}

    @impl true
    def resolve(artifact, _opts) do
      {:ok, String.trim_trailing(artifact.storage_origin, "/") <> "/" <> artifact.storage_key}
    end

    @impl true
    def discard(artifact, opts) do
      if pid = opts[:test_pid], do: send(pid, {:discarded, artifact.id})
      :ok
    end
  end

  defmodule FakeWorkerGenerator do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.Generator

    @impl true
    def available?, do: true

    @impl true
    def runtime_profile, do: :audited_static

    @impl true
    def generate(_proposal, opts) do
      attempt = Process.get(:artifact_worker_generator_attempt, 0) + 1
      Process.put(:artifact_worker_generator_attempt, attempt)
      Process.put(:artifact_worker_repair, opts[:repair])
      Process.put(:artifact_worker_author_feedback, opts[:author_feedback])

      {:ok,
       %{
         files: %{
           "index.html" =>
             "<!doctype html><html><head><title>Candidate #{attempt}</title></head><body></body></html>"
         },
         manifest: %{"entrypoint" => "index.html", "library_ids" => []},
         capi_manifest: %{"inputs" => [], "outputs" => []},
         metadata: %{
           "runtime_profile" => "audited_static",
           "generator_name" => "attempt-test-generator",
           "generator_version" => "1",
           "provider" => "test",
           "model" => "deterministic",
           "provider_usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }
       }}
    end
  end

  defmodule FakeWorkerSandbox do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.Sandbox

    @impl true
    def available?, do: true

    @impl true
    def build_and_validate(bundle, _opts) do
      attempt = Process.get(:artifact_worker_sandbox_attempt, 0) + 1
      Process.put(:artifact_worker_sandbox_attempt, attempt)

      if attempt == 1 do
        finding = %{
          "category" => "sample",
          "code" => "capi_sample_failed",
          "message" => "CAPI sample case did not match.",
          "details" => %{
            "sample_index" => 0,
            "expected" => %{"pressure" => 2},
            "actual" => %{"pressure" => 3}
          }
        }

        {:error,
         %{
           code: :browser_acceptance_failed,
           stage: :browser_validation,
           retryable: false,
           findings: [finding],
           validation_payload: %{
             "status" => "failed",
             "validator" => "browser_container_v1",
             "findings" => [finding]
           }
         }}
      else
        hash = String.duplicate("7", 64)

        {:ok,
         %{
           files: bundle.files,
           content_hash: hash,
           byte_size: 100,
           bundle_manifest: %{"entrypoint" => "index.html"},
           capi_manifest: bundle.capi_manifest,
           accessibility_metadata: %{"keyboard" => "passed"},
           validation_payload: %{
             "status" => "passed",
             "validator" => "browser_container_v1"
           }
         }}
      end
    end
  end

  defmodule FakeWorkerStorage do
    @behaviour Oli.OpenStax.CourseImport.Enrichment.ArtifactStorage

    @impl true
    def available?, do: true

    @impl true
    def cleanup_available?, do: true

    @impl true
    def prepare(_artifact, bundle, _opts), do: {:ok, identity(bundle, "unstaged")}

    @impl true
    def stage(_artifact, bundle, _opts), do: {:ok, identity(bundle, "staged")}

    @impl true
    def resolve(_artifact, _opts), do: {:error, :not_used}

    @impl true
    def discard(_artifact, _opts), do: :ok

    defp identity(bundle, state) do
      hash = bundle.content_hash

      %{
        storage_provider: "test",
        storage_key: "bundles/#{hash}/index.html",
        storage_origin: "https://simulations.example.edu",
        storage_state: state,
        byte_size: bundle.byte_size
      }
    end
  end

  setup do
    author = author_fixture()
    %{project: project} = project_fixture(author, "OpenStax enrichment lifecycle")

    {:ok, run} =
      %Run{}
      |> Run.create_changeset(%{
        project_id: project.id,
        author_id: author.id,
        source_url: "https://openstax.org/details/books/chemistry-2e",
        book_slug: "chemistry-2e",
        status: :awaiting_lesson_approval,
        plan_schema_version: 6
      })
      |> Repo.insert()

    {:ok, unit} =
      %Unit{}
      |> Unit.changeset(%{run_id: run.id, unit_name: "Matter", order: 1})
      |> Repo.insert()

    {:ok, lesson} =
      %Lesson{}
      |> Lesson.changeset(%{
        run_id: run.id,
        unit_id: unit.id,
        order: 1,
        planning_position: 1,
        title: "Matter and Measurement"
      })
      |> Repo.insert()

    {:ok, author: author, project: project, run: run, lesson: lesson}
  end

  test "current author updates cannot downgrade or stringify system schema metadata", %{
    author: author,
    lesson: lesson
  } do
    for schema_version <- [4, "5"] do
      assert {:error, :plan_schema_version_immutable} =
               CourseImport.update_lesson_plan(
                 lesson.id,
                 author,
                 %{
                   "content_payload" => %{
                     "schema_version" => schema_version,
                     "objective" => "Apply the source concept"
                   },
                   "questions_payload" => %{"items" => []}
                 },
                 "basic"
               )
    end
  end

  test "plan persistence rejects a schema downgrade", %{lesson: lesson} do
    changeset =
      LessonPlan.changeset(%LessonPlan{}, %{
        lesson_id: lesson.id,
        version: 1,
        content_payload: %{
          "schema_version" => 4,
          "authoring_mode" => "advanced",
          "coverage_manifest" => %{}
        },
        questions_payload: %{"items" => []},
        created_by: "author"
      })

    refute changeset.valid?
    assert {message, _} = changeset.errors[:content_payload]
    assert message =~ "Basic schema 5 or Advanced schema 6"
  end

  test "proposal decisions cannot commit after the run leaves review", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, _cancelled} =
      run
      |> Run.update_changeset(%{status: :cancelled})
      |> Repo.update()

    assert {:error, {:run_not_reviewable, :cancelled}} =
             Enrichment.approve_proposal(proposal.id, author)
  end

  test "artifact approval cannot commit after the run leaves review", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    {:ok, preview} =
      Enrichment.record_artifact_generation_result(artifact.id, {:ok, preview_attrs("c")})

    {:ok, _cancelled} =
      run
      |> Run.update_changeset(%{status: :cancelled})
      |> Repo.update()

    assert {:error, {:run_not_reviewable, :cancelled}} =
             Enrichment.approve_artifact(
               preview.id,
               preview.version,
               preview.content_hash,
               author
             )
  end

  test "synchronizes at most three ranked proposals and locks after governance begins", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    attrs = [proposal_attrs("article", 1), proposal_attrs("video", 2)]

    assert {:ok, [first, second]} = Enrichment.sync_proposals(run.id, lesson.id, attrs)
    assert [first.rank, second.rank] == [1, 2]

    assert {:ok, [revised_first, revised_second]} =
             Enrichment.sync_proposals(run.id, lesson.id, attrs)

    assert revised_first.id == first.id
    assert revised_second.id == second.id
    assert revised_first.version == 2

    assert {:error, :too_many_proposals} =
             Enrichment.sync_proposals(run.id, lesson.id, [
               proposal_attrs("article", 1),
               proposal_attrs("video", 2),
               proposal_attrs("existing_simulation", 3),
               proposal_attrs("external_resource", 4)
             ])

    assert {:ok, _running} = Enrichment.mark_research_running(revised_first.id)

    assert {:ok, researched_first} =
             Enrichment.record_research_result(
               revised_first.id,
               {:ok,
                %{
                  evidence: %{"authority" => "Reviewed source"},
                  resource_title: "A reviewed chemistry resource",
                  resource_url: "https://example.edu/chemistry"
                }}
             )

    assert {:ok, approved} = Enrichment.approve_proposal(researched_first.id, author)
    assert approved.approved_version == approved.version

    assert [%{"action" => "approve"}] =
             Enum.map(approved.approval_history, &Map.take(&1, ["action"]))

    assert {:error, :proposal_sync_locked} =
             Enrichment.sync_proposals(run.id, lesson.id, attrs)
  end

  test "requires evidence, spec, and exact artifact approval gates", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    assert {:ok, proposal} =
             Enrichment.create_proposal(
               run.id,
               lesson.id,
               proposal_attrs("generated_simulation", 1)
             )

    assert {:error, :simulation_spec_not_approved} =
             Enrichment.begin_artifact_generation(proposal.id)

    assert {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)
    refute Enrichment.approved_but_incomplete?(run.id)

    assert {:error, :stale_simulation_spec} =
             Enrichment.begin_artifact_generation(
               proposal.id,
               artifact_start_attrs(spec, simulation_spec_hash: String.duplicate("f", 64))
             )

    assert {:ok, artifact_v1} =
             Enrichment.begin_artifact_generation(proposal.id, %{
               generator_name: "test-generator",
               generator_version: "1",
               simulation_spec_id: spec.id,
               simulation_spec_hash: spec.content_hash
             })

    assert {:ok, preview_v1} =
             Enrichment.record_artifact_generation_result(
               artifact_v1.id,
               {:ok, preview_attrs("a")}
             )

    assert preview_v1.status == "ready_for_review"

    assert {:error, :stale_artifact_version} =
             Enrichment.approve_artifact(
               preview_v1.id,
               preview_v1.version,
               String.duplicate("f", 64),
               author
             )

    assert {:ok, rejected_v1} =
             Enrichment.reject_artifact(preview_v1.id, author, "Try a clearer visual")

    assert rejected_v1.status == "rejected"

    assert {:ok, artifact_v2} =
             Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    assert {:ok, preview_v2} =
             Enrichment.record_artifact_generation_result(
               artifact_v2.id,
               {:ok, preview_attrs("b")}
             )

    assert {:ok, approved_v2} =
             Enrichment.approve_artifact(
               preview_v2.id,
               preview_v2.version,
               preview_v2.content_hash,
               author
             )

    assert approved_v2.version == 2
    refute Enrichment.approved_but_incomplete?(run.id)
    assert {:ok, %{id: approved_id}} = Enrichment.resolve_approved_artifact(proposal.id)
    assert approved_id == approved_v2.id

    assert {:error, {:invalid_artifact_status, "approved"}} =
             Enrichment.reject_artifact(approved_v2.id, author, "Approved versions are immutable")

    expected_hash = String.duplicate("b", 64)
    expected_url = "https://simulations.example.edu/bundles/#{expected_hash}/index.html"

    assert {:ok, ^expected_url} =
             Enrichment.artifact_url(approved_v2,
               artifact_storage: FakeStorage,
               trusted_origin: "https://simulations.example.edu"
             )
  end

  test "new research supersedes unfinished specs and artifacts", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    assert {:ok, proposal} =
             Enrichment.create_proposal(
               run.id,
               lesson.id,
               proposal_attrs("generated_simulation", 1)
             )

    assert {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    assert {:ok, artifact} =
             Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    assert {:ok, preview} =
             Enrichment.record_artifact_generation_result(artifact.id, {:ok, preview_attrs("c")})

    assert {:ok, restarted} = Enrichment.mark_research_running(proposal.id)
    assert restarted.state == "researching"
    assert restarted.research_version == 2
    assert Repo.reload!(spec).status == "superseded"
    assert Repo.reload!(preview).status == "superseded"
  end

  test "artifact candidate attempts append immutable ordered validation evidence", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    assert {:ok, first} =
             Enrichment.record_artifact_attempt(artifact.id, %{
               status: "validation_failed",
               source_hash: String.duplicate("1", 64),
               findings: [
                 %{
                   code: "capi_sample_failed",
                   details: %{sample_index: 0, expected: %{y: 4}, actual: %{y: 5}}
                 }
               ],
               validation_summary: %{status: "failed", validator: "browser_container_v1"},
               model_usage: %{generator: %{input_tokens: 10, output_tokens: 5}}
             })

    assert {:ok, second} =
             Enrichment.record_artifact_attempt(artifact.id, %{
               status: "accepted",
               source_hash: String.duplicate("2", 64),
               content_hash: String.duplicate("3", 64),
               validation_summary: %{status: "passed", validator: "browser_container_v1"},
               criticism: %{approved: true, confidence: 1.0}
             })

    assert first.attempt_number == 1
    assert second.attempt_number == 2
    assert first.findings |> hd() |> get_in(["details", "sample_index"]) == 0

    assert [persisted_first, persisted_second] =
             Enrichment.list_artifact_attempts(artifact.id)

    assert persisted_first.id == first.id
    assert persisted_second.id == second.id

    assert [%{attempts: [_, _]}] = Enrichment.list_artifacts(proposal.id)

    assert {:ok, fetched} = Enrichment.fetch_proposal(proposal.id)
    assert [%{attempts: attempts}] = fetched.simulation_artifacts
    assert Enum.map(attempts, & &1.id) |> MapSet.new() == MapSet.new([first.id, second.id])
  end

  test "generation worker persists every candidate and sends exact findings to repair", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    previous_generator = Application.get_env(:oli, :openstax_enrichment_generator)
    previous_sandbox = Application.get_env(:oli, :openstax_enrichment_sandbox)
    previous_storage = Application.get_env(:oli, :openstax_enrichment_artifact_storage)

    Application.put_env(:oli, :openstax_enrichment_generator, FakeWorkerGenerator)
    Application.put_env(:oli, :openstax_enrichment_sandbox, FakeWorkerSandbox)
    Application.put_env(:oli, :openstax_enrichment_artifact_storage, FakeWorkerStorage)

    on_exit(fn ->
      Application.put_env(:oli, :openstax_enrichment_generator, previous_generator)
      Application.put_env(:oli, :openstax_enrichment_sandbox, previous_sandbox)
      Application.put_env(:oli, :openstax_enrichment_artifact_storage, previous_storage)
    end)

    Process.put(:artifact_worker_generator_attempt, 0)
    Process.put(:artifact_worker_sandbox_attempt, 0)
    Process.delete(:artifact_worker_repair)
    Process.delete(:artifact_worker_author_feedback)

    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(
        proposal.id,
        spec
        |> artifact_start_attrs()
        |> Map.put(:generation_metadata, %{
          "author_feedback" => "Show the evidence table before the chart."
        })
      )

    job = %Oban.Job{
      args: %{"artifact_id" => artifact.id, "run_id" => run.id},
      attempt: 1,
      max_attempts: 3
    }

    assert :ok = SimulationGenerationWorker.perform(job)
    assert Process.get(:artifact_worker_generator_attempt) == 2
    assert Process.get(:artifact_worker_sandbox_attempt) == 2

    assert Process.get(:artifact_worker_author_feedback) ==
             "Show the evidence table before the chart."

    assert %{findings: [repair_finding]} = Process.get(:artifact_worker_repair)
    assert repair_finding["code"] == "capi_sample_failed"
    assert repair_finding["details"]["sample_index"] == 0
    assert repair_finding["details"]["expected"] == %{"pressure" => 2}
    assert repair_finding["details"]["actual"] == %{"pressure" => 3}

    assert [failed_attempt, accepted_attempt] =
             Enrichment.list_artifact_attempts(artifact.id)

    assert failed_attempt.status == "validation_failed"
    assert failed_attempt.findings == [repair_finding]
    assert accepted_attempt.status == "accepted"
    assert accepted_attempt.content_hash == String.duplicate("7", 64)
    assert failed_attempt.source_hash != accepted_attempt.source_hash

    saved = Repo.get!(SimulationArtifact, artifact.id)
    assert saved.status == "ready_for_review"
    assert saved.validation_status == "passed"
    assert get_in(saved.generation_metadata, ["builder_repair_count"]) == 1
    assert length(saved.generation_metadata["builder_history"]) == 2

    assert saved.generation_metadata["author_feedback"] ==
             "Show the evidence table before the chart."
  end

  test "approved incomplete generation can be cancelled without blocking core compilation", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    assert :ok = Enrichment.ensure_generation_complete(run.id)

    assert {:ok, cancelled} =
             Enrichment.cancel_proposal(proposal.id, author, "Proceed without the simulation")

    assert cancelled.state == "cancelled"
    assert Repo.get!(SimulationArtifact, artifact.id).status == "cancelled"
    assert :ok = Enrichment.ensure_generation_complete(run.id)
  end

  test "provider errors persist sanitized classifications and disabled defaults remain non-blocking",
       %{
         run: run,
         lesson: lesson
       } do
    {:ok, proposal} =
      Enrichment.create_proposal(run.id, lesson.id, proposal_attrs("article", 1))

    refute Generator.available?()
    refute Sandbox.available?()
    refute Research.available?()
    assert {:error, :generator_unavailable} = Generator.generate(proposal)
    assert {:error, :sandbox_unavailable} = Sandbox.build_and_validate(%{})

    assert {:ok, researched} = Enrichment.research_proposal(proposal.id)
    assert researched.state == "proposed"
    assert researched.research_status == "failed"
    assert researched.research_failure["code"] == "research_unavailable"
  end

  test "curated proposals require completed research evidence before approval", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(run.id, lesson.id, proposal_attrs("article", 1))

    assert {:error, :curated_enrichment_not_ready} =
             Enrichment.approve_proposal(proposal.id, author)

    assert {:ok, _running} = Enrichment.mark_research_running(proposal.id)

    assert {:ok, researched} =
             Enrichment.record_research_result(
               proposal.id,
               {:ok,
                %{
                  evidence: %{"license" => "CC BY 4.0"},
                  resource_title: "Open chemistry article",
                  resource_url: "https://example.edu/open-chemistry"
                }}
             )

    assert {:ok, approved} = Enrichment.approve_proposal(researched.id, author)
    assert approved.state == "approved"
  end

  test "failed generation never persists provider messages or generated source", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    assert {:ok, failed} =
             Enrichment.record_artifact_generation_result(
               artifact.id,
               {:error,
                %{
                  code: :sandbox_timeout,
                  stage: :validation,
                  retryable: true,
                  message: "secret provider body",
                  generated_source: "<script>secret</script>"
                }}
             )

    assert failed.status == "failed"

    assert failed.failure == %{
             "code" => "sandbox_timeout",
             "retryable" => true,
             "stage" => "validation"
           }

    refute inspect(failed.failure) =~ "secret"
  end

  test "orphan cleanup discards only never-approved artifact bundles and retains audit rows", %{
    author: author,
    run: run,
    lesson: lesson
  } do
    {:ok, proposal} =
      Enrichment.create_proposal(
        run.id,
        lesson.id,
        proposal_attrs("generated_simulation", 1)
      )

    {:ok, proposal, spec} = prepare_generated_proposal(proposal, author)

    {:ok, artifact} =
      Enrichment.begin_artifact_generation(proposal.id, artifact_start_attrs(spec))

    {:ok, failed_validation} =
      Enrichment.record_artifact_generation_result(
        artifact.id,
        {:ok,
         preview_attrs("c")
         |> Map.put(:validation_status, "failed")}
      )

    cutoff = DateTime.utc_now() |> DateTime.add(1, :second)

    assert [candidate] = Enrichment.list_orphaned_artifacts(run.id, cutoff)
    assert candidate.id == failed_validation.id

    assert {:ok, %{discarded: 1, failed: []}} =
             Enrichment.cleanup_orphaned_artifacts(
               run.id,
               cutoff,
               artifact_storage: FakeStorage,
               test_pid: self()
             )

    assert_receive {:discarded, artifact_id}
    assert artifact_id == artifact.id
    assert Repo.get!(SimulationArtifact, artifact.id).storage_state == "discarded"
  end

  test "proposal schema rejects non-HTTPS curated resource URLs" do
    changeset =
      EnrichmentProposal.create_changeset(%EnrichmentProposal{}, %{
        project_id: 1,
        run_id: Ecto.UUID.generate(),
        lesson_id: Ecto.UUID.generate(),
        kind: "article",
        rank: 1,
        instructional_rationale: "Connect the model to a current application.",
        learner_task: "Compare the evidence in the source and the article.",
        resource_url: "http://example.com/resource"
      })

    assert "must be an absolute HTTPS URL" in errors_on(changeset).resource_url
  end

  defp proposal_attrs(kind, rank) do
    attrs = %{
      kind: kind,
      rank: rank,
      instructional_rationale: "Let learners test the section's central model.",
      objective_ids: ["objective-1"],
      source_evidence: %{"block_ids" => ["block-1"]},
      placement: %{"after_block_id" => "block-1"},
      learner_task: "Predict the result, inspect the evidence, and explain the outcome."
    }

    if kind == "generated_simulation" do
      Map.put(attrs, :metadata, %{
        "planner_id" => "sim-#{rank}",
        "domain" => "chemistry",
        "research_query" => "primary sources for gas pressure and volume relationships",
        "misconception_target" => "Pressure and volume always increase together",
        "expected_instructional_value" => "Learners can compare prediction to evidence."
      })
    else
      attrs
    end
  end

  defp prepare_generated_proposal(proposal, author) do
    source_hash = String.duplicate("d", 64)
    content_hash = String.duplicate("e", 64)

    assert {:ok, _running} = Enrichment.mark_research_running(proposal.id)

    assert {:ok, _review} =
             Enrichment.record_research_result(
               proposal.id,
               {:ok,
                %{
                  evidence: %{
                    "retrieved_sources" => [
                      %{
                        "url" =>
                          "https://openstax.org/books/chemistry-2e/pages/9-2-relating-pressure-volume-amount-and-temperature-the-ideal-gas-law",
                        "title" => "OpenStax gas law"
                      },
                      %{
                        "url" => "https://physics.nist.gov/cuu/Constants/",
                        "title" => "NIST constants"
                      }
                    ],
                    "proposed_sources" => [
                      %{
                        "url" =>
                          "https://openstax.org/books/chemistry-2e/pages/9-2-relating-pressure-volume-amount-and-temperature-the-ideal-gas-law",
                        "title" => "OpenStax gas law"
                      },
                      %{
                        "url" => "https://physics.nist.gov/cuu/Constants/",
                        "title" => "NIST constants"
                      }
                    ],
                    "claims" => [
                      %{
                        "paraphrase" =>
                          "At fixed amount and temperature, pressure varies inversely with volume.",
                        "citation_urls" => [
                          "https://openstax.org/books/chemistry-2e/pages/9-2-relating-pressure-volume-amount-and-temperature-the-ideal-gas-law"
                        ]
                      }
                    ],
                    "search_count" => 1,
                    "source_count" => 2,
                    "provider" => "test",
                    "model" => "deterministic-fixture",
                    "source_hash" => source_hash,
                    "content_hash" => content_hash,
                    "accessed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                  }
                }}
             )

    research =
      proposal.id
      |> Enrichment.fetch_proposal()
      |> elem(1)
      |> Map.fetch!(:research_sets)
      |> Enum.find(&(&1.status == "evidence_review"))

    assert {:ok, approved_research} =
             Enrichment.approve_evidence(
               proposal.id,
               research.id,
               research.content_hash,
               author
             )

    assert {:ok, spec} = Enrichment.begin_spec_generation(proposal.id)

    spec_hash = String.duplicate("9", 64)

    assert {:ok, ready_spec} =
             Enrichment.record_spec_result(
               spec.id,
               {:ok,
                %{
                  spec: %{"domain" => "chemistry", "sample_cases" => []},
                  content_hash: spec_hash,
                  provider: "test",
                  model: "deterministic-fixture",
                  validation: %{"status" => "passed"}
                }}
             )

    assert approved_research.content_hash == ready_spec.evidence_hash
    {:ok, elem(Enrichment.fetch_proposal(proposal.id), 1), ready_spec}
  end

  defp artifact_start_attrs(spec, overrides \\ []) do
    [simulation_spec_id: spec.id, simulation_spec_hash: spec.content_hash]
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  defp preview_attrs(hash_character) do
    content_hash = String.duplicate(hash_character, 64)

    %{
      bundle_manifest: %{"entrypoint" => "index.html", "files" => ["index.html"]},
      capi_manifest: %{"inputs" => [], "outputs" => []},
      accessibility_metadata: %{
        "title" => "Particle motion simulation",
        "description" => "Adjust temperature and observe particle motion."
      },
      validation_status: "passed",
      validation_version: 1,
      validation_payload: %{"checks" => %{"accessibility" => "passed"}},
      content_hash: content_hash,
      byte_size: 1_024,
      storage_state: "staged",
      storage_provider: "media_bucket",
      storage_key: "bundles/#{content_hash}/index.html",
      storage_origin: "https://simulations.example.edu",
      generated_at: DateTime.utc_now(),
      staged_at: DateTime.utc_now()
    }
  end
end
