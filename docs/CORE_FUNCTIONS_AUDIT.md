# DocsGrid — Consolidated Audit of All 10 Core Functions

Audit date: 2026-11-09  
Audited base commit: `703f36032394356971d8a6ab34740afaa1c9c4bb`  
Audit branch: `audit/consolidated-10-core-fixes`  
Scope: all ten product functions, their data/repository logic, storage integration, database schema/migrations, native Android/iOS bridges, and existing automated tests.

**Source review: 10/10 functions completed.**  
**Corrective changes: consolidated into this one branch.**  
**Hosted CI: pending on the single consolidated PR.**  
**Physical-device sign-off: not claimed; Android/iOS devices and third-party storage providers still require hands-on testing.**

## Results by function

| # | Core function | Source audit result | Consolidated corrections | Remaining gate |
|---|---|---|---|---|
| 1 | Smart Import & Auto Rename | PDF header validation, SHA-256, collision-safe private filenames, staging cleanup and DB writes reviewed. | Added duplicate recheck inside the DB transaction for ordinary and scanner imports; stale destination/category selection is revalidated before insert; migration no longer treats provider errors or hash mismatches as a missing file; optional metadata parsing is fail-safe; PDF names are bounded. | FilePicker providers without a local path still expose bytes rather than a stream; large-file memory and interrupted provider-import tests remain. |
| 2 | Smart Folder & Subfolder Management | Nested CRUD, rename, delete, physical URI mapping and cycle handling reviewed. | Folder traversal and ancestor resolution are iterative; rename rejects duplicate siblings; empty-folder deletion rechecks DB state inside the transaction; provider errors are classified as NOT_FOUND only when native confirms absence; Android/iOS native delete refuses non-empty directories, including hidden iOS entries; storage I/O moved off the UI thread. | Physical SAF/Files provider permission persistence, revocation, cloud folders and very deep trees need device/provider tests. |
| 3 | Smart Category & Tags | CRUD, built-in protections, document assignment, tag links and backup references reviewed. | Category/tag create, rename, delete and document assignments now write history in the same SQLite transaction; assignment updates document timestamps; backup restore remaps category/tag IDs by name rather than silently ignoring conflicting IDs. | Full restore conflict integration tests and UI/history rendering checks remain in hosted CI. |
| 4 | Advanced PDF Search (OCR) | PDF page rendering, recognizer lifecycle, page markers, temporary image cleanup, indexing and search query reviewed. | OCR search uses literal `instr()` matching so `%` and `_` are not SQL wildcards; added SQLite-backed regression tests. | iOS recognizer remains Latin-only; Android includes Latin and Devanagari. OCR index provenance is not stored, so text indexes can become stale if a PDF is modified outside DocsGrid; mixed-script, large and multi-page accuracy need device tests. |
| 5 | Duplicate Detection | Exact SHA-256 and normalized OCR-text grouping, plus manual review/Recycle Bin path reviewed. | Exact duplicate grouping now re-hashes current PDF bytes before grouping and refreshes stale stored hashes; added a regression test with stale hashes and different file contents. Automatic bulk deletion remains intentionally disabled; reviewed copies use Recycle Bin. | OCR-text duplicate hints rely on the last OCR index and can be stale after external file edits; manual review remains required before trashing. |
| 6 | Favorites & Recent Documents | Favorite metadata, last-opened ordering and history writes reviewed. | Malformed optional metadata no longer prevents favorite toggling or document listing; favorite/open events and their metadata/timestamps are committed transactionally. | App-restart persistence and sort behaviour are covered by the full hosted test run. |
| 7 | Expiry Reminder System | Stable IDs, recurrence calculation, OS scheduling, resume reconciliation, snooze, enable/disable and cancellation reviewed. | Snooze now uses an independent deterministic notification ID and does not overwrite the recurring reminder's original time; reconciliation schedules/cancels both IDs; re-enabling runs full reconciliation; regression coverage checks ID separation and recurrence calculations. | Real delivery, timezone/DST changes, reboot, Android inexact scheduling and iOS pending-notification limits need physical-device checks. |
| 8 | Document Scanner & Quick Share | Camera/gallery scanning, PDF assembly, temporary files, Android Share receive, iOS Files Open-In and outbound share reviewed. | Native storage file work runs on serial background queues; Android incoming-share file staging is moved off the UI thread; provider copies continue to use SHA-256 verification and cleanup paths. | Camera/gallery permissions, multi-page capture, Android Share sheet, iOS Files/Open-In and cloud-provider behaviour require real devices. |
| 9 | Document History & Recycle Bin | Open/import/move/rename/trash/restore/permanent-delete history paths and soft-delete behaviour reviewed. | Category/tag events now join the same history system; folder deletion is guarded against concurrent DB inserts and physical non-empty folders; existing trash/restore history remains transactional. | Failure-injection around physical permanent-delete followed by DB failure remains a recovery edge case; test on device before release. |
| 10 | Backup & Restore | ZIP streaming, archive bounds, metadata validation, PDF mapping/hash checks, additive restore and portable snapshot fallback reviewed. | Backup restore now maps category/tag IDs safely to existing records; staged restore remains transactional and cleanup-safe; regression coverage is added for adjacent integrity/search paths. | Large archives are bounded by configured archive limits; portable metadata snapshots are materialized as JSON tables in memory. Large-library, interruption, cross-device and provider recovery drills remain. |

## Consolidated code changes in this branch

- `lib/features/documents/data/document_repository.dart`: transactional duplicate rechecks for import, active folder/category revalidation, strict storage migration error handling, safer metadata parsing and bounded PDF names.
- `lib/features/folders/data/folder_repository.dart`: iterative deep-tree traversal, iterative ancestor resolution, sibling-name protection and transactional empty-folder recheck.
- `lib/core/storage/storage_location_service.dart`: explicit native `NOT_FOUND` classification; permission/provider/I/O failures now fail closed.
- `platform/android/MainActivity.kt`: serial background storage executor, main-thread result dispatch, background share staging, explicit NOT_FOUND and non-empty SAF directory deletion guard.
- `platform/ios/AppDelegate.swift`: serial background storage queue, main-thread result dispatch, explicit NOT_FOUND and hidden-file-aware non-empty directory deletion guard.
- `lib/features/categories/data/category_repository.dart`: transactional category/tag history.
- `lib/features/tools/document_tools_service.dart`: literal OCR search, current-byte SHA duplicate grouping and safe category/tag ID remapping during backup restore.
- `lib/features/reminders/data/reminder_notifications.dart` and `reminder_repository.dart`: independent snooze scheduling and recurrence-anchor preservation.
- `.github/workflows/flutter-ci.yml`: Flutter SDK pinned to 3.47.9 on Android and iOS; both jobs enforce the committed `pubspec.lock`.
- Regression tests added for category/tag history, literal OCR wildcard search, current-byte duplicate grouping, explicit storage NOT_FOUND and independent snooze IDs.

## Database and migration review

- Current schema remains version 3; this audit branch does not introduce a schema migration.
- Existing migration tests cover real SQLite v1 → v2 → v3, v2 → v3, downgrade refusal and rollback after a failed v1 → v2 migration.
- Foreign-key enforcement and migration transactions are retained.
- Backup and portable snapshot restore both validate their incoming metadata before permanent writes; backup category/tag mapping was corrected in this branch.

## CI and release gates

1. Open exactly one PR from this branch to `main`.
2. Run the complete Android job: Flutter analyze, all tests, strict dependency verification, debug APK build and artifact upload.
3. Run the complete iOS job: Flutter analyze, all tests and unsigned iOS build.
4. Fix every CI failure on this same PR; do not create a second PR for this audit.
5. Merge only after both jobs are green.
6. After merge, verify Post-Merge CI and then perform the physical Android/iPhone/provider checks listed above.

A green hosted CI result proves the code compiled and automated tests passed on the runners. It does **not** prove real-device permission persistence, Files bookmarks, notification delivery, cloud provider behaviour, scanner camera permissions or recovery after a device/app interruption.
