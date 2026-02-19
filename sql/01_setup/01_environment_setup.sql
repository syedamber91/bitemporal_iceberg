-- =============================================================================
-- FILE: 01_environment_setup.sql
-- PURPOSE: Create warehouse, database, schema, and roles for the POC
-- RUN ORDER: 1 of 4 in the setup phase
-- ROLE REQUIRED: ACCOUNTADMIN or SYSADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- 1. WAREHOUSE
-- ---------------------------------------------------------------------------
-- A virtual warehouse provides compute. X-SMALL is sufficient for this POC.
CREATE WAREHOUSE IF NOT EXISTS ICEBERG_POC_WH
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND   = 60
    AUTO_RESUME    = TRUE
    COMMENT        = 'Warehouse for Iceberg bitemporal NAV POC';

-- ---------------------------------------------------------------------------
-- 2. DATABASE AND SCHEMA
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ICEBERG_NAV_DB
    COMMENT = 'Bitemporal NAV POC using Snowflake-managed Iceberg tables';

CREATE SCHEMA IF NOT EXISTS ICEBERG_NAV_DB.BITEMPORAL
    COMMENT = 'Holds Iceberg tables, views, and audit objects';

-- ---------------------------------------------------------------------------
-- 3. ROLE SETUP (optional but demonstrates real enterprise patterns)
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS ICEBERG_POC_ROLE;

GRANT USAGE  ON WAREHOUSE ICEBERG_POC_WH                TO ROLE ICEBERG_POC_ROLE;
GRANT USAGE  ON DATABASE  ICEBERG_NAV_DB                TO ROLE ICEBERG_POC_ROLE;
GRANT USAGE  ON SCHEMA    ICEBERG_NAV_DB.BITEMPORAL      TO ROLE ICEBERG_POC_ROLE;
GRANT ALL    ON SCHEMA    ICEBERG_NAV_DB.BITEMPORAL      TO ROLE ICEBERG_POC_ROLE;

-- Grant the role to the current user so you can switch to it
-- Replace YOUR_USERNAME with the output of: SELECT CURRENT_USER();
GRANT ROLE ICEBERG_POC_ROLE TO USER SYED0228;

-- ---------------------------------------------------------------------------
-- 4. USE context for all subsequent scripts
-- ---------------------------------------------------------------------------
USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

SELECT 'Environment setup complete' AS status;
