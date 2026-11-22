#!/usr/bin/env python3
"""Verify persistent Home Cache across two REAL emulator process-cold relaunches.

Runs on disposable emulator after the opt-in E2E profiling run, without clearing
data, modifying preferences, or opening/deleting PDF files. Only anonymous
milestone names and durations are reported. The APK remains installed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from benchmark_android_cold_launch import ACTIVITY, PACKAGE, adb, parse_ttid
from benchmark_end_to_end_startup import parse_markers


def verify_session(marks: dict[str, int]) -> dict:
    required = (
        "dart_main_enter", "home_cache_read_start", "home_cache_read_done",
        "home_cache_summary_hit", "home_summary_ready", "home_page_ready",
        "home_recent_ready", "home_core_ready",
    )
    missing = [m for m in required if m not in marks]
    if missing:
        raise ValueError("Real Android cache relaunch markers missing: " +
                         ", ".join(missing))
    if marks["home_cache_read_done"] < marks["home_cache_read_start"]:
        raise ValueError("Cache read completed before it began")
    if marks["home_core_ready"] < marks["home_summary_ready"]:
        raise ValueError("Home claimed ready before live SQLite summary")
    if "home_cache_summary_miss" in marks:
        raise ValueError("Contradictory cache hit/miss observations")
    applied = "home_cache_summary_applied" in marks
    if applied and marks["home_cache_summary_applied"] > marks["home_summary_ready"]:
        raise ValueError("Old cache applied after authoritative live summary")
    return {
        "cache_persisted_after_force_stop": True,
        "live_sqlite_summary_ready": True,
        "cache_was_applied_before_live": applied,
        "cache_read_done_since_dart_main_ms": round(
            (marks["home_cache_read_done"] - marks["dart_main_enter"]) / 1000, 3
        ),
        "live_summary_since_dart_main_ms": round(
            (marks["home_summary_ready"] - marks["dart_main_enter"]) / 1000, 3
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile-report", required=True, type=Path)
    args = parser.parse_args()
    baseline = json.loads(args.profile_report.read_text(encoding="utf-8"))
    if not baseline.get("same_run_perfetto_and_dart") or not baseline.get("profile_apk_sha256"):
        raise ValueError("First profiling launch must succeed before relaunch checks")
    if adb("get-state") != "device" or adb("shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("Emulator-only test: refusing real phone")
    if not adb("shell", "pm", "path", PACKAGE).startswith("package:"):
        raise RuntimeError("Profiling APK must already be installed")
    runs = []
    for i in range(2):
        adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(0.7)
        adb("logcat", "-c")
        launch_text = adb(
            "shell", "am", "start", "-S", "-W", "-a",
            "android.intent.action.MAIN", "-c",
            "android.intent.category.LAUNCHER", "-n", ACTIVITY,
            timeout=120,
        )
        ttid = parse_ttid(launch_text)
        if not adb("shell", "pidof", PACKAGE):
            raise RuntimeError("App exited after relaunch")
        deadline = time.monotonic() + 18
        marks = {}
        while time.monotonic() < deadline:
            marks = parse_markers(adb("logcat", "-d", "-v", "brief", timeout=60))
            if "home_core_ready" in marks and "home_cache_read_done" in marks:
                break
            time.sleep(0.5)
        result = verify_session(marks)
        runs.append({"relaunch": i + 1, "ttid_ms": ttid, **result})
        print(
            f"Relaunch {i + 1}/2: TTID {ttid} ms; "
            f"cache hit; applied={result['cache_was_applied_before_live']}; "
            f"cache read at {result['cache_read_done_since_dart_main_ms']} ms; "
            f"live at {result['live_summary_since_dart_main_ms']} ms",
            flush=True,
        )
        time.sleep(1)
    report = {
        "schema": 1,
        "check": "Real Android persisted Home summary after -S process cold stop",
        "checked_utc": datetime.now(timezone.utc).isoformat(),
        "dataset": "disposable emulator, no imported PDFs",
        "original_profile_apk_sha256": baseline["profile_apk_sha256"],
        "never_cleared_app_data": True,
        "requires_cache_hit_and_authoritative_summary": True,
        "runs": runs,
        "note": "The cache hit proves persistence, not display before live. "
                "Only cache_was_applied_before_live reflects provisional UI state. "
                "The live SQLite summary overrides any provisional cache.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Home cache 2x real-process relaunch verification: PASSED", flush=True)


if __name__ == "__main__":
    main()
