#!/usr/bin/env python3
"""Read-only Android Release startup critical-path capture using Perfetto.

Records ONE additional process-cold first-frame launch on an already-installed
Release APK, after the existing seven-run untraced TTID benchmark. No app
source changes, app-data clears, reinstallation, permission requests or PDF
writes. The binary trace is intended for interactive analysis in Perfetto UI.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import time

from benchmark_android_cold_launch import PACKAGE, ACTIVITY, file_sha256, parse_ttid

TRACE_NAME = "docsgrid-startup.perfetto-trace"
TRACE_DEVICE = "/data/misc/perfetto-traces/docsgrid-startup-critical-path.perfetto-trace"
CATEGORIES = (
    "sched", "freq", "idle", "am", "wm", "gfx", "view",
    "binder_driver", "dalvik",
)


def adb(*args: str, timeout: int = 60) -> str:
    completed = subprocess.run(
        ["adb", *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        check=False, text=True, timeout=timeout,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed: {completed.stdout[-1200:]}")
    return completed.stdout.strip()


def checked_baseline(raw: dict, apk_sha: str) -> dict:
    """Fail closed when the reference run came from another APK/metric."""
    if (raw.get("apk_sha256") != apk_sha
            or raw.get("package") != PACKAGE
            or raw.get("metric") != "Android am start -S -W TotalTime (TTID)"
            or raw.get("iterations") != 7
            or not isinstance(raw.get("samples_ms"), list)
            or len(raw["samples_ms"]) != 7):
        raise ValueError("The untraced baseline does not match this exact APK")
    p50 = raw.get("p50_ms")
    p95 = raw.get("p95_ms")
    if not isinstance(p50, (int, float)) or not isinstance(p95, (int, float)):
        raise ValueError("The baseline lacks numeric P50/P95")
    return {"baseline_p50_ms": p50, "baseline_p95_ms": p95}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--trace-seconds", type=int, default=16)
    args = parser.parse_args()
    if not 12 <= args.trace_seconds <= 30:
        parser.error("--trace-seconds must be between 12 and 30")
    if not args.apk.is_file() or args.apk.stat().st_size < 1024:
        parser.error("Release APK missing or too small")
    if not args.baseline.is_file():
        parser.error("Matching untraced cold-launch baseline is required")

    apk_sha = file_sha256(args.apk)
    baseline = checked_baseline(json.loads(args.baseline.read_text()), apk_sha)
    if adb("get-state") != "device":
        raise RuntimeError("ADB target is not ready")
    if not adb("shell", "pm", "path", PACKAGE).startswith("package:"):
        raise RuntimeError("Release APK is not installed: refusing to install or clear data")
    sdk = adb("shell", "getprop", "ro.build.version.sdk")
    if not sdk.isdigit() or int(sdk) < 29:
        raise RuntimeError("Android 10+ required for Perfetto")
    model = adb("shell", "getprop", "ro.product.model")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # The prior benchmark already installed the exact verified APK. Keep all
    # packages, user records, local storage and permission grants untouched.
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(0.5)
    trace_cmd = [
        "adb", "shell", "perfetto", "-t", f"{args.trace_seconds}s",
        "-b", "32mb", "-o", TRACE_DEVICE, *CATEGORIES,
    ]
    tracer = subprocess.Popen(
        trace_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    try:
        # Let the Perfetto service initialize before the launch is requested.
        time.sleep(3)
        if tracer.poll() is not None:
            output, _ = tracer.communicate()
            raise RuntimeError(f"Perfetto failed to start: {output[-1200:]}")
        started_utc = datetime.now(timezone.utc).isoformat()
        launch_text = adb(
            "shell", "am", "start", "-S", "-W", "-a",
            "android.intent.action.MAIN", "-c",
            "android.intent.category.LAUNCHER", "-n", ACTIVITY, timeout=80,
        )
        traced_ttid = parse_ttid(launch_text)
        perfetto_output, _ = tracer.communicate(timeout=args.trace_seconds + 15)
        if tracer.returncode != 0:
            raise RuntimeError(f"Perfetto failed: {perfetto_output[-1500:]}")
        if not adb("shell", "pidof", PACKAGE):
            raise RuntimeError("App exited after traced launch")
        local_trace = args.output_dir / TRACE_NAME
        adb("pull", TRACE_DEVICE, str(local_trace), timeout=60)
        if not local_trace.is_file() or local_trace.stat().st_size < 4096:
            raise RuntimeError("Perfetto produced an empty or invalid-size trace")

        # The traced launch incurs observer overhead; never substitute its TTID
        # for the independently measured seven-run, untraced P50/P95.
        report = {
            "schema": 1,
            "profiler": "Android Perfetto (system/CPU/thread startup trace)",
            "device": model,
            "android_api": int(sdk),
            "package": PACKAGE,
            "launch_activity": ACTIVITY,
            "run_started_utc": started_utc,
            "apk_sha256": apk_sha,
            "untraced_runs": 7,
            **baseline,
            "traced_ttid_ms": traced_ttid,
            "metric": "Android am start -S -W TotalTime (TTID)",
            "ttfd_measured": False,
            "dart_sqlite_phase_durations_measured": False,
            "trace_file": TRACE_NAME,
            "trace_bytes": local_trace.stat().st_size,
            "trace_sha256": file_sha256(local_trace),
            "note": "Traced TTID has observer overhead. Examine bindApplication, activityStart, CPU scheduler, Flutter threads and first frame in ui.perfetto.dev. No application-level database or fully-drawn milestone was instrumented.",
        }
        (args.output_dir / "startup-critical-path.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
        print("Perfetto startup critical-path trace:", local_trace, flush=True)
        print(f"Traced TTID (diagnostic only): {traced_ttid} ms", flush=True)
        print(
            f"Untraced same-APK baseline: P50 {baseline['baseline_p50_ms']} ms"
            f", P95 {baseline['baseline_p95_ms']} ms", flush=True
        )
        print("No TTFD or Dart SQLite stage measurements claimed.", flush=True)
    finally:
        if tracer.poll() is None:
            tracer.terminate()
            try:
                tracer.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                tracer.kill()
                tracer.communicate()
        # Remove only the temporary trace created by this script on the CI
        # emulator. This never targets app-private storage or user documents.
        try:
            adb("shell", "rm", "-f", TRACE_DEVICE)
        except Exception:
            pass


if __name__ == "__main__":
    main()
