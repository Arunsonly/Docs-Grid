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

def find_grid_tab(current):
    """Flutter NavigationBar exposes the tab ordinal in its semantics label.

    Home also contains a plain "Grid" Recent filter. It must never be tapped
    as navigation. Fail closed if the actual destination is not identifiable.
    """
    matches = [
        node for node in current
        if re.fullmatch(r"Grid\s+Tab\s+3\s+of\s+3", " ".join(label(node).split()),
                        flags=re.IGNORECASE)
        and node.get("enabled", "true") == "true"
    ]
    if len(matches) > 1:
        clickable = [node for node in matches if node.get("clickable") == "true"]
        return clickable[0] if len(clickable) == 1 else None
    return matches[0] if matches else None


def grid_screen_visible(current):
    # Independent evidence of the actual screen, not just a Grid word on Home.
    labels = [label(node) for node in current]
    return any(
        item == "Folders" or "Search folders or PDF names" in item
        or item == "Create folder"
        for item in labels
    )


def tap(node):
    coordinates = [int(x) for x in re.findall(r"\d+", node.get("bounds", ""))]
    if len(coordinates) != 4:
        raise RuntimeError("Missing UI bounds")
    x1, y1, x2, y2 = coordinates
    if x2 <= x1 or y2 <= y1:
        raise RuntimeError("Empty UI bounds")
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
    # Save evidence on failures too, so a navigation failure is distinguishable
    # from a real Grid query timeout. Keep the original 18-second acceptance
    # limit, measured from the first tap of the actual destination.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"fresh_install": True, "empty_grid_visible": False,
              "grid_screen_seen": False, "stage": "home_navigation",
              "last_labels": []}
    start = None
    try:
        deadline = time.monotonic() + 45
        grid = None
        while time.monotonic() < deadline:
            current = nodes()
            report["last_labels"] = [label(n) for n in current if label(n)]
            fresh = next((n for n in current if label(n) == "Start fresh"), None)
            if fresh is not None:
                tap(fresh)
                continue
            grid = find_grid_tab(current)
            if grid is not None:
                break
            time.sleep(0.3)
        if grid is None:
            raise RuntimeError("Actual Grid navigation tab not found: " +
                               repr(report["last_labels"]))
        report["navigation_label"] = label(grid)
        report["navigation_bounds"] = grid.get("bounds")
        print("Tapping actual Grid destination:", repr(label(grid)),
              grid.get("bounds"), flush=True)
        start = time.monotonic()
        report["stage"] = "grid_navigation"
        tap(grid)
        while time.monotonic() - start < 18:
            current = nodes()
            last = [label(n) for n in current if label(n)]
            report["last_labels"] = last
            if grid_screen_visible(current):
                report["grid_screen_seen"] = True
                report["stage"] = "grid_content"
            if any("Could not load folders" in x or "Could not load PDFs" in x for x in last):
                raise RuntimeError("Empty Grid reported a loading error: " + repr(last))
            if any("All Your Docs. One Smart Place." in x for x in last):
                report["empty_grid_visible"] = True
                report["grid_screen_seen"] = True
                report["stage"] = "passed"
                print(report, flush=True)
                return
            time.sleep(0.2)
        if not report["grid_screen_seen"]:
            raise RuntimeError("Grid navigation did not reach Grid screen: " +
                               repr(report["last_labels"]))
        raise RuntimeError("Grid opened but empty content did not become visible within smoke limit: " +
                           repr(report["last_labels"]))
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if start is not None:
            report["observed_ms"] = round((time.monotonic()-start)*1000)
        args.output.write_text(json.dumps(report, indent=2)+"\n")


if __name__ == "__main__":
    main()
