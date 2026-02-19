-- =============================================================================
-- demo_cheatsheet.sql
-- ─────────────────────────────────────────────────────────────────────────────
-- STUDENT CHEAT-SHEET: Copy-paste any query below into Snowsight
-- or let demo_runner.py run them in order.
--
-- STORY SO FAR:
--   Jan 1  : Fund loads Apple=100, Google=100, MSFT=150
--   Jan 5  : Correction — Apple was wrong, should be 120
--   Jan 7  : Correction — Google was wrong, should be 105
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUICK REFERENCE: The 4 time columns
-- ─────────────────────────────────────────────────────────────────────────────
--
--   valid_from  │ When the price became true in the real world (business date)
--   valid_to    │ When the price stops being true  (9999 = "still true")
--   system_from │ When THIS ROW was inserted into the system
--   system_to   │ When THIS ROW was superseded     (9999 = "still believed")
--
--   Current rows  → system_to  = '9999-12-31 00:00:00'
--   Closed rows   → system_to  < '9999-12-31 00:00:00'  (never deleted!)


-- ─────────────────────────────────────────────────────────────────────────────
-- 0. SEE EVERYTHING — full raw table (no filters)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    fund_id, asset, price, valid_from,
    system_from::DATE AS sys_from,
    system_to::DATE   AS sys_to,
    record_version    AS ver,
    CASE WHEN system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
         THEN '✓ CURRENT' ELSE '  HISTORY' END AS status
FROM nav_prices
ORDER BY fund_id, asset, valid_from, system_from;


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. AUDIT QUESTION A — "What did we PUBLISH on Jan 2?"
--    (system was Jan 2, Apple correction hadn't happened yet → Apple = 100)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT asset, price AS published_price
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from  = '2024-01-01'
  AND system_from <= '2024-01-02 23:59:59'::TIMESTAMP_NTZ   -- believed on Jan 2
  AND system_to   > '2024-01-02 23:59:59'::TIMESTAMP_NTZ
ORDER BY asset;
-- Expected: APPLE=100, GOOGLE=100, MSFT=150


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. AUDIT QUESTION B — "What is CORRECT for Jan 1 today?"
--    (current rows only → Apple=120, Google=105, MSFT=150)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT asset, price AS corrected_price
FROM nav_prices
WHERE fund_id   = 'FUND1'
  AND valid_from = '2024-01-01'
  AND system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ     -- current belief
ORDER BY asset;
-- Expected: APPLE=120, GOOGLE=105, MSFT=150


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. NAV CALCULATION — published vs corrected, side by side
-- ─────────────────────────────────────────────────────────────────────────────
WITH pub AS (
    SELECT ROUND(SUM(price*units)/SUM(units),2) AS nav
    FROM   nav_prices
    WHERE  fund_id='FUND1' AND valid_from='2024-01-01'
      AND  system_from <= '2024-01-02 23:59:59'::TIMESTAMP_NTZ
      AND  system_to   > '2024-01-02 23:59:59'::TIMESTAMP_NTZ
),
cor AS (
    SELECT ROUND(SUM(price*units)/SUM(units),2) AS nav
    FROM   nav_prices
    WHERE  fund_id='FUND1' AND valid_from='2024-01-01'
      AND  system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
)
SELECT
    pub.nav                         AS published_nav,
    cor.nav                         AS corrected_nav,
    cor.nav - pub.nav               AS difference
FROM pub, cor;
-- A traditional database can only give you ONE of these answers.
-- Bitemporal gives you BOTH, forever.


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ICEBERG SNAPSHOT LOG — the commit history
--    (one row per INSERT / UPDATE / DELETE)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    snapshot_id,
    committed_at,
    operation,
    PARSE_JSON(summary)['added-records']::INT   AS rows_added,
    PARSE_JSON(summary)['total-records']::INT   AS total_rows
FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        'NAV_PRICES','BITEMPORAL','ICEBERG_NAV_DB'))
ORDER BY committed_at;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ICEBERG DATA FILES — actual Parquet files on storage
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    file_path,
    record_count,
    file_size_bytes,
    CASE content WHEN 0 THEN 'DATA' WHEN 1 THEN 'POS-DELETES'
                 WHEN 2 THEN 'EQ-DELETES' END AS file_type
FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(
        'NAV_PRICES','BITEMPORAL','ICEBERG_NAV_DB'))
ORDER BY record_count DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. SNOWFLAKE TIME TRAVEL — see the table before the Apple correction
-- ─────────────────────────────────────────────────────────────────────────────
SELECT asset, price, system_from, system_to
FROM nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ)
WHERE fund_id = 'FUND1'
ORDER BY asset;
-- Apple is 100 here — the correction on Jan 5 hasn't happened yet


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. QUERY A SPECIFIC ICEBERG SNAPSHOT by ID
--    Get the snapshot_id from query 4 above, then paste it here:
-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT asset, price, system_from, system_to
-- FROM nav_prices AT (VERSION => <paste_snapshot_id_here>)
-- WHERE fund_id = 'FUND1';


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. CORRECTION AUDIT LOG — who changed what and when
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    fund_id, asset, valid_date,
    original_price, corrected_price,
    corrected_price - original_price  AS change,
    correction_ts,
    ticket_reference
FROM nav_correction_log
ORDER BY correction_ts;


-- ─────────────────────────────────────────────────────────────────────────────
-- 9. ICEBERG TABLE METADATA JSON
--    Shows: metadata file path, current snapshot, format version
-- ─────────────────────────────────────────────────────────────────────────────
SELECT PARSE_JSON(
    SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES')
) AS iceberg_info;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10. CLONE the table at a past point in time (zero-copy)
--     Creates a "frozen" read-only copy — useful for auditors
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nav_prices_pre_correction
CLONE nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ);

SELECT asset, price FROM nav_prices_pre_correction WHERE fund_id='FUND1';
-- This clone shares the same Parquet files as the original — no data is copied!
