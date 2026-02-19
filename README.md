# Bitemporal NAV Milestoning — Snowflake + Apache Iceberg POC

## What this project demonstrates

This codebase implements **bitemporal data modeling** for NAV (Net Asset Value)
corrections in a mutual fund system, using **Snowflake-managed Apache Iceberg
tables**.

Run the SQL files in order and you will see, from first principles:

- How the bitemporal pattern physically works
- How Iceberg stores metadata, manifests, and Parquet data files
- How to answer both audit questions ("what did we publish?" and "what is
  correct today?")
- How Snowflake time travel and Iceberg snapshot travel differ

---

## Project structure

```
sql/
  01_setup/
    01_environment_setup.sql       ← warehouse, database, schema, role
    02_iceberg_catalog_setup.sql   ← catalog options (managed vs external S3)
  02_bitemporal/
    01_create_tables.sql           ← Iceberg table + views
    02_initial_load.sql            ← Day 1 data (Jan 1-3 prices)
    03_correction_scenario.sql     ← Correction on Jan 5 (Apple) + Jan 7 (Google)
  03_queries/
    01_bitemporal_queries.sql      ← Core analytical queries
    02_time_travel_queries.sql     ← Snowflake AT/BEFORE + Iceberg snapshot
  04_metadata/
    01_iceberg_metadata_inspection.sql  ← Snapshots, manifests, data files
    02_metadata_file_structure.sql      ← What the files look like physically
```

---

## Run order

```
01_setup/01_environment_setup.sql
01_setup/02_iceberg_catalog_setup.sql    (read only — no changes needed)
02_bitemporal/01_create_tables.sql
02_bitemporal/02_initial_load.sql
    → inspect metadata here (04_metadata/01_iceberg_metadata_inspection.sql)
02_bitemporal/03_correction_scenario.sql
    → inspect metadata again (see new snapshots appear)
03_queries/01_bitemporal_queries.sql
03_queries/02_time_travel_queries.sql
04_metadata/01_iceberg_metadata_inspection.sql
04_metadata/02_metadata_file_structure.sql
```

---

## Iceberg on Snowflake — two modes

| Mode | Who owns storage | Files visible in S3? | SQL identical? |
|------|-----------------|---------------------|----------------|
| **Snowflake-managed** (this POC) | Snowflake | No — inspect via SQL functions | Yes |
| **External stage** (Option A) | You (your S3/GCS) | Yes — browse directly | Yes |

This POC uses **Snowflake-managed** so you need zero AWS credentials.
To switch to external S3, only the `CREATE ICEBERG TABLE` statement changes
(see comments in `01_create_tables.sql`).

---

## Iceberg physical file hierarchy

```
table_root/
├── metadata/
│   ├── v1.metadata.json          ← created at CREATE TABLE
│   ├── v2.metadata.json          ← after first INSERT (initial load)
│   ├── v3.metadata.json          ← after UPDATE (close Apple row)
│   ├── v4.metadata.json          ← after INSERT (corrected Apple)
│   ├── v5.metadata.json          ← after UPDATE (close Google row)
│   ├── v6.metadata.json          ← after INSERT (corrected Google)
│   ├── snap-<id1>-1.avro         ← manifest LIST for snapshot 1
│   ├── snap-<id2>-1.avro         ← manifest LIST for snapshot 2
│   └── <uuid>.avro               ← manifest FILE (lists Parquet files)
└── data/
    ├── <uuid-initial>.parquet    ← initial 11-row load
    ├── <uuid-correction>.parquet ← 1-row Apple correction
    └── <uuid-google>.parquet     ← 1-row Google correction
```

### How to see these files

**Snowflake-managed** (this POC):

```sql
-- Current table metadata JSON
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('ICEBERG_NAV_DB.BITEMPORAL.NAV_PRICES');

-- Snapshot log (one row per DML operation)
SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
    'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'));

-- Manifest files
SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_MANIFESTS(
    'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'));

-- Parquet data files with column statistics
SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(
    'NAV_PRICES', 'BITEMPORAL', 'ICEBERG_NAV_DB'));
```

**External S3** (Option A — requires storage integration):

```bash
# List all metadata files
aws s3 ls s3://your-bucket/iceberg-nav/nav_prices/metadata/ --recursive

# Read a metadata file (JSON, human-readable)
aws s3 cp s3://your-bucket/iceberg-nav/nav_prices/metadata/v2.metadata.json -

# List Parquet data files
aws s3 ls s3://your-bucket/iceberg-nav/nav_prices/data/ --recursive
```

---

## The bitemporal pattern at a glance

```
VALID TIME axis  →  When the fact is true in the real world
SYSTEM TIME axis →  When the system believed the fact

Every row has 4 time columns:
  valid_from  | valid_to   — business truth window
  system_from | system_to  — system belief window

Current rows:  system_to  = '9999-12-31'
Closed rows:   system_to  < '9999-12-31'  (never deleted, preserved forever)
```

### Correction lifecycle

```
2024-01-01 09:00  INSERT Apple price = 100  (system_to = 9999)
                  Row state: CURRENT, price=100

2024-01-05 10:00  STEP 1: UPDATE system_to = '2024-01-05 10:00'
                  Row state: SUPERSEDED (still exists, now closed)

                  STEP 2: INSERT Apple price = 120  (system_to = 9999)
                  Row state: CURRENT, price=120

Result: two rows exist for the same valid_from=2024-01-01
  Row 1: price=100, system_from=Jan1, system_to=Jan5  → what we published
  Row 2: price=120, system_from=Jan5, system_to=9999  → what is correct today
```

---

## Key analytical queries (summary)

| Question | Filter |
|----------|--------|
| What NAV did we publish on Jan 2? | `system_from <= Jan2 AND system_to > Jan2` |
| What is the correct NAV for Jan 1 today? | `system_to = 9999` |
| Full audit trail for an asset | No system_to filter, ORDER BY system_from |
| Restatement comparison | JOIN original vs corrected CTE |

See `03_queries/01_bitemporal_queries.sql` for full implementations.

---

## Time travel comparison

| Feature | Scope | Syntax | Retention |
|---------|-------|--------|-----------|
| Bitemporal SQL | Any date in our data | `system_from <= X AND system_to > X` | Forever (our own rows) |
| Snowflake native | Physical table state | `AT (TIMESTAMP => ts)` | 1–90 days |
| Iceberg snapshot | Specific commit | `AT (VERSION => snapshot_id)` | Until `EXPIRE SNAPSHOTS` |

---

## Iceberg metadata concepts

| File type | Format | Purpose |
|-----------|--------|---------|
| `metadata.json` | JSON | Table schema, partition specs, current snapshot pointer |
| Manifest list (`.avro`) | Avro | List of manifest files in a snapshot |
| Manifest file (`.avro`) | Avro | List of data files + column statistics |
| Data file (`.parquet`) | Parquet | Actual row data, columnar compressed |

The **metadata.json → manifest list → manifest file → parquet** chain is what
makes Iceberg's time travel, schema evolution, and partition pruning possible
without scanning all data.

---

## Requirements

- Snowflake account (Standard or Enterprise)
- Role with `SYSADMIN` or `ACCOUNTADMIN` privileges (for initial setup only)
- Snowflake CLI or Snowsight worksheet
- No AWS account needed for the Snowflake-managed mode
