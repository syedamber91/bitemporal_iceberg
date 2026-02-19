"""
snowflake_runner.py
───────────────────
Core module for connecting to Snowflake and executing SQL.

Used by:
  • demo_runner.py  (interactive classroom demo)
  • run_scripts.py  (batch execution of all SQL files)

Usage from Python:
  from snowflake_runner import SnowflakeRunner
  with SnowflakeRunner() as sf:
      sf.run_file("sql/02_bitemporal/01_create_tables.sql")
      results = sf.query("SELECT COUNT(*) FROM nav_prices")
"""

import os
import re
import time
from pathlib import Path
from typing import Optional, Union, Any

import snowflake.connector
from dotenv import load_dotenv
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.syntax import Syntax
from rich import box

load_dotenv()          # reads .env if present
console = Console()    # rich console for pretty output


# ─────────────────────────────────────────────────────────────────────────────
# Connection
# ─────────────────────────────────────────────────────────────────────────────

class SnowflakeRunner:
    """
    Thin wrapper around snowflake-connector-python.

    Handles:
      - Connection lifecycle (open / close / context manager)
      - Running a single SQL statement with pretty-printed results
      - Running a full .sql file (splits on ';', skips blank/comment lines)
      - Displaying results as a Rich table
    """

    def __init__(
        self,
        account:   Optional[str] = None,
        user:      Optional[str] = None,
        password:  Optional[str] = None,
        warehouse: Optional[str] = None,
        database:  Optional[str] = None,
        schema:    Optional[str] = None,
        role:      Optional[str] = None,
    ):
        # Prefer explicit args, fall back to environment variables
        self.account   = account   or os.environ["SNOWFLAKE_ACCOUNT"]
        self.user      = user      or os.environ["SNOWFLAKE_USER"]
        self.password  = password  or os.environ["SNOWFLAKE_PASSWORD"]
        self.warehouse = warehouse or os.getenv("SNOWFLAKE_WAREHOUSE", "ICEBERG_POC_WH")
        self.database  = database  or os.getenv("SNOWFLAKE_DATABASE",  "ICEBERG_NAV_DB")
        self.schema    = schema    or os.getenv("SNOWFLAKE_SCHEMA",     "BITEMPORAL")
        self.role      = role      or os.getenv("SNOWFLAKE_ROLE",       "SYSADMIN")
        self._conn     = None

    # ── connection lifecycle ──────────────────────────────────────────────────

    def connect(self) -> "SnowflakeRunner":
        console.print(f"\n[bold cyan]Connecting to Snowflake[/bold cyan] "
                      f"[dim]({self.account})[/dim]...")
        self._conn = snowflake.connector.connect(
            account=self.account,
            user=self.user,
            password=self.password,
            warehouse=self.warehouse,
            database=self.database,
            schema=self.schema,
            role=self.role,
            session_parameters={"QUERY_TAG": "ICEBERG_POC_DEMO"},
        )
        console.print("[bold green]✓ Connected[/bold green]\n")
        return self

    def close(self):
        if self._conn:
            self._conn.close()
            self._conn = None
            console.print("\n[dim]Connection closed.[/dim]")

    def __enter__(self):
        return self.connect()

    def __exit__(self, *_):
        self.close()

    # ── execution helpers ─────────────────────────────────────────────────────

    def _cursor(self):
        if not self._conn:
            raise RuntimeError("Not connected. Call connect() first.")
        return self._conn.cursor(snowflake.connector.DictCursor)

    def query(self, sql: str, silent: bool = False) -> list[dict]:
        """
        Execute a single SQL statement.
        Returns a list of dicts (one per row).
        Prints a formatted table unless silent=True.
        """
        sql = sql.strip()
        if not sql:
            return []

        start = time.perf_counter()
        with self._cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall() or []
            elapsed = time.perf_counter() - start

            if not silent:
                self._print_result(rows, elapsed)

        return rows

    def run_statement(self, sql: str, label: str = "", show_sql: bool = True) -> list[dict]:
        """
        Execute one statement with an optional label printed above it.
        show_sql=True prints the SQL before executing (useful in demos).
        """
        if label:
            console.print(Panel(label, style="bold yellow", expand=False))

        if show_sql and sql.strip():
            syntax = Syntax(sql.strip(), "sql", theme="monokai", word_wrap=True)
            console.print(syntax)
            console.print()

        return self.query(sql)

    def run_file(self, filepath: Union[str, Path], show_sql: bool = False) -> None:
        """
        Read a .sql file and execute each statement in sequence.
        Splits on ';' — handles multi-line statements correctly.
        Skips pure-comment blocks.
        """
        path = Path(filepath)
        console.print(f"\n[bold blue]▶  Running:[/bold blue] {path.name}")
        console.rule(style="blue")

        raw = path.read_text(encoding="utf-8")
        statements = _split_sql(raw)

        total = len(statements)
        for i, stmt in enumerate(statements, 1):
            preview = stmt.strip().splitlines()[0][:60]
            console.print(f"[dim]  [{i}/{total}] {preview}...[/dim]")
            try:
                self.query(stmt, silent=not show_sql)
            except Exception as exc:
                console.print(f"[bold red]  ✗ Error:[/bold red] {exc}\n")
                raise

        console.print(f"[bold green]✓ {path.name} complete[/bold green]\n")

    # ── pretty printing ───────────────────────────────────────────────────────

    def _print_result(self, rows: list[dict], elapsed: float):
        if not rows:
            console.print("[dim]  (no rows returned)[/dim]\n")
            return

        table = Table(box=box.SIMPLE_HEAVY, show_header=True,
                      header_style="bold magenta")

        # Build columns from first row keys
        for col in rows[0].keys():
            table.add_column(str(col), overflow="fold", max_width=50)

        for row in rows:
            table.add_row(*[str(v) if v is not None else "NULL" for v in row.values()])

        console.print(table)
        console.print(f"[dim]  {len(rows)} row(s)  ·  {elapsed:.2f}s[/dim]\n")


# ─────────────────────────────────────────────────────────────────────────────
# SQL file parsing
# ─────────────────────────────────────────────────────────────────────────────

def _split_sql(raw: str) -> list[str]:
    """
    Split a SQL file into individual runnable statements.

    Rules:
      - Split on ';' (statement terminator)
      - Ignore lines that are blank or start with '--'
      - Drop resulting empty / comment-only blocks
    """
    # Remove block comments /* ... */
    raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.DOTALL)

    statements = []
    for chunk in raw.split(";"):
        # Remove inline -- comments from each line
        lines = []
        for line in chunk.splitlines():
            stripped = line.strip()
            if stripped.startswith("--"):
                continue          # skip pure comment lines
            # strip trailing inline comments
            line = re.sub(r"--.*$", "", line)
            lines.append(line)

        stmt = "\n".join(lines).strip()
        if stmt:
            statements.append(stmt)

    return statements
