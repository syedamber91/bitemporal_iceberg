"""
demo_runner.py
──────────────
Interactive classroom demo runner.

Each "slide" consists of:
  - A title
  - A plain-English explanation for students (printed BEFORE the SQL runs)
  - The SQL to execute
  - An optional "what to look for" note printed AFTER results

Run it:
    python demo_runner.py                     # full demo, step by step
    python demo_runner.py --slide 3           # jump to a specific slide
    python demo_runner.py --list              # list all slides
    python demo_runner.py --auto              # run without waiting for Enter
"""

import argparse
import time
from dataclasses import dataclass, field
from typing import Optional

from rich.console import Console
from rich.panel import Panel
from rich.rule import Rule
from rich.syntax import Syntax
from rich.text import Text
from rich import box
from rich.table import Table

from snowflake_runner import SnowflakeRunner

console = Console()


# ─────────────────────────────────────────────────────────────────────────────
# Slide definition
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class Slide:
    number:      int
    title:       str
    explain:     str          # plain-English, shown BEFORE SQL
    sql:         str          # SQL to run
    takeaway:    str = ""     # "what to look for", shown AFTER results
    section:     str = ""     # groups slides visually


# ─────────────────────────────────────────────────────────────────────────────
# All demo slides — ordered for classroom walkthrough
# ─────────────────────────────────────────────────────────────────────────────

SLIDES: list[Slide] = [

    # ── SECTION 1: Setup ──────────────────────────────────────────────────────

    Slide(
        number=1,
        section="SETUP",
        title="Create the Iceberg Table",
        explain="""\
What is an Iceberg table?
  Think of a normal database table — but instead of storing data inside the
  database engine, it stores data as open Parquet files (like Excel sheets,
  but binary and compressed).

  Iceberg is the FORMAT LAYER on top of those files. It provides:
    • A schema  (column names and types)
    • A history (every change is recorded, nothing is overwritten)
    • Statistics (so queries only read the files they need)

  When we say CATALOG = 'SNOWFLAKE', we are telling Snowflake:
  "You manage the Iceberg metadata for us."

What you will see:
  The table is created with 12 columns — 4 of them are our time columns
  (valid_from, valid_to, system_from, system_to). These are the heart of
  bitemporal modeling.\
""",
        sql="""\
USE WAREHOUSE ICEBERG_POC_WH;
USE DATABASE  ICEBERG_NAV_DB;
USE SCHEMA    BITEMPORAL;

CREATE OR REPLACE ICEBERG TABLE nav_prices (
    fund_id           VARCHAR(20)   NOT NULL,
    asset             VARCHAR(50)   NOT NULL,
    price             NUMBER(18, 4) NOT NULL,
    units             NUMBER(18, 4) NOT NULL DEFAULT 100,
    valid_from        DATE          NOT NULL,
    valid_to          DATE          NOT NULL DEFAULT '9999-12-31',
    system_from       TIMESTAMP_NTZ NOT NULL,
    system_to         TIMESTAMP_NTZ NOT NULL DEFAULT '9999-12-31 00:00:00',
    source_feed       VARCHAR(50)   NOT NULL DEFAULT 'MANUAL',
    correction_reason VARCHAR(255)           DEFAULT NULL,
    created_by        VARCHAR(100)           DEFAULT CURRENT_USER(),
    record_version    INTEGER       NOT NULL DEFAULT 1
)
CATALOG = 'SNOWFLAKE';

SHOW ICEBERG TABLES IN SCHEMA BITEMPORAL;\
""",
        takeaway="""\
✓ Notice "ICEBERG" in the table type column — this is not a regular table.
✓ valid_to = '9999-12-31' is a common sentinel meaning "this record is still active".
✓ system_to = '9999-12-31' means "the system currently believes this row is true".\
""",
    ),

    # ── SECTION 2: Initial Load ───────────────────────────────────────────────

    Slide(
        number=2,
        section="INITIAL DATA",
        title="Day 1 — Load original prices (Jan 1, 2024)",
        explain="""\
Scenario:
  It is January 1, 2024. The fund manager receives end-of-day prices
  from Bloomberg at 9:00 AM.

  FUND1 holds three assets: Apple (₹100), Google (₹100), Microsoft (₹150).

  We insert these as fresh rows with:
    valid_from  = 2024-01-01  (the price is true from Jan 1)
    valid_to    = 9999-12-31  (we don't know when it stops being true yet)
    system_from = 2024-01-01 09:00  (we received this data at 9 AM)
    system_to   = 9999-12-31       (this is our current belief)

Key insight:
  system_to = 9999 is our way of saying "this is what we believe RIGHT NOW".
  We never delete or overwrite. We only ever ADD new rows.\
""",
        sql="""\
INSERT INTO nav_prices
    (fund_id, asset, price, units, valid_from, valid_to,
     system_from, system_to, source_feed, record_version)
VALUES
    ('FUND1','APPLE',  100, 100, '2024-01-01','9999-12-31',
     '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
     'BLOOMBERG', 1),
    ('FUND1','GOOGLE', 100, 100, '2024-01-01','9999-12-31',
     '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
     'BLOOMBERG', 1),
    ('FUND1','MSFT',   150, 100, '2024-01-01','9999-12-31',
     '2024-01-01 09:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
     'BLOOMBERG', 1);

SELECT fund_id, asset, price, valid_from, system_from, system_to
FROM   nav_prices
ORDER  BY asset;\
""",
        takeaway="""\
✓ All 3 rows have system_to = 9999 — these are the "current" rows.
✓ All 3 rows have valid_from = 2024-01-01 — same real-world date.
✓ We have 3 rows in the table. No deletes will ever happen.\
""",
    ),

    Slide(
        number=3,
        section="INITIAL DATA",
        title="Calculate NAV — Day 1",
        explain="""\
NAV = Net Asset Value per unit.

  Formula:
    NAV = Total value of all assets ÷ Number of units

  For FUND1 on Jan 1:
    Apple  = 100 × 100 units = 10,000
    Google = 100 × 100 units = 10,000
    MSFT   = 150 × 100 units = 15,000
    ─────────────────────────────────
    Total  = 35,000 ÷ 300 units = ₹116.67 per unit

  The WHERE clause below says:
    "Give me prices that were valid ON Jan 1"          (valid_from / valid_to)
    "AND that the system believed AS OF Jan 1"         (system_from / system_to)

  Both conditions together = bitemporal point-in-time query.\
""",
        sql="""\
SELECT
    fund_id,
    '2024-01-01'                                  AS nav_date,
    SUM(price * units)                            AS total_aum,
    SUM(units)                                    AS total_units,
    ROUND(SUM(price * units) / SUM(units), 4)     AS nav_per_unit
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from <= '2024-01-01'
  AND valid_to   >= '2024-01-01'
  AND system_from <= '2024-01-01 23:59:59'::TIMESTAMP_NTZ
  AND system_to   > '2024-01-01 23:59:59'::TIMESTAMP_NTZ
GROUP BY fund_id;\
""",
        takeaway="""\
✓ NAV = ₹116.67 per unit. This is what was PUBLISHED on Jan 1.
✓ This query will always return 116.67, even after future corrections.
   That is the power of bitemporal — the past is never destroyed.\
""",
    ),

    # ── SECTION 3: Iceberg Metadata (before correction) ───────────────────────

    Slide(
        number=4,
        section="ICEBERG INTERNALS",
        title="Peek inside Iceberg — Snapshot after initial load",
        explain="""\
Every time you write to an Iceberg table, it creates a new SNAPSHOT.
A snapshot is like a photograph of the table at that moment.

Iceberg stores snapshots in metadata files (.json and .avro) on storage.
This is called the "commit log" — it cannot be altered.

Think of it like Git commits:
  Commit 1 = CREATE TABLE
  Commit 2 = INSERT (our 3 rows)

The query below reads Snowflake's INFORMATION_SCHEMA to show us
the snapshot log. Each row is one snapshot.\
""",
        sql="""\
SELECT
    snapshot_id,
    committed_at,
    operation,
    PARSE_JSON(summary)['added-records']::INT   AS rows_added,
    PARSE_JSON(summary)['total-records']::INT   AS total_rows_in_snapshot,
    manifest_list
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY committed_at;\
""",
        takeaway="""\
✓ You should see 2 snapshots: one for CREATE TABLE, one for the INSERT.
✓ 'manifest_list' is the path to an .avro file that lists all data files.
✓ 'added-records' = 3 for the INSERT snapshot.
✓ NOTHING was deleted. Iceberg only appends.\
""",
    ),

    Slide(
        number=5,
        section="ICEBERG INTERNALS",
        title="Peek inside Iceberg — The actual data files (Parquet)",
        explain="""\
Below the snapshot layer, Iceberg tracks individual Parquet files.
Each Parquet file is a column-oriented compressed data file.

What makes Iceberg smart is that each file entry in the manifest
carries column-level STATISTICS:
  - lower_bounds: the minimum value of each column in this file
  - upper_bounds: the maximum value of each column in this file

When you run a WHERE clause like "WHERE fund_id = 'FUND1'",
Snowflake checks these bounds BEFORE reading the file.
If fund_id bounds don't match, the file is SKIPPED entirely.
This is called "predicate pushdown" or "file pruning".\
""",
        sql="""\
SELECT
    file_path,
    file_format,
    record_count,
    file_size_bytes,
    CASE content
        WHEN 0 THEN 'DATA FILE'
        WHEN 1 THEN 'POSITION DELETES'
        WHEN 2 THEN 'EQUALITY DELETES'
    END AS file_content_type
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY record_count DESC;\
""",
        takeaway="""\
✓ file_content_type = 'DATA FILE' means this is a real Parquet data file.
✓ record_count shows how many rows are in each file.
✓ The file_path shows the full storage location of the Parquet file.
✓ After our INSERT we have exactly 1 data file with 3 records.\
""",
    ),

    # ── SECTION 4: The Correction ─────────────────────────────────────────────

    Slide(
        number=6,
        section="THE CORRECTION",
        title="Jan 5 — Problem discovered: Apple price was wrong!",
        explain="""\
It is January 5, 2024. The risk team calls and says:

  "The Apple price we received on Jan 1 was wrong.
   Bloomberg had a system error. The correct price was ₹120, not ₹100."

In a traditional database, someone would just UPDATE the row:
  UPDATE nav_prices SET price = 120 WHERE asset = 'APPLE'

THE PROBLEM: That destroys history. You can never go back and ask
  "What did we publish to clients on Jan 1?"

THE BITEMPORAL SOLUTION — Two steps:
  Step 1: CLOSE the old row — stamp system_to with RIGHT NOW
  Step 2: INSERT a new row with the corrected price

The old row still exists! It just has a system_to that is no longer 9999.\
""",
        sql="""\
-- ── STEP 1: Close the stale row ─────────────────────────────────────────────
-- We stamp system_to with the exact moment the correction was applied.
-- This row is now a "closed" historical belief — it still exists on disk.
UPDATE nav_prices
SET    system_to = '2024-01-05 10:00:00'::TIMESTAMP_NTZ
WHERE  fund_id    = 'FUND1'
  AND  asset      = 'APPLE'
  AND  valid_from = '2024-01-01'
  AND  system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ;

-- ── STEP 2: Insert the corrected row ─────────────────────────────────────────
-- valid_from is STILL 2024-01-01 — the real-world date hasn't changed.
-- system_from is NOW 2024-01-05 — this is when we learned the true price.
INSERT INTO nav_prices
    (fund_id, asset, price, units, valid_from, valid_to,
     system_from, system_to, source_feed, correction_reason, record_version)
VALUES
    ('FUND1','APPLE', 120, 100, '2024-01-01','9999-12-31',
     '2024-01-05 10:00:00'::TIMESTAMP_NTZ, '9999-12-31 00:00:00'::TIMESTAMP_NTZ,
     'BLOOMBERG_CORRECTION',
     'Price feed error: vendor supplied wrong closing price',
     2);

-- ── See the result ────────────────────────────────────────────────────────────
SELECT
    asset,
    price,
    system_from::DATE    AS believed_from,
    system_to::DATE      AS believed_until,
    record_version,
    CASE WHEN system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
         THEN '>>> CURRENT' ELSE '    HISTORY' END AS status
FROM nav_prices
WHERE fund_id = 'FUND1' AND asset = 'APPLE'
ORDER BY system_from;\
""",
        takeaway="""\
✓ You now see TWO rows for Apple / 2024-01-01.
✓ Row 1 (price=100): believed_from=Jan1, believed_until=Jan5 — the OLD belief.
✓ Row 2 (price=120): believed_from=Jan5, believed_until=9999 — the CURRENT belief.
✓ Neither row was deleted. The full truth is preserved forever.\
""",
    ),

    # ── SECTION 5: The Two Audit Queries ─────────────────────────────────────

    Slide(
        number=7,
        section="AUDIT QUERIES",
        title='Audit Query 1 — "What did we PUBLISH on Jan 2?"',
        explain="""\
Imagine a client calls on Feb 1 and says:
  "Your Jan 2 statement shows NAV = ₹116.67. I disagree."

You need to reproduce EXACTLY what the system believed on Jan 2.
On Jan 2, the correction hadn't happened yet. Apple was still ₹100.

The query uses system_from / system_to to travel back to Jan 2's beliefs.

Read the WHERE clause out loud:
  "Prices that were valid on Jan 1"
  AND "the system believed them as of Jan 2 close of business"\
""",
        sql="""\
SELECT
    fund_id,
    '2024-01-01'                                  AS for_nav_date,
    '2024-01-02'                                  AS as_believed_on,
    asset,
    price
FROM nav_prices
WHERE fund_id    = 'FUND1'
  AND valid_from <= '2024-01-01'
  AND valid_to   >= '2024-01-01'
  AND system_from <= '2024-01-02 23:59:59'::TIMESTAMP_NTZ
  AND system_to   > '2024-01-02 23:59:59'::TIMESTAMP_NTZ
ORDER BY asset;\
""",
        takeaway="""\
✓ Apple = ₹100.  Google = ₹100.  MSFT = ₹150.
✓ This is the ORIGINAL state. The correction on Jan 5 is invisible here.
✓ Auditors can reproduce this at any time, years from now.\
""",
    ),

    Slide(
        number=8,
        section="AUDIT QUERIES",
        title='Audit Query 2 — "What is CORRECT for Jan 1 today?"',
        explain="""\
Now the same auditor asks:
  "OK, but what is the correct NAV for Jan 1 after all corrections?"

For this, we want only the CURRENT rows — system_to = 9999.
These represent our best knowledge TODAY.

After the correction:
  Apple = ₹120 (corrected)
  Google = ₹100 (not corrected)
  MSFT = ₹150 (not corrected)

New NAV = (120 + 100 + 150) × 100 units ÷ 300 = ₹123.33\
""",
        sql="""\
SELECT
    fund_id,
    '2024-01-01'                                  AS for_nav_date,
    'TODAY'                                       AS as_believed_on,
    asset,
    price
FROM nav_prices
WHERE fund_id   = 'FUND1'
  AND valid_from <= '2024-01-01'
  AND valid_to   >= '2024-01-01'
  AND system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
ORDER BY asset;\
""",
        takeaway="""\
✓ Apple = ₹120 now (corrected).  Google and MSFT unchanged.
✓ This is the RESTATED NAV — what we tell the auditor is correct.
✓ The published NAV (slide 7) and restated NAV (this slide) both exist.
   A traditional DB can only answer ONE of these questions.\
""",
    ),

    Slide(
        number=9,
        section="AUDIT QUERIES",
        title="NAV Restatement — Side by side comparison",
        explain="""\
This is the query regulators love to see.
It shows BOTH the original published NAV and the corrected NAV
for the same date, in one result.

This is called a "restatement report" and is required by SEBI and
other regulators when mutual fund NAVs are corrected after publication.\
""",
        sql="""\
WITH original_nav AS (
    SELECT
        fund_id,
        ROUND(SUM(price * units) / SUM(units), 4) AS nav_published
    FROM nav_prices
    WHERE fund_id    = 'FUND1'
      AND valid_from <= '2024-01-01'
      AND valid_to   >= '2024-01-01'
      AND system_from <= '2024-01-02 23:59:59'::TIMESTAMP_NTZ
      AND system_to   > '2024-01-02 23:59:59'::TIMESTAMP_NTZ
    GROUP BY fund_id
),
corrected_nav AS (
    SELECT
        fund_id,
        ROUND(SUM(price * units) / SUM(units), 4) AS nav_restated
    FROM nav_prices
    WHERE fund_id   = 'FUND1'
      AND valid_from <= '2024-01-01'
      AND valid_to   >= '2024-01-01'
      AND system_to  = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
    GROUP BY fund_id
)
SELECT
    o.fund_id,
    '2024-01-01'                                      AS nav_date,
    o.nav_published                                   AS original_nav,
    c.nav_restated                                    AS corrected_nav,
    ROUND(c.nav_restated - o.nav_published, 4)        AS difference,
    ROUND((c.nav_restated/o.nav_published - 1)*100,2) AS pct_change
FROM original_nav o JOIN corrected_nav c USING (fund_id);\
""",
        takeaway="""\
✓ The difference column shows exactly how much the NAV was understated.
✓ Both numbers came from the SAME table — no backup needed.
✓ This is regulatory-grade audit capability built into the data model.\
""",
    ),

    # ── SECTION 6: Snowflake Time Travel ─────────────────────────────────────

    Slide(
        number=10,
        section="TIME TRAVEL",
        title="Snowflake Time Travel — Query the table as it was before correction",
        explain="""\
Snowflake has its own time travel LAYER on top of Iceberg.
This is DIFFERENT from our bitemporal columns.

Snowflake time travel goes back to the PHYSICAL state of the table.
Before our Jan 5 UPDATE, the table had Apple = 100 as an active row.
After the UPDATE, Apple = 100 is "superseded" in our bitemporal logic.

With AT (TIMESTAMP => ...), Snowflake shows us the raw table
exactly as it existed at that timestamp — including all physical rows.

Two flavours:
  AT (TIMESTAMP => ts)    — go to this exact moment
  AT (OFFSET    => -3600) — go back N seconds from now\
""",
        sql="""\
-- Query the table as it physically existed just before the correction
SELECT
    fund_id,
    asset,
    price,
    system_from,
    system_to
FROM nav_prices AT (TIMESTAMP => '2024-01-04 23:59:00'::TIMESTAMP_NTZ)
WHERE fund_id = 'FUND1'
ORDER BY asset;\
""",
        takeaway="""\
✓ You see Apple = 100 with system_to = 9999. That is the pre-correction state.
✓ The AT clause works at the storage / snapshot level — not our bitemporal columns.
✓ Bitemporal + Snowflake time travel together give you TWO independent
   ways to go back in time. Both complement each other.\
""",
    ),

    Slide(
        number=11,
        section="TIME TRAVEL",
        title="Iceberg Snapshot History — The commit log",
        explain="""\
Every write to an Iceberg table creates a permanent SNAPSHOT.
This is like a Git commit history for your data.

Each snapshot has:
  - snapshot_id  : unique ID (large integer)
  - operation    : 'append' (INSERT) or 'overwrite' (UPDATE/DELETE)
  - committed_at : when it was written
  - added-records / deleted-records in the summary

After our demo so far, we should have snapshots for:
  1. CREATE TABLE
  2. INSERT (initial 3 rows)
  3. UPDATE (stamp system_to on Apple row)
  4. INSERT (corrected Apple row)

You can query any snapshot individually:
  SELECT * FROM nav_prices AT (VERSION => <snapshot_id>)\
""",
        sql="""\
SELECT
    snapshot_id,
    committed_at,
    operation,
    PARSE_JSON(summary)['added-records']::INT     AS rows_added,
    PARSE_JSON(summary)['deleted-records']::INT   AS rows_removed,
    PARSE_JSON(summary)['total-records']::INT     AS total_rows
FROM TABLE(
    INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
        TABLE_NAME    => 'NAV_PRICES',
        TABLE_SCHEMA  => 'BITEMPORAL',
        TABLE_CATALOG => 'ICEBERG_NAV_DB'
    )
)
ORDER BY committed_at;\
""",
        takeaway="""\
✓ Count the snapshots — one per DML operation. This is the immutable commit log.
✓ 'overwrite' = Snowflake rewrote a file to apply the UPDATE (copy-on-write).
✓ 'append' = new Parquet file added, old file untouched.
✓ Copy the snapshot_id of an early snapshot, then run:
   SELECT * FROM nav_prices AT (VERSION => <id>)
   to see the table exactly as it was at that commit.\
""",
    ),

    # ── SECTION 7: Architecture summary ──────────────────────────────────────

    Slide(
        number=12,
        section="WRAP UP",
        title="Final state — Full audit trail for all assets",
        explain="""\
This final query shows the complete bitemporal history for all assets.
Every row that ever existed is shown, with its "belief window".

This is what an auditor or regulator receives when they ask:
  "Show me the complete history of all price data for FUND1 on Jan 1."

Key columns to explain:
  believed_from  — when THIS version of the price entered the system
  believed_until — when THIS version was superseded (or 9999 if current)
  status         — CURRENT (system still believes this) or HISTORY (superseded)\
""",
        sql="""\
SELECT
    asset,
    price,
    valid_from,
    system_from::DATE                 AS believed_from,
    system_to::DATE                   AS believed_until,
    record_version                    AS version,
    COALESCE(correction_reason,
             'Original entry')        AS reason,
    CASE WHEN system_to = '9999-12-31 00:00:00'::TIMESTAMP_NTZ
         THEN '✓ CURRENT' ELSE '  HISTORY' END AS status
FROM nav_prices
WHERE fund_id   = 'FUND1'
  AND valid_from = '2024-01-01'
ORDER BY asset, system_from;\
""",
        takeaway="""\
✓ Apple has 2 rows — history (100) and current (120). Correction visible.
✓ Google and MSFT each have 1 row — no corrections yet.
✓ This is a COMPLETE, IMMUTABLE audit trail. Nothing was deleted or overwritten.

SUMMARY OF WHAT WE DEMONSTRATED:
  1. Iceberg tables store data as Parquet files with a metadata commit log
  2. Bitemporal modeling adds valid_time + system_time dimensions
  3. Corrections CLOSE old rows and INSERT new ones — never UPDATE in place
  4. We can answer: "What did we publish?" AND "What is correct today?"
  5. Snowflake time travel + Iceberg snapshots give two more ways to go back
  6. All metadata (snapshots, manifests, files) is queryable via SQL\
""",
    ),
]


# ─────────────────────────────────────────────────────────────────────────────
# Rendering helpers
# ─────────────────────────────────────────────────────────────────────────────

def print_slide_header(slide: Slide, total: int):
    section_tag = f"[bold white on blue]  {slide.section}  [/]  " if slide.section else ""
    console.print()
    console.rule(style="dim")
    console.print(
        f"\n{section_tag}"
        f"[bold yellow]SLIDE {slide.number}/{total}[/bold yellow]  "
        f"[bold white]{slide.title}[/bold white]\n"
    )


def print_explanation(text: str):
    console.print(Panel(
        Text(text),
        title="[bold cyan]What this means[/bold cyan]",
        border_style="cyan",
        padding=(1, 2),
    ))
    console.print()


def print_sql(sql: str):
    console.print("[bold magenta]SQL:[/bold magenta]")
    console.print(Syntax(sql.strip(), "sql", theme="monokai",
                         line_numbers=True, word_wrap=True))
    console.print()


def print_takeaway(text: str):
    if text:
        console.print(Panel(
            Text(text),
            title="[bold green]What to look for[/bold green]",
            border_style="green",
            padding=(1, 2),
        ))
    console.print()


def wait_for_enter(auto: bool):
    if not auto:
        console.print("[dim]Press Enter to run this SQL...[/dim]", end="")
        input()
    else:
        time.sleep(0.5)


def wait_for_next(auto: bool):
    if not auto:
        console.print("[dim]Press Enter for next slide (or Ctrl+C to quit)...[/dim]", end="")
        input()
    else:
        time.sleep(1.5)


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def list_slides():
    table = Table(box=box.SIMPLE, show_header=True, header_style="bold magenta")
    table.add_column("#",       style="bold yellow", width=4)
    table.add_column("Section", style="cyan",        width=20)
    table.add_column("Title",   style="white")
    for s in SLIDES:
        table.add_row(str(s.number), s.section, s.title)
    console.print(table)


def run_demo(start_slide: int = 1, auto: bool = False):
    slides_to_run = [s for s in SLIDES if s.number >= start_slide]
    total = len(SLIDES)

    console.print(Panel(
        "[bold]Iceberg Bitemporal NAV — Classroom Demo[/bold]\n"
        f"Starting from slide {start_slide}  •  {len(slides_to_run)} slides to run\n"
        "[dim]Ctrl+C at any time to stop[/dim]",
        expand=False,
        border_style="yellow",
    ))

    if not auto:
        console.print("[dim]Press Enter to begin...[/dim]", end="")
        input()

    with SnowflakeRunner() as sf:
        for slide in slides_to_run:
            try:
                print_slide_header(slide, total)
                print_explanation(slide.explain)
                print_sql(slide.sql)
                wait_for_enter(auto)

                # Execute — split on ; to handle multi-statement slides
                from snowflake_runner import _split_sql
                statements = _split_sql(slide.sql)
                for stmt in statements:
                    sf.query(stmt)

                print_takeaway(slide.takeaway)
                wait_for_next(auto)

            except KeyboardInterrupt:
                console.print("\n[yellow]Demo paused.[/yellow]")
                break

    console.print(Panel("[bold green]Demo complete![/bold green]", expand=False))


def main():
    parser = argparse.ArgumentParser(description="Iceberg NAV classroom demo")
    parser.add_argument("--slide", type=int, default=1,
                        help="Start from this slide number")
    parser.add_argument("--list",  action="store_true",
                        help="List all slides and exit")
    parser.add_argument("--auto",  action="store_true",
                        help="Run without waiting for Enter (for screen recording)")
    args = parser.parse_args()

    if args.list:
        list_slides()
        return

    run_demo(start_slide=args.slide, auto=args.auto)


if __name__ == "__main__":
    main()
