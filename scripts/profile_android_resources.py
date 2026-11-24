#!/usr/bin/env python3
"""Android disposable-emulator resource sampling; not heap-leak proof."""
import argparse
import json
from pathlib import Path
import re
import time
from benchmark_android_cold_launch import adb, PACKAGE, ACTIVITY
from smoke_android_fresh_grid import nodes, label, tap

def sample():
    memory = adb("shell", "dumpsys", "meminfo", PACKAGE)
    match = re.search(r"TOTAL PSS:\s*(\d+)", memory)
    if not match:
        match = re.search(r"^\s*TOTAL\s+(\d+)", memory, re.M)
    if not match:
        raise RuntimeError("Could not read application PSS")
    cpu = adb("shell", "dumpsys", "cpuinfo")
    match_cpu = re.search(r"([\d.]+)%\s+\d+/" + re.escape(PACKAGE) + r":", cpu)
    return {"pss_kib": int(match.group(1)), "cpu_percent_sample": float(match_cpu.group(1)) if match_cpu else None}

def select(name, ordinal):
    target = f"{name} Tab {ordinal} of 3"
    matches = [n for n in nodes() if " ".join(label(n).split()) == target
               and n.get("enabled", "true") == "true"]
    if len(matches) != 1:
        raise RuntimeError("Could not identify unique navigation tab: " + target)
    tap(matches[0])
    time.sleep(0.8)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if adb("shell", "getprop", "ro.kernel.qemu") != "1":
        raise RuntimeError("Resource test requires disposable emulator")
    report = {"scope": "empty-library repeated tab navigation, PSS and sampled CPU; no leak or battery certification",
              "samples": [], "status": "incomplete"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        adb("shell", "am", "start", "-W", "-n", ACTIVITY)
        time.sleep(2)
        pid = adb("shell", "pidof", PACKAGE)
        if not pid:
            raise RuntimeError("Application process is missing")
        select("Home", 2)
        report["samples"].append(sample())
        for cycle in range(5):
            select("Phone", 1)
            select("Grid", 3)
            select("Home", 2)
            if adb("shell", "pidof", PACKAGE) != pid:
                raise RuntimeError("Application process restarted during navigation")
            report["samples"].append(sample())
        report["status"] = "measured"
        report["pss_delta_kib"] = report["samples"][-1]["pss_kib"] - report["samples"][0]["pss_kib"]
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
