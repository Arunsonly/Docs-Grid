#!/usr/bin/env python3
"""Prepare a GENERATED Flutter Android app for a user-controlled release key.

This script never generates keys and never prints secret values. It fails
closed when production identity/signing variables are unavailable. Run after
flutter create --platforms=android and before flutter build apk/appbundle.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

REQUIRED = (
    "DOCSGRID_ANDROID_KEYSTORE_PATH",
    "DOCSGRID_ANDROID_STORE_PASSWORD",
    "DOCSGRID_ANDROID_KEY_ALIAS",
    "DOCSGRID_ANDROID_KEY_PASSWORD",
)


def configure_release(gradle: Path, env: dict[str, str]) -> None:
    missing = [key for key in REQUIRED if not env.get(key)]
    if missing:
        raise RuntimeError("Production signing configuration is incomplete: " + ", ".join(missing))
    keystore = Path(env["DOCSGRID_ANDROID_KEYSTORE_PATH"])
    if not keystore.is_file():
        raise RuntimeError("Production keystore file is unavailable; no release artifact was signed.")
    if not gradle.is_file():
        raise RuntimeError("Generated Android Gradle app configuration was not found.")

    original = gradle.read_text()
    if gradle.suffix == ".kts":
        signature = """
    signingConfigs {
        create("docsgridProduction") {
            storeFile = file(System.getenv("DOCSGRID_ANDROID_KEYSTORE_PATH"))
            storePassword = System.getenv("DOCSGRID_ANDROID_STORE_PASSWORD")
            keyAlias = System.getenv("DOCSGRID_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("DOCSGRID_ANDROID_KEY_PASSWORD")
        }
    }
"""
        release = 'signingConfig = signingConfigs.getByName("docsgridProduction")'
        pattern = r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)'
    else:
        signature = """
    signingConfigs {
        docsgridProduction {
            storeFile file(System.getenv("DOCSGRID_ANDROID_KEYSTORE_PATH"))
            storePassword System.getenv("DOCSGRID_ANDROID_STORE_PASSWORD")
            keyAlias System.getenv("DOCSGRID_ANDROID_KEY_ALIAS")
            keyPassword System.getenv("DOCSGRID_ANDROID_KEY_PASSWORD")
        }
    }
"""
        release = "signingConfig signingConfigs.docsgridProduction"
        pattern = r'signingConfig\s+signingConfigs\.debug'

    if "docsgridProduction" in original:
        raise RuntimeError("Release signing configuration is already present; review before rerunning.")
    source, count = re.subn(pattern, release, original, count=1)
    if count != 1:
        raise RuntimeError("Generated Android release block was not recognized; refusing a debug-signed release.")

    # Insert after the FIRST android { block, not at a random dependencies block.
    match = re.search(r"\bandroid\s*\{", source)
    if match is None:
        raise RuntimeError("Android Gradle source has no android block.")
    source = source[:match.end()] + signature + source[match.end():]
    gradle.write_text(source)
    print("Prepared explicit Android production signing (no secrets displayed).")


if __name__ == "__main__":
    candidates = (Path("android/app/build.gradle.kts"), Path("android/app/build.gradle"))
    path = next((candidate for candidate in candidates if candidate.exists()), candidates[0])
    configure_release(path, dict(os.environ))
