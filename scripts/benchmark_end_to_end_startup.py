#!/usr/bin/env python3
"""CI-only E2E timing: same-run Android TTID, Dart markers and Perfetto.

Never run on a physical phone. Reinstall only on disposable emulator, with
-r preserving data. Raw logcat stays in memory; JSON is anonymous timing only.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time

from benchmark_android_cold_launch import (
    ACTIVITY, PACKAGE, adb, file_sha256, parse_ttid,
)

EVENT = re.compile(r"DOCSGRID_STARTUP\|v1\|([a-z][a-z0-9_]*)\|([0-9]+)")
REQUIRED = (
    "dart_main_enter", "flutter_binding_ready", "run_app_called",
    "root_home_init", "home_init", "home_first_frame",
    "database_open_start", "database_open_ready",
    "home_cache_read_start", "home_cache_read_done",
    "home_page_start", "home_page_ready",
    "home_summary_start", "home_summary_ready",
    "home_recent_start", "home_recent_ready", "home_core_ready",
)
PAIRS = {
    "binding_ms": ("dart_main_enter", "flutter_binding_ready"),
    "dart_to_first_home_frame_ms": ("dart_main_enter", "home_first_frame"),
    "sqlite_open_ms": ("database_open_start", "database_open_ready"),
    "home_cache_read_ms": ("home_cache_read_start", "home_cache_read_done"),
    "first_pdf_page_ms": ("home_page_start", "home_page_ready"),
    "dashboard_summary_ms": ("home_summary_start", "home_summary_ready"),
    "recent_documents_ms": ("home_recent_start", "home_recent_ready"),
    "home_core_from_dart_ms": ("dart_main_enter", "home_core_ready"),
    "optional_phone_scan_ms": ("home_phone_scan_start", "home_phone_scan_finished"),
    "optional_trash_summary_ms": ("home_trash_start", "home_trash_ready"),
    "optional_theme_read_ms": ("theme_read_start", "theme_read_ready"),
}
TRACE_DEVICE = "/data/misc/perfetto-traces/docsgrid-end-to-end.perfetto-trace"
TRACE_FILE = "docsgrid-end-to-end.perfetto-trace"


def parse_markers(logcat: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for m in EVENT.finditer(logcat):
        result.setdefault(m.group(1), int(m.group(2)))
    return result


def analyze(marks: dict[str, int]) -> dict:
    missing = sorted(set(REQUIRED) - set(marks))
    if missing:
        raise ValueError("Missing required startup markers: " + ", ".join(missing))
    gates = ("home_first_frame", "home_page_ready", "home_summary_ready",
             "home_recent_ready")
    if marks["home_core_ready"] < max(marks[x] for x in gates):
        raise ValueError("Home core-ready was emitted before its milestones")
    delta = {}
    for label, (a, b) in PAIRS.items():
        if a in marks and b in marks:
            if marks[b] < marks[a]:
                raise ValueError("Negative stage duration: " + label)
            delta[label] = round((marks[b] - marks[a]) / 1000, 3)
    return {
        "durations_ms": delta,
        "last_finished_core_gate": max(gates, key=lambda key: marks[key]),
        "milestones_since_dart_main_ms": {
            k: round((v - marks["dart_main_enter"]) / 1000, 3)
            for k, v in sorted(marks.items(), key=lambda item: item[1])
        },
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    a = p.parse_args()
    if not a.apk.is_file() or a.apk.stat().st_size < 1024:
        p.error("Isolated startup-profile APK is missing")
    base = json.loads(a.baseline.read_text(encoding="utf-8"))
    if base.get("package") != PACKAGE or base.get("iterations") != 7:
        raise ValueError("Normal seven-run Release baseline is required")
    if adb("get-state") != "device":
        raise RuntimeError("ADB is not ready")
    if adb("shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("Refusing to install or inspect logs on a real phone")
    profile_sha = file_sha256(a.apk)
    if profile_sha == base.get("apk_sha256"):
        raise ValueError("Profiling APK must be separate from ordinary Release")
    a.output_dir.mkdir(parents=True, exist_ok=True)
    print(adb("install", "-r", str(a.apk), timeout=240), flush=True)
    if not adb("shell", "pm", "path", PACKAGE).startswith("package:"):
        raise RuntimeError("Unexpected Android app package")
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    adb("logcat", "-c")
    cmd = ["adb", "shell", "perfetto", "-t", "24s", "-b", "32mb", "-o",
           TRACE_DEVICE, "sched", "freq", "idle", "am", "wm", "gfx",
           "view", "binder_driver", "dalvik"]
    tracer = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    try:
        time.sleep(3)
        if tracer.poll() is not None:
            out, _ = tracer.communicate()
            raise RuntimeError("Perfetto could not start: " + out[-1000:])
        started = datetime.now(timezone.utc).isoformat()
        output = adb("shell", "am", "start", "-S", "-W", "-a",
                     "android.intent.action.MAIN", "-c",
                     "android.intent.category.LAUNCHER", "-n", ACTIVITY)
        traced_ttid = parse_ttid(output)
        deadline = time.monotonic() + 18
        marks: dict[str, int] = {}
        while time.monotonic() < deadline:
            marks = parse_markers(adb("logcat", "-d", "-v", "brief"))
            if "home_core_ready" in marks:
                time.sleep(1.5)
                marks = parse_markers(adb("logcat", "-d", "-v", "brief"))
                break
            time.sleep(0.6)
        results = analyze(marks)
        result, _ = tracer.communicate(timeout=35)
        if tracer.returncode != 0:
            raise RuntimeError("Perfetto trace failed: " + result[-1000:])
        trace = a.output_dir / TRACE_FILE
        adb("pull", TRACE_DEVICE, str(trace), timeout=60)
        if not trace.exists() or trace.stat().st_size < 4096:
            raise RuntimeError("Missing/invalid end-to-end Perfetto trace")
        report = {
            "schema": 1,
            "device": adb("shell", "getprop", "ro.product.model"),
            "package": PACKAGE,
            "started_utc": started,
            "same_run_perfetto_and_dart": True,
            "normal_apk_sha256": base["apk_sha256"],
            "profile_apk_sha256": profile_sha,
            "normal_p50_ms": base["p50_ms"],
            "normal_p95_ms": base["p95_ms"],
            "profiled_android_ttid_ms": traced_ttid,
            "trace_file": TRACE_FILE,
            "trace_sha256": file_sha256(trace),
            "trace_bytes": trace.stat().st_size,
            **results,
            "limitations": [
                "Profiling is a separate, instrumented evaluation APK.",
                "Android TTID and Dart-relative times use different clocks; do not subtract them.",
                "home_core_ready = first frame, first PDF page, live summary and recent list; optional Phone scan/backup not required.",
                "Empty CI emulator is not representative of a populated real phone.",
                "The last completed parallel task is a readiness gate, not proof of greatest CPU cost.",
            ],
        }
        dest = a.output_dir / "docsgrid-end-to-end-startup.json"
        dest.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("E2E TTID (instrumented):", traced_ttid, "ms", flush=True)
        print("Last core-readiness gate:", results["last_finished_core_gate"], flush=True)
        for k, v in results["durations_ms"].items():
            print(k + ":", v, "ms", flush=True)
        print("Trace verified:", trace.stat().st_size, "bytes", flush=True)
    finally:
        if tracer.poll() is None:
            tracer.terminate()
            try:
                tracer.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                tracer.kill()
                tracer.communicate()
        try:
            adb("shell", "rm", "-f", TRACE_DEVICE)
        except Exception:
            pass


if __name__ == "__main__":
    main()
