defmodule Oli.OpenStax.CourseImport.SchemaCutoverTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  test "removed legacy schema dispatch and Advanced fallback functions cannot return" do
    files = Path.wildcard(Path.join(@root, "lib/oli/openstax/course_import/**/*.ex"))
    source = Enum.map_join(files, "\n", &File.read!/1)

    refute source =~ "deterministic_advanced_fallback"
    refute source =~ "maybe_downgrade_plan_schema"
    refute source =~ "ensure_authoring_blueprint"
    refute source =~ "def generate_lesson_plans"
    refute source =~ "defp plan_import_lesson"
    refute source =~ "defp persist_planned_lesson_result"
    refute File.exists?(Path.join(@root, "lib/oli/openstax/course_import/planner.ex"))

    refute File.exists?(
             Path.join(@root, "lib/oli/openstax/course_import/worker/lesson_planner_worker.ex")
           )

    current_contract_files =
      ~w(parser.ex checks.ex authoring_compiler.ex ai_planner.ex advanced_plan_v6.ex)
      |> Enum.map(&Path.join(@root, "lib/oli/openstax/course_import/#{&1}"))
      |> Enum.map_join("\n", &File.read!/1)

    refute current_contract_files =~ "advanced_blueprint"
    refute current_contract_files =~ "legacy_excerpt"
    refute current_contract_files =~ "adaptive_section_groups"
    refute current_contract_files =~ "compile_advanced("
    refute current_contract_files =~ "worked_examples"
    refute current_contract_files =~ "application_problems"
    refute current_contract_files =~ "curiosity_prompts"
  end

  test "plan persistence accepts only Basic 5 and Advanced 6 content contracts" do
    alias Oli.OpenStax.CourseImport.LessonPlan

    base = %{lesson_id: Ecto.UUID.generate(), version: 1}

    for contract <- [
          %{"authoring_mode" => "basic", "schema_version" => 4},
          %{"authoring_mode" => "basic", "schema_version" => 6},
          %{"authoring_mode" => "advanced", "schema_version" => 4},
          %{"authoring_mode" => "advanced", "schema_version" => 5}
        ] do
      refute LessonPlan.changeset(%LessonPlan{}, Map.put(base, :content_payload, contract)).valid?
    end

    assert LessonPlan.changeset(
             %LessonPlan{},
             Map.put(base, :content_payload, %{
               "authoring_mode" => "basic",
               "schema_version" => 5
             })
           ).valid?

    assert LessonPlan.changeset(
             %LessonPlan{},
             Map.put(base, :content_payload, %{
               "authoring_mode" => "advanced",
               "schema_version" => 6
             })
           ).valid?
  end

  test "only explicit Basic 5 and Advanced 6 compiler entry contracts remain callable" do
    compiler =
      File.read!(Path.join(@root, "lib/oli/openstax/course_import/authoring_compiler.ex"))

    assert compiler =~ ~s("schema_version" => 5)
    assert compiler =~ ~s("schema_version" => 6)

    refute compiler =~
             "expected_content_schema_version(_run_plan_schema_version, _plan_mode), do: 4"
  end

  test "outline construction rejects every pre-v6 run schema" do
    snapshot = %{
      "book_slug" => "chemistry-2e",
      "chapters" => [
        %{
          "id" => "chapter-1",
          "selected" => true,
          "sections" => [%{"url" => "https://openstax.org/books/chemistry-2e/pages/1-1"}]
        }
      ]
    }

    assert {:error, {:unsupported_openstax_plan_schema, 4}} =
             Oli.OpenStax.CourseImport.Parser.build_outline(snapshot, plan_schema_version: 4)
  end

  test "legacy cleanup commands and exact-v6 constraints are absent" do
    refute File.exists?(Path.join(@root, "lib/oli/openstax/course_import/legacy_purge.ex"))

    refute File.exists?(Path.join(@root, "lib/mix/tasks/openstax.purge_legacy_imports.ex"))

    assert File.exists?(
             Path.join(
               @root,
               "priv/repo/migrations/20260812131000_enforce_openstax_v6_cutover.exs"
             )
           )

    migration_source =
      @root
      |> Path.join("priv/repo/migrations/*openstax*v6*.exs")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    refute migration_source =~ "source_schema_version = 3 AND plan_schema_version = 6"
    refute migration_source =~ "DELETE FROM"
    refute migration_source =~ "UPDATE course_import"
  end

  test "pilot migrations contain no legacy project, run, resource, media, job, or artifact rewrite" do
    migration_source =
      @root
      |> Path.join("priv/repo/migrations/20260817*.exs")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    for table <-
          ~w(projects course_import_runs resources revisions course_import_media oban_jobs course_import_simulation_artifacts) do
      refute Regex.match?(
               ~r/\b(?:UPDATE|DELETE\s+FROM|TRUNCATE)\s+#{table}\b/i,
               migration_source
             ),
             "pilot migration must not rewrite or delete legacy rows in #{table}"
    end
  end
end
