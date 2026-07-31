defmodule Oli.GoogleDocs.SlidesClientTest do
  use Oli.DataCase, async: true

  import Mox

  alias Oli.GoogleDocs.SlidesClient

  setup :verify_on_exit!

  test "get_presentation_id/1 extracts id from standard url" do
    url = "https://docs.google.com/presentation/d/abc123XYZ/edit#slide=id.p"

    assert {:ok, "abc123XYZ"} = SlidesClient.get_presentation_id(url)
  end

  test "get_presentation_id/1 rejects invalid urls" do
    assert {:error, :invalid_presentation_url} =
             SlidesClient.get_presentation_id("https://example.com/not-slides")
  end

  test "get_slides/1 returns slide list" do
    json = %{"slides" => [%{"objectId" => "s1"}, %{"objectId" => "s2"}]}
    assert length(SlidesClient.get_slides(json)) == 2
  end

  test "only forwards the Slides OAuth token to trusted Google image hosts" do
    assert SlidesClient.trusted_google_image_url?(
             "https://lh3.googleusercontent.com/presentation-image"
           )

    assert SlidesClient.trusted_google_image_url?(
             "https://slides.googleapis.com/v1/presentations/deck/pages/slide"
           )

    refute SlidesClient.trusted_google_image_url?("https://example.com/presentation-image")

    refute SlidesClient.trusted_google_image_url?(
             "https://googleusercontent.com.example.com/presentation-image"
           )

    refute SlidesClient.trusted_google_image_url?("https://user@example.com/presentation-image")

    assert {:error, :untrusted_image_url} =
             SlidesClient.fetch_image_bytes(
               "https://example.com/presentation-image",
               "must-not-be-forwarded"
             )
  end

  test "fetch_page_thumbnail/4 returns bounded transient thumbnail metadata" do
    expect(Oli.Test.MockHTTP, :get, fn url, headers, opts ->
      assert url ==
               "https://slides.googleapis.com/v1/presentations/deck-1/pages/slide-2/thumbnail" <>
                 "?thumbnailProperties.mimeType=PNG&thumbnailProperties.thumbnailSize=LARGE"

      assert {"authorization", "Bearer slides-token"} in headers
      assert opts[:max_body_length] == 64 * 1024

      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body:
           Jason.encode!(%{
             "contentUrl" => "https://lh3.googleusercontent.com/slide-thumbnail",
             "width" => 1600,
             "height" => 900
           })
       }}
    end)

    assert {:ok,
            %{
              "url" => "https://lh3.googleusercontent.com/slide-thumbnail",
              "width" => 1600,
              "height" => 900
            }} =
             SlidesClient.fetch_page_thumbnail("deck-1", "slide-2", "slides-token", "LARGE")
  end

  test "fetch_page_thumbnail/4 rejects an untrusted thumbnail capability URL" do
    expect(Oli.Test.MockHTTP, :get, fn _url, _headers, _opts ->
      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body:
           Jason.encode!(%{
             "contentUrl" => "https://example.com/slide-thumbnail",
             "width" => 1600,
             "height" => 900
           })
       }}
    end)

    assert {:error, :invalid_thumbnail_response} =
             SlidesClient.fetch_page_thumbnail("deck-1", "slide-2", "slides-token", "LARGE")
  end
end
