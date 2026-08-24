defmodule Oli.OpenStax.CourseImport.SourceIntegrityTest do
  use ExUnit.Case, async: true

  alias Oli.OpenStax.CourseImport.SourceIntegrity

  @hash String.duplicate("a", 64)

  test "accepts only canonical OpenStax sections with hashed, located source blocks" do
    section = valid_section()

    assert SourceIntegrity.invalid_urls([section]) == []

    assert SourceIntegrity.invalid_urls([
             put_in(section, ["source_blocks", Access.at(0), "source_locator"], nil)
           ]) == [section["url"]]

    assert SourceIntegrity.invalid_urls([Map.put(section, "content_hash", "stale")]) == [
             section["url"]
           ]
  end

  test "rejects a non-OpenStax source before generation" do
    section = %{valid_section() | "url" => "https://example.com/copied-section"}

    assert SourceIntegrity.invalid_urls([section]) == [section["url"]]
  end

  defp valid_section do
    %{
      "url" => "https://openstax.org/books/chemistry-2e/pages/1-1",
      "content_hash" => @hash,
      "source_blocks" => [
        %{
          "id" => "source-block-1",
          "normalized_text" => "Canonical source evidence.",
          "content_hash" => @hash,
          "source_locator" => %{"semantic_path" => ["Evidence"]}
        }
      ]
    }
  end
end
