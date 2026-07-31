defmodule Oli.GoogleSlides.ImportWorkflow.ProvenanceValidatorTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.AI.Draft
  alias Oli.GoogleSlides.ImportWorkflow.ProvenanceValidator

  test "accepts interaction evidence quoted from the cited slide" do
    plan = lesson_plan("Choose the best answer")

    assert :ok = ProvenanceValidator.validate(plan, source_snapshot())
  end

  test "rejects a model's fabricated interaction evidence" do
    plan = lesson_plan("Complete the invented quiz")

    assert {:error, errors} = ProvenanceValidator.validate(plan, source_snapshot())
    assert Enum.any?(errors, &(&1["code"] == "ungrounded_interaction"))
  end

  test "does not treat source metadata as interaction evidence" do
    plan = lesson_plan("text")

    snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "contentBlocks"],
        [
          %{
            "type" => "text",
            "objectId" => "text",
            "metadata" => %{"text" => "text"},
            "width" => 640,
            "height" => 480,
            "transform" => %{"unit" => "PT"}
          }
        ]
      )

    assert {:error, errors} = ProvenanceValidator.validate(plan, snapshot)
    assert Enum.any?(errors, &(&1["code"] == "ungrounded_interaction"))
  end

  test "requires source-grounded answers to cite an explicit correctness cue" do
    plan = lesson_plan("Choose the best answer")

    {:ok, plan} =
      Draft.set_interaction_response(plan, "screen_one", "transport_check", 1, [
        source_ref("Correct answer: Osmosis")
      ])

    grounded_snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "notes"],
        "Correct answer: Osmosis"
      )

    assert :ok = ProvenanceValidator.validate(plan, grounded_snapshot)

    unsupported_snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "notes"],
        "Osmosis is one of the available choices."
      )

    assert {:error, errors} = ProvenanceValidator.validate(plan, unsupported_snapshot)
    assert Enum.any?(errors, &(&1["code"] == "ungrounded_correct_response"))
  end

  test "rejects invented choice labels even when an interaction itself is grounded" do
    invented =
      put_in(
        lesson_plan("Choose the best answer"),
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "configuration",
          "choices"
        ],
        ["Diffusion", "Invented distractor"]
      )

    assert {:error, errors} = ProvenanceValidator.validate(invented, source_snapshot())
    assert Enum.any?(errors, &(&1["code"] == "ungrounded_option"))
  end

  test "validates adaptivity source references" do
    valid_rule = %{
      "key" => "continue_after_answer",
      "condition" => %{"interactionKey" => "transport_check", "outcome" => "correct"},
      "action" => %{"type" => "navigate", "target" => "next"},
      "sourceRefs" => [
        %{
          "slideId" => "slide-1",
          "slideIndex" => 1,
          "evidence" => "Choose the best answer"
        }
      ]
    }

    valid_plan =
      put_in(
        lesson_plan("Choose the best answer"),
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [valid_rule]
      )

    assert :ok = ProvenanceValidator.validate(valid_plan, source_snapshot())

    invalid_plan =
      put_in(
        valid_plan,
        ["lesson", "screens", Access.at(0), "adaptivity", Access.at(0), "sourceRefs"],
        [%{"slideId" => "missing-slide"}]
      )

    assert {:error, errors} = ProvenanceValidator.validate(invalid_plan, source_snapshot())

    assert Enum.any?(errors, fn error ->
             error["code"] == "unknown_source" and
               error["path"] ==
                 "lesson.screens[0].adaptivity[0].sourceRefs[0]"
           end)
  end

  test "rejects adaptivity that cites a real slide without explicit source evidence" do
    rule = %{
      "key" => "invented_branch",
      "condition" => %{"interactionKey" => "transport_check", "outcome" => "correct"},
      "action" => %{"type" => "navigate", "target" => "next"},
      "sourceRefs" => [%{"slideId" => "slide-1", "slideIndex" => 1}]
    }

    plan =
      put_in(
        lesson_plan("Choose the best answer"),
        ["lesson", "screens", Access.at(0), "adaptivity"],
        [rule]
      )

    assert {:error, errors} = ProvenanceValidator.validate(plan, source_snapshot())

    assert Enum.any?(errors, fn error ->
             error["code"] == "ungrounded_adaptivity" and
               error["path"] == "lesson.screens[0].adaptivity[0].sourceRefs"
           end)
  end

  test "accepts exact title, structural, and unsupported object ids from the cited slide inventory" do
    inventory = [
      inventory_entry("title-placeholder-1", "shape"),
      inventory_entry("group-1", "group"),
      inventory_entry("future-widget-1", "unknown")
    ]

    plan =
      update_in(
        lesson_plan("Choose the best answer"),
        ["lesson", "screens", Access.at(0), "sourceRefs"],
        fn refs ->
          refs ++
            [
              source_ref_for_object("title-placeholder-1"),
              source_ref_for_object("group-1"),
              source_ref_for_object("future-widget-1")
            ]
        end
      )

    snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "sourceInventory"],
        inventory
      )

    assert :ok = ProvenanceValidator.validate(plan, snapshot)
  end

  test "accepts the resolved slide id as a slide-level object reference" do
    plan =
      put_in(
        lesson_plan("Choose the best answer"),
        ["lesson", "screens", Access.at(0), "sourceRefs"],
        [
          %{
            "slideId" => "slide-1",
            "objectId" => "slide-1",
            "slideIndex" => 1,
            "evidence" => "Choose the best answer"
          }
        ]
      )

    assert :ok = ProvenanceValidator.validate(plan, source_snapshot())
  end

  test "does not accept an inventory object that belongs to another slide" do
    plan =
      update_in(
        lesson_plan("Choose the best answer"),
        ["lesson", "screens", Access.at(0), "sourceRefs"],
        &(&1 ++ [source_ref_for_object("other-slide-object")])
      )

    snapshot =
      update_in(source_snapshot(), ["slides"], fn slides ->
        slides ++
          [
            %{
              "index" => 2,
              "objectId" => "slide-2",
              "title" => "Another slide",
              "paragraphs" => [],
              "listItems" => [],
              "contentBlocks" => [],
              "sourceInventory" => [inventory_entry("other-slide-object", "unknown", "slide-2")],
              "notes" => "",
              "links" => []
            }
          ]
      end)

    assert {:error, errors} = ProvenanceValidator.validate(plan, snapshot)

    assert Enum.any?(errors, fn error ->
             error["code"] == "unknown_object" and
               error["path"] == "lesson.screens[0].sourceRefs[1]"
           end)
  end

  test "requires image and video object ids to exist on the cited slide" do
    {:ok, grounded_plan} =
      Draft.add_media_part(lesson_plan("Choose the best answer"), "screen_one", %{
        "key" => "transport_diagram",
        "kind" => "image",
        "sourceObjectId" => "image-1",
        "altText" => "Water crossing a cell membrane",
        "sourceRefs" => [source_ref()]
      })

    snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "contentBlocks"],
        [
          %{
            "type" => "image",
            "objectId" => "image-1",
            "altText" => "Water crossing a cell membrane"
          }
        ]
      )

    assert :ok = ProvenanceValidator.validate(grounded_plan, snapshot)

    ungrounded_plan =
      put_in(
        grounded_plan,
        [
          "lesson",
          "screens",
          Access.at(0),
          "parts",
          Access.at(0),
          "content",
          "sourceObjectId"
        ],
        "image-from-another-slide"
      )

    assert {:error, errors} = ProvenanceValidator.validate(ungrounded_plan, snapshot)

    assert Enum.any?(errors, fn error ->
             error["code"] == "ungrounded_source_object" and
               error["path"] ==
                 "lesson.screens[0].parts[0].content.sourceObjectId"
           end)
  end

  test "requires linked audio and iframe URLs to occur on the cited slide" do
    source_url = "https://media.example.edu/osmosis.mp3"
    iframe_url = "https://labs.example.edu/osmosis"

    {:ok, plan} =
      Draft.add_media_part(lesson_plan("Choose the best answer"), "screen_one", %{
        "key" => "transport_audio",
        "kind" => "audio",
        "sourceUrl" => source_url,
        "transcript" => "Water moves through a selectively permeable membrane.",
        "sourceRefs" => [source_ref()]
      })

    plan =
      plan
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "componentKey"
        ],
        "iframe"
      )
      |> put_in(
        [
          "lesson",
          "screens",
          Access.at(0),
          "interactions",
          Access.at(0),
          "configuration"
        ],
        %{"src" => iframe_url}
      )

    grounded_snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "links"],
        [source_url, iframe_url]
      )

    assert :ok = ProvenanceValidator.validate(plan, grounded_snapshot)

    assert {:error, errors} = ProvenanceValidator.validate(plan, source_snapshot())

    assert Enum.count(errors, &(&1["code"] == "ungrounded_url")) == 2
  end

  test "accepts an author-supplied caption URL only with the trusted source marker" do
    caption_url = "https://captions.example.edu/osmosis.vtt"

    {:ok, plan} =
      Draft.add_media_part(lesson_plan("Choose the best answer"), "screen_one", %{
        "key" => "transport_video",
        "kind" => "video",
        "sourceObjectId" => "video-1",
        "captionTrackUrl" => caption_url,
        "altText" => "Osmosis demonstration",
        "accessibility" => %{"captionsSource" => "author_answer"},
        "sourceRefs" => [source_ref()]
      })

    snapshot =
      put_in(
        source_snapshot(),
        ["slides", Access.at(0), "contentBlocks"],
        [
          %{
            "type" => "video",
            "objectId" => "video-1",
            "alt" => "Osmosis demonstration"
          }
        ]
      )

    assert :ok = ProvenanceValidator.validate(plan, snapshot)

    untrusted_plan =
      put_in(
        plan,
        [
          "lesson",
          "screens",
          Access.at(0),
          "parts",
          Access.at(0),
          "accessibility",
          "captionsSource"
        ],
        nil
      )

    assert {:error, errors} = ProvenanceValidator.validate(untrusted_plan, snapshot)

    assert Enum.any?(errors, fn error ->
             error["code"] == "ungrounded_url" and
               error["path"] ==
                 "lesson.screens[0].parts[0].accessibility.captions"
           end)
  end

  defp lesson_plan(evidence) do
    source_ref = source_ref(evidence)

    {:ok, plan} =
      Draft.create_lesson(%{
        "title" => "Cell transport",
        "presentationId" => "presentation-1",
        "fingerprint" => "fingerprint-1"
      })

    {:ok, plan} =
      Draft.add_screen(plan, %{
        "key" => "screen_one",
        "title" => "Transport check",
        "sourceRefs" => [source_ref]
      })

    {:ok, plan} =
      Draft.add_interaction(plan, "screen_one", %{
        "key" => "transport_check",
        "componentKey" => "multiple_choice",
        "explicit" => true,
        "sourceEvidence" => [source_ref],
        "prompt" => "Which process moves water?",
        "configuration" => %{"choices" => ["Diffusion", "Osmosis"]},
        "correctResponse" => 1
      })

    plan
  end

  defp source_snapshot do
    %{
      "presentation" => %{
        "id" => "presentation-1",
        "fingerprint" => "fingerprint-1"
      },
      "slides" => [
        %{
          "index" => 1,
          "objectId" => "slide-1",
          "title" => "Check your understanding",
          "paragraphs" => [
            "Choose the best answer about membrane transport: Diffusion or Osmosis."
          ],
          "listItems" => [],
          "contentBlocks" => [],
          "notes" => "",
          "links" => []
        }
      ]
    }
  end

  defp source_ref(evidence \\ "Choose the best answer") do
    %{
      "slideId" => "slide-1",
      "slideIndex" => 1,
      "evidence" => evidence
    }
  end

  defp source_ref_for_object(object_id) do
    source_ref()
    |> Map.put("objectId", object_id)
  end

  defp inventory_entry(object_id, source_type, slide_id \\ "slide-1") do
    %{
      "inventoryId" => "#{slide_id}:#{object_id}",
      "slideId" => slide_id,
      "objectId" => object_id,
      "sourceType" => source_type
    }
  end
end
