-- =============================================================================
-- FILE: 01_create_tables.sql
-- PURPOSE: Create the Iceberg bitemporal NAV table plus helper objects
-- RUN ORDER: 1 of 3 in the bitemporal phase
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ---------------------------------------------------------------------------
-- MAIN BITEMPORAL TABLE  —  Snowflake-managed Iceberg
-- ---------------------------------------------------------------------------
-- Column glossary:
--   fund_id      : Identifier for the mutual fund
--   asset        : Underlying stock / bond / asset name
--   price        : Price of the asset (INR)
--   units        : Number of units of this asset held by the fund
--   valid_from   : Start of the real-world period this price is true for
--   valid_to     : End   of the real-world period (9999-12-31 = "still active")
--   system_from  : Timestamp when THIS ROW was inserted into the system
--   system_to    : Timestamp when THIS ROW was superseded (9999 = current row)
--   source_feed  : Origin of the price data (e.g., Bloomberg, Reuters)
--   correction_reason : Populated only on corrected rows
--
-- TWO time axes:
--   VALID TIME   = (valid_from,  valid_to)   — business / real-world time
--   SYSTEM TIME  = (system_from, system_to)  — when WE believed it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE ICEBERG TABLE nav_prices (

    -- Business key
    fund_id           VARCHAR       NOT NULL,
    asset             VARCHAR       NOT NULL,

    -- Fact
    price             NUMBER(18, 4) NOT NULL,
    units             NUMBER(18, 4) NOT NULL  DEFAULT 100,

    -- VALID TIME dimension  (real-world applicability)
    valid_from        DATE          NOT NULL,
    valid_to          DATE          NOT NULL  DEFAULT TO_DATE('9999-12-31'),

    -- SYSTEM TIME dimension  (when the system held this belief)
    system_from       TIMESTAMP_NTZ(6) NOT NULL,
    system_to         TIMESTAMP_NTZ(6) NOT NULL  DEFAULT CAST('9999-12-31 00:00:00' AS TIMESTAMP_NTZ(6)),

    -- Audit / lineage columns
    source_feed       VARCHAR       NOT NULL  DEFAULT 'MANUAL',
    correction_reason VARCHAR                 DEFAULT NULL,
    created_by        VARCHAR                 DEFAULT CURRENT_USER(),
    record_version    INTEGER       NOT NULL  DEFAULT 1

)
EXTERNAL_VOLUME = 'ICEBERG_EXTERNAL_VOL'
CATALOG         = 'SNOWFLAKE'
BASE_LOCATION   = 'nav_prices/'
COMMENT         = 'Bitemporal NAV price table — Iceberg format';

-- ---------------------------------------------------------------------------
-- AUXILIARY: Correction audit log
-- Tracks every correction event independently for compliance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE nav_correction_log (

    correction_id      VARCHAR       NOT NULL,   -- UUID
    fund_id            VARCHAR       NOT NULL,
    asset              VARCHAR       NOT NULL,
    original_price     NUMBER(18,4)  NOT NULL,
    corrected_price    NUMBER(18,4)  NOT NULL,
    valid_date         DATE          NOT NULL,
    correction_ts      TIMESTAMP_NTZ NOT NULL,
    corrected_by       VARCHAR       NOT NULL,
    reason             VARCHAR       NOT NULL,
    ticket_reference   VARCHAR

)
EXTERNAL_VOLUME = 'ICEBERG_EXTERNAL_VOL'
CATALOG         = 'SNOWFLAKE'
BASE_LOCATION   = 'nav_correction_log/'
COMMENT         = 'Immutable audit log of every NAV correction event';

-- ---------------------------------------------------------------------------
-- VIEW: Current NAV snapshot (system_to = 9999 means current belief)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_nav_current AS
SELECT
    fund_id,
    asset,
    price,
    units,
    valid_from,
    valid_to,
    system_from,
    source_feed,
    correction_reason,
    record_version
FROM nav_prices
WHERE system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ;

-- ---------------------------------------------------------------------------
-- VIEW: NAV summary per fund (current belief only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fund_nav_current AS
SELECT
    fund_id,
    valid_from                                   AS nav_date,
    SUM(price * units) / SUM(units)              AS nav_per_unit,
    SUM(price * units)                           AS aum,
    COUNT(DISTINCT asset)                        AS asset_count,
    MAX(system_from)                             AS last_updated
FROM nav_prices
WHERE system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
  AND valid_to   = '9999-12-31'::DATE
GROUP BY fund_id, valid_from;

SELECT 'Tables and views created successfully' AS status;
SHOW ICEBERG TABLES IN SCHEMA BITEMPORAL;
