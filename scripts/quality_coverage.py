#!/usr/bin/env python3
"""Validate LCOV evidence and the initial regression inventory; no runtime imports."""
import argparse
import os
from pathlib import Path

REQUIRED_TESTS = (
    "test/smart_collection_selection_test.dart",
    "test/smart_collection_editor_contract_test.dart",
    "test/phone_storage_browser_screen_test.dart",
    "test/pdf_details_dialog_test.dart",
    "test/reminder_inbox_sheet_test.dart",
    "test/fresh_grid_database_test.dart",
    "test/grid_first_load_timeout_test.dart",
    "test/document_backup_restore_integration_test.dart",
    "test/backup_validation_test.dart",
    "test/zip_restore_regression_contract_test.dart",
    "test/durable_file_operations_test.dart",
    "test/grid_storage_boundary_test.dart",
    "test/ios_recovery_parity_contract_test.dart",
    "scripts/smoke_android_fresh_grid.py",
    "scripts/benchmark_android_cold_launch.py",
)

def coverage(text):
    # LCOV may contain multiple records per file. Merge by source and line.
    records = {}
    source = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            source = line[3:].strip().replace("\\", "/")
        elif line == "end_of_record":
            source = None
        elif line.startswith("DA:"):
            if not source:
                raise ValueError("DA outside source record")
            parts = line[3:].split(",")
            if len(parts) not in (2, 3):
                raise ValueError("Invalid DA record")
            number, hits = int(parts[0]), int(parts[1])
            if number < 1 or hits < 0:
                raise ValueError("Invalid line number or hit count")
            if source.startswith("lib/") or "/lib/" in source:
                key = (source, number)
                records[key] = max(hits, records.get(key, 0))
    total = len(records)
    hit = sum(value > 0 for value in records.values())
    if not total or not hit:
        raise ValueError("Missing or empty application coverage")
    return hit, total

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lcov", nargs="?", type=Path)
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    if args.inventory:
        missing = [p for p in REQUIRED_TESTS if not Path(p).is_file() or not Path(p).stat().st_size]
        if missing:
            raise SystemExit("Regression inventory missing: " + ", ".join(missing))
        print(f"{len(REQUIRED_TESTS)} regression files present; presence is not proof of full coverage.")
    else:
        if not args.lcov:
            parser.error("LCOV file is required")
        hit, total = coverage(args.lcov.read_text())
        report = f"Application line coverage: {hit}/{total} ({100 * hit / total:.2f}%). Measured lines only; no threshold yet."
        print(report)
        if os.getenv("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as out:
                out.write(report + "\n")

if __name__ == "__main__":
    main()
