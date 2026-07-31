defmodule Oli.GoogleSlides.ImportWorkflow.FidelityValidatorTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.ImportWorkflow.{AnswerResolver, FidelityValidator, Planner}

  test "only concrete lesson elements cover meaningful inventory objects" do
    {:ok, plan} = base_plan(title_object_id: "title-1")

    {:ok, plan} =
      Draft.add_content_part(plan, "screen_one", %{
        "key" => "body",
        "kind" => "text",
        "content" => %{"text" => "Membranes regulate transport."},
        "sourceRefs" => [source_ref("body-1")]
      })

    assert {:ok, reconciled} = FidelityValidator.reconcile(plan, snapshot())

    coverage = Map.new(reconciled["sourceCoverage"], &{&1["inventoryId"], &1})

    assert coverage["slide-1:title-1"]["status"] == "included"
    assert [%{"kind" => "screen_title"}] = coverage["slide-1:title-1"]["targets"]

    assert coverage["slide-1:body-1"]["status"] == "included"
    assert [%{"kind" => "part", "key" => "body"}] = coverage["slide-1:body-1"]["targets"]

    assert coverage["slide-1:image-1"]["status"] == "unaccounted"
    refute Map.has_key?(coverage, "slide-1:decorative-1")

    assert [
             %{
               "code" => "source_inventory_unaccounted",
               "details" => %{"inventoryId" => "slide-1:image-1"}
             }
           ] =
             Enum.filter(
               reconciled["blockers"],
               &(&1["code"] == "source_inventory_unaccounted")
             )

    # A citation on the screen itself is intentionally insufficient for an
    # ordinary image or content object.
    image_ref_plan =
      update_in(plan, ["lesson", "screens", Access.at(0), "sourceRefs"], fn refs ->
        refs ++ [source_ref("image-1")]
      end)

    assert {:ok, still_blocked} = FidelityValidator.reconcile(image_ref_plan, snapshot())

    assert Enum.any?(
             still_blocked["blockers"],
             &(&1["target"] == "inventory:slide-1:image-1")
           )
  end

  test "container groups are reviewed through their meaningful descendants without duplicate blockers" do
    {:ok, plan} = base_plan()

    {:ok, plan} =
      Draft.add_content_part(plan, "screen_one", %{
        "key" => "group_text",
        "kind" => "text",
        "content" => %{"text" => "Grouped explanation"},
        "sourceRefs" => [source_ref("group-child-1")]
      })

    assert {:ok, reconciled} = FidelityValidator.reconcile(plan, group_snapshot())
    coverage = Map.new(reconciled["sourceCoverage"], &{&1["inventoryId"], &1})

    assert %{
             "status" => "included",
             "coverageMode" => "descendants",
             "appliedDisposition" => "decomposed_children",
             "targets" => [%{"kind" => "part", "key" => "group_text"}]
           } = coverage["slide-1:group-1"]

    assert %{
             "status" => "included",
             "coverageMode" => "descendants",
             "targets" => [%{"kind" => "part", "key" => "group_text"}]
           } = coverage["slide-1:group-2"]

    refute Enum.any?(
             reconciled["blockers"],
             &(&1["target"] == "inventory:slide-1:group-1")
           )
  end

  test "unsupported source types remain blocking even when a model attaches them to a part" do
    {:ok, plan} = base_plan()

    {:ok, plan} =
      Draft.add_content_part(plan, "screen_one", %{
        "key" => "future_widget_description",
        "kind" => "text",
        "content" => %{"text" => "Future widget"},
        "sourceRefs" => [source_ref("future-widget-1")]
      })

    snapshot =
      source_snapshot([
        inventory("future-widget-1",
          source_type: "unknown",
          suggested_disposition: "unsupported",
          fidelity: "unsupported",
          summary: %{"text" => "Future widget"}
        )
      ])

    assert {:ok, reconciled} = FidelityValidator.reconcile(plan, snapshot)
    [coverage] = reconciled["sourceCoverage"]

    assert coverage["status"] == "unaccounted"

    assert [%{"kind" => "part", "key" => "future_widget_description"}] =
             coverage["targets"]

    assert Enum.any?(
             reconciled["blockers"],
             &(&1["target"] == "inventory:slide-1:future-widget-1")
           )

    blocker_key = "source_inventory_unaccounted:inventory:slide-1:future-widget-1"
    assert {:ok, omitted} = AnswerResolver.apply(reconciled, %{blocker_key => "omit"})
    assert {:ok, still_blocked} = FidelityValidator.reconcile(omitted, snapshot)
    assert hd(still_blocked["sourceCoverage"])["status"] == "unaccounted"
  end

  test "only a trusted author answer can omit an inventory element" do
    {:ok, plan} = base_plan()
    assert {:ok, blocked} = FidelityValidator.reconcile(plan, image_only_snapshot())

    blocker_key = "source_inventory_unaccounted:inventory:slide-1:image-1"

    assert {:ok, unchanged} = AnswerResolver.apply(blocked, %{blocker_key => "include"})
    assert Enum.any?(unchanged["blockers"], &(&1["key"] == blocker_key))

    assert {:ok, omitted} = AnswerResolver.apply(blocked, %{blocker_key => "omit"})

    assert [
             %{
               "inventoryId" => "slide-1:image-1",
               "status" => "author_omitted",
               "decisionSource" => "author_answer"
             }
           ] = omitted["sourceCoverage"]

    refute Enum.any?(omitted["blockers"], &(&1["key"] == blocker_key))

    assert Enum.any?(
             omitted["warnings"],
             &(&1["code"] == "source_inventory_author_omitted")
           )

    assert {:ok, reconciled} = FidelityValidator.reconcile(omitted, image_only_snapshot())
    assert hd(reconciled["sourceCoverage"])["status"] == "author_omitted"
    assert :ok = FidelityValidator.validate(reconciled, image_only_snapshot())
  end

  test "model-like omission fields without the trusted marker are discarded" do
    {:ok, plan} = base_plan()

    forged =
      Map.put(plan, "sourceCoverage", [
        %{
          "inventoryId" => "slide-1:image-1",
          "status" => "author_omitted",
          "decisionSource" => "model",
          "targets" => []
        }
      ])

    assert {:ok, reconciled} = FidelityValidator.reconcile(forged, image_only_snapshot())
    assert hd(reconciled["sourceCoverage"])["status"] == "unaccounted"

    assert Enum.any?(
             reconciled["blockers"],
             &(&1["code"] == "source_inventory_unaccounted")
           )
  end

  test "reconciliation forces Torus defaults and strips color-bearing declarations" do
    {:ok, plan} = base_plan()

    {:ok, plan} =
      Draft.set_layout(plan, %{"styleProfile" => "habworlds-assessment"})

    assert Enum.any?(plan["blockers"], &(&1["code"] == "style_profile_confirmation"))

    {:ok, plan} =
      Draft.set_style_rules(plan, [
        %{
          "target" => "body",
          "declarations" => %{
            "background-color" => "#fff",
            "border-color" => "#222",
            "color" => "#111",
            "padding" => "1rem"
          }
        },
        %{
          "target" => "prompt",
          "declarations" => %{"color" => "#333"}
        }
      ])

    assert {:ok, reconciled} = FidelityValidator.reconcile(plan, empty_snapshot())

    assert get_in(reconciled, ["lesson", "layout", "styleProfile"]) == "torus-default"

    refute Enum.any?(
             reconciled["blockers"],
             &(&1["code"] == "style_profile_confirmation")
           )

    assert get_in(reconciled, ["lesson", "layout", "styleRules"]) == [
             %{"target" => "body", "declarations" => %{"padding" => "1rem"}}
           ]

    assert Enum.any?(
             reconciled["warnings"],
             &(&1["code"] == "source_colors_not_imported")
           )

    assert :ok = FidelityValidator.validate(reconciled, empty_snapshot())

    assert {:error, [error]} = FidelityValidator.validate(plan, empty_snapshot())
    assert error["code"] == "stale_source_coverage"

    unsanitized =
      put_in(reconciled, ["lesson", "layout", "styleRules"], [
        %{"target" => "body", "declarations" => %{"background-color" => "#fff"}}
      ])

    assert {:error, [color_error]} =
             FidelityValidator.validate(unsanitized, empty_snapshot())

    assert color_error["path"] == "lesson.layout"
    assert color_error["code"] == "source_colors_not_sanitized"
  end

  test "generation validation rejects unaccounted, stale, and truncated coverage" do
    {:ok, plan} = base_plan()
    assert {:ok, blocked} = FidelityValidator.reconcile(plan, image_only_snapshot())

    assert {:error, errors} = FidelityValidator.validate(blocked, image_only_snapshot())
    assert Enum.any?(errors, &(&1["code"] == "unaccounted_source_element"))

    {:ok, covered_plan} =
      Draft.add_media_part(plan, "screen_one", %{
        "key" => "image",
        "kind" => "image",
        "sourceObjectId" => "image-1",
        "sourceRefs" => [source_ref("image-1")],
        "altText" => "A membrane diagram"
      })

    assert {:ok, covered} = FidelityValidator.reconcile(covered_plan, image_only_snapshot())
    assert :ok = FidelityValidator.validate(covered, image_only_snapshot())

    assert {:error, [stale_error]} =
             covered
             |> Map.put("sourceCoverage", [])
             |> FidelityValidator.validate(image_only_snapshot())

    assert stale_error["code"] == "stale_source_coverage"

    truncated =
      put_in(image_only_snapshot(), ["inventoryAccounting", "omitted"], 2)

    assert {:error, [limit_error]} = FidelityValidator.validate(covered, truncated)
    assert limit_error["path"] == "sourceSnapshot.inventoryAccounting.omitted"
    assert limit_error["code"] == "source_inventory_truncated"
  end

  test "fidelity blockers become explicit include or omit questions" do
    {:ok, plan} = base_plan()
    assert {:ok, blocked} = FidelityValidator.reconcile(plan, image_only_snapshot())

    assert [question] =
             blocked
             |> Planner.questions(image_only_snapshot())
             |> Enum.filter(&(&1["key"] =~ "source_inventory_unaccounted"))

    assert question["options"] == [
             %{"value" => "include", "label" => "Keep this content in the lesson"},
             %{"value" => "omit", "label" => "Leave this content out"}
           ]

    assert question["prompt"] == "Should this slide content be kept in the imported lesson?"
    assert question["subject"] == "Membrane diagram"
    assert question["source"] == "Slide 1 — Cell membranes"

    assert question["sourceRefs"] == [
             %{"slideId" => "slide-1", "objectId" => "image-1", "evidence" => "Membrane diagram"}
           ]

    assert question["explanation"] =~
             "not represented in the draft lesson yet"
  end

  defp base_plan(opts \\ []) do
    title_object_id = Keyword.get(opts, :title_object_id)

    source_refs =
      case title_object_id do
        nil -> [%{"slideId" => "slide-1", "slideIndex" => 1, "evidence" => "Transport"}]
        object_id -> [source_ref(object_id)]
      end

    with {:ok, plan} <-
           Draft.create_lesson(%{
             "title" => "Transport",
             "presentationId" => "presentation-1",
             "fingerprint" => String.duplicate("a", 64)
           }),
         {:ok, plan} <-
           Draft.add_screen(plan, %{
             "key" => "screen_one",
             "title" => "Transport",
             "sourceRefs" => source_refs
           }) do
      {:ok, plan}
    end
  end

  defp snapshot do
    source_snapshot([
      inventory("title-1",
        summary: %{"text" => "Transport", "placeholderType" => "TITLE"}
      ),
      inventory("body-1", summary: %{"text" => "Membranes regulate transport."}),
      inventory("image-1",
        source_type: "image",
        suggested_disposition: "native_media",
        fidelity: "content",
        summary: %{"text" => "Membrane diagram"}
      ),
      inventory("decorative-1",
        meaningful: false,
        decorative: true,
        summary: %{"text" => "Decorative divider"}
      )
    ])
  end

  defp image_only_snapshot do
    source_snapshot([
      inventory("image-1",
        source_type: "image",
        suggested_disposition: "native_media",
        fidelity: "content",
        summary: %{"text" => "Membrane diagram"}
      )
    ])
  end

  defp group_snapshot do
    source_snapshot([
      inventory("group-1",
        source_type: "group",
        meaningful: false,
        container: true,
        suggested_disposition: "decomposed_children",
        fidelity: "decomposed",
        summary: %{"text" => "Grouped explanation"}
      ),
      inventory("group-2",
        source_type: "group",
        meaningful: false,
        container: true,
        parent_object_id: "group-1",
        suggested_disposition: "visual_fallback",
        fidelity: "rasterized",
        summary: %{"text" => "Nested group"}
      ),
      inventory("group-child-1",
        parent_object_id: "group-2",
        summary: %{"text" => "Grouped explanation"}
      )
    ])
  end

  defp empty_snapshot, do: source_snapshot([])

  defp source_snapshot(entries) do
    %{
      "inventoryAccounting" => %{
        "discovered" => length(entries),
        "included" => length(entries),
        "omitted" => 0
      },
      "slides" => [
        %{
          "index" => 0,
          "objectId" => "slide-1",
          "title" => "Cell membranes",
          "sourceInventory" => entries
        }
      ]
    }
  end

  defp inventory(object_id, opts) do
    %{
      "inventoryId" => "slide-1:#{object_id}",
      "slideId" => "slide-1",
      "objectId" => object_id,
      "objectIdSource" => "google",
      "parentObjectId" => Keyword.get(opts, :parent_object_id),
      "depth" => 0,
      "order" => 0,
      "sourceType" => Keyword.get(opts, :source_type, "shape"),
      "suggestedDisposition" => Keyword.get(opts, :suggested_disposition, "native_semantic"),
      "fidelity" => Keyword.get(opts, :fidelity, "semantic"),
      "reviewRequired" => true,
      "meaningful" => Keyword.get(opts, :meaningful, true),
      "decorative" => Keyword.get(opts, :decorative, false),
      "container" => Keyword.get(opts, :container, false),
      "summary" => Keyword.get(opts, :summary, %{"text" => "Source element"})
    }
  end

  defp source_ref(object_id) do
    %{
      "slideId" => "slide-1",
      "slideIndex" => 1,
      "objectId" => object_id,
      "evidence" => "Transport"
    }
  end
end
