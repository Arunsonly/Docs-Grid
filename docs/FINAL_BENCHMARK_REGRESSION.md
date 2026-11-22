# Final Benchmark + Regression Testing

Validation-only additions to DocsGrid Draft PR #35.

The same GitHub runner builds the pre-profiling PR head c5a17a0e0e451e40a0968156dde08fde0619dedd and current candidate with the same SDK, generated Android native scaffold, app identity, icon, signing key, and no profiling flag.

The same disposable Android 14 emulator executes seven process-cold `am start -S -W` TotalTime samples per normal Release APK, excluding one warmup each. The candidate also retains its initial seven-run sample series, Perfetto profile, instrumented Dart-stage timing, and two cached Home relaunches.

Regression gates require successful Android and iOS static analysis, all unit/widget tests, functional integration, full backup/restore tests, 10k/100k FFI SQLite performance fixtures, Android debug/release builds and unsigned iOS build.

The final machine-readable artifact is docsgrid-final-benchmark-regression-report, with reference.json, candidate.json, final-benchmark.json and FINAL_REPORT.md.

No PDF, DB schema, application storage behavior, UI functionality, backup or restore logic changed. `main` and protected Stable-V1 remain untouched. Profiling APK is separate from both compared ordinary APKs.

Limitations: Android TTID is first display, not TTFD or full Home readiness. Empty emulator samples do not certify a populated phone; small N=7 samples are directional rather than statistically decisive. Performance tests based on desktop SQLite FFI do not predict device latency.
