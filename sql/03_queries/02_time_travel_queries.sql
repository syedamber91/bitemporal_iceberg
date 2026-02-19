-- =============================================================================
-- FILE: 02_time_travel_queries.sql
-- PURPOSE: Demonstrate Snowflake + Iceberg time travel capabilities.
--
-- TWO LAYERS of time travel in this stack:
--
--   LAYER 1 — Bitemporal SQL (our own columns)
--     Uses system_from / system_to to replay any historical belief.
--     Works across ALL time ranges we have data for.
--
--   LAYER 2 — Snowflake native time travel (AT / BEFORE syntax)
--     Queries a previous SNAPSHOT of the physical Iceberg table.
--     Lets you see rows as they physically existed before any DML.
--     Default retention: 1 day (Standard), 90 days (Enterprise).
--
--   LAYER 3 — Iceberg metadata time travel
--     Queries against a specific Iceberg snapshot ID.
--     Persisted in Iceberg metadata files (.json).
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ===========================================================================
-- LAYER 1: Bitemporal SQL time travel
-- (Already demonstrated in 01_bitemporal_queries.sql — shown again for contrast)
-- ===========================================================================

SELECT 'LAYER 1 — Bitemporal SQL: system knew on Jan 3' AS layer;

SELECT fund_id, asset, price, valid_from, system_from, system_to
FROM nav_prices
WHERE fund_id = 'FUND1'
  AND system_from <= '2024-01-03 00:00:00'::TIMESTAMP_NTZ
  AND system_to   > '2024-01-03 00:00:00'::TIMESTAMP_NTZ
ORDER BY asset;

-- ===========================================================================
-- LAYER 2: Snowflake Native Time Travel (AT / BEFORE)
-- These queries go back to the physical state of the table at a past time.
-- NOTE: The timestamp must be within the DATA_RETENTION_TIME_IN_DAYS window.
--       For this POC the timestamps are in the past; substitute real
--       timestamps from your session if running live.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- TT-1: Before the first correction (Apple was still 100)
-- Replace the TIMESTAMP value with one from your QUERY_HISTORY if re-running
-- ---------------------------------------------------------------------------
SELECT 'LAYER 2 — Snowflake time travel: table state before Apple correction' AS layer;

-- Syntax:  SELECT ... FROM table AT (TIMESTAMP => 'ts'::TIMESTAMP_NTZ)
--          SELECT ... FROM table AT (OFFSET => -3600)   -- 1 hour ago
--          SELECT ... FROM table AT (STATEMENT => '<query_id>')
--          SELECT ... FROM table BEFORE (STATEMENT => '<query_id>')

SELECT fund_id, asset, price, valid_from, system_from, system_to
FROM nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ)
WHERE fund_id = 'FUND1'
ORDER BY asset;

-- ---------------------------------------------------------------------------
-- TT-2: After Apple correction but before Google correction
-- ---------------------------------------------------------------------------
SELECT 'LAYER 2 — After Apple correction, before Google correction' AS layer;

SELECT fund_id, asset, price, valid_from, system_from, system_to
FROM nav_prices AT (TIMESTAMP => '2024-01-06 00:00:00'::TIMESTAMP_NTZ)
WHERE fund_id = 'FUND1'
ORDER BY asset;

-- ---------------------------------------------------------------------------
-- TT-3: Table state 1 hour ago (useful during live testing sessions)
-- ---------------------------------------------------------------------------
SELECT 'LAYER 2 — Table state 1 hour ago (live)' AS layer;

SELECT fund_id, asset, price, valid_from
FROM nav_prices AT (OFFSET => -3600)
WHERE fund_id = 'FUND1'
ORDER BY asset, valid_from;

-- ---------------------------------------------------------------------------
-- TT-4: UNDROP simulation
-- If you accidentally dropped the table, you could restore it:
--   UNDROP TABLE nav_prices;
-- You can also clone a table at a past state:
--   CREATE TABLE nav_prices_snapshot_jan4
--   CLONE nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ);
-- ---------------------------------------------------------------------------

-- Create a read-only snapshot clone (safe — does NOT copy data, uses metadata)
CREATE TABLE IF NOT EXISTS nav_prices_snapshot_pre_correction
CLONE nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ)
COMMENT = 'Frozen snapshot: table state before Apple NAV correction on Jan 5';

SELECT 'Cloned snapshot created — pre-correction state preserved' AS status;

SELECT fund_id, asset, price, valid_from
FROM nav_prices_snapshot_pre_correction
WHERE fund_id = 'FUND1'
ORDER BY asset;

-- ===========================================================================
-- LAYER 3: Iceberg Snapshot (metadata-level) time travel
-- Snowflake exposes Iceberg snapshot IDs through system functions.
-- ===========================================================================

SELECT 'LAYER 3 — List Iceberg snapshots for nav_prices' AS layer;

-- This returns each Iceberg snapshot with its ID and commit timestamp.
-- Each INSERT/UPDATE/DELETE creates a NEW snapshot (append-only log).
SELECT *
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        TABLE_NAME   => 'NAV_PRICES',
        TABLE_SCHEMA => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY committed_at;

-- You can query using a specific snapshot_id from the above result:
-- SELECT * FROM nav_prices AT (VERSION => <snapshot_id>);

-- ---------------------------------------------------------------------------
-- Retrieve current Iceberg metadata (catalog metadata path, snapshot)
-- ---------------------------------------------------------------------------
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES');
