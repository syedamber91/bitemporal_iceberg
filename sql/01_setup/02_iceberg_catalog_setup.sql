-- =============================================================================
-- FILE: 02_iceberg_catalog_setup.sql
-- PURPOSE: Configure the Iceberg catalog (Snowflake-managed).
--
-- KEY CONCEPT — Two modes for Iceberg on Snowflake:
--   A) Snowflake as Iceberg catalog  → Snowflake writes metadata + Parquet to
--      an external S3/GCS/Azure stage. YOU control the storage.
--   B) Snowflake-managed tables      → Snowflake manages everything internally,
--      but still stores data in Iceberg format under the hood.
--
-- This POC uses MODE B (Snowflake-managed) because:
--   • No AWS/GCS account required
--   • All Iceberg metadata files are still real and inspectable via
--     system functions (SYSTEM$GET_ICEBERG_TABLE_INFORMATION, etc.)
--   • Identical SQL works against real external Iceberg catalogs
--
-- If you later want MODE A (external stage on S3), see the commented-out
-- block at the bottom — only the CREATE TABLE statement changes.
-- =============================================================================

USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

-- ---------------------------------------------------------------------------
-- OPTION A  (External stage / customer-managed S3)
-- Uncomment and fill in your bucket details if running against real S3.
-- ---------------------------------------------------------------------------
/*
-- Step 1: Create a storage integration (done once by ACCOUNTADMIN)
CREATE STORAGE INTEGRATION IF NOT EXISTS nav_s3_integration
    TYPE                      = EXTERNAL_STAGE
    STORAGE_PROVIDER          = 'S3'
    ENABLED                   = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('s3://your-bucket/iceberg-nav/');

-- After creation, run:
--   DESC INTEGRATION nav_s3_integration;
-- Copy the STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID values,
-- then add a trust policy to your S3 bucket IAM role to allow Snowflake.

-- Step 2: Create an external stage pointing to S3
CREATE STAGE IF NOT EXISTS nav_iceberg_stage
    URL                  = 's3://your-bucket/iceberg-nav/'
    STORAGE_INTEGRATION  = nav_s3_integration
    COMMENT              = 'Iceberg data files land here';

-- In CREATE TABLE (see 02_bitemporal/01_create_table.sql) you would use:
--   EXTERNAL_VOLUME = nav_iceberg_stage
--   BASE_LOCATION   = 'nav_prices/'
*/

-- ---------------------------------------------------------------------------
-- OPTION B  (Snowflake-managed — default for this POC, zero infra needed)
-- ---------------------------------------------------------------------------
-- Nothing extra to create here.
-- Snowflake-managed Iceberg tables are created directly with:
--   CREATE ICEBERG TABLE ... CATALOG = 'SNOWFLAKE'
-- Metadata is stored in Snowflake-managed storage but is fully Iceberg-spec.

SELECT 'Catalog setup complete — using Snowflake-managed Iceberg' AS status;
