-- =============================================================================
-- FILE: 01_bitemporal_queries.sql
-- PURPOSE: The core analytical queries that demonstrate bitemporal power
-- These answer the two fundamental audit questions in finance.
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ===========================================================================
-- QUERY CATEGORY 1: AS-OF SYSTEM TIME
-- "What did the system BELIEVE on a given day?"
-- (Useful for: reproducing reports, regulatory audits, client disputes)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Q1a: What NAV did we publish on Jan 2 (i.e., what did the system know)?
-- System time = Jan 2 → sees only rows that existed in the DB on Jan 2
-- Apple was still 100 (correction hadn't happened yet)
-- Expected: FUND1 NAV ≈ 116.67 (100+100+150 / 300 units)
-- ---------------------------------------------------------------------------
SELECT 'Q1a: NAV as published on 2024-01-02' AS query_label;

SELECT
    fund_id,
    '2024-01-02'                                  AS as_of_system_date,
    SUM(price * units)                            AS total_aum,
    SUM(units)                                    AS total_units,
    ROUND(SUM(price * units) / SUM(units), 4)     AS nav_per_unit
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from <= '2024-01-01'          -- prices valid on Jan 1
  AND valid_to   >= '2024-01-01'
  AND system_from <= '2024-01-02'::TIMESTAMP_NTZ   -- system believed on Jan 2
  AND system_to   > '2024-01-02'::TIMESTAMP_NTZ    -- was current on Jan 2
GROUP BY fund_id;

-- ---------------------------------------------------------------------------
-- Q1b: Reusable macro pattern — parameterise both time dimensions
--      Replace the two date literals to query any point-in-time.
-- ---------------------------------------------------------------------------
-- FOR VALID_DATE = '2024-01-01', SYSTEM_DATE = '2024-01-06' (post-correction)
SELECT 'Q1b: NAV for Jan-01 as the system knew on Jan-06 (post Apple correction)' AS query_label;

SELECT
    fund_id,
    ROUND(SUM(price * units) / SUM(units), 4) AS nav_per_unit,
    SUM(price * units)                        AS total_aum
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from <= '2024-01-01'
  AND valid_to   >= '2024-01-01'
  AND system_from <= '2024-01-06 00:00:00'::TIMESTAMP_NTZ
  AND system_to   > '2024-01-06 00:00:00'::TIMESTAMP_NTZ
GROUP BY fund_id;

-- ===========================================================================
-- QUERY CATEGORY 2: AS-OF VALID TIME
-- "What is the correct (current belief) value for a given real-world date?"
-- (Useful for: restating NAV, corrected client statements)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Q2: Today's best-known NAV for Jan 1 (after all corrections applied)
-- Apple = 120, Google = 105, MSFT = 150
-- Expected: FUND1 NAV = (120+105+150) / 300 ≈ 125.00
-- ---------------------------------------------------------------------------
SELECT 'Q2: Best-known NAV for 2024-01-01 as of today' AS query_label;

SELECT
    fund_id,
    '2024-01-01'                                  AS for_nav_date,
    ROUND(SUM(price * units) / SUM(units), 4)     AS nav_per_unit,
    SUM(price * units)                            AS total_aum
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from <= '2024-01-01'
  AND valid_to   >= '2024-01-01'
  AND system_to   = '9999-12-31 00:00:00'::TIMESTAMP_NTZ  -- current rows only
GROUP BY fund_id;

-- ===========================================================================
-- QUERY CATEGORY 3: NAV RESTATEMENT COMPARISON
-- Side-by-side: original published NAV vs corrected NAV for the same date
-- Exactly what an auditor or regulator asks for.
-- ===========================================================================

SELECT 'Q3: NAV restatement comparison — original vs corrected' AS query_label;

WITH original_nav AS (
    -- What was believed BEFORE the correction (system_to is not 9999)
    SELECT
        fund_id,
        '2024-01-01'::DATE                            AS nav_date,
        ROUND(SUM(price * units) / SUM(units), 4)     AS nav_published
    FROM nav_prices
    WHERE fund_id    = 'FUND1'
      AND valid_from <= '2024-01-01'
      AND valid_to   >= '2024-01-01'
      -- Records that were current on Jan 2 but closed before Jan 8
      AND system_from <= '2024-01-02 00:00:00'::TIMESTAMP_NTZ
      AND system_to   > '2024-01-02 00:00:00'::TIMESTAMP_NTZ
    GROUP BY fund_id
),
corrected_nav AS (
    -- Current best-known prices
    SELECT
        fund_id,
        '2024-01-01'::DATE                            AS nav_date,
        ROUND(SUM(price * units) / SUM(units), 4)     AS nav_restated
    FROM nav_prices
    WHERE fund_id   = 'FUND1'
      AND valid_from <= '2024-01-01'
      AND valid_to   >= '2024-01-01'
      AND system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
    GROUP BY fund_id
)
SELECT
    o.fund_id,
    o.nav_date,
    o.nav_published,
    c.nav_restated,
    ROUND(c.nav_restated - o.nav_published, 4)         AS nav_difference,
    ROUND((c.nav_restated / o.nav_published - 1) * 100, 2) AS pct_change
FROM original_nav o
JOIN corrected_nav c USING (fund_id, nav_date);

-- ===========================================================================
-- QUERY CATEGORY 4: FULL CORRECTION TIMELINE
-- Show every belief state for each asset over time — the full audit trail
-- ===========================================================================

SELECT 'Q4: Full audit trail per asset' AS query_label;

SELECT
    fund_id,
    asset,
    price,
    valid_from,
    system_from                       AS believed_from_ts,
    system_to                         AS believed_until_ts,
    record_version,
    COALESCE(correction_reason, 'Original entry') AS entry_reason,
    CASE WHEN system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
         THEN 'CURRENT'
         ELSE 'SUPERSEDED'
    END                               AS row_status,
    DATEDIFF('hour', system_from, system_to) AS hours_this_belief_was_held
FROM nav_prices
WHERE fund_id = 'FUND1'
ORDER BY asset, valid_from, system_from;

-- ===========================================================================
-- QUERY CATEGORY 5: ROLLING NAV SERIES
-- Show NAV across multiple valid dates using current (corrected) beliefs
-- ===========================================================================

SELECT 'Q5: Rolling corrected NAV series for FUND1' AS query_label;

SELECT
    valid_from                                        AS nav_date,
    ROUND(SUM(price * units) / SUM(units), 4)         AS nav_per_unit,
    SUM(price * units)                                AS total_aum,
    COUNT(DISTINCT asset)                             AS assets_count
FROM nav_prices
WHERE fund_id  = 'FUND1'
  AND system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
GROUP BY valid_from
ORDER BY valid_from;

-- ===========================================================================
-- QUERY CATEGORY 6: CORRECTION LOG SUMMARY
-- ===========================================================================

SELECT 'Q6: Correction audit log' AS query_label;

SELECT
    correction_id,
    fund_id,
    asset,
    valid_date,
    original_price,
    corrected_price,
    corrected_price - original_price    AS price_delta,
    ROUND((corrected_price / original_price - 1) * 100, 2) AS pct_change,
    correction_ts,
    corrected_by,
    ticket_reference
FROM nav_correction_log
ORDER BY correction_ts;
