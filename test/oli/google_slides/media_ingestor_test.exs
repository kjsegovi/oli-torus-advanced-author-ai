defmodule Oli.GoogleSlides.MediaIngestorTest do
  use ExUnit.Case, async: true

  alias Oli.GoogleSlides.MediaIngestor
  alias Oli.GoogleSlides.PresentationParser.ImageRef

  defmodule MediaLibraryStub do
    def add(_project_slug, filename, bytes) do
      {:ok, %{url: "https://media.example/#{filename}?bytes=#{byte_size(bytes)}"}}
    end
  end

  test "rejects an excessive image count before uploading" do
    images =
      Enum.map(1..3, fn index ->
        %ImageRef{
          object_id: "image-#{index}",
          inline_bytes: "png",
          inline_content_type: "image/png"
        }
      end)

    assert {:error, {:source_media_limit_exceeded, :image_count, 2}} =
             MediaIngestor.ingest_images(images, "project", "token",
               media_library: MediaLibraryStub,
               max_image_count: 2
             )
  end

  test "rejects a cumulative byte overflow before uploading any image" do
    images = [
      %ImageRef{
        object_id: "image-1",
        inline_bytes: "1234",
        inline_content_type: "image/png"
      },
      %ImageRef{
        object_id: "image-2",
        inline_bytes: "5678",
        inline_content_type: "image/png"
      }
    ]

    assert {:error, {:source_media_limit_exceeded, :total_bytes, 7}} =
             MediaIngestor.ingest_images(images, "project", "token",
               media_library: MediaLibraryStub,
               max_total_image_bytes: 7
             )
  end

  test "uploads prepared inline fallbacks after all media fits the import budget" do
    image = %ImageRef{
      object_id: "line-1",
      inline_bytes: "<svg></svg>",
      inline_content_type: "image/svg+xml"
    }

    assert {:ok, %{"line-1" => url}, []} =
             MediaIngestor.ingest_images([image], "project", "token",
               media_library: MediaLibraryStub
             )

    assert url =~ "slides-line-1.svg"
  end
end
