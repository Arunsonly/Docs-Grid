#!/usr/bin/env python3
"""Fresh-install empty Grid acceptance check. Disposable CI emulator only."""
import argparse
import json
from pathlib import Path
import re
import time
import xml.etree.ElementTree as ET

from benchmark_android_cold_launch import adb, PACKAGE, ACTIVITY

def nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/docsgrid-smoke.xml", timeout=12)
    return list(ET.fromstring(adb("shell", "cat", "/sdcard/docsgrid-smoke.xml")).iter("node"))

def label(node):
    return (node.get("text", "") + " " + node.get("content-desc", "")).strip()

def tap(node):
    coordinates = [int(x) for x in re.findall(r"\d+", node.get("bounds", ""))]
    if len(coordinates) != 4:
        raise RuntimeError("Missing UI bounds")
    x1, y1, x2, y2 = coordinates
    adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if adb("shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("Refusing to run fresh-install smoke on a real device")
    if PACKAGE in adb("shell", "pm", "list", "packages"):
        raise RuntimeError("Fresh-install smoke requires a previously uninstalled app")
    adb("install", args.apk, timeout=240)
    adb("shell", "appops", "set", PACKAGE, "MANAGE_EXTERNAL_STORAGE", "allow")
    adb("shell", "am", "start", "-W", "-n", ACTIVITY)
    deadline = time.monotonic() + 45
    grid = None
    while time.monotonic() < deadline:
        current = nodes()
        fresh = next((n for n in current if label(n) == "Start fresh"), None)
        if fresh is not None:
            tap(fresh)
            continue
        grid = next((n for n in current if label(n) == "Grid" or
                     label(n).startswith("Grid\n") or
                     label(n).startswith("Grid Tab ")), None)
        if grid is not None:
            break
        time.sleep(0.3)
    if grid is None:
        raise RuntimeError("Fresh installation did not expose Grid navigation")
    start = time.monotonic()
    tap(grid)
    last = []
    while time.monotonic() - start < 18:
        current = nodes()
        last = [label(n) for n in current if label(n)]
        if any("All Your Docs. One Smart Place." in x for x in last):
            report = {"fresh_install": True, "empty_grid_visible": True,
                      "observed_ms": round((time.monotonic()-start)*1000)}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2)+"\n")
            print(report, flush=True)
            return
        if any("Could not load folders" in x or "Could not load PDFs" in x for x in last):
            raise RuntimeError("Empty Grid reported a loading error: " + repr(last))
        time.sleep(0.2)
    raise RuntimeError("Empty Grid did not become visible within smoke limit: " + repr(last))

if __name__ == "__main__":
    main()
