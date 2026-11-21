# DocsGrid — Critical Path Profiling (system-level Phase 1)

**Scope:** Only PR #35, Draft/unmerged. Existing Release evaluation APK is
reused unchanged; this profiling stage does **not** instrument or change Dart,
Android application code, UI, PDFs, SQLite, settings, package ID, signing,
backup/restore or storage permissions.

## Reproducible same-APK workflow

1. The Android CI job builds and verifies the evaluation Release APK.
2. The Linux/KVM Android 14 x86_64 emulator measures seven process-cold
   launches **without tracing** and saves `cold-launch.json` (P50/P95).
3. On the **same already-installed APK and emulator**, an extra
   `am start -S -W` cold launch is recorded under Perfetto for 16 seconds.
4. The report refuses a missing/mismatched seven-run baseline, validates
   startup output, requires a nonempty binary trace, and publishes both.

Artifacts (14-day retention):
- `docsgrid-android-cold-launch-baseline` — raw baseline JSON (7 untraced runs).
- `docsgrid-android-startup-critical-path` — `startup-critical-path.json`
  and `docsgrid-startup.perfetto-trace`.

Open the trace in https://ui.perfetto.dev and inspect **Android App Startups**,
`bindApplication`, `activityStart`, thread scheduling, Flutter UI/raster,
GC and binder activity around the first Activity frame. It helps locate
Android/system/Flutter engine stalls and lock contention **without slowing
production users with persistent loggers**.

## Measurement boundaries

- TTID = first displayed Activity frame. This is **not** the phone icon-tap
  wall clock and **not** Home's completed data/preview readiness (TTFD).
- Tracing adds overhead; the single traced TTID is only diagnostic, **not**
  a replacement for the untraced P50/P95 or evidence of a speed regression.
- OS filesystem caches can stay warm even when the process is stopped.
- Emulator measurements must not be projected onto actual phones.
- The trace does **not** distinguish individual Dart operations (Home cache,
  SQLite summary, recent items, Phone index) without separate, opt-in
  app-specific phase markers. Do not invent per-stage times or declare a
  bottleneck without examining the captured trace.
- Avoid uploading personal-device traces: system traces may include
  process/activity identifiers. CI uses an empty emulator.

The profiler never installs/uninstalls, clears storage, forces permissions,
modifies application source or touches user PDFs. It removes only its own
temporary Perfetto trace from the CI emulator after transfer. Stable-V1 and
`main` remain unchanged.

Manual reproduction on a **dedicated backed-up test emulator** after running
`benchmark_android_cold_launch.py`:

```bash
python3 scripts/profile_android_startup.py \
  --apk artifacts/release/app-release.apk \
  --baseline startup-results/cold-launch.json \
  --output-dir startup-results/critical-path \
  --trace-seconds 16
```
