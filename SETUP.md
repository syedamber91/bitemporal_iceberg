# Setup & Quick Start

## 1. Install Python dependencies

```bash
cd "Iceberg-Snowflake Demo"
pip install -r requirements.txt
```

## 2. Configure credentials

```bash
cp .env.example .env
```

Open `.env` and fill in your Snowflake details:

```
SNOWFLAKE_ACCOUNT=xy12345.us-east-1    # from Snowflake URL: https://<account>.snowflakecomputing.com
SNOWFLAKE_USER=your_username
SNOWFLAKE_PASSWORD=your_password
SNOWFLAKE_WAREHOUSE=ICEBERG_POC_WH
SNOWFLAKE_DATABASE=ICEBERG_NAV_DB
SNOWFLAKE_SCHEMA=BITEMPORAL
SNOWFLAKE_ROLE=SYSADMIN
```

**Finding your account identifier:**
In Snowsight go to Admin → Accounts. Copy the account identifier shown.
It looks like `xy12345` or `xy12345.us-east-1` depending on your region.

## 3. Run Snowflake setup (first time only)

Open `sql/01_setup/01_environment_setup.sql` in Snowsight and run it manually,
or use the batch runner:

```bash
python run_scripts.py --step setup
```

This creates the warehouse, database, schema, and role.

## 4. Build the full demo from scratch

```bash
python run_scripts.py --step bitemporal
```

This runs:
- `01_create_tables.sql` — creates the Iceberg table
- `02_initial_load.sql` — loads Day 1 prices (Jan 1–3)
- `03_correction_scenario.sql` — applies the Apple and Google corrections

## 5. Run the interactive classroom demo

```bash
python demo_runner.py
```

What happens:
- Each slide prints a plain-English explanation for students
- The SQL is shown with syntax highlighting
- Press **Enter** to run the SQL
- Results appear in a formatted table
- A "what to look for" note appears after results
- Press **Enter** again to advance

### Options

```bash
python demo_runner.py --list          # see all 12 slides
python demo_runner.py --slide 6       # jump to the correction scenario
python demo_runner.py --slide 10      # jump to time travel section
python demo_runner.py --auto          # auto-advance (for screen recording)
```

## 6. Run individual query files

```bash
python run_scripts.py --step queries     # analytical queries
python run_scripts.py --step metadata    # Iceberg metadata inspection
```

## 7. Student cheat sheet

Give students the file `sql/05_demo/demo_cheatsheet.sql`.
It contains 10 numbered queries they can paste directly into Snowsight.

---

## Slide overview

| # | Section | What it teaches |
|---|---------|----------------|
| 1 | Setup | What an Iceberg table is; CATALOG = 'SNOWFLAKE' |
| 2 | Initial Data | Bitemporal INSERT; valid/system time columns |
| 3 | Initial Data | NAV calculation; bitemporal WHERE clause |
| 4 | Iceberg Internals | Snapshot log; every write creates a commit |
| 5 | Iceberg Internals | Parquet data files; column statistics |
| 6 | The Correction | Close + re-insert pattern; nothing is deleted |
| 7 | Audit Queries | "What did we publish?" — system time query |
| 8 | Audit Queries | "What is correct today?" — current rows query |
| 9 | Audit Queries | NAV restatement report side by side |
| 10 | Time Travel | Snowflake AT (TIMESTAMP) syntax |
| 11 | Time Travel | Iceberg snapshot IDs; AT (VERSION) syntax |
| 12 | Wrap Up | Full audit trail; what we demonstrated |

---

## Troubleshooting

**`snowflake.connector` not found**
```bash
pip install snowflake-connector-python==3.12.3
```

**`250001 (08001): Failed to connect`**
Check your SNOWFLAKE_ACCOUNT value. Try with and without the region suffix.
Example: try both `xy12345` and `xy12345.us-east-1`.

**`INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS unknown function`**
This function is in preview. Contact Snowflake support to enable it,
or skip slides 4, 5, and 11 for now. All bitemporal queries still work.

**`Iceberg table requires Enterprise edition`**
If on Standard edition, use `CREATE TABLE` instead of `CREATE ICEBERG TABLE`
and remove `CATALOG = 'SNOWFLAKE'`. All SQL except the metadata inspection
queries will still work correctly.

**Permission denied on CREATE WAREHOUSE**
Run `01_environment_setup.sql` as ACCOUNTADMIN or ask your Snowflake admin
to create the warehouse and database for you, then use SYSADMIN for the rest.
