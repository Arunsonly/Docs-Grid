#!/usr/bin/env python3
"""Evidence-driven four-part report. Missing data is never a passing result."""
import json
import os
from pathlib import Path
import re
import urllib.request
from quality_coverage import coverage

BASELINE = {"commit": "49393e0753b548e87f926210790360d3a42e5721",
            "run_id": 45389313055, "dart_files": 61, "apk_bytes": 97601715,
            "android_coverage_percent": 48.25, "ios_coverage_percent": 48.24,
            "android_analyzer_infos": 232, "ios_analyzer_infos": 232,
            "android_tests": 561, "ios_tests": 561, "android_ttid_p50_ms": 3225}
ROOT = Path("quality-collected")

def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}

def read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""

def metric_count(text, pattern):
    matches = re.findall(pattern, text, re.M)
    return int(matches[-1]) if matches else None

def fetch_jobs():
    url = (os.environ["GITHUB_API_URL"] + "/repos/" + os.environ["GITHUB_REPOSITORY"]
           + "/actions/runs/" + os.environ["GITHUB_RUN_ID"] + "/attempts/"
           + os.environ["GITHUB_RUN_ATTEMPT"] + "/jobs?per_page=100")
    request = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["jobs"]

def main():
    out = Path("quality-report")
    out.mkdir(exist_ok=True)
    api_error = None
    try:
        jobs = fetch_jobs()
    except Exception as error:
        jobs = []
        api_error = str(error)
    steps = {job["name"]: {step["name"]: step.get("conclusion")
                           for step in job.get("steps", [])} for job in jobs}
    android = "Android analyze, test and APK"
    ios = "iOS analyze, test and unsigned build"
    emulator = "Release APK process-cold launch benchmark (Android emulator)"
    a = ROOT / "docsgrid-quality-evidence-Linux"
    i = ROOT / "docsgrid-quality-evidence-macOS"
    apk = read_json(a / "apk-audit.json")
    source = read_json(a / "source-audit.json")
    mutation = read_json(a / "mutation.json")
    cold = read_json(ROOT / "startup/cold-launch.json")
    fresh = read_json(ROOT / "startup/fresh-grid.json")
    resources = read_json(ROOT / "startup/resources.json")
    metrics = {"dart_files": source.get("dart_files"), "dart_lines": source.get("dart_lines"),
               "apk_bytes": apk.get("apk_bytes"), "apk_sha256": apk.get("apk_sha256"),
               "android_ttid_p50_ms": cold.get("p50_ms"), "android_ttid_p95_ms": cold.get("p95_ms"),
               "android_resource_samples": resources.get("samples"),
               "android_pss_delta_kib": resources.get("pss_delta_kib"),
               "mutation": mutation.get("mutants"), "source_audit": source,
               "apk_audit": apk}
    for platform, folder, os_name in (("android", a, "Linux"), ("ios", i, "macOS")):
        analyzer = read_text(folder / "analyzer.txt")
        info_count = len(re.findall(r"\binfo\s+[•-]", analyzer))
        metrics[platform + "_analyzer_infos"] = info_count if analyzer else None
        metrics[platform + "_analyzer_errors"] = len(re.findall(r"\berror\s+[•-]", analyzer)) if analyzer else None
        metrics[platform + "_analyzer_warnings"] = len(re.findall(r"\bwarning\s+[•-]", analyzer)) if analyzer else None
        metrics[platform + "_analyzer_diagnostics"] = [
            line.strip() for line in analyzer.splitlines()
            if re.search(r"\b(?:error|warning|info)\s+[•-]", line)]
        test_log = read_text(folder / "tests.txt")
        test_count = metric_count(test_log, r"\+(\d+): All tests passed!")
        if test_count is None:
            test_count = metric_count(test_log, r"(\d+) tests passed\.")
        metrics[platform + "_tests"] = test_count
        metrics[platform + "_performance_log"] = [
            line for line in read_text(folder / "performance.txt").splitlines()
            if "DOCSGRID_" in line]
        try:
            hit, total = coverage((ROOT / ("docsgrid-coverage-" + os_name) / "lcov.info").read_text())
            metrics[platform + "_coverage_percent"] = round(hit * 100 / total, 2)
        except (OSError, ValueError):
            metrics[platform + "_coverage_percent"] = None

    rows = []
    def add(name, status, scope):
        rows.append({"test": name, "status": status, "scope": scope})
    def result(names, success="PASS"):
        values = [steps.get(job, {}).get(step) for job, step in names]
        if any(v in ("failure", "timed_out", "action_required", "startup_failure") for v in values):
            return "FAIL"
        if all(v == "success" for v in values):
            return success
        if any(v in ("cancelled", "skipped") for v in values):
            return "BLOCKED"
        return "NOT_TESTED"
    def both(step, success="PASS"):
        return result([(android, step), (ios, step)], success)
    suites = "Widget and unit tests with line coverage"
    integration = "End-to-end integration workflow tests"
    perf = "Performance benchmark (10k documents)"
    fuzz = "Seeded fuzz and ZIP fault injection"
    android_build = "Build internal performance-evaluation Release APK"
    ios_build = "Build iOS without code signing"
    analyses = both("Analyze")
    if analyses == "PASS":
        counts = [metrics["android_analyzer_infos"], metrics["ios_analyzer_infos"]]
        analyses = "PARTIAL" if None in counts else ("PASS_WITH_ISSUES" if any(counts) else "PASS")
    add("Static code analysis", analyses, "Dart analyzer, all informational diagnostics retained")
    add("Unit testing", both(suites), "Both hosted test suites")
    add("Widget testing", both(suites), "Both hosted test suites")
    add("Integration testing", both(integration), "Host-side library integration")
    add("End-to-end testing", result([(android, integration), (ios, integration)], "PARTIAL"), "Not full real-device workflows")
    add("Regression testing", both(suites, "PARTIAL"), "Existing contracts and tested active features")
    add("Android functionality testing", result([(android, suites)], "PARTIAL"), "Host-side plus fresh Grid emulator evidence")
    add("iOS functionality testing", result([(ios, suites)], "PARTIAL"), "macOS host tests, not physical iPhone")
    add("Code coverage", both("Validate and summarize coverage", "PARTIAL"), "Measured Dart lines; no full active-code or native threshold")
    add("Dead code re-audit", result([(android, "Retired feature source and dependency audit")], "PARTIAL"), "Known retired symbols and import reachability only")
    add("Unused dependency re-audit", result([(android, "Retired feature source and dependency audit")], "PARTIAL"), "Retired ML Kit only; complete dependency utilization not proven")
    add("Memory leakage testing", "PARTIAL" if resources.get("status") == "measured" else "NOT_TESTED", "PSS trend does not prove heap leak absence")
    add("RAM consumption testing", "PARTIAL" if resources.get("status") == "measured" else "NOT_TESTED", "Emulator PSS samples, no real-device baseline")
    add("CPU consumption testing", "PARTIAL" if any(s.get("cpu_percent_sample") is not None for s in resources.get("samples", [])) else "NOT_TESTED", "Emulator CPU samples only")
    add("Battery consumption testing", "NOT_TESTED", "Requires physical-device energy instrumentation")
    add("Mutation testing", result([(android, "Targeted mutation testing")], "PARTIAL"), "Four validator mutants, not whole codebase")
    add("Fuzz testing", both(fuzz, "PARTIAL"), "Seeded folder graph and malformed ZIP scope")
    add("Fault injection testing", both(fuzz, "PARTIAL"), "ZIP truncation and existing durable-operation fault tests")
    add("Stress testing", both(perf, "PARTIAL"), "10k/100k database records; not 100k physical PDFs")
    add("Performance testing", both(perf), "Defined repository benchmarks; device performance separate")
    add("Security testing", result([(android, "OSV dependency scan (resolved Dart packages)"), (android, "Retired feature APK binary audit")], "PARTIAL"), "Dart known vulnerabilities and scoped APK audit")
    add("Data integrity testing", both(suites, "PARTIAL"), "Defined database, file and checksum tests")
    add("Backup and restore testing", both(suites), "Defined host-side backup/restore suite; devices separate")
    add("Crash recovery testing", both(suites, "PARTIAL"), "Durable journal fault simulation, not every device crash")
    add("Backward compatibility testing", both(suites, "PARTIAL"), "Schema and legacy backup tests; installed updates separate")
    add("Fresh installation testing", "PASS" if fresh.get("stage") == "passed" and fresh.get("empty_grid_visible") is True else ("FAIL" if fresh.get("error") else "NOT_TESTED"), "Android emulator only")
    add("Existing installation update testing", "NOT_TESTED", "Requires signed old APK/IPA and retained fixture install")
    add("Android cold startup testing", "PASS" if cold.get("iterations") == 7 and cold.get("p50_ms") else "NOT_TESTED", "Seven measured emulator TTID launches, not TTFD")
    add("APK integrity testing", result([(android, "Validate Release APK integrity, identity and signing"), (android, "Retired feature APK binary audit")]), "Internal evaluation signing and retired OCR fingerprints")
    add("iOS build testing", result([(ios, ios_build)]), "Unsigned build, not signed IPA")
    add("Android-iOS feature parity testing", both(suites, "PARTIAL"), "Shared host suites, native device parity not certified")
    outcome = os.getenv("GATE_OUTCOME")
    add("Permanent automated quality gate", {"success":"PASS","failure":"FAIL","cancelled":"BLOCKED","skipped":"BLOCKED"}.get(outcome,"NOT_TESTED"), "Configured CI jobs only")
    add("Release APK compilation", result([(android, android_build)]), "Internal candidate, not production publication")
    add("Automatic merge protection", "NOT_TESTED", "Repository branch protection separately configured and verified")
    add("Production release protection", "NOT_TESTED", "Signing and release approval separate")
    if resources.get("error"):
        add("Emulator navigation/resource sampling", "FAIL", resources["error"])
    else:
        add("Emulator navigation/resource sampling", "PARTIAL" if resources.get("status") == "measured" else "NOT_TESTED", "Five repeated tab-navigation cycles")
    step_evidence = [
        {"job": job["name"], "step": step["name"], "conclusion": step.get("conclusion")}
        for job in jobs for step in job.get("steps", [])
    ]
    report = {"schema": 1, "run": os.getenv("GITHUB_RUN_ID"), "attempt": os.getenv("GITHUB_RUN_ATTEMPT"),
              "commit": os.getenv("GITHUB_SHA"), "baseline": BASELINE, "metrics": metrics,
              "api_error": api_error, "tests": rows, "step_evidence": step_evidence}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    parts = [
        ("1. Passed", {"PASS"}),
        ("2. Passed with observations", {"PASS_WITH_ISSUES"}),
        ("3. Pending / blocked", {"NOT_TESTED", "BLOCKED"}),
        ("4. Partial", {"PARTIAL"}),
        ("Failed", {"FAIL"}),
    ]
    lines = ["# DocsGrid detailed quality report", "", "Run " + str(report["run"]),
             "", "Scope is limited to observed evidence. Missing results are never PASS.", ""]
    if api_error:
        lines.extend(["Job evidence unavailable: " + api_error, ""])
    for heading, statuses in parts:
        lines.extend(["## " + heading, "", "| Test | Status | Scope |", "| --- | --- | --- |"])
        for row in rows:
            if row["status"] in statuses:
                lines.append("| " + " | ".join(str(row[k]).replace("|", "/").replace("\n", " ") for k in ("test","status","scope")) + " |")
        lines.append("")
    lines.extend(["## Before / after metrics", "", "| Metric | Baseline | Candidate |", "| --- | ---: | ---: |"])
    for key, old in BASELINE.items():
        if key in ("commit", "run_id"):
            continue
        new = metrics.get(key)
        lines.append(f"| {key} | {old} | {new if new is not None else 'NOT MEASURED'} |")
    lines.extend(["", "## Analyzer findings", "", "| Platform | Errors | Warnings | Info |", "| --- | ---: | ---: | ---: |"])
    for platform in ("android", "ios"):
        values = [metrics.get(platform + "_analyzer_" + suffix) for suffix in ("errors", "warnings", "infos")]
        lines.append("| " + platform + " | " + " | ".join("NOT MEASURED" if x is None else str(x) for x in values) + " |")
    lines.extend(["", "## Failed and skipped steps", "", "| Job | Step | Conclusion |", "| --- | --- | --- |"])
    for step in step_evidence:
        if step["conclusion"] in ("failure", "cancelled", "skipped", "timed_out"):
            lines.append("| " + " | ".join(str(step[k]).replace("|", "/") for k in ("job", "step", "conclusion")) + " |")
    content = "\n".join(lines) + "\n"
    (out / "report.md").write_text(content)
    if os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write(content)
    if api_error:
        raise SystemExit("Could not obtain job evidence; report is incomplete.")

if __name__ == "__main__":
    main()
