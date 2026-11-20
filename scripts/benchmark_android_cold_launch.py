#!/usr/bin/env python3
"""Non-destructive, reproducible Android RELEASE process-cold launch baseline.

Measures Android am start -S -W TotalTime (TTID), NOT Home data readiness
(TTFD). Never clears app data, uninstalls a previous app, or deletes PDFs.
Run on a dedicated emulator or a safely backed-up test phone.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

PACKAGE = "com.docsgrid.mobile"
ACTIVITY = "com.docsgrid.mobile/com.docsgrid.docs_grid.MainActivity"
TOTAL_TIME = re.compile(r"^TotalTime:\s*([0-9]+)\s*$", re.MULTILINE)


def parse_ttid(text: str) -> int:
    """Android's TotalTime is first display, not asynchronous Home readiness."""
    clean = text.replace("\r", "")
    matches = TOTAL_TIME.findall(clean)
    if "Status: ok" not in clean or "Complete" not in clean or len(matches) != 1:
        raise ValueError(f"Failed or ambiguous Android launch: {clean[:1500]}")
    milliseconds = int(matches[0])
    if not 0 < milliseconds < 120000:
        raise ValueError(f"Implausible TTID reported: {milliseconds}")
    return milliseconds


def summarize(milliseconds: list[int]) -> dict[str, object]:
    if not milliseconds:
        raise ValueError("At least one cold-launch measurement is required")
    samples = sorted(milliseconds)
    return {
        "iterations": len(samples),
        "min_ms": samples[0],
        "p50_ms": statistics.median(samples),
        "p95_ms": samples[max(0, math.ceil(0.95 * len(samples)) - 1)],
        "max_ms": samples[-1],
        "mean_ms": round(statistics.mean(samples), 2),
        "samples_ms": milliseconds,
    }


def adb(*arguments: str, timeout: int = 120) -> str:
    command = ["adb", *arguments]
    result = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=timeout, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{command!r} failed: {result.stdout[-2000:]}")
    return result.stdout.strip()


def get_property(key: str) -> str:
    return adb("shell", "getprop", key).strip()


def file_sha256(file: Path) -> str:
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=1)
    arguments = parser.parse_args()
    if not 3 <= arguments.iterations <= 30:
        parser.error("--iterations must be between 3 and 30")
    if not 0 <= arguments.warmups <= 5:
        parser.error("--warmups must be between 0 and 5")
    if not arguments.apk.is_file() or arguments.apk.stat().st_size < 1024:
        parser.error(f"APK missing or implausibly small: {arguments.apk}")

    device = adb("get-state")
    if device != "device":
        raise RuntimeError(f"ADB target not ready: {device!r}")
    # Install only on the disposable emulator in CI. On a physical phone,
    # callers must first back up their data and ensure signatures agree.
    print(adb("install", "-r", str(arguments.apk), timeout=240), flush=True)
    installed = adb("shell", "pm", "path", PACKAGE)
    if not installed.startswith("package:"):
        raise RuntimeError(f"Unexpected installed package: {installed!r}")

    model = get_property("ro.product.model")
    api_level = get_property("ro.build.version.sdk")
    for property_name in (
        "window_animation_scale", "transition_animation_scale",
        "animator_duration_scale",
    ):
        adb("shell", "settings", "put", "global", property_name, "0")

    print(f"Device: {model}, API {api_level}", flush=True)
    print(f"Package: {PACKAGE}, activity: {ACTIVITY}", flush=True)
    print("Metric: process-cold Time To Initial Display (TTID); NOT TTFD", flush=True)
    measurements: list[int] = []
    for iteration in range(arguments.warmups + arguments.iterations):
        # -S stops the app process before each launcher intent. User/app data
        # remains intact. The OS filesystem cache may still be warm.
        adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(0.7)
        output = adb(
            "shell", "am", "start", "-S", "-W", "-a",
            "android.intent.action.MAIN", "-c",
            "android.intent.category.LAUNCHER", "-n", ACTIVITY,
            timeout=120,
        )
        try:
            measured = parse_ttid(output)
        except ValueError:
            print("Unparseable launch response:", output, flush=True)
            raise
        if not adb("shell", "pidof", PACKAGE):
            raise RuntimeError("The target app process exited immediately after launch")
        if iteration >= arguments.warmups:
            measurements.append(measured)
            print(f"Cold launch {len(measurements)}/{arguments.iterations}: "
                  f"TTID={measured} ms", flush=True)
        else:
            print(f"Discarded warmup: TTID={measured} ms", flush=True)
        time.sleep(1)

    stats = summarize(measurements)
    report: dict[str, object] = {
        "schema": 1,
        "metric": "Android am start -S -W TotalTime (TTID)",
        "startup_mode": "process-cold, cached OS pages possible",
        "ttfd_measured": False,
        "dataset": "newly installed emulator, no imported user PDFs",
        "package": PACKAGE,
        "activity": ACTIVITY,
        "model": model,
        "api_level": api_level,
        "apk_sha256": file_sha256(arguments.apk),
        "apk_bytes": arguments.apk.stat().st_size,
        "git_commit": os.getenv("GITHUB_SHA", "not specified"),
        "warmups_excluded": arguments.warmups,
        **stats,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    summary = (
        f"### DocsGrid Android Release startup (process-cold TTID)\n"
        f"- Device: {model}, API {api_level}; {arguments.iterations} runs\n"
        f"- Median: **{stats['p50_ms']} ms**; "
        f"P95: **{stats['p95_ms']} ms**; "
        f"minimum: {stats['min_ms']} ms; maximum: {stats['max_ms']} ms\n"
        f"- This is *not* TTFD, not icon-tap wall clock, and not "
        f"a performance comparison with the old APK.\n"
    )
    print(summary, flush=True)
    if os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
            stream.write(summary)


if __name__ == "__main__":
    main()
