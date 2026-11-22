# DocsGrid — Android Release Build & Cold-Launch Baseline

**Scope:** Draft PR #35, performance-measurement infrastructure only. No changes
to app Dart logic, Android storage integration, PDF bytes, databases, backup,
restore, user files, app ID, splash assets or launcher icon.

## Artifacts built by Flutter CI

- `docsgrid-android-debug-apk` — the existing `app-debug.apk`, unchanged.
- `docsgrid-android-release-evaluation-apk` — `app-release.apk` from
  `flutter build apk --release`; the Release APK is checked with `unzip -tq`,
  Android `apksigner verify` and `aapt dump badging`.
- `docsgrid-android-cold-launch-baseline` — measured raw JSON, including
  sample timings and the APK's SHA-256, produced by the separate emulator job.

**Signing warning:** Flutter-generated Android scaffolding ordinarily signs a
locally built evaluation Release APK with the **debug keystore**. It is **not a
Play Store production release** and must not be distributed as one. A new
GitHub Actions runner may generate a different debug certificate, so an
existing DocsGrid installation may not accept an in-place update. **Do not
uninstall to force an update without first saving and verifying a complete
backup.** This job does not generate or publish production credentials.

## What the benchmark measures

Android's `adb shell am start -S -W` reports `TotalTime`, which is the
**Time To Initial Display (TTID)**: intent to first drawn Activity frame.
Each iteration begins with a *process-cold* launch, and a warmup is excluded.
The emulator may have warm operating-system file caches.

This is **not** the launcher-icon touch latency, **not** a completely cold
device reboot, and **not** **TTFD** (time until PDF rows and counts have loaded).
DocsGrid has not been modified to call `reportFullyDrawn`. We deliberately
do not mislabel first-frame measurements as full Home readiness.

The initial emulator dataset has no imported real user PDFs. Do not compare
this synthetic first-install baseline to a populated on-device library as if
the conditions were identical. This establishes a repeatable baseline for
**future commits on the same emulator API/profile**. A claimed performance
improvement requires before/after runs on the **same model and conditions**.

The benchmark reports each run plus the median (P50), nearest-rank P95, mean,
minimum and maximum. There is **no arbitrary speed pass/fail threshold**.

## Reproduce on an emulator or a backed-up test phone

Requirements: Android SDK `adb`, Python 3, a compatible installed Android
emulator/device and the verified Release APK.

```bash
python3 -m unittest discover -s scripts -p 'test_android_cold_launch.py' -v
python3 scripts/benchmark_android_cold_launch.py \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --output startup-results/cold-launch.json \
  --iterations 7 --warmups 1
```

**Use a dedicated emulator whenever possible.** The benchmark installs the
supplied APK with `adb install -r` and changes animation-scale settings on
the attached device. It does **not** clear app storage, run `pm clear`,
uninstall the package, delete PDFs or modify the database. On a physical
phone, verify package and signing compatibility and back up all data first.

The CI emulator is configured as Android API 34 / x86_64 / Pixel 6 profile.
Comparisons across different virtual-device hosts or API levels are only
indicative, not controlled hardware evidence.

## Safe restore point

This change is limited to CI and measurement scripts. The previous
PR #35 commit remains available as a Git SHA, and this version gets a new
independent SHA. The PR remains a Draft; `main` is unchanged. Git source
restoration does not roll a user's database backwards.
