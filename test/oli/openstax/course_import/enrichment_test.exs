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

    {:ok, proposal} = Enrichment.approve_proposal(proposal.id, author)
    {:ok, artifact} = Enrichment.begin_artifact_generation(proposal.id)

    {:ok, preview} =
      Enrichment.record_artifact_generation_result(artifact.id, {:ok, preview_attrs("c")})

    {:ok, _cancelled} =
      run
      |> Run.update_changeset(%{status: :cancelled})
      |> Repo.update()

    assert {:error, {:run_not_reviewable, :cancelled}} =
             Enrichment.approve_artifact(preview.id, author)
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

  test "requires both approval gates and resolves only the exact approved artifact", %{
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

    assert {:error, :proposal_not_approved} =
             Enrichment.begin_artifact_generation(proposal.id)

    assert {:ok, proposal} = Enrichment.approve_proposal(proposal.id, author)
    assert Enrichment.approved_but_incomplete?(run.id)

    assert {:ok, artifact_v1} =
             Enrichment.begin_artifact_generation(proposal.id, %{
               generator_name: "test-generator",
               generator_version: "1"
             })

    assert {:ok, preview_v1} =
             Enrichment.record_artifact_generation_result(
               artifact_v1.id,
               {:ok, preview_attrs("a")}
             )

    assert preview_v1.status == "ready_for_review"
    assert {:ok, approved_v1} = Enrichment.approve_artifact(preview_v1.id, author)
    refute Enrichment.approved_but_incomplete?(run.id)

    assert {:ok, ^approved_v1} = Enrichment.resolve_approved_artifact(proposal.id)

    expected_hash = String.duplicate("a", 64)
    expected_url = "https://simulations.example.edu/bundles/#{expected_hash}/index.html"

    assert {:ok, ^expected_url} =
             Enrichment.artifact_url(approved_v1,
               artifact_storage: FakeStorage,
               trusted_origin: "https://simulations.example.edu"
             )

    assert {:ok, artifact_v2} = Enrichment.begin_artifact_generation(proposal.id)

    assert {:ok, preview_v2} =
             Enrichment.record_artifact_generation_result(
               artifact_v2.id,
               {:ok, preview_attrs("b")}
             )

    assert {:ok, approved_v2} = Enrichment.approve_artifact(preview_v2.id, author)
    assert approved_v2.version == 2
    assert {:ok, %{id: approved_id}} = Enrichment.resolve_approved_artifact(proposal.id)
    assert approved_id == approved_v2.id
    assert Repo.get!(SimulationArtifact, approved_v1.id).status == "superseded"
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

    {:ok, proposal} = Enrichment.approve_proposal(proposal.id, author)
    {:ok, artifact} = Enrichment.begin_artifact_generation(proposal.id)

    assert {:error, {:approved_enrichment_incomplete, [proposal_id]}} =
             Enrichment.ensure_generation_complete(run.id)

    assert proposal_id == proposal.id

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

    {:ok, proposal} = Enrichment.approve_proposal(proposal.id, author)
    {:ok, artifact} = Enrichment.begin_artifact_generation(proposal.id)

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

    {:ok, proposal} = Enrichment.approve_proposal(proposal.id, author)
    {:ok, artifact} = Enrichment.begin_artifact_generation(proposal.id)

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
    %{
      kind: kind,
      rank: rank,
      instructional_rationale: "Let learners test the section's central model.",
      objective_ids: ["objective-1"],
      source_evidence: %{"block_ids" => ["block-1"]},
      placement: %{"after_block_id" => "block-1"},
      learner_task: "Predict the result, inspect the evidence, and explain the outcome."
    }
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
