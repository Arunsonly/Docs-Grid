#!/usr/bin/env python3
"""Targeted mutation checks on the isolated CI checkout, never user data."""
import json
import subprocess
from pathlib import Path

SOURCE = Path("lib/features/tools/backup_folder_graph_validator.dart")
TESTS = ["test/backup_folder_graph_validator_test.dart", "test/quality_fault_fuzz_test.dart"]
MUTANTS = [
    ("missing_parent", "parentId != null && !parents.containsKey(parentId)", "false",
     "rejects missing parents"),
    ("duplicate_id", "parents.containsKey(id))", "false)",
     "rejects duplicate and empty IDs"),
    ("empty_id", "id.trim().isEmpty", "false",
     "rejects duplicate and empty IDs"),
    ("parent_order", "return List.unmodifiable(ordered);", "return List.unmodifiable(ordered.reversed);",
     "seeded folder graph fuzz"),
]

def execute():
    result = subprocess.run(["flutter", "test", "--machine", *TESTS],
                            capture_output=True, text=True, timeout=180)
    events = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
            if isinstance(event, dict):
                events.append(event)
        except json.JSONDecodeError:
            continue
    return result, events

def main():
    original = SOURCE.read_text()
    report = {"scope": "four targeted folder-validator mutants, not whole-repository mutation score",
              "mutants": []}
    out = Path("quality-reports/mutation.json")
    out.parent.mkdir(exist_ok=True)
    try:
        baseline, events = execute()
        if baseline.returncode != 0 or not any(e.get("type") == "done" and e.get("success") is True for e in events):
            raise RuntimeError("Baseline mutation test suite did not pass")
        problems = []
        for name, old, new, expected in MUTANTS:
            if original.count(old) != 1:
                problems.append("Ambiguous mutation anchor: " + name)
                report["mutants"].append({"name": name, "status": "BLOCKED"})
                continue
            SOURCE.write_text(original.replace(old, new, 1))
            try:
                result, events = execute()
            finally:
                SOURCE.write_text(original)
            test_names = {e["test"]["id"]: e["test"]["name"] for e in events
                          if e.get("type") == "testStart" and isinstance(e.get("test"), dict)}
            killed = (result.returncode != 0 and any(
                e.get("type") == "testDone" and e.get("result") in ("error", "failure")
                and expected in test_names.get(e.get("testID"), "")
                for e in events))
            report["mutants"].append({"name": name, "killed_by_expected_test": killed})
            if not killed:
                problems.append("Mutant survived or expected test evidence unavailable: " + name)
        if problems:
            raise RuntimeError("; ".join(problems))
        print("All four targeted mutants detected by their expected tests.")
    finally:
        SOURCE.write_text(original)
        out.write_text(json.dumps(report, indent=2) + "\n")

if __name__ == "__main__":
    main()
