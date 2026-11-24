#!/usr/bin/env python3
"""Scoped, conservative source and APK audit; never delete application files."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

RETIRED = re.compile(r'\b(?:OcrSearchPreferences|OcrSearchModeControl|PhoneOcrSearchIndex|OcrIndexCancelled|TextRecognizer|OcrSearchIndexSummary|indexPendingPdfsForSearch|indexPdfTextFromUri|extractPhonePdfTextFromUri|ocrSearchAvailable|DocumentPdfViewerScreen|findDuplicateGroups|createManualBackup|BackupChainPlan|migrateLegacyStorageToCanonicalIfNeeded|google_mlkit_text_recognition)\b')

def source_audit():
    files = sorted(Path("lib").rglob("*.dart"))
    contents = {p: p.read_text() for p in files}
    findings = [{"file": str(p), "line": i, "symbol": m.group(0)}
                for p, source in contents.items()
                for i, line in enumerate(source.splitlines(), 1)
                for m in RETIRED.finditer(line)]
    imports = {}
    root = Path.cwd().resolve()
    by_absolute = {p.resolve(): p for p in files}
    for path, source in contents.items():
        targets = []
        for uri in re.findall(r"""^\s*(?:import|export|part)\s+['"]([^'"]+)['"]""", source, re.M):
            if uri.startswith("package:docs_grid/"):
                target = root / "lib" / uri.removeprefix("package:docs_grid/")
            elif ":" not in uri:
                target = path.parent / uri
            else:
                continue
            if target.resolve() in by_absolute:
                targets.append(by_absolute[target.resolve()])
            else:
                findings.append({"file": str(path), "missing_local_import": uri})
        imports[path] = targets
    reachable = set()
    pending = [Path("lib/main.dart")]
    while pending:
        path = pending.pop()
        if path not in reachable:
            reachable.add(path)
            pending.extend(imports.get(path, []))
    config = Path("pubspec.yaml").read_text() + Path("pubspec.lock").read_text()
    workflow = Path(".github/workflows/flutter-ci.yml").read_text()
    for symbol in ("google_mlkit_",):
        if symbol in config:
            findings.append({"retired_dependency": symbol})
    for symbol in ("android.permission.CAMERA", "NSCameraUsageDescription",
                   "NSPhotoLibraryUsageDescription", "com.google.mlkit:text-recognition"):
        if symbol in workflow:
            findings.append({"retired_build_setting": symbol})
    return {"scope": "retired symbol/import/config scan; import reachability is not runtime call reachability",
            "dart_files": len(files), "dart_lines": sum(len(s.splitlines()) for s in contents.values()),
            "import_unreachable_candidates": [str(p) for p in files if p not in reachable],
            "findings": findings}

def apk_audit(apk, permissions):
    fingerprints = (b"Lcom/google/mlkit/vision/text/", b"Lcom/google_mlkit_text_recognition/")
    with zipfile.ZipFile(apk) as z:
        corrupt = z.testzip()
        if corrupt:
            raise RuntimeError("Invalid APK member: " + corrupt)
        names = z.namelist()
        hits = [name for name in names if re.search(r"mlkit|text.recognizer|devanagari", name, re.I)]
        for name in names:
            if re.fullmatch(r"classes\d*\.dex", name):
                data = z.read(name)
                hits.extend(name + ":" + token.decode() for token in fingerprints if token in data)
    permissions_text = permissions.read_text()
    if "android.permission.CAMERA" in permissions_text:
        hits.append("manifest:android.permission.CAMERA")
    with apk.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"scope": "targeted APK ZIP/DEX fingerprints and manifest camera permission; obfuscation limits detection",
            "apk_bytes": apk.stat().st_size, "apk_sha256": digest,
            "permissions": permissions_text.splitlines(), "findings": hits}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--permissions", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = apk_audit(args.apk, args.permissions) if args.apk else source_audit()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if report["findings"]:
        raise SystemExit("Retired-feature audit found residual code/configuration")

if __name__ == "__main__":
    main()
