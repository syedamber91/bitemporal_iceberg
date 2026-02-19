"""
run_scripts.py
──────────────
Batch runner — executes all SQL files in the correct order.
Use this to set up the full POC from scratch on a fresh Snowflake account.

    python run_scripts.py                  # run everything
    python run_scripts.py --step setup     # only environment + catalog setup
    python run_scripts.py --step bitemporal
    python run_scripts.py --step queries
    python run_scripts.py --step metadata
"""

import argparse
import sys
from pathlib import Path

from snowflake_runner import SnowflakeRunner
from rich.console import Console
from rich.panel import Panel
from rich.rule import Rule

console = Console()

# ─────────────────────────────────────────────────────────────────────────────
# Script groups — run in this exact order
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_GROUPS = {
    "setup": [
        "sql/01_setup/01_environment_setup.sql",
        "sql/01_setup/02_iceberg_catalog_setup.sql",
    ],
    "bitemporal": [
        "sql/02_bitemporal/01_create_tables.sql",
        "sql/02_bitemporal/02_initial_load.sql",
        "sql/02_bitemporal/03_correction_scenario.sql",
    ],
    "queries": [
        "sql/03_queries/01_bitemporal_queries.sql",
        "sql/03_queries/02_time_travel_queries.sql",
    ],
    "metadata": [
        "sql/04_metadata/01_iceberg_metadata_inspection.sql",
        "sql/04_metadata/02_metadata_file_structure.sql",
    ],
}

ALL_GROUPS = ["setup", "bitemporal", "queries", "metadata"]


def run_group(runner: SnowflakeRunner, group: str):
    console.print(Rule(f"[bold yellow]GROUP: {group.upper()}[/bold yellow]"))
    for script in SCRIPT_GROUPS[group]:
        path = Path(script)
        if not path.exists():
            console.print(f"[red]File not found: {script}[/red]")
            sys.exit(1)
        runner.run_file(path)


def main():
    parser = argparse.ArgumentParser(
        description="Batch SQL runner for Iceberg NAV POC"
    )
    parser.add_argument(
        "--step",
        choices=list(SCRIPT_GROUPS.keys()) + ["all"],
        default="all",
        help="Which group of scripts to run (default: all)",
    )
    args = parser.parse_args()

    groups = ALL_GROUPS if args.step == "all" else [args.step]

    console.print(Panel(
        "[bold]Iceberg Bitemporal NAV — Batch SQL Runner[/bold]\n"
        f"Running groups: [cyan]{', '.join(groups)}[/cyan]",
        expand=False,
    ))

    with SnowflakeRunner() as sf:
        for group in groups:
            run_group(sf, group)

    console.print(Panel("[bold green]All scripts completed successfully![/bold green]",
                        expand=False))


if __name__ == "__main__":
    main()
