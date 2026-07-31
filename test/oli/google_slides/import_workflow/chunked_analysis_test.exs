defmodule Oli.GoogleSlides.ImportWorkflow.ChunkedAnalysisTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.ImportWorkflow.ChunkedAnalysis

  test "large-deck proposals cover every slide exactly once and respect pathway edges" do
    chunks = chunks([{1, 12}, {13, 24}, {25, 36}, {37, 48}, {49, 60}, {61, 72}, {73, 80}])

    maps = [
      %{
        "slides" => [%{"index" => 1, "title" => "Foundations"}],
        "explicitSections" => [],
        "pathwayEdges" => [
          %{"fromSlide" => 20, "toSlide" => 50, "evidence" => "explicit slide navigation"}
        ]
      }
    ]

    proposal = ChunkedAnalysis.propose_structure(chunks, maps, 80)
    lessons = get_in(proposal, ["split", "lessons"])

    assert length(lessons) == 2

    assert Enum.flat_map(lessons, &Enum.to_list(&1["startSlide"]..&1["endSlide"])) ==
             Enum.to_list(1..80)

    refute Enum.any?(Enum.drop(lessons, -1), fn lesson ->
             lesson["endSlide"] in 20..49
           end)
  end

  test "oversized-slide fragments never create an overlapping lesson boundary" do
    chunks =
      chunks([
        {1, 12},
        {12, 12},
        {13, 24},
        {25, 36},
        {37, 48},
        {49, 60},
        {61, 72},
        {73, 80}
      ])

    proposal = ChunkedAnalysis.propose_structure(chunks, structure_maps(), 80)
    lessons = get_in(proposal, ["split", "lessons"])

    assert is_list(lessons)

    assert Enum.flat_map(lessons, &Enum.to_list(&1["startSlide"]..&1["endSlide"])) ==
             Enum.to_list(1..80)

    refute Enum.any?(lessons, &(&1["startSlide"] == 12))
  end

  test "two explicit instructional sections trigger a split for a smaller deck" do
    chunks = chunks([{1, 12}, {13, 24}, {25, 36}])

    maps = [
      %{
        "slides" => [
          %{"index" => 1, "title" => "Section 1: Foundations"},
          %{"index" => 25, "title" => "Section 2: Practice"}
        ],
        "explicitSections" => [1, 25],
        "pathwayEdges" => []
      }
    ]

    proposal = ChunkedAnalysis.propose_structure(chunks, maps, 36)

    assert proposal["reason"] == "explicit_sections"
    assert length(get_in(proposal, ["split", "lessons"])) == 2
  end

  defp chunks(ranges) do
    ranges
    |> Enum.with_index()
    |> Enum.map(fn {{first, last}, ordinal} ->
      %{
        ordinal: ordinal,
        source_fragment: %{
          "slides" => Enum.map(first..last, &%{"index" => &1})
        }
      }
    end)
  end

  defp structure_maps do
    [
      %{
        "slides" => [%{"index" => 1, "title" => "Foundations"}],
        "explicitSections" => [],
        "pathwayEdges" => []
      }
    ]
  end
end
