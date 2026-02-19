-- =============================================================================
-- FILE: 02_initial_load.sql
-- PURPOSE: Simulate Day 1 — initial NAV price data loaded on 2024-01-01
-- SCENARIO: Fund manager receives EOD prices from Bloomberg at 09:00 AM
-- RUN ORDER: 2 of 3 in the bitemporal phase
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ---------------------------------------------------------------------------
-- STEP 1: Capture the "as-of" business timestamp for this load
-- In production this comes from the feed timestamp, not CURRENT_TIMESTAMP.
-- We hardcode it here so results are deterministic and reproducible.
-- ---------------------------------------------------------------------------

-- Day 1 load: system receives prices on 2024-01-01 at 09:00 AM
-- NAV date: 2024-01-01 (valid_from = valid_to period start)

INSERT INTO nav_prices (
    fund_id, asset, price, units,
    valid_from, valid_to,
    system_from, system_to,
    source_feed, correction_reason, record_version
)
VALUES

-- ---- FUND1: Balanced Equity Fund ----------------------------------------
-- Apple Inc.    — initially priced at 100
('FUND1', 'APPLE',  100.0000, 100, '2024-01-01', '9999-12-31',
 '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- Google (Alphabet) — initially priced at 100
('FUND1', 'GOOGLE', 100.0000, 100, '2024-01-01', '9999-12-31',
 '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- Microsoft — initially priced at 150
('FUND1', 'MSFT',   150.0000, 100, '2024-01-01', '9999-12-31',
 '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- ---- FUND2: Tech Growth Fund ---------------------------------------------
-- Apple in FUND2 — same date, different fund context
('FUND2', 'APPLE',  100.0000, 200, '2024-01-01', '9999-12-31',
 '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- Nvidia — high-growth stock
('FUND2', 'NVIDIA', 400.0000, 50, '2024-01-01', '9999-12-31',
 '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- ---- Day 2: Jan 2 prices (normal EOD feed, no corrections) ---------------
('FUND1', 'APPLE',  102.0000, 100, '2024-01-02', '9999-12-31',
 '2024-01-02 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

('FUND1', 'GOOGLE', 101.5000, 100, '2024-01-02', '9999-12-31',
 '2024-01-02 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

('FUND1', 'MSFT',   152.0000, 100, '2024-01-02', '9999-12-31',
 '2024-01-02 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

-- ---- Day 3: Jan 3 prices -------------------------------------------------
('FUND1', 'APPLE',  101.0000, 100, '2024-01-03', '9999-12-31',
 '2024-01-03 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

('FUND1', 'GOOGLE', 103.0000, 100, '2024-01-03', '9999-12-31',
 '2024-01-03 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1),

('FUND1', 'MSFT',   155.0000, 100, '2024-01-03', '9999-12-31',
 '2024-01-03 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
 'BLOOMBERG', NULL, 1);

-- ---------------------------------------------------------------------------
-- VERIFICATION: Confirm initial load
-- ---------------------------------------------------------------------------
SELECT 'Initial load complete' AS status;

SELECT
    fund_id,
    asset,
    price,
    valid_from,
    system_from::DATE AS system_date,
    system_to::DATE   AS system_to_date
FROM nav_prices
ORDER BY fund_id, asset, valid_from;

-- ---------------------------------------------------------------------------
-- NAV CALCULATION — Day 1, as believed on Day 1
-- Expected: FUND1 = (100+100+150)/300 = 116.67 per unit
-- ---------------------------------------------------------------------------
SELECT
    fund_id,
    valid_from                               AS nav_date,
    SUM(price * units)                       AS total_aum,
    SUM(units)                               AS total_units,
    ROUND(SUM(price * units) / SUM(units), 4) AS nav_per_unit
FROM nav_prices
WHERE fund_id   = 'FUND1'
  AND valid_from = '2024-01-01'
  AND system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
GROUP BY fund_id, valid_from;
