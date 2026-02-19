-- =============================================================================
-- FILE: 03_correction_scenario.sql
-- PURPOSE: Simulate the correction event on 2024-01-05
-- SCENARIO: Bloomberg reports Apple price on Jan 1 was wrong (100 → 120).
--           Risk team confirms. Operations team applies correction at 10:00 AM.
-- RUN ORDER: 3 of 3 in the bitemporal phase
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ---------------------------------------------------------------------------
-- BEFORE-PICTURE: What does the system currently believe for Jan 1?
-- ---------------------------------------------------------------------------


SELECT fund_id, asset, price, valid_from, system_from, system_to
FROM nav_prices
WHERE fund_id = 'FUND1'
  AND asset   = 'APPLE'
ORDER BY valid_from, system_from;

-- ---------------------------------------------------------------------------
-- STEP 1: Close the stale row
--
-- We do NOT delete the old row. We stamp system_to with the exact moment
-- the correction was applied. This row becomes a "closed" historical belief.
-- ---------------------------------------------------------------------------
UPDATE nav_prices
SET    system_to = CAST('2024-01-05 10:00:00' AS TIMESTAMP_NTZ(6))
WHERE  fund_id   = 'FUND1'
  AND  asset     = 'APPLE'
  AND  valid_from = '2024-01-01'
  AND  system_to  = CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6));

-- ---------------------------------------------------------------------------
-- STEP 2: Insert the corrected row
--
-- valid_from / valid_to are UNCHANGED  → still Jan 1 (real-world truth)
-- system_from = 2024-01-05 10:00       → this is when we learned the truth
-- system_to   = 9999                   → this is now the "current" belief
-- record_version incremented to 2
-- ---------------------------------------------------------------------------
INSERT INTO nav_prices (
    fund_id, asset, price, units,
    valid_from, valid_to,
    system_from, system_to,
    source_feed, correction_reason, record_version
)
VALUES (
    'FUND1', 'APPLE', 120.0000, 100,
    '2024-01-01', '9999-12-31',
    CAST('2024-01-05 10:00:00' AS TIMESTAMP_NTZ(6)), CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6)),
    'BLOOMBERG_CORRECTION',
    'Price feed error: vendor supplied closing price instead of adjusted NAV price',
    2
);

-- ---------------------------------------------------------------------------
-- STEP 3: Log the correction in the audit table
-- ---------------------------------------------------------------------------
INSERT INTO nav_correction_log (
    correction_id, fund_id, asset,
    original_price, corrected_price,
    valid_date, correction_ts,
    corrected_by, reason, ticket_reference
)
VALUES (
    '550e8400-e29b-41d4-a716-446655440000',
    'FUND1', 'APPLE',
    100.0000, 120.0000,
    '2024-01-01',
    CAST('2024-01-05 10:00:00' AS TIMESTAMP_NTZ(6)),
    'ops.team@fund.com',
    'Bloomberg price feed error — ticket OPS-20240105-001',
    'OPS-20240105-001'
);

-- ---------------------------------------------------------------------------
-- AFTER-PICTURE: Same asset — now see both rows
-- ---------------------------------------------------------------------------


SELECT
    fund_id,
    asset,
    price,
    valid_from,
    system_from::DATE  AS system_believed_from,
    system_to::DATE    AS system_believed_to,
    record_version,
    CASE WHEN system_to = CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6))
         THEN 'CURRENT'
         ELSE 'SUPERSEDED'
    END AS row_status
FROM nav_prices
WHERE fund_id = 'FUND1'
  AND asset   = 'APPLE'
ORDER BY valid_from, system_from;

-- ---------------------------------------------------------------------------
-- SIMULATE A SECOND CORRECTION (Jan 7): Google price also needs fixing
-- This shows the pattern is repeatable — record_version becomes 2
-- ---------------------------------------------------------------------------

-- Close stale Google row
UPDATE nav_prices
SET    system_to = CAST('2024-01-07 14:30:00' AS TIMESTAMP_NTZ(6))
WHERE  fund_id   = 'FUND1'
  AND  asset     = 'GOOGLE'
  AND  valid_from = '2024-01-01'
  AND  system_to  = CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6));

-- Insert corrected Google row
INSERT INTO nav_prices (
    fund_id, asset, price, units,
    valid_from, valid_to,
    system_from, system_to,
    source_feed, correction_reason, record_version
)
VALUES (
    'FUND1', 'GOOGLE', 105.0000, 100,
    '2024-01-01', '9999-12-31',
    CAST('2024-01-07 14:30:00' AS TIMESTAMP_NTZ(6)), CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6)),
    'BLOOMBERG_CORRECTION',
    'Incorrect ISIN mapping caused wrong price to be loaded',
    2
);

INSERT INTO nav_correction_log (
    correction_id, fund_id, asset,
    original_price, corrected_price,
    valid_date, correction_ts,
    corrected_by, reason, ticket_reference
)
VALUES (
    '6ba7b810-9dad-11d1-80b4-00c04fd430c8',
    'FUND1', 'GOOGLE',
    100.0000, 105.0000,
    '2024-01-01',
    CAST('2024-01-07 14:30:00' AS TIMESTAMP_NTZ(6)),
    'ops.team@fund.com',
    'Incorrect ISIN mapping in Bloomberg terminal',
    'OPS-20240107-003'
);

-- ---------------------------------------------------------------------------
-- FINAL STATE: Full NAV price table
-- ---------------------------------------------------------------------------


SELECT
    fund_id, asset, price, valid_from, valid_to,
    system_from, system_to, record_version,
    correction_reason,
    CASE WHEN system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
         THEN '>>> CURRENT'
         ELSE '    HISTORY'
    END AS row_status
FROM nav_prices
ORDER BY fund_id, asset, valid_from, system_from;
