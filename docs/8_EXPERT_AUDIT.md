# DocsGrid — 8 Expert Engineering Audit

Repository: `Arunsonly/Docs-Grid`  
Review branch: `audit/10-core-functions`  
Baseline: completed 10 Core Functions Audit  
Status: **Initial source-review pass recorded; remediation and verification remain in progress. This is not a final sign-off.**

## Review lenses

| # | Expert lens | Areas inspected | Initial status |
|---|---|---|---|
| 1 | Software Architecture | feature boundaries, repository/service ownership, dependency injection, lifecycle | Findings recorded; broader UI/lifecycle review pending |
| 2 | Flutter/Dart Engineering | async flows, state boundaries, file handling, error propagation | Findings recorded; widget lifecycle review pending |
| 3 | Database & Data Integrity | SQLite schema, migrations, transactions, referential integrity, concurrency | Findings recorded; migration fixtures needed |
| 4 | Android Platform Engineering | SAF grants, URI handling, native storage bridge, share intake | Source reviewed; device/provider validation pending |
| 5 | iOS Platform Engineering | Files picker, security-scoped bookmarks, native storage bridge | Source reviewed; device/provider validation pending |
| 6 | Security & Privacy | untrusted names/paths, archive validation, URI boundaries, local data | Static review underway; threat-model pass pending |
| 7 | Performance & Reliability | large PDFs, archive memory, hashing, main-thread I/O, recovery | Findings recorded; benchmarks pending |
| 8 | QA, Testing & Release Engineering | automated coverage, CI reproducibility, testability, release gates | Findings recorded; expanded test plan pending |

## Initial findings

### EXP-01 — Native storage I/O is performed synchronously by platform-channel handlers
**Severity: High — performance/reliability**

- Evidence: `platform/android/MainActivity.kt` handles `readPdf`, `copyPdf`, `copyPdfToPath`, `sha256Pdf`, `readTextFile`, and directory enumeration directly inside the MethodChannel handler. These operations read, copy, hash, or enumerate provider content.
- Evidence: `platform/ios/AppDelegate.swift` dispatches storage methods from `handle(_:result:)`; helpers such as `readPdf`, `copyPdf`, `sha256Pdf`, `listDirectory`, and metadata reads perform synchronous FileManager/Data/FileHandle work.
- Risk: large or slow cloud/provider files can block the UI/platform thread, cause visible freezes, watchdog termination, or Android ANRs.
- Required action: move file/provider work to a bounded background execution queue; marshal UI presentation and Flutter results safely; add large-file and slow-provider integration coverage.
- Status: confirmed by source inspection; runtime impact not yet benchmarked.

### EXP-02 — Database lazy-open is not guarded against concurrent first access
**Severity: High — data/reliability**

- Evidence: `AppDatabase.database` checks `_database` and then awaits `openDatabase`, but has no shared in-flight Future.
- Risk: two first-use calls made before the first open completes can both attempt to open and initialize the same database. This can cause duplicate initialization work and nondeterministic startup behaviour.
- Required action: cache a single in-flight open Future and clear it only after an open failure; add a concurrent-first-access regression test.
- Status: concurrency window confirmed by source inspection; reproduction test pending.

### EXP-03 — Reminder database writes and OS notification scheduling are separate failure domains
**Severity: High — functional reliability**

- Evidence: `ReminderRepository.create` inserts the row before requesting permission and scheduling; `update` commits the row before cancel/reschedule; `snooze` commits state before scheduling the snooze.
- Risk: if the plugin, permission API, or OS scheduler throws after the database commit, persisted reminder state and actual scheduled notifications can diverge.
- Required action: define explicit scheduling-failure semantics, reconcile persisted reminders with pending OS notifications on startup/resume, and test plugin failures at each boundary.
- Status: failure window confirmed by source inspection; failure-injection tests pending.

### EXP-04 — Folder uniqueness and empty-folder deletion use check-then-act sequences
**Severity: High — data integrity**

- Evidence: `FolderRepository.create` and `rename` check sibling names before the insert/update without a database uniqueness constraint covering active siblings. `deleteEmpty` counts child folders/documents before opening its soft-delete transaction.
- Risk: concurrent operations can create duplicate sibling names or insert content between the emptiness check and soft-delete.
- Required action: enforce active-sibling uniqueness at the database layer with a migration strategy for pre-existing duplicates; repeat emptiness checks and soft-delete in one transaction.
- Status: race windows confirmed by source inspection; concurrent database tests pending.

### EXP-05 — Backup/restore materializes large payloads in memory
**Severity: High — performance/reliability**

- Evidence: `DocumentToolsService.createBackup` reads each PDF with `readAsBytes`, accumulates archive entries, and encodes the complete ZIP in memory. `restoreBackup` reads the full ZIP, decodes it, and materializes PDF entry bytes before writing restored files.
- Risk: large libraries or a single large PDF can cause high peak memory, long pauses, or out-of-memory termination, especially on lower-memory phones.
- Required action: use streaming archive/file processing where supported, enforce and communicate safe size limits otherwise, and add peak-memory/large-archive benchmarks.
- Status: implementation behaviour confirmed by source inspection; device measurements pending.

### EXP-06 — Broad provider lookup catches can convert access errors into create attempts
**Severity: Medium — storage consistency**

- Evidence: folder materialization and migration paths catch all errors from `findChildUri` and then call `createDirectory`.
- Risk: permission revocation, provider outage, or query failure may be treated like “child does not exist”, causing duplicate folders or masking the real access failure.
- Required action: distinguish a genuine not-found result from provider/permission errors; fail closed for unknown failures; add fake-provider tests.
- Status: broad catch behaviour confirmed by source inspection; provider-specific reproduction pending.

### EXP-09 — Deleting a database-empty folder could remove unmanaged external files
**Severity: High — data safety**

- Evidence: folder deletion previously checked only DocsGrid database rows before calling the platform's generic delete operation. iOS used `FileManager.removeItem` for a directory, which can remove its contents; Android delegated directory deletion to the selected SAF provider.
- Risk: files manually added through Files/another file manager, or otherwise not represented in SQLite, could be deleted with the folder.
- **Remediation committed:** Android now checks the provider's actual directory contents before deleting a directory; iOS now enumerates the actual directory (including hidden entries) and refuses deletion unless it is empty.
- Status: source fix committed; platform compile CI pending; physical/provider race testing remains required.

### EXP-07 — Hosted CI dependency/toolchain resolution is not fully reproducible
**Severity: Medium — release engineering**

- Evidence: root repository listing contains no committed `pubspec.lock`; workflow selects Flutter `stable` rather than a pinned SDK version and generates native scaffolding during CI.
- Risk: dependency resolution and generated Android/iOS project scaffolding can change between runs without a source change.
- Required action: commit the application lockfile, pin or deliberately manage the Flutter toolchain, and document generated native scaffolding/version assumptions.
- Status: repository/workflow configuration confirmed by source inspection.

### EXP-08 — Critical integration boundaries have limited automated regression coverage
**Severity: Medium — QA**

- Evidence: current test inventory has 10 Dart test files / 46 tests, while platform storage bridge operations, database migration from real v1/v2 database files, scheduler failure recovery, and concurrent folder operations do not have dedicated automated integration suites in this branch.
- Risk: hosted analyze/unit CI can pass while platform-channel, migration, provider, and cross-layer regressions remain undetected.
- Required action: add migration fixtures, fake MethodChannel/provider contract tests, notification failure injection, and end-to-end import/move/restore flows.
- Status: test inventory and current test paths inspected; expanded coverage not yet implemented.

### EXP-10 — Backup validation has no archive expansion/resource limits
**Severity: High — security/reliability**

- Evidence: `validateBackup` calls `ZipDecoder().decodeBytes(await zipFile.readAsBytes())` before validating manifest contents, and `restoreBackup` decodes the archive again. There is no pre-decode archive-size, total uncompressed-size, per-entry-size, or entry-count limit.
- Risk: a malformed or highly-compressed ZIP selected by the user can cause excessive memory allocation or app termination before integrity checks complete.
- Required action: preflight ZIP central-directory metadata and enforce explicit limits before decompression; stream validation/restore where possible; add oversized and high-compression-ratio fixtures.
- Status: source behaviour confirmed; hardening and tests pending.

## Next execution order inside this audit

1. Fix the shared database-open race and add a regression test.
2. Make folder uniqueness/empty deletion safe under concurrent operations.
3. Define and implement reminder scheduling reconciliation/failure semantics.
4. Move native storage I/O off the UI thread without changing the MethodChannel contract.
5. Reduce backup/restore peak memory or add explicit safe limits.
6. Narrow provider error handling and add fake-provider tests.
7. Make CI dependency/toolchain resolution reproducible.
8. Re-run the full Android/iOS CI and update each finding with evidence.

## Sign-off rule

No expert lens is marked PASS until its source review, relevant automated tests, and applicable integration checks have evidence. Hosted CI does not certify real Android SAF permissions, iOS security-scoped bookmark persistence, cloud-provider behaviour, notification delivery, or physical-device performance.
