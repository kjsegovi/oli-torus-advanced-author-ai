defmodule Oli.OpenStax.CourseImport.QualityCriticTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.QualityCritic

  test "requires explicit approval, confidence, and zero unresolved blocking or repair findings" do
    assert {:ok, low_confidence} = review(%{"approved" => true, "confidence" => 0.89})
    refute QualityCritic.approved?(low_confidence)
    assert Enum.any?(low_confidence["findings"], &(&1["code"] == "critic_low_confidence"))

    assert {:ok, blocked} =
             review(%{
               "approved" => true,
               "confidence" => 0.98,
               "findings" => [
                 %{
                   "severity" => "hard_blocker",
                   "code" => "missing_source",
                   "path" => "$.content_groups",
                   "message" => "A required source block is missing."
                 }
               ]
             })

    refute QualityCritic.approved?(blocked)

    assert {:ok, repair_pending} =
             review(%{
               "approved" => true,
               "confidence" => 0.98,
               "findings" => [
                 %{
                   "severity" => "repair",
                   "code" => "feedback_consistency",
                   "path" => "$.questions_payload.items[0]",
                   "message" => "Align the feedback with the answer guidance."
                 }
               ]
             })

    refute QualityCritic.approved?(repair_pending)

    assert {:ok, approved} =
             review(%{
               "approved" => true,
               "confidence" => "0.95",
               "findings" => [
                 %{
                   "severity" => "advisory",
                   "code" => "optional_style",
                   "path" => "$",
                   "message" => "An optional wording improvement is available."
                 }
               ]
             })

    assert QualityCritic.approved?(approved)
  end

  test "turns a withheld approval without repair guidance into an actionable finding" do
    assert {:ok, review} =
             review(%{
               "approved" => false,
               "confidence" => 0.95,
               "findings" => []
             })

    refute QualityCritic.approved?(review)
    assert [%{"severity" => "repair", "code" => "critic_not_approved"}] = review["findings"]
  end

  test "retains a synthesized gate finding when the critic fills the finding budget with advisories" do
    advisories =
      Enum.map(1..30, fn index ->
        %{
          "severity" => "advisory",
          "code" => "style_#{index}",
          "path" => "$",
          "message" => "Optional style improvement #{index}."
        }
      end)

    assert {:ok, review} =
             review(%{
               "approved" => false,
               "confidence" => 0.95,
               "findings" => advisories
             })

    assert length(review["findings"]) == 30
    assert hd(review["findings"])["code"] == "critic_not_approved"
    refute QualityCritic.approved?(review)
  end

  test "keeps server-owned attribution out of architect criticism" do
    execution_fun = fn _context, messages, _service ->
      payload =
        messages |> Enum.find(&(&1.role == :user)) |> Map.fetch!(:content) |> Jason.decode!()

      refute Map.has_key?(payload["content_plan"], "attribution")
      refute Map.has_key?(payload["content_plan"], "instructional_sections")
      refute Map.has_key?(payload["content_plan"], "key_takeaways")
      assert payload["content_plan"]["schema_version"] == 5

      {:ok,
       %{
         content: Jason.encode!(%{"approved" => true, "confidence" => 0.99, "findings" => []}),
         metadata: %{}
       }}
    end

    assert {:ok, review} =
             QualityCritic.review_content(
               %{"title" => "Lesson", "source_blocks" => []},
               %{
                 "schema_version" => 5,
                 "attribution" => %{"license" => "CC BY 4.0"}
               },
               %{},
               critic_execution_fun: execution_fun
             )

    assert QualityCritic.approved?(review)
  end

  test "separates server-owned source findings from architect-repairable findings" do
    review = %{
      "findings" => [
        %{
          "severity" => "hard_blocker",
          "code" => "invalid_equation_variable",
          "path" => "content_plan.content_groups[3].source_blocks[0].ast[7].src"
        },
        %{
          "severity" => "repair",
          "code" => "duplicate_orientation_content",
          "path" => "content_plan.orientation.overview"
        },
        %{
          "severity" => "repair",
          "code" => "missing_source_assignment",
          "path" => "content_plan.content_groups[0].source_block_ids"
        },
        %{
          "severity" => "advisory",
          "code" => "optional_style",
          "path" => "$"
        }
      ]
    }

    assert %{repairable: repairable, unowned: [unowned]} =
             QualityCritic.partition_repair_findings(review, :basic_content_architect)

    assert Enum.map(repairable, & &1["code"]) ==
             ~w(duplicate_orientation_content missing_source_assignment)

    assert unowned["code"] == "invalid_equation_variable"
  end

  test "keeps pre-activity fields out of architect repair and tolerates malformed paths" do
    findings = [
      %{
        "severity" => "hard_blocker",
        "code" => "missing_instantiated_activities",
        "path" => "experience_blueprint.activities"
      },
      %{
        "severity" => "repair",
        "code" => "unsupported_duration_estimate",
        "path" => "experience_blueprint.duration_manifest"
      },
      %{
        "severity" => "repair",
        "code" => "malformed_path_from_provider",
        "path" => %{"unexpected" => "shape"}
      }
    ]

    assert %{repairable: [repairable], unowned: unowned} =
             QualityCritic.partition_repair_findings(findings, :advanced_content_architect)

    assert repairable["code"] == "malformed_path_from_provider"

    assert Enum.map(unowned, & &1["code"]) ==
             ~w(missing_instantiated_activities unsupported_duration_estimate)
  end

  test "demotes source-owned findings to non-blocking advisories" do
    source_finding = %{
      "severity" => "hard_blocker",
      "code" => "malformed_source_formula",
      "path" => "content_plan.content_groups[0].source_blocks[0].ast",
      "message" => "The imported formula is malformed."
    }

    review = %{
      "approved" => false,
      "gate_passed" => false,
      "confidence" => 0.97,
      "findings" => [source_finding],
      "hard_blocker_count" => 1,
      "repair_count" => 0,
      "advisory_count" => 0
    }

    accepted = QualityCritic.demote_source_owned_findings(review, [source_finding])

    assert QualityCritic.approved?(accepted)
    assert accepted["source_diagnostics_accepted"]
    assert accepted["hard_blocker_count"] == 0
    assert accepted["advisory_count"] == 1

    assert [%{"severity" => "advisory", "source_owned" => true, "blocking" => false}] =
             accepted["findings"]
  end

  test "classifies mixed source and model findings deterministically" do
    findings = [
      %{
        "severity" => "hard_blocker",
        "code" => "bad_locator",
        "path" => "$.source_evidence_links[0].source_locator"
      },
      %{
        "severity" => "repair",
        "code" => "weak_transition",
        "path" => "$.orientation.overview"
      }
    ]

    partition = QualityCritic.partition_repair_findings(findings, :basic_content_architect)

    assert [%{"code" => "bad_locator", "ownership" => "source_resolvable"}] =
             partition.source_resolvable

    assert [%{"code" => "weak_transition", "ownership" => "model_repairable"}] =
             partition.repairable
  end

  test "publishes the realized activity schema to the post-attachment critic" do
    execution_fun = fn _context, messages, _service ->
      payload =
        messages |> Enum.find(&(&1.role == :user)) |> Map.fetch!(:content) |> Jason.decode!()

      source_contract = payload["source_contract"]
      assert source_contract["review_phase"] == "realized_activities"
      assert source_contract["allowed_realized_stage_item_kinds"] == ["content_group", "activity"]
      assert source_contract["activity_slots_are_realized_as_activity_items"]
      assert source_contract["remediation_target_authority"] == "approved_activity_slot"

      system_prompt = messages |> Enum.find(&(&1.role == :system)) |> Map.fetch!(:content)
      assert system_prompt =~ "approved activity slot owns remediation_content_group_id"
      assert system_prompt =~ "Do not require one target group to contain every cited"

      {:ok,
       %{
         content: Jason.encode!(%{"approved" => true, "confidence" => 0.99, "findings" => []}),
         metadata: %{}
       }}
    end

    assert {:ok, review} =
             QualityCritic.review_advanced_activities(
               %{"title" => "Lesson", "source_blocks" => []},
               %{"experience_blueprint" => %{}, "content_groups" => []},
               %{},
               critic_execution_fun: execution_fun
             )

    assert QualityCritic.approved?(review)
  end

  defp review(response) do
    execution_fun = fn _context, _messages, _service ->
      {:ok, %{content: Jason.encode!(response), metadata: %{model: "sol-critic"}}}
    end

    QualityCritic.review_content(
      %{"title" => "Lesson", "source_blocks" => []},
      %{"schema_version" => 5},
      %{},
      critic_execution_fun: execution_fun
    )
  end
end
