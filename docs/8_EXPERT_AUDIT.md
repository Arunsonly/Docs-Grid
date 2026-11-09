# DocsGrid — Eight-Expert Final Audit

Audit date: 2026-11-09  
Audit baseline: `main` at merge commit `5744438ce3b93d741901904ffe29a5fb716825ac`  
Consolidated remediation branch: `audit/eight-expert-final-hardening`  
PR policy: all findings and corrective changes from these eight review areas are consolidated into one PR; no per-area PRs.

## Audit status

The eight source-review lenses have been re-examined against the post-PR-13 `main` tree. Existing database migration, backup validation, storage-channel, folder concurrency, reminder and security tests were inspected. Two concrete queue-capacity mismatches were found and corrected on the consolidated branch:

- Android used `Executors.newSingleThreadExecutor()`, whose work queue is unbounded, despite the earlier report describing a bounded queue. It now uses a single-worker `ThreadPoolExecutor` with a 64-operation `ArrayBlockingQueue`. Queue saturation returns a clear `BUSY` result. Incoming Android share intents are cleared only after queue admission, so a rejected operation does not discard the share.
- iOS used a serial GCD queue with no admission bound. A 64-slot semaphore now bounds pending storage operations; saturated requests return `BUSY` without blocking the UI thread.

These source changes are **not yet CI-verified**. Do not mark Task 2 or release readiness complete until the consolidated PR has a fresh passing Android and iOS run. Device-only checks remain separate.

## Eight expert review lenses

| # | Expert lens | Source review and evidence | Consolidated remediation / current status | Remaining verification |
|---|---|---|---|---|
| 1 | Software Architecture | Reviewed feature/repository boundaries, database ownership, storage channel, app lifecycle and reminder reconciliation entry points. | Existing repository/service split retained. Startup and resume invoke durable reminder reconciliation. Native storage work is serialized off the UI path. Queue admission is now bounded on both platforms in this branch. | Review full user journeys on installed builds; verify cancellation/lifecycle behaviour under app backgrounding and process death. |
| 2 | Flutter/Dart Engineering | Reviewed async database opening, repository transaction boundaries, error propagation, file staging and lifecycle callbacks. | `AppDatabase` shares one in-flight open Future and resets it after failure; regression tests cover concurrent first-open and retry. Provider errors fail closed rather than being treated as missing files. Backup validation is performed before restore side effects. | Add/execute cross-layer failure tests for interrupted provider copies and UI cancellation; inspect runtime error reporting on devices. |
| 3 | Database & Data Integrity | Inspected schema v1/v2/v3, foreign keys, migration transaction callback, rollback/downgrade handling, row validation and folder concurrency logic. | Real SQLite FFI fixtures cover v1→v3, v1→v2→v3, downgrade refusal, failed migration rollback, and foreign-key checks. A v1→v2 target-version regression is covered. Concurrent folder creation has a repository-level transaction test. | Run full test suite on the current branch. Add stronger real-SQLite concurrent repository race coverage beyond the current serialized fake-database test; exercise migration on a copy of real user data before release. |
| 4 | Android Platform Engineering | Reviewed SAF tree permission acquisition, persisted URI grants, native file operations, provider NOT_FOUND classification, share intake, directory deletion and channel threading. | Native provider I/O runs on a single worker. This branch adds a 64-item bounded queue and explicit BUSY response; incoming shares are retained if admission fails. Existing copy paths verify SHA-256 and clean up failed destinations. | Physical Android checks: grant/revoke/reselect, reboot persistence, provider disconnect, hidden/non-empty folders, share-sheet intake, large/slow provider operations and queue saturation. |
| 5 | iOS Platform Engineering | Reviewed Files picker, security-scoped bookmark storage/resolution, coordinated provider reads, background file operations, Open-In and directory deletion. | Provider I/O uses a serial background queue. This branch adds a 64-slot admission bound and BUSY response rather than permitting unbounded queued work. Directory deletion checks actual contents, including hidden entries. | Physical iPhone checks: bookmark persistence after force quit/reboot, stale/revoked bookmark recovery, iCloud/third-party provider downloads, Files Open-In, background/foreground transitions and queue saturation. |
| 6 | Security & Privacy | Reviewed untrusted ZIP names, archive resource preflight, restore folder graph, table references, path-token generation, URI handling and file replacement behaviour. | ZIP preflight limits compressed/expanded size, entry count, entry size, central directory and compression ratio; restore rejects unsafe paths/symlinks/duplicates and validates relational references before provider writes. Imported IDs are not used directly as filesystem path segments. | Threat-model review and malicious archive corpus testing remain. Confirm sensitive document data is never emitted to logs/analytics; perform platform permission review on release builds. |
| 7 | Performance & Reliability | Reviewed main-thread/platform I/O, hashing/copy loops, archive creation/decoding, memory limits and notification reconciliation. | Android and iOS storage operations are off the UI thread and now have bounded pending queues. Backup creation/validation uses file streams and archive preflight limits; copy operations use chunked/verified paths where supported. | No measured device benchmarks yet. Profile cold start, 1/10/100/1000-document libraries, large PDFs, archive peak memory, slow cloud providers and repeated queue saturation on low-memory devices. |
| 8 | QA, Testing & Release Engineering | Reviewed Flutter CI workflow, analyzer/test/build gates and regression coverage. Main's post-merge CI is a separate run from PR CI. | Existing tests cover database migration/open concurrency, backup validation, malformed snapshot rows, folder validation/concurrency, storage-channel contracts, duplicate hashes, OCR query behaviour and reminder logic. All new fixes remain on this one branch for one PR. | Await this branch's uncancelled Android/iOS CI. Then run end-to-end import→move→rename→trash→restore→backup→fresh-install restore flows. Produce and install release artifacts only after device checks. |

## Consolidated code change in this branch

1. `platform/android/MainActivity.kt`
   - Replace unbounded single-thread executor with a one-worker, 64-slot bounded executor.
   - Return `BUSY` on queue saturation.
   - Clear the incoming share Intent only after successful queue admission.
2. `platform/ios/AppDelegate.swift`
   - Add a 64-slot semaphore around the serial storage queue.
   - Reject excess pending storage operations immediately with `BUSY`, without blocking the main thread.
3. This report records the eight-lens findings, evidence, remediation and remaining device/release gates.

## CI and sign-off rules

- Keep all eight-area source fixes and any follow-up corrections in `audit/eight-expert-final-hardening` and exactly one PR to `main`.
- Run Android analyze, full Flutter tests and debug APK build.
- Run iOS analyze, full Flutter tests and unsigned iOS build.
- Fix every failure found by the complete run on this same branch; do not open separate PRs.
- Merge only when both platform jobs pass.
- A green hosted CI verifies runner builds and automated tests only. It does not certify physical SAF/Files permissions, bookmark persistence, OS notification delivery, cloud-provider behaviour, real-device recovery or measured performance.

## Final sign-off

**Eight source-review lenses: reviewed.**  
**Two bounded-queue corrections: committed to the single consolidated branch.**  
**CI verification of these corrections: pending.**  
**Physical-device, provider, performance and end-to-end release verification: pending.**

Do not label the eight-area audit fully signed off or DocsGrid release-ready until the consolidated CI and the applicable device/release gates are complete.
