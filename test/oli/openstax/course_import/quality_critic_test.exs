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
