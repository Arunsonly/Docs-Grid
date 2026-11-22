#!/usr/bin/env python3
"""Pin a bundled Hindi/Devanagari ML Kit model in generated Android builds.

Invoked by both CI and the documented release workflow. Never downloads
models at app runtime or silently accepts an incompatible native version.
"""
from __future__ import annotations

import re
from pathlib import Path

DEPENDENCY = "com.google.mlkit:text-recognition-devanagari:16.0.1"


def configure_ocr(build: Path) -> None:
    if not build.is_file():
        raise RuntimeError("Generated Android Gradle app file was not found")
    content = build.read_text()
    if re.search(r"com\.google\.mlkit:text-recognition-devanagari:(?!16\.0\.1)[A-Za-z0-9._-]+", content):
        raise RuntimeError("Conflicting native Devanagari OCR dependency version")
    dependency = (
        f'implementation("{DEPENDENCY}")'
        if build.suffix == ".kts"
        else f"implementation '{DEPENDENCY}'"
    )
    if dependency in content:
        return
    opening = re.search(r"\bdependencies\s*\{", content)
    if opening:
        content = (content[:opening.end()] + "\n    " + dependency
                   + content[opening.end():])
    else:
        content += "\ndependencies {\n    " + dependency + "\n}\n"
    build.write_text(content)
    print("Configured bundled Devanagari OCR dependency in", build)


if __name__ == "__main__":
    locations = (Path("android/app/build.gradle.kts"), Path("android/app/build.gradle"))
    target = next((path for path in locations if path.is_file()), locations[0])
    configure_ocr(target)
