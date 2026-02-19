-- =============================================================================
-- FILE: 01_iceberg_metadata_inspection.sql
-- PURPOSE: Inspect Iceberg internal metadata — snapshots, manifests, data files
--
-- ICEBERG FILE HIERARCHY (what physically exists on storage):
--
--   table_root/
--   ├── metadata/
--   │   ├── v1.metadata.json          ← Table definition at creation
--   │   ├── v2.metadata.json          ← After first INSERT
--   │   ├── v3.metadata.json          ← After first UPDATE (correction)
--   │   ├── snap-<id1>-1.avro         ← Manifest LIST (list of manifests)
--   │   ├── snap-<id2>-1.avro         ← Manifest LIST after correction
--   │   └── <uuid>.avro               ← Manifest FILE (list of data files)
--   └── data/
--       ├── <uuid1>.parquet           ← Initial load data files
--       ├── <uuid2>.parquet           ← Correction insert data files
--       └── ...
--
-- WHERE ARE THESE FILES ON SNOWFLAKE-MANAGED ICEBERG?
--   Snowflake stores them in its own managed object store.
--   You CANNOT browse them via S3 console (that's Option A / external stage).
--   Instead, Snowflake exposes the metadata through:
--     1. SYSTEM$GET_ICEBERG_TABLE_INFORMATION()  → JSON blob of current metadata
--     2. INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS()  → snapshot log
--     3. SHOW ICEBERG TABLES  → high-level table info
--     4. Dynamic Tables / Streams  → change data capture
--
-- If you use EXTERNAL STAGE (Option A):
--   Files appear directly in your S3 bucket at the BASE_LOCATION.
--   You can open them in any Iceberg-compatible reader (Spark, Trino, Flink).
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ===========================================================================
-- SECTION 1: Table-level metadata
-- ===========================================================================

SELECT '=== SECTION 1: Table-level Iceberg metadata ===' AS section;

-- 1a. Show all Iceberg tables in the schema
SHOW ICEBERG TABLES IN SCHEMA BITEMPORAL;

-- 1b. DDL of the Iceberg table (includes storage properties)
SELECT GET_DDL('TABLE', 'ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES');

-- 1c. Full Iceberg table information (returns a JSON string)
--     This includes: metadata_location, format_version, snapshot_id,
--                    schema, partition_spec, sort_order
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES')
    AS iceberg_table_info_json;

-- 1d. Parse the JSON to extract key fields
SELECT
    PARSE_JSON(
        SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES')
    ) AS info,
    info:metadataLocation::STRING   AS metadata_file_path,
    info:status::STRING             AS status,
    info:icebergFormatVersion::INT  AS iceberg_format_version;

-- ===========================================================================
-- SECTION 2: Snapshot log (each DML = one new snapshot)
-- ===========================================================================

SELECT '=== SECTION 2: Iceberg snapshot log ===' AS section;

-- Each Iceberg write operation appends a new snapshot.
-- This is the append-only commit log at the heart of Iceberg.
SELECT
    snapshot_id,
    parent_id,
    operation,                -- 'append', 'overwrite', 'replace', 'delete'
    committed_at,
    summary,
    manifest_list             -- path to the manifest list .avro file
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY committed_at;

-- What does each snapshot represent?
--   snapshot 1  →  CREATE TABLE
--   snapshot 2  →  INSERT (initial load: 11 rows)
--   snapshot 3  →  UPDATE (close Apple row)
--   snapshot 4  →  INSERT (corrected Apple row)
--   snapshot 5  →  UPDATE (close Google row)
--   snapshot 6  →  INSERT (corrected Google row)

-- ===========================================================================
-- SECTION 3: Schema evolution history
-- (Iceberg tracks schema changes without rewriting files)
-- ===========================================================================

SELECT '=== SECTION 3: Schema history ===' AS section;

SELECT *
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SCHEMAS(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY schema_id;

-- ===========================================================================
-- SECTION 4: Query against specific Iceberg snapshots
-- ===========================================================================

SELECT '=== SECTION 4: Snapshot-level queries ===' AS section;

-- Step 1: Get snapshot IDs
-- (Run SECTION 2 first, copy the snapshot_id values)

-- Step 2: Query a specific snapshot by VERSION (snapshot_id)
-- Replace <SNAPSHOT_ID_HERE> with an actual ID from Section 2 output
-- SELECT * FROM nav_prices AT (VERSION => <SNAPSHOT_ID_HERE>);

-- Step 3: Compare row counts across snapshots to verify DML operations
-- This shows how many physical rows existed at each snapshot
WITH snapshot_list AS (
    SELECT snapshot_id, committed_at, operation
    FROM TABLE(
        INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
            TABLE_NAME    => 'NAV_PRICES',
            TABLE_SCHEMA  => 'BITEMPORAL',
            TABLE_CATALOG => 'ICEBERG_NAV_DB'
        )
    )
)
SELECT
    snapshot_id,
    committed_at,
    operation,
    'Use: SELECT COUNT(*) FROM nav_prices AT (VERSION => ' || snapshot_id || ')' AS time_travel_query
FROM snapshot_list
ORDER BY committed_at;

-- ===========================================================================
-- SECTION 5: Partition metadata
-- (Even without explicit partitioning, Iceberg tracks data files)
-- ===========================================================================

SELECT '=== SECTION 5: Partition / data file information ===' AS section;

SELECT *
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY record_count DESC;

-- Columns returned include:
--   content          → 0=DATA, 1=POSITIONAL_DELETES, 2=EQUALITY_DELETES
--   file_path        → Parquet file location
--   file_format      → PARQUET
--   record_count     → rows in this file
--   file_size_bytes  → compressed file size
--   column_sizes     → per-column storage size map
--   value_counts     → non-null count per column
--   null_value_counts
--   lower_bounds     → min value per column (used for file pruning)
--   upper_bounds     → max value per column (used for file pruning)

-- ===========================================================================
-- SECTION 6: Manifest files
-- Manifests are Avro files that list data files in a snapshot.
-- ===========================================================================

SELECT '=== SECTION 6: Manifest information ===' AS section;

SELECT *
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_MANIFESTS(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY added_snapshot_id, sequence_number;

-- Columns include:
--   manifest_path        → full path to the .avro manifest file
--   manifest_length      → size in bytes
--   partition_spec_id    → which partition spec applied
--   added_snapshot_id    → which snapshot added this manifest
--   added_data_files_count
--   added_rows_count
--   existing_rows_count
--   deleted_rows_count   → used by merge-on-read deletes
--   sequence_number

-- ===========================================================================
-- SECTION 7: Change tracking — what changed between snapshots?
-- ===========================================================================

SELECT '=== SECTION 7: Change data between two snapshots ===' AS section;

-- Iceberg change tracking using CHANGES clause (requires Streams or AT/BEFORE)
-- This shows rows added or deleted between two moments in time.
SELECT
    fund_id,
    asset,
    price,
    valid_from,
    system_from,
    system_to,
    METADATA$ACTION,           -- 'INSERT' or 'DELETE'
    METADATA$ISUPDATE          -- TRUE if this row is part of an update pair
FROM nav_prices
    CHANGES (INFORMATION => DEFAULT)
    AT      (TIMESTAMP => '2024-01-01 00:00:00'::TIMESTAMP_NTZ)
    END     (TIMESTAMP => CURRENT_TIMESTAMP)
ORDER BY METADATA$ACTION, asset;

-- ===========================================================================
-- SECTION 8: Storage statistics
-- ===========================================================================

SELECT '=== SECTION 8: Storage stats ===' AS section;

SELECT
    table_name,
    table_type,
    row_count,
    bytes,
    retention_time,
    created,
    last_altered,
    comment
FROM information_schema.tables
WHERE table_schema = 'BITEMPORAL'
  AND table_name   IN ('NAV_PRICES', 'NAV_CORRECTION_LOG')
ORDER BY table_name;

-- ===========================================================================
-- SECTION 9: Iceberg vs Snowflake Native — Explain plan
-- Demonstrates that Snowflake is reading Parquet files via Iceberg catalog
-- ===========================================================================

SELECT '=== SECTION 9: Query explain plan ===' AS section;

EXPLAIN
SELECT fund_id, asset, price
FROM nav_prices
WHERE fund_id   = 'FUND1'
  AND system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ;

-- In the explain output look for:
--   "TableScan [nav_prices]" — confirms Iceberg table scan
--   Filter pushdown lines   — Iceberg prunes files using column statistics
