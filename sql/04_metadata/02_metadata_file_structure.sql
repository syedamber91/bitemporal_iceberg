-- =============================================================================
-- FILE: 02_metadata_file_structure.sql
-- PURPOSE: Illustrate and document the Iceberg physical file structure.
--          These queries explain WHERE and HOW metadata is stored.
--
-- IMPORTANT NOTE ON FILE VISIBILITY:
-- ─────────────────────────────────
-- For SNOWFLAKE-MANAGED Iceberg tables:
--   Files are in Snowflake's internal managed storage.
--   You cannot browse them in an S3 console.
--   Access them ONLY via SQL functions shown in this script.
--
-- For EXTERNAL STAGE Iceberg tables (Option A / customer-managed S3):
--   Files are in YOUR S3 bucket.
--   You CAN browse them via AWS S3 console or CLI.
--   Example S3 path structure (see diagram in README):
--     s3://your-bucket/iceberg-nav/nav_prices/
--       metadata/
--         v1.metadata.json
--         v2.metadata.json
--         snap-<id>-1.avro     ← manifest list
--       data/
--         <partition>/
--           <uuid>.parquet
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ===========================================================================
-- SIMULATED METADATA FILE CONTENT
-- The queries below show what these files contain conceptually.
-- Actual file contents are binary (Avro) or JSON — shown as SQL equivalents.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- WHAT metadata/v1.metadata.json LOOKS LIKE (conceptual)
-- This file is created when the table is first created.
-- ---------------------------------------------------------------------------
SELECT 'metadata/v1.metadata.json — Table schema definition' AS file_name;

SELECT OBJECT_CONSTRUCT(
    'format-version', 2,
    'table-uuid', UUID_STRING(),
    'location', 's3://your-bucket/iceberg-nav/nav_prices',
    'last-sequence-number', 0,
    'last-updated-ms', DATEDIFF('millisecond', '1970-01-01', CURRENT_TIMESTAMP),
    'last-column-id', 12,
    'current-schema-id', 0,
    'schemas', ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT(
            'schema-id', 0,
            'type', 'struct',
            'fields', ARRAY_CONSTRUCT(
                OBJECT_CONSTRUCT('id', 1, 'name', 'fund_id',    'type', 'string',    'required', TRUE),
                OBJECT_CONSTRUCT('id', 2, 'name', 'asset',      'type', 'string',    'required', TRUE),
                OBJECT_CONSTRUCT('id', 3, 'name', 'price',      'type', 'decimal(18,4)', 'required', TRUE),
                OBJECT_CONSTRUCT('id', 4, 'name', 'units',      'type', 'decimal(18,4)', 'required', TRUE),
                OBJECT_CONSTRUCT('id', 5, 'name', 'valid_from', 'type', 'date',      'required', TRUE),
                OBJECT_CONSTRUCT('id', 6, 'name', 'valid_to',   'type', 'date',      'required', TRUE),
                OBJECT_CONSTRUCT('id', 7, 'name', 'system_from','type', 'timestamptz','required', TRUE),
                OBJECT_CONSTRUCT('id', 8, 'name', 'system_to',  'type', 'timestamptz','required', TRUE),
                OBJECT_CONSTRUCT('id', 9, 'name', 'source_feed','type', 'string',    'required', TRUE),
                OBJECT_CONSTRUCT('id',10, 'name', 'correction_reason','type','string','required', FALSE),
                OBJECT_CONSTRUCT('id',11, 'name', 'created_by', 'type', 'string',    'required', FALSE),
                OBJECT_CONSTRUCT('id',12, 'name', 'record_version','type','int',     'required', TRUE)
            )
        )
    ),
    'default-spec-id', 0,
    'partition-specs', ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT('spec-id', 0, 'fields', ARRAY_CONSTRUCT())  -- unpartitioned
    ),
    'current-snapshot-id', -1,
    'snapshots', ARRAY_CONSTRUCT(),
    'properties', OBJECT_CONSTRUCT(
        'write.format.default', 'parquet',
        'write.parquet.compression-codec', 'zstd',
        'write.metadata.compression-codec', 'gzip'
    )
) AS metadata_v1_json;

-- ---------------------------------------------------------------------------
-- WHAT metadata/v2.metadata.json LOOKS LIKE (after INSERT)
-- A new version is written; v1 is kept (immutable)
-- ---------------------------------------------------------------------------
SELECT 'metadata/v2.metadata.json — After initial INSERT (snapshot 1)' AS file_name;

SELECT OBJECT_CONSTRUCT(
    'format-version', 2,
    'current-snapshot-id', 1001,
    'last-sequence-number', 1,
    'snapshots', ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT(
            'snapshot-id', 1001,
            'sequence-number', 1,
            'timestamp-ms', DATEDIFF('millisecond', '1970-01-01', '2024-01-01 09:05:00'::TIMESTAMP_NTZ),
            'operation', 'append',
            'manifest-list', 'metadata/snap-1001-1.avro',
            'summary', OBJECT_CONSTRUCT(
                'added-data-files', '1',
                'added-records', '11',
                'added-files-size', '4096',
                'total-data-files', '1',
                'total-records', '11',
                'total-files-size', '4096'
            )
        )
    )
) AS metadata_v2_json;

-- ---------------------------------------------------------------------------
-- WHAT a manifest list (snap-1001-1.avro) CONTAINS (Avro schema)
-- The manifest list is an Avro file listing one or more manifest files.
-- ---------------------------------------------------------------------------
SELECT 'snap-1001-1.avro — Manifest list contents (one entry per manifest file)' AS file_name;

-- Each entry in the manifest list:
SELECT
    'metadata/<uuid>.avro'                  AS manifest_path,
    1024                                    AS manifest_length,
    0                                       AS partition_spec_id,
    0                                       AS content,         -- 0 = DATA
    1001                                    AS added_snapshot_id,
    1                                       AS sequence_number,
    0                                       AS min_sequence_number,
    1                                       AS added_data_files_count,
    11                                      AS added_rows_count,
    0                                       AS existing_data_files_count,
    0                                       AS existing_rows_count,
    0                                       AS deleted_data_files_count,
    0                                       AS deleted_rows_count;

-- ---------------------------------------------------------------------------
-- WHAT a manifest file (<uuid>.avro) CONTAINS
-- Each manifest file lists actual Parquet data files with column statistics.
-- ---------------------------------------------------------------------------
SELECT 'metadata/<uuid>.avro — Manifest file (one entry per Parquet data file)' AS file_name;

SELECT
    0                                       AS content,         -- 0=DATA
    'data/00000-0-<uuid>.parquet'           AS file_path,
    'PARQUET'                               AS file_format,
    OBJECT_CONSTRUCT()                      AS partition,       -- empty (unpartitioned)
    1001                                    AS file_sequence_number,
    1001                                    AS pos,
    11                                      AS record_count,
    4096                                    AS file_size_in_bytes,
    -- Column sizes (Iceberg column IDs map to file offsets)
    OBJECT_CONSTRUCT('1',512,'2',1024,'3',256,'4',256,'5',256,'6',256) AS column_sizes,
    -- Lower bounds (per-column min values for predicate pushdown)
    OBJECT_CONSTRUCT('1','FUND1','2','APPLE','3','100.0','5','2024-01-01') AS lower_bounds,
    -- Upper bounds (per-column max values)
    OBJECT_CONSTRUCT('1','FUND2','2','NVIDIA','3','400.0','5','2024-01-03') AS upper_bounds,
    OBJECT_CONSTRUCT('10', 9)               AS null_value_counts  -- correction_reason is null for 9 rows
;

-- ===========================================================================
-- WHAT HAPPENS DURING A CORRECTION (file-level)
-- ===========================================================================

SELECT '=== What physically happens during UPDATE + INSERT correction ===' AS section;

-- An UPDATE on Iceberg is NOT in-place. Here is what Snowflake does:
-- 1. Reads the existing Parquet file(s) containing the target row
-- 2. Writes a NEW Parquet file with the row marked as deleted
--    (or rewrites the file without the row — copy-on-write mode)
-- 3. Writes the INSERT as a new Parquet file with the corrected row
-- 4. Creates a new manifest listing both the delete file and new data file
-- 5. Writes a new metadata.json pointing to the new snapshot

-- This means:
--   BEFORE correction: snap-1001 → manifest-A → parquet-1 (11 rows, Apple=100)
--   AFTER  correction: snap-1003 → manifest-B → parquet-1 (now referenced but Apple row deleted)
--                                              → parquet-2 (1 row, Apple=120)
--   snap-1001 and parquet-1 still exist — Iceberg is immutable!

SELECT OBJECT_CONSTRUCT(
    'before_correction', OBJECT_CONSTRUCT(
        'snapshot_id', 1001,
        'data_files', ARRAY_CONSTRUCT('parquet-initial-load.parquet'),
        'total_rows', 11,
        'apple_price', 100
    ),
    'after_update_close', OBJECT_CONSTRUCT(
        'snapshot_id', 1002,
        'operation', 'overwrite',
        'data_files', ARRAY_CONSTRUCT('parquet-after-update.parquet'),
        'note', 'Row with Apple/100 now has system_to stamped; all other rows unchanged'
    ),
    'after_insert_correction', OBJECT_CONSTRUCT(
        'snapshot_id', 1003,
        'operation', 'append',
        'new_data_files', ARRAY_CONSTRUCT('parquet-correction.parquet'),
        'note', 'New file with Apple/120 inserted as separate Parquet file'
    ),
    'time_travel_still_works', TRUE,
    'snapshot_1001_still_readable', TRUE
) AS file_lifecycle_explanation;

-- ===========================================================================
-- PRACTICAL: Access metadata via INFORMATION_SCHEMA functions
-- ===========================================================================

-- Snapshots (commit log)
SELECT snapshot_id, parent_id, committed_at, operation,
       PARSE_JSON(summary):added-records::INT AS rows_added,
       PARSE_JSON(summary):deleted-records::INT AS rows_deleted
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'
    )
)
ORDER BY committed_at;

-- Data files in current snapshot
SELECT
    file_path,
    file_format,
    record_count,
    file_size_bytes,
    content  -- 0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(
        'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'
    )
)
ORDER BY record_count DESC;

-- Manifests
SELECT
    manifest_path,
    manifest_length,
    added_snapshot_id,
    added_data_files_count,
    added_rows_count,
    deleted_rows_count
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_MANIFESTS(
        'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'
    )
)
ORDER BY added_snapshot_id;
