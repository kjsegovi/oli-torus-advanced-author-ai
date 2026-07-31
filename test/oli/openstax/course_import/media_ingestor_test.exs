defmodule Oli.OpenStax.CourseImport.MediaIngestorTest do
  use Oli.DataCase, async: false

  alias Oli.OpenStax.CourseImport
  alias Oli.OpenStax.CourseImport.{Media, MediaIngestor, RichSource, SourceAsset}
  alias Oli.Repo
  alias Oli.ScopedFeatureFlags

  defmodule HTTPClient do
    def reset(responses) do
      Process.put({__MODULE__, :responses}, responses)
      Process.put({__MODULE__, :calls}, [])
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def get(url, headers, opts) do
      Process.put({__MODULE__, :calls}, [{url, headers, opts} | calls_reversed()])

      case Map.fetch(Process.get({__MODULE__, :responses}, %{}), url) do
        {:ok, response} -> response
        :error -> {:error, :unexpected_url}
      end
    end

    defp calls_reversed, do: Process.get({__MODULE__, :calls}, [])
  end

  defmodule MediaLibraryStub do
    def reset do
      Process.put({__MODULE__, :calls}, [])
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    def add(project_slug, filename, bytes) do
      Process.put(
        {__MODULE__, :calls},
        [{project_slug, filename, bytes} | Process.get({__MODULE__, :calls}, [])]
      )

      {:ok, %{url: "https://media.example/#{filename}"}}
    end
  end

  defmodule DuplicateMediaLibrary do
    def add(_project_slug, filename, _bytes) do
      {:duplicate, %{url: "https://media.example/reused/#{filename}"}}
    end
  end

  setup do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "OpenStax media staging")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/sample-book"
      )

    HTTPClient.reset(%{})
    MediaLibraryStub.reset()

    {:ok, project: project, run: run}
  end

  test "revalidates an allowed redirect, checks MIME bytes, and stages through MediaLibrary", %{
    run: run,
    project: project
  } do
    source_url = "https://openstax.org/assets/diagram"
    final_url = "https://assets.openstax.org/figures/diagram.png"
    png = png_bytes("diagram")

    persist_asset(run.id, source_url, "image/png")

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 302,
           headers: [{"Location", final_url}],
           body: ""
         }},
      final_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [
             {"Content-Type", "image/png"},
             {"Content-Length", Integer.to_string(byte_size(png))}
           ],
           body: png
         }}
    })

    assert {:ok, %MediaIngestor.Result{staged: 1, reused: 0, skipped: 0}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub
             )

    assert Enum.map(HTTPClient.calls(), &elem(&1, 0)) == [source_url, final_url]

    project_slug = project.slug
    assert [{^project_slug, filename, ^png}] = MediaLibraryStub.calls()
    assert String.ends_with?(filename, ".png")

    media = Repo.one!(from(media in Media, where: media.run_id == ^run.id))
    asset = Repo.one!(from(asset in SourceAsset, where: asset.run_id == ^run.id))

    assert media.status == "staged"
    assert media.final_source_url == final_url
    assert media.media_url =~ "https://media.example/"
    assert media.mime_type == "image/png"
    assert media.byte_size == byte_size(png)
    assert byte_size(media.sha256) == 64
    assert asset.status == "staged"
  end

  test "never follows a redirect outside the OpenStax HTTPS allowlist", %{run: run} do
    source_url = "https://openstax.org/assets/diagram"
    persist_asset(run.id, source_url, "image/png")

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 302,
           headers: [{"location", "https://attacker.example/diagram.png"}],
           body: ""
         }}
    })

    assert {:ok, %MediaIngestor.Result{staged: 0, skipped: 1}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub
             )

    assert Enum.map(HTTPClient.calls(), &elem(&1, 0)) == [source_url]
    assert MediaLibraryStub.calls() == []

    media = Repo.one!(from(media in Media, where: media.run_id == ^run.id))
    assert media.status == "skipped"
    assert media.failure_reason["reason"] =~ "untrusted_or_excessive_redirect"
  end

  test "skips MIME signature mismatches and oversized responses before upload", %{run: run} do
    source_url = "https://assets.openstax.org/figures/not-a-png.png"
    invalid_png = "GIF89a-not-really-a-png"
    persist_asset(run.id, source_url, "image/png")

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [
             {"content-type", "image/png"},
             {"content-length", Integer.to_string(byte_size(invalid_png))}
           ],
           body: invalid_png
         }}
    })

    assert {:ok, %MediaIngestor.Result{skipped: 1}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub
             )

    assert MediaLibraryStub.calls() == []

    media = Repo.one!(from(media in Media, where: media.run_id == ^run.id))
    assert media.failure_reason["reason"] =~ "mime_signature_mismatch"

    # A fresh run proves the response-length ceiling is checked independently.
    oversized_run = another_run()
    persist_asset(oversized_run.id, source_url, "image/png")
    png = png_bytes("too large")

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [
             {"content-type", "image/png"},
             {"content-length", Integer.to_string(byte_size(png))}
           ],
           body: png
         }}
    })

    assert {:ok, %MediaIngestor.Result{skipped: 1}} =
             MediaIngestor.stage_run(oversized_run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub,
               max_asset_bytes: byte_size(png) - 1
             )

    assert MediaLibraryStub.calls() == []
  end

  test "rejects images whose decoded dimensions exceed the configured pixel budget", %{run: run} do
    source_url = "https://assets.openstax.org/figures/huge.png"
    persist_asset(run.id, source_url, "image/png")
    huge_png = png_bytes("huge", 10_000, 10_000)

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [{"content-type", "image/png"}],
           body: huge_png
         }}
    })

    assert {:ok, %MediaIngestor.Result{skipped: 1}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub,
               max_image_pixels: 1_000_000
             )

    media = Repo.one!(from(media in Media, where: media.run_id == ^run.id))
    assert media.failure_reason["reason"] =~ "image_dimensions_exceeded"
    assert MediaLibraryStub.calls() == []
  end

  test "records MediaLibrary content reuse as a durable reused state", %{run: run} do
    source_url = "https://assets.openstax.org/figures/reused.png"
    png = png_bytes("reused")
    persist_asset(run.id, source_url, "image/png")

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [{"content-type", "image/png"}],
           body: png
         }}
    })

    assert {:ok, %MediaIngestor.Result{staged: 0, reused: 1, skipped: 0}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: DuplicateMediaLibrary
             )

    media = Repo.one!(from(media in Media, where: media.run_id == ^run.id))
    asset = Repo.one!(from(asset in SourceAsset, where: asset.run_id == ^run.id))

    assert media.status == "reused"
    assert media.media_url =~ "/reused/"
    assert asset.status == "reused"

    # A retry does not fetch or upload a completed asset again.
    HTTPClient.reset(%{})

    assert {:ok, %MediaIngestor.Result{reused: 1}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: DuplicateMediaLibrary
             )

    assert HTTPClient.calls() == []
  end

  test "stages only the selected required asset and rejects unknown plan media", %{run: run} do
    first_url = "https://assets.openstax.org/figures/selected.png"
    second_url = "https://assets.openstax.org/figures/not-selected.png"
    [first, second] = persist_assets(run.id, [first_url, second_url], "image/png")
    png = png_bytes("selected")

    assert {:error, {:unknown_required_media_ids, ["not-owned-by-run"]}} =
             MediaIngestor.select_required_assets(run.id, ["not-owned-by-run"])

    assert {:ok, [%SourceAsset{source_key: selected_key, required: true}]} =
             MediaIngestor.select_required_assets(run.id, [first.source_key])

    assert selected_key == first.source_key

    HTTPClient.reset(%{
      first_url =>
        {:ok,
         %{
           status_code: 200,
           headers: [{"content-type", "image/png"}],
           body: png
         }}
    })

    assert {:ok, %MediaIngestor.Result{total: 1, staged: 1}} =
             MediaIngestor.stage_required_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub
             )

    assert Enum.map(HTTPClient.calls(), &elem(&1, 0)) == [first_url]
    assert Repo.get!(SourceAsset, second.id).status == "discovered"
    refute Repo.get!(SourceAsset, second.id).required
  end

  test "reports a durable progress checkpoint after each staged asset", %{run: run} do
    urls = [
      "https://assets.openstax.org/figures/progress-one.png",
      "https://assets.openstax.org/figures/progress-two.png"
    ]

    persist_assets(run.id, urls, "image/png")

    HTTPClient.reset(
      Map.new(urls, fn url ->
        {url,
         {:ok,
          %{
            status_code: 200,
            headers: [{"content-type", "image/png"}],
            body: png_bytes(url)
          }}}
      end)
    )

    test_process = self()

    assert {:ok, %MediaIngestor.Result{total: 2, staged: 2}} =
             MediaIngestor.stage_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub,
               on_progress: fn result ->
                 send(
                   test_process,
                   {:media_progress, result.staged + result.reused, result.total}
                 )

                 :ok
               end
             )

    assert_receive {:media_progress, 1, 2}
    assert_receive {:media_progress, 2, 2}
  end

  test "a permanent failure for required media is durable and blocks staging", %{run: run} do
    source_url = "https://openstax.org/assets/required"
    asset = persist_asset(run.id, source_url, "image/png")

    assert {:ok, [_asset]} =
             MediaIngestor.select_required_assets(run.id, [asset.source_key])

    HTTPClient.reset(%{
      source_url =>
        {:ok,
         %{
           status_code: 302,
           headers: [{"location", "https://attacker.example/required.png"}],
           body: ""
         }}
    })

    assert {:error, {:required_media_unavailable, [unavailable]}} =
             MediaIngestor.stage_required_run(run.id,
               http_client: HTTPClient,
               media_library: MediaLibraryStub
             )

    assert unavailable["source_media_id"] == asset.source_key
    assert Repo.get!(SourceAsset, asset.id).status == "skipped"
  end

  test "required media URLs require a live same-project MediaLibrary item", %{
    run: run,
    project: project
  } do
    asset =
      persist_asset(
        run.id,
        "https://assets.openstax.org/figures/ready.png",
        "image/png"
      )

    assert {:ok, [_asset]} =
             MediaIngestor.select_required_assets(run.id, [asset.source_key])

    item =
      %Oli.Authoring.MediaLibrary.MediaItem{}
      |> Oli.Authoring.MediaLibrary.MediaItem.changeset(%{
        url: "https://media.example/ready.png",
        file_name: "ready.png",
        mime_type: "image/png",
        file_size: 12,
        md5_hash: "ready-md5",
        deleted: false,
        project_id: project.id
      })
      |> Repo.insert!()

    %Media{}
    |> Media.changeset(%{
      run_id: run.id,
      source_asset_id: asset.id,
      project_id: project.id,
      media_item_id: item.id,
      status: "staged",
      source_url: asset.source_url,
      media_url: item.url,
      attempts: 1
    })
    |> Repo.insert!()

    source_key = asset.source_key

    assert {:ok, %{^source_key => %{"url" => "https://media.example/ready.png"}}} =
             MediaIngestor.required_media_urls(run.id)

    item
    |> Ecto.Changeset.change(deleted: true)
    |> Repo.update!()

    assert {:error, {:required_media_not_ready, ^source_key, :missing_media_record}} =
             MediaIngestor.required_media_urls(run.id)
  end

  test "cleanup deletes only unreferenced items created by this run, never reused media", %{
    run: run,
    project: project
  } do
    [created_asset, reused_asset] =
      persist_assets(
        run.id,
        [
          "https://assets.openstax.org/figures/created.png",
          "https://assets.openstax.org/figures/reused-cleanup.png"
        ],
        "image/png"
      )

    created_item = insert_media_item(project.id, "created")
    reused_item = insert_media_item(project.id, "reused")

    insert_media(run, created_asset, created_item, "staged")
    insert_media(run, reused_asset, reused_item, "reused")

    run
    |> Oli.OpenStax.CourseImport.Run.update_changeset(%{status: :awaiting_lesson_approval})
    |> Repo.update!()

    assert {:ok, %{deleted: 1, media_item_ids: [created_id]}} =
             MediaIngestor.cleanup_run_created_media(run.id)

    assert created_id == created_item.id
    assert Repo.get!(Oli.Authoring.MediaLibrary.MediaItem, created_item.id).deleted
    refute Repo.get!(Oli.Authoring.MediaLibrary.MediaItem, reused_item.id).deleted
  end

  test "cleanup removes selected staged media after an atomic run fails", %{
    run: run,
    project: project
  } do
    asset =
      persist_asset(
        run.id,
        "https://assets.openstax.org/figures/selected-before-failure.png",
        "image/png"
      )

    asset
    |> SourceAsset.changeset(%{required: true})
    |> Repo.update!()

    item = insert_media_item(project.id, "selected-before-failure")
    insert_media(run, asset, item, "staged")

    run
    |> Oli.OpenStax.CourseImport.Run.update_changeset(%{status: :failed})
    |> Repo.update!()

    assert {:ok, %{deleted: 1, media_item_ids: [item_id]}} =
             MediaIngestor.cleanup_run_created_media(run.id)

    assert item_id == item.id
    assert Repo.get!(Oli.Authoring.MediaLibrary.MediaItem, item.id).deleted
  end

  defp persist_asset(run_id, source_url, declared_mime_type) do
    [asset] = persist_assets(run_id, [source_url], declared_mime_type)
    asset
  end

  defp persist_assets(run_id, source_urls, declared_mime_type) do
    assert {:ok, %{assets: asset_count}} =
             RichSource.persist_snapshot(run_id, %{
               "book_slug" => "sample-book",
               "title" => "Sample Book",
               "chapters" => [
                 %{
                   "id" => "chapter-1",
                   "order" => 1,
                   "sections" => [
                     %{
                       "title" => "Media section",
                       "url" => "https://openstax.org/books/sample-book/pages/1-1-media-section",
                       "order" => 1,
                       "source_blocks" => [
                         %{
                           "block_kind" => "paragraph",
                           "normalized_text" => "A source-grounded media explanation."
                         }
                       ],
                       "source_media" =>
                         Enum.with_index(source_urls, 1)
                         |> Enum.map(fn {source_url, index} ->
                           %{
                             "id" => "media-#{index}",
                             "source_url" => source_url,
                             "mime_type" => declared_mime_type,
                             "alt_text" => "A meaningful diagram"
                           }
                         end)
                     }
                   ]
                 }
               ]
             })

    assert asset_count == length(source_urls)

    SourceAsset
    |> where([asset], asset.run_id == ^run_id)
    |> order_by([asset], asc: asset.order)
    |> Repo.all()
  end

  defp insert_media_item(project_id, suffix) do
    %Oli.Authoring.MediaLibrary.MediaItem{}
    |> Oli.Authoring.MediaLibrary.MediaItem.changeset(%{
      url: "https://media.example/#{suffix}.png",
      file_name: "#{suffix}.png",
      mime_type: "image/png",
      file_size: 12,
      md5_hash: "#{suffix}-md5",
      deleted: false,
      project_id: project_id
    })
    |> Repo.insert!()
  end

  defp insert_media(run, asset, item, status) do
    %Media{}
    |> Media.changeset(%{
      run_id: run.id,
      source_asset_id: asset.id,
      project_id: run.project_id,
      media_item_id: item.id,
      status: status,
      source_url: asset.source_url,
      media_url: item.url,
      attempts: 1,
      staged_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp another_run do
    author = author_fixture()

    %{project: project, resource_revision: root} =
      project_fixture(author, "Another OpenStax media run")

    {:ok, _flag} = ScopedFeatureFlags.enable_feature(:openstax_course_import, project)

    {:ok, run} =
      CourseImport.start_import(
        project,
        root,
        author,
        "https://openstax.org/details/books/another-book"
      )

    run
  end

  defp png_bytes(suffix, width \\ 32, height \\ 32) do
    <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", width::32, height::32, 8, 6,
      0, 0, 0, 0::32>> <> suffix
  end
end
