#!/usr/bin/env python3
"""Matched same-emulator Release comparison: 7 process-cold TTID samples each.

Pinned reference: passing PR#35 head before startup diagnostics. Both builds
come from the same CI runner, with identical signing and Android host. Never
runs on a real phone; no app-data clearing, uninstall, PDF access or writes.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

from benchmark_android_cold_launch import PACKAGE, ACTIVITY, adb, file_sha256, summarize

REF_SHA = "c5a17a0e0e451e40a0968156dde08fde0619dedd"


def validate(data: dict, apk: Path, role: str) -> None:
    if data.get("apk_sha256") != file_sha256(apk):
        raise ValueError(role + ": APK SHA mismatch")
    if data.get("package") != PACKAGE or data.get("activity") != ACTIVITY:
        raise ValueError(role + ": package or activity mismatch")
    if data.get("metric") != "Android am start -S -W TotalTime (TTID)" or data.get("ttfd_measured") is not False:
        raise ValueError(role + ": not a valid TTID result")
    samples = data.get("samples_ms")
    if not isinstance(samples, list) or len(samples) != 7 or any(type(t) is not int or not 0 < t < 120000 for t in samples):
        raise ValueError(role + ": seven valid samples required")
    recalculated = summarize(samples)
    if any(data.get(k) != recalculated[k] for k in ("p50_ms", "p95_ms", "mean_ms", "min_ms", "max_ms")):
        raise ValueError(role + ": inconsistent statistics")


def comparison(old: dict, new: dict) -> dict:
    delta = new["p50_ms"] - old["p50_ms"]
    pct = round(delta / old["p50_ms"] * 100, 2)
    warn = delta > 300 and pct > 20
    return {
        "p50_delta_ms": delta,
        "p50_delta_percent": pct,
        "possible_large_regression_flag": warn,
        "interpretation": (
            "POSSIBLE REGRESSION: reproduce on a representative phone before merging."
            if warn else
            "No large >20% and >300ms slowdown observed; not proof of unchanged speed."
        ),
    }


def report_markdown(data: dict) -> str:
    a = data["reference"]
    b = data["candidate"]
    delta = data["comparison"]
    rows = [
        "# DocsGrid — Final Benchmark and Regression Report",
        "",
        "Reference: pre-profiling PR #35 commit " + REF_SHA,
        "Candidate: PR #35 head, ordinary Release APK (profiling disabled)",
        "Device: " + a["model"] + ", Android API " + a["api_level"],
        "Method: same Android emulator and runner, same signing; 7 process-cold launches per APK.",
        "",
        "| Measure | Reference | Candidate |",
        "|---|---:|---:|",
    ]
    for key, name in (
        ("p50_ms", "P50 TTID"), ("p95_ms", "P95 TTID"),
        ("min_ms", "Minimum TTID"), ("max_ms", "Maximum TTID"),
        ("mean_ms", "Mean TTID"),
    ):
        rows.append("| " + name + " | " + str(a[key]) + " ms | " + str(b[key]) + " ms |")
    rows += [
        "",
        "Candidate minus reference P50: " + str(delta["p50_delta_ms"]) +
        " ms (" + str(delta["p50_delta_percent"]) + "%).",
        "Interpretation: " + delta["interpretation"],
        "",
        "Reference runs (ms): " + str(a["samples_ms"]),
        "Candidate runs (ms): " + str(b["samples_ms"]),
        "",
        "Regression gates: Android/iOS unit, widget, integration, and 10k/100k SQLite",
        "performance tests must separately PASS in the GitHub workflow jobs.",
        "The emulator benchmark requires all launches to succeed and the exact APK",
        "SHA-256 values, package and activity to match the reports.",
        "",
        "Limits: TTID measures the first Android display, not full Home readiness",
        "or icon-tap wall clock. The emulator has no imported PDF dataset.",
        "OS caches may be warm. Seven samples are directional, not statistically",
        "conclusive. Old reference is NOT Stable-V1 or a public release.",
        "Neither APK is deployed to users and no personal data is accessed.",
        "",
    ]
    return "\n".join(rows)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--reference-apk", required=True, type=Path)
    p.add_argument("--candidate-apk", required=True, type=Path)
    p.add_argument("--initial-candidate", required=True, type=Path)
    p.add_argument("--output-dir", required=True, type=Path)
    args = p.parse_args()
    if adb("get-state") != "device" or adb("shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("Only allowed on disposable emulator")
    for item in [args.reference_apk, args.candidate_apk, args.initial_candidate]:
        if not item.exists():
            p.error("Missing comparison input: " + str(item))
    initial = json.loads(args.initial_candidate.read_text())
    validate(initial, args.candidate_apk, "initial candidate")
    if file_sha256(args.reference_apk) == file_sha256(args.candidate_apk):
        raise ValueError("Reference and candidate APKs are unexpectedly identical")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    def run(apk: Path, name: str) -> dict:
        output = args.output_dir / (name + ".json")
        subprocess.run([
            sys.executable, str(Path(__file__).with_name("benchmark_android_cold_launch.py")),
            "--apk", str(apk), "--output", str(output),
            "--warmups", "1", "--iterations", "7",
        ], check=True)
        result = json.loads(output.read_text())
        validate(result, apk, name)
        return result

    old = run(args.reference_apk, "reference")
    new = run(args.candidate_apk, "candidate")
    if old["model"] != new["model"] or old["api_level"] != new["api_level"]:
        raise ValueError("Comparator changed devices")
    data = {
        "schema": 1,
        "run_utc": datetime.now(timezone.utc).isoformat(),
        "reference_commit": REF_SHA,
        "variant": "uninstrumented ordinary Android Release",
        "same_emulator": True,
        "emulator_has_no_imported_pdf_data": True,
        "no_app_data_clear": True,
        "reference": old,
        "candidate": new,
        "candidate_initial": initial,
        "comparison": comparison(old, new),
    }
    (args.output_dir / "final-benchmark.json").write_text(json.dumps(data, indent=2) + "\n")
    markdown = report_markdown(data)
    (args.output_dir / "FINAL_REPORT.md").write_text(markdown)
    print(markdown, flush=True)


if __name__ == "__main__":
    main()
