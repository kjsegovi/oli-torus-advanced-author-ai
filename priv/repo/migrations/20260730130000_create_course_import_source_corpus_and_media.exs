defmodule Oli.Repo.Migrations.CreateCourseImportSourceCorpusAndMedia do
  use Ecto.Migration

  @old_active_statuses "'preflighting', 'awaiting_scope', 'ingesting', 'planning_outline', 'awaiting_outline_approval', 'planning_lessons', 'awaiting_lesson_approval', 'compiling', 'applying'"
  @new_active_statuses "'preflighting', 'awaiting_scope', 'ingesting', 'staging_media', 'planning_outline', 'awaiting_outline_approval', 'planning_lessons', 'awaiting_lesson_approval', 'compiling', 'applying'"
  @terminal_statuses "'completed', 'failed', 'cancelled'"

  @old_lesson_statuses "'pending', 'ready_for_review', 'approved', 'needs_repair', 'failed', 'compiled', 'applied'"
  @new_lesson_statuses "'pending', 'ready_for_review', 'approved', 'needs_attention', 'needs_repair', 'failed', 'compiled', 'applied'"

  def up do
    drop constraint(:course_import_runs, :course_import_runs_valid_status)

    create constraint(:course_import_runs, :course_import_runs_valid_status,
             check: "status IN (#{@new_active_statuses}, #{@terminal_statuses})"
           )

    drop index(:course_import_runs, [:project_id, :target_root_container_resource_id],
           name: :course_import_runs_one_active_per_project
         )

    create unique_index(
             :course_import_runs,
             [:project_id, :target_root_container_resource_id],
             name: :course_import_runs_one_active_per_project,
             where: "status IN (#{@new_active_statuses})"
           )

    drop constraint(:course_import_lessons, :course_import_lessons_status)

    create constraint(:course_import_lessons, :course_import_lessons_status,
             check: "status IN (#{@new_lesson_statuses})"
           )

    alter table(:course_import_lessons) do
      add :source_word_count, :integer, null: false, default: 0
      add :source_coverage, :map, null: false, default: %{}
    end

    create constraint(:course_import_lessons, :course_import_lessons_source_word_count,
             check: "source_word_count >= 0"
           )

    create table(:course_import_source_sections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :canonical_url, :text, null: false
      add :section_slug, :string
      add :title, :text, null: false
      add :order, :integer, null: false
      add :chapter_id, :string
      add :chapter_order, :integer
      add :section_order, :integer
      add :learning_objectives, {:array, :text}, null: false, default: []
      add :normalized_word_count, :integer, null: false, default: 0
      add :content_hash, :string, null: false
      add :retrieved_at, :utc_datetime_usec
      add :attribution_payload, :map, null: false, default: %{}
      add :source_coverage, :map, null: false, default: %{}
      add :source_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_source_sections, :course_import_source_sections_order,
             check: "\"order\" > 0 AND normalized_word_count >= 0"
           )

    create unique_index(:course_import_source_sections, [:run_id, :canonical_url])
    create unique_index(:course_import_source_sections, [:run_id, :order])
    create index(:course_import_source_sections, [:run_id, :chapter_order, :section_order])
    create index(:course_import_source_sections, [:run_id, :content_hash])

    create table(:course_import_source_blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_section_id,
          references(:course_import_source_sections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :order, :integer, null: false
      add :heading_path, {:array, :text}, null: false, default: []
      add :block_kind, :string, null: false
      add :normalized_text, :text, null: false
      add :source_locator, :map, null: false, default: %{}
      add :token_estimate, :integer, null: false, default: 0
      add :content_hash, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_source_blocks, :course_import_source_blocks_order,
             check: "\"order\" > 0 AND token_estimate >= 0"
           )

    create unique_index(:course_import_source_blocks, [:source_section_id, :order])
    create index(:course_import_source_blocks, [:run_id, :content_hash])
    create index(:course_import_source_blocks, [:source_section_id, :block_kind])

    create table(:course_import_source_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_section_id,
          references(:course_import_source_sections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_block_id,
          references(:course_import_source_blocks, type: :binary_id, on_delete: :nilify_all)

      add :order, :integer, null: false
      add :asset_type, :string, null: false, default: "image"
      add :source_url, :text, null: false
      add :alt_text, :text
      add :caption, :text
      add :declared_mime_type, :string
      add :source_locator, :map, null: false, default: %{}
      add :status, :string, null: false, default: "discovered"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_source_assets, :course_import_source_assets_order,
             check: "\"order\" > 0"
           )

    create constraint(:course_import_source_assets, :course_import_source_assets_status,
             check: "status IN ('discovered', 'staging', 'staged', 'reused', 'skipped', 'failed')"
           )

    create unique_index(:course_import_source_assets, [:source_section_id, :order])
    create index(:course_import_source_assets, [:run_id, :status])
    create index(:course_import_source_assets, [:source_block_id])

    create table(:course_import_lesson_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lesson_id,
          references(:course_import_lessons, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source_block_id,
          references(:course_import_source_blocks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :order, :integer, null: false
      add :purpose, :string, null: false, default: "instruction"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_lesson_sources, :course_import_lesson_sources_order,
             check: "\"order\" > 0"
           )

    create unique_index(:course_import_lesson_sources, [:lesson_id, :source_block_id])
    create unique_index(:course_import_lesson_sources, [:lesson_id, :order])
    create index(:course_import_lesson_sources, [:run_id])
    create index(:course_import_lesson_sources, [:source_block_id])

    create table(:course_import_media, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:course_import_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_asset_id,
          references(:course_import_source_assets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :media_item_id, references(:media_items, on_delete: :nilify_all)
      add :status, :string, null: false, default: "discovered"
      add :source_url, :text, null: false
      add :final_source_url, :text
      add :media_url, :text
      add :file_name, :string
      add :mime_type, :string
      add :byte_size, :integer
      add :sha256, :string
      add :attempts, :integer, null: false, default: 0
      add :failure_reason, :map
      add :staged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:course_import_media, :course_import_media_status,
             check: "status IN ('discovered', 'staging', 'staged', 'reused', 'skipped', 'failed')"
           )

    create constraint(:course_import_media, :course_import_media_sizes,
             check: "attempts >= 0 AND (byte_size IS NULL OR byte_size >= 0)"
           )

    create unique_index(:course_import_media, [:source_asset_id])
    create index(:course_import_media, [:run_id, :status])
    create index(:course_import_media, [:project_id, :sha256])
    create index(:course_import_media, [:media_item_id])
  end

  def down do
    drop table(:course_import_media)
    drop table(:course_import_lesson_sources)
    drop table(:course_import_source_assets)
    drop table(:course_import_source_blocks)
    drop table(:course_import_source_sections)

    drop constraint(:course_import_lessons, :course_import_lessons_source_word_count)

    alter table(:course_import_lessons) do
      remove :source_coverage
      remove :source_word_count
    end

    drop constraint(:course_import_lessons, :course_import_lessons_status)

    create constraint(:course_import_lessons, :course_import_lessons_status,
             check: "status IN (#{@old_lesson_statuses})"
           )

    drop index(:course_import_runs, [:project_id, :target_root_container_resource_id],
           name: :course_import_runs_one_active_per_project
         )

    create unique_index(
             :course_import_runs,
             [:project_id, :target_root_container_resource_id],
             name: :course_import_runs_one_active_per_project,
             where: "status IN (#{@old_active_statuses})"
           )

    drop constraint(:course_import_runs, :course_import_runs_valid_status)

    create constraint(:course_import_runs, :course_import_runs_valid_status,
             check: "status IN (#{@old_active_statuses}, #{@terminal_statuses})"
           )
  end
end
