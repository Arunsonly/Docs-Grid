# DocsGrid — 8 Expert Engineering Audit

Repository: `Arunsonly/Docs-Grid`  
Review branch: `audit/10-core-functions`  
Baseline: completed 10 Core Functions Audit  
Status: **Eight engineering review lenses inspected; remediation committed for the high-risk source findings. **Source-audit sign-off: COMPLETE.** Full Android/iOS CI run 42508391092 passed on the committed source and resolved lockfile (56 tests, Android Debug APK, iOS unsigned build). A supplementary run 42509056268 is checking the stricter `--enforce-lockfile` workflow mode; it does not contain further source-code changes. Real-device/provider and measured-performance checks remain deferred to their later platform/performance tasks.**

## Review lenses

| # | Expert lens | Areas inspected | Initial status |
|---|---|---|---|
| 1 | Software Architecture | feature boundaries, repository/service ownership, dependency injection, lifecycle | Source review completed; lifecycle and cross-layer risks recorded |
| 2 | Flutter/Dart Engineering | async flows, state boundaries, file handling, error propagation | Source review completed; async and error-boundary risks recorded |
| 3 | Database & Data Integrity | SQLite schema, migrations, transactions, referential integrity, concurrency | Source review completed; database-open regression tests added; migration fixtures remain |
| 4 | Android Platform Engineering | SAF grants, URI handling, native storage bridge, share intake | Source review completed; background I/O and provider error handling remediated; device validation pending |
| 5 | iOS Platform Engineering | Files picker, security-scoped bookmarks, native storage bridge | Source reviewed; device/provider validation pending |
| 6 | Security & Privacy | untrusted names/paths, archive validation, URI boundaries, local data | Static source review completed; backup path and ZIP resource validation hardened; broader threat-model verification remains |
| 7 | Performance & Reliability | large PDFs, archive memory, hashing, main-thread I/O, recovery | Source review completed; memory/ZIP limits added; measured device benchmarks remain |
| 8 | QA, Testing & Release Engineering | automated coverage, CI reproducibility, testability, release gates | Source review completed; regression tests and CI gates expanded; end-to-end provider tests remain |

## Initial findings

### EXP-01 — Native storage I/O is performed synchronously by platform-channel handlers
**Severity: High — performance/reliability**

- Evidence: `platform/android/MainActivity.kt` handles `readPdf`, `copyPdf`, `copyPdfToPath`, `sha256Pdf`, `readTextFile`, and directory enumeration directly inside the MethodChannel handler. These operations read, copy, hash, or enumerate provider content.
- Evidence: `platform/ios/AppDelegate.swift` dispatches storage methods from `handle(_:result:)`; helpers such as `readPdf`, `copyPdf`, `sha256Pdf`, `listDirectory`, and metadata reads perform synchronous FileManager/Data/FileHandle work.
- Risk: large or slow cloud/provider files can block the UI/platform thread, cause visible freezes, watchdog termination, or Android ANRs.
- **Remediation committed:** Android storage work now runs on a single worker with a bounded queue (64 pending operations); channel replies are marshalled to the main thread. iOS provider/file work uses a dedicated serial background queue; picker/preview UI stays on main.
- Status: source remediation committed; latest native compile CI pending; real slow-provider and large-file measurements remain.

### EXP-02 — Database lazy-open is not guarded against concurrent first access
**Severity: High — data/reliability**

- Evidence: `AppDatabase.database` checks `_database` and then awaits `openDatabase`, but has no shared in-flight Future.
- Risk: two first-use calls made before the first open completes can both attempt to open and initialize the same database. This can cause duplicate initialization work and nondeterministic startup behaviour.
- **Remediation committed:** the database caches one in-flight open Future and clears it after failure.
- **Regression tests added:** concurrent first access opens once; a failed open can be retried.

### EXP-03 — Reminder database writes and OS notification scheduling are separate failure domains
**Severity: High — functional reliability**

- Evidence: `ReminderRepository.create` inserts the row before requesting permission and scheduling; `update` commits the row before cancel/reschedule; `snooze` commits state before scheduling the snooze.
- Risk: if the plugin, permission API, or OS scheduler throws after the database commit, persisted reminder state and actual scheduled notifications can diverge.
- **Remediation committed:** persisted reminder rows are now reconciled against OS scheduling on app startup and every resume. Disabled/completed rows are cancelled; active rows and future snoozes are rescheduled. Failures leave database records intact for retry on the next resume.
- Regression coverage added for which persisted states should have notifications. OS/plugin failure injection remains a device/integration check.

### EXP-04 — Folder uniqueness and empty-folder deletion use check-then-act sequences
**Severity: High — data integrity**

- Evidence: `FolderRepository.create` and `rename` check sibling names before the insert/update without a database uniqueness constraint covering active siblings. `deleteEmpty` counts child folders/documents before opening its soft-delete transaction.
- Risk: concurrent operations can create duplicate sibling names or insert content between the emptiness check and soft-delete.
- **Remediation committed:** create/rename recheck active sibling names inside their write transactions; empty-folder deletion rechecks children and soft-deletes atomically; document imports revalidate active destination folders and categories inside their insert transaction.
- Limitation: no partial unique index was added because soft-delete/revival semantics and existing duplicate cleanup require a migration policy. Concurrent repository-level race tests remain.

### EXP-05 — Backup/restore materializes large payloads in memory
**Severity: High — performance/reliability**

- Evidence: `DocumentToolsService.createBackup` reads each PDF with `readAsBytes`, accumulates archive entries, and encodes the complete ZIP in memory. `restoreBackup` reads the full ZIP, decodes it, and materializes PDF entry bytes before writing restored files.
- Risk: large libraries or a single large PDF can cause high peak memory, long pauses, or out-of-memory termination, especially on lower-memory phones.
- **Mitigation committed:** backup creation and restore validation now enforce compressed archive (128 MiB), expanded archive (256 MiB), per-entry (128 MiB), entry-count (10,000), central-directory (8 MiB), and expansion-ratio limits before ZIP decompression. Creation also checks limits before reading each PDF and before writing the ZIP.
- Limitation: archive/PDF payloads are still materialized in memory within these caps; streaming backup remains a future improvement. Device peak-memory benchmarks remain.

### EXP-06 — Broad provider lookup catches can convert access errors into create attempts
**Severity: Medium — storage consistency**

- Evidence: folder materialization and migration paths catch all errors from `findChildUri` and then call `createDirectory`.
- Risk: permission revocation, provider outage, or query failure may be treated like “child does not exist”, causing duplicate folders or masking the real access failure.
- **Remediation committed:** Android and iOS now return a distinct `NOT_FOUND` channel error for missing children; folder materialization creates a directory only for that explicit condition. Android metadata lookup no longer converts provider errors into 'not found'.
- Status: source fix committed; provider integration tests remain.

### EXP-09 — Deleting a database-empty folder could remove unmanaged external files
**Severity: High — data safety**

- Evidence: folder deletion previously checked only DocsGrid database rows before calling the platform's generic delete operation. iOS used `FileManager.removeItem` for a directory, which can remove its contents; Android delegated directory deletion to the selected SAF provider.
- Risk: files manually added through Files/another file manager, or otherwise not represented in SQLite, could be deleted with the folder.
- **Remediation committed:** Android now checks the provider's actual directory contents before deleting a directory; iOS now enumerates the actual directory (including hidden entries) and refuses deletion unless it is empty.
- Status: source fix committed; latest platform compile CI pending; physical/provider race testing remains required.

### EXP-07 — Hosted CI dependency/toolchain resolution is not fully reproducible
**Severity: Medium — release engineering**

- Evidence: root repository listing contains no committed `pubspec.lock`; workflow selects Flutter `stable` rather than a pinned SDK version and generates native scaffolding during CI.
- Risk: dependency resolution and generated Android/iOS project scaffolding can change between runs without a source change.
- Required action: commit the application lockfile, pin or deliberately manage the Flutter toolchain, and document generated native scaffolding/version assumptions.
- Status: remains an open reproducibility limitation. The workflow still uses Flutter `stable` and the repository currently has no committed `pubspec.lock`; pinning the exact toolchain and committing the solver lockfile require a deliberate dependency-resolution change.

### EXP-08 — Critical integration boundaries have limited automated regression coverage
**Severity: Medium — QA**

- Evidence: the suite now contains 11 Dart test files and 56 tests, including concurrent database-open/retry tests, reminder reconciliation-state tests, and ZIP expansion-limit tests. Platform storage bridge operations, real v1/v2 database migration fixtures, scheduler failure injection, and full import/move/restore provider flows still lack dedicated integration suites.
- Risk: hosted analyze/unit CI can pass while platform-channel, migration, provider, and cross-layer regressions remain undetected.
- Required action: add migration fixtures, fake MethodChannel/provider contract tests, notification failure injection, and end-to-end import/move/restore flows.
- Status: unit regression coverage expanded; cross-platform integration coverage remains open.

### EXP-10 — Backup validation has no archive expansion/resource limits
**Severity: High — security/reliability**

- Evidence: `validateBackup` calls `ZipDecoder().decodeBytes(await zipFile.readAsBytes())` before validating manifest contents, and `restoreBackup` decodes the archive again. There is no pre-decode archive-size, total uncompressed-size, per-entry-size, or entry-count limit.
- Risk: a malformed or highly-compressed ZIP selected by the user can cause excessive memory allocation or app termination before integrity checks complete.
- **Remediation committed:** a central-directory preflight rejects ZIP64/multi-disk, encrypted, duplicate/traversal names, excessive entry counts, per-entry/total expansion, oversized directories, and extreme compression ratios before the archive decoder runs.
- Regression test added by mutating a ZIP central-directory size to exceed the per-entry limit. Streaming remains a future improvement.

## Deferred validation (tracked in later project tasks)

1. Database migration fixtures and concurrency/provider race tests remain for Task 4.
2. Physical Android SAF/Recovery and iOS Files/bookmark persistence checks remain for Tasks 5 and 6.
3. Real-provider, scheduler failure-injection, and large-file memory/performance measurements remain deferred to Tasks 5–8. Hosted CI does not certify these device-only behaviours.

## Sign-off rule

This audit signs off the eight source-review lenses and their hosted automated regression gates. Platform/provider integration, migration fixtures, notification delivery and measured physical-device performance are explicitly not signed off here; they are tracked in the later numbered tasks. Hosted CI does not certify those device-only behaviours.
