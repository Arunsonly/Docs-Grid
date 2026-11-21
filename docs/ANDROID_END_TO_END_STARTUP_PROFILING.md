# DocsGrid End-to-End Startup Profiling — Draft PR #35

This is read-only diagnostic instrumentation. The ordinary Release evaluation APK
is built, verified and uploaded as before, without any profiling flag.
An **isolated, separately uploaded evaluation APK** is compiled with
`--dart-define=DOCSGRID_STARTUP_PROFILE=true`. Its markers are compile-time
disabled in all ordinary builds. Never deploy the profiling APK to a user's phone.

On a disposable Android 14 KVM emulator, the original seven-run process-cold
TTID baseline is retained. The original Release APK is traced with Perfetto.
Afterwards an E2E variant is installed with `adb install -r` (no app-data
clear). For the variant, one Android cold launch, same-run system Perfetto
trace and Flutter/Dart elapsed milestones are measured.

## Observed Dart stages

- main/binding, root/Home init and post-frame Home callback;
- first SQLite database open;
- cached Home read and live first PDF page;
- dashboard counts/size/favorites summary and recent items;
- core Home ready (latest of first frame, first page, live summary and recent);
- optional background Phone scan, trash summary and theme preferences.

The JSON report contains stage names, durations and hashes only; raw logcat
and user data are not uploaded. Missing required markers fail the test.

## Critical boundaries

TTID is first Activity frame, not TTFD or icon-click latency. Dart times start
at Dart main (a different clock origin), so they cannot be subtracted directly
from TTID. Parallel stage durations must never be added. The last Home
milestone is the **readiness gate**, not necessarily the CPU bottleneck.
The profile build and tracing can increase latency. Clean emulator timings do
not establish performance of a phone with thousands of imported PDFs.
Core Home readiness does not include background Phone scan, backup or recovery.

CI script refuses physical devices. No app data, permissions, PDF storage,
backup/restore or existing functional logic changed. Restore branch Stable-V1
and main are unchanged. PR #35 must remain Draft/unmerged.
