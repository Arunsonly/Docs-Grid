# DocsGrid — Release candidate preparation (not public distribution)

This runbook prepares reproducible builds; it never creates a production
signing identity, merges the audit PR, or publishes an application.

## Android production signing
1. Obtain the approved package ID, key alias, keystore and durable key-custody
   procedure from the owner. Do not guess, generate or substitute a debug key.
2. Generate the Flutter Android scaffold, then apply the same native
   MainActivity, manifest, desugaring, SDK and bundled Devanagari OCR settings
   as the exact CI workflow. Record every generated Gradle change.
3. On the generated app, run `PYTHONPATH=tool python3 tool/prepare_android_ocr.py`.
   It uses the same pinned bundled Devanagari library as CI; release signing
   refuses to proceed without the dependency.
4. Set these environment variables through a protected local/CI secret store:
   DOCSGRID_ANDROID_KEYSTORE_PATH, DOCSGRID_ANDROID_STORE_PASSWORD,
   DOCSGRID_ANDROID_KEY_ALIAS, DOCSGRID_ANDROID_KEY_PASSWORD.
5. Run `python3 tool/prepare_android_release_signing.py` after scaffold
   generation. This script refuses missing secrets or unrecognized debug
   signing configuration.
6. Run `flutter build apk --release` and `flutter build appbundle --release`
   only with the approved identity. Verify certificate SHA-256, package ID,
   versionCode, merged manifest, OCR classes and the artifact digest.
7. Test the exact release APK on a clean Android installation and document
   the real-device PDF, backup, rename, OCR, permissions and recovery flows.

## iOS
A successful unsigned iOS CI build is not a distribution-ready .ipa.
Apple Team ID, Bundle ID, certificates, provisioning profiles, code-signing
entitlements and on-device checks require the owner's separate decisions.

## Approval boundary
Release tooling is NOT approval to sign with a newly invented key, upload
to an app store, publish externally or merge the draft PR. Keep any missing
key/device/approval step as NOT RUN, and complete independent source tests.
