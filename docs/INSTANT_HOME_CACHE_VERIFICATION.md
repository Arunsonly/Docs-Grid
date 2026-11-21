# Instant Home Cache verification (DocsGrid)

This is a **validation-only change** to Draft PR #35; it does not change
PDF/backup/restore/storage/UI behavior. Production HomeCache remains the
same. The only app change is anonymous `StartupTimeline` diagnostic stages,
disabled for ordinary builds.

## Real-device-style force-stop on disposable emulator

The CI workflow retains the original uninstrumented 7-run Release benchmark,
system Perfetto trace, and one opt-in E2E profiling launch. Without
uninstalling, clearing any app data, altering SharedPreferences or opening
PDFs, it performs **two additional process-cold Home launches** on the
installed profiling APK. Each must produce:
- a persisted cached summary HIT after process force-stop;
- a successful live SQLite summary, first page, Recent and Home-core markers;
- no application crash and a parseable Android TTID.
- a report distinguishing **cache was applied before live** from **cache hit
  but live won the race**; neither is misreported as instant first paint.

The output `docsgrid-android-home-cache-verification/relaunch.json` contains
only anonymous metrics and no user filenames, paths, hashes of PDF contents
or contact information. Never run this script on a personal device.

## Actual DB + Backup Restore correctness

Unit and integration tests additionally verify:
- new cache instance sees previous saved summary and recent labels;
- latest summary and recent values replace previous data, and queued writes
  preserve order; empty library clears count and Recent preview;
- actual `DocumentToolsService.restoreBackup(...fullReplacement)` with the
  production migrated SQLite schema changes live PDF count and bytes;
- `document_summary_state` revision triggers invalidate the in-memory
  summary after changing favorites and soft-deleting a PDF;
- subsequent cached snapshot reflects correct values, with no saved document
  IDs, storage paths or actionable stale Recent entries.

### Limitations

CI emulator has no imported personal PDFs. It proves real Android
SharedPreferences persistence and UI milestone completion on that emulator,
not latency or data scale on a populated user's handset. A hit may be too
late to paint before the authoritative DB result; read the explicit field
`cache_was_applied_before_live` in the report. A new on-device interactive
acceptance test would be needed to establish real-phone speed.
