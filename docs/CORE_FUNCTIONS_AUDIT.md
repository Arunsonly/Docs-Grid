# DocsGrid — 10 Core Functions Audit

Audit branch: `audit/10-core-functions`  
Base: `feature/complete-ten-features`  
Status: **Source review and corrective changes committed; current-head Android/iOS CI and final regression sign-off pending.**

This audit is limited to the ten requested core product functions. It does not claim Android/iOS physical-device verification.

| # | Core function | Source audit result | Changes made on this branch | Remaining verification / limitation |
|---|---|---|---|---|
| 1 | Smart Import & Auto Rename | Import validates the PDF signature, computes SHA-256, checks exact duplicates, sanitizes names and uses collision-safe private filenames. | Scanned PDFs copied to external storage are now SHA-256 verified before a DB record is committed. Malformed optional metadata no longer prevents the document list from loading. | FilePicker providers without a local path still use an in-memory fallback; large-file memory behaviour and import-failure recovery need CI/device coverage. |
| 2 | Smart Folder & Subfolder Management | Nested folder CRUD and external URI reconciliation reviewed. Found private-mode rename could update only the DB name while leaving files at the old path. | Private folder rename now moves the directory and updates descendant document paths transactionally; external descendant URIs are reconciled; duplicate sibling names, unsafe names and cyclic parent traversal are rejected. | Automated repository tests for deep nested moves/renames and provider-specific SAF behaviour remain required. |
| 3 | Smart Category & Tags | CRUD, built-in category protection, category clearing and transactional document-tag assignment reviewed. | Shared category/tag name validation now has boundary tests; category deletion and tag assignment remain transactional. | Dedicated database tests for duplicate names, multi-document assignment and migration from older DB versions remain required. |
| 4 | Advanced PDF Search (OCR) | Per-page rendering, recognizer lifecycle, temporary image cleanup, SQLite index and text search reviewed. | Android now runs Latin + Devanagari recognizers and CI bundles the Devanagari model; OCR search escapes SQL LIKE wildcards for literal matching. | iOS ML Kit currently supports Latin only; mixed-script OCR accuracy and large/multi-page PDF tests remain required. |
| 5 | Duplicate Detection | Exact SHA-256 grouping and user review flow verified; reviewed copies are sent to Recycle Bin rather than immediately erased. | Re-hashes every current file before cleanup, rechecks the group inside one DB transaction, and records all soft-delete history atomically. | DB-backed 3+ copy groups, changed-file and concurrent-review regression tests remain required. |
| 6 | Favorites & Recent Documents | Favorite metadata and recent ordering reviewed. | Favorite metadata/history and recent-open timestamp/history now commit atomically; deleted records are excluded from both actions; malformed optional metadata falls back safely. | Persistence and ordering tests across app restart remain required. |
| 7 | Expiry Reminder System | Local notification scheduling and recurrence reviewed. Found process-dependent `String.hashCode` used for persisted notification IDs and no monthly UI option. | Replaced with deterministic IDs; daily/weekly/monthly next-occurrence handling; snooze now has an independent ID and does not replace recurring schedules; cancellation removes both IDs. | Current-head CI must pass; real notification delivery, timezone changes, snooze interactions and reboot behaviour require devices. |
| 8 | Document Scanner & Quick Share | Camera/gallery capture, crop workflow, PDF import and Android incoming share path reviewed. | External scanner copies are SHA-256 verified; scanner staging files and incoming shared-PDF cache copies are cleaned after success, cancellation or failure; outbound share staging files are cleaned. | Camera capture is currently one page per camera action (gallery supports multiple images); native share-sheet/device tests remain required. |
| 9 | Document History & Recycle Bin | Soft delete, restore, history writes and permanent deletion reviewed. | Trash/restore transitions update records and history in one DB transaction; permanent deletion is blocked unless the record is already in Recycle Bin; malformed optional history JSON is tolerated. | Failure-injection tests for storage deletion and DB commit boundaries remain required. |
| 10 | Backup & Restore | ZIP archive, PDF hashes, additive DB transaction, staged restore and rollback reviewed. Found restore paths used raw archive IDs and metadata entries were not independently hashed. | Restore paths use SHA-256-derived safe path tokens; folder cycles are rejected; staging paths are not misreported as canonical library-relative paths; backup validation checks metadata hashes/counts, PDF entry mapping, signatures, hashes and completeness; portable recovery skips corrupt newest snapshots and falls back to an older verified one. | Large-archive memory usage, interruption recovery and full restore/rollback tests remain required. |

## Added/updated automated tests

The current branch contains **10 Dart test files and 46 unit/widget test cases**:

- `test/backup_validation_test.dart` — archive integrity, path mapping, missing PDFs and duplicate IDs.
- `test/category_validation_test.dart` — category/tag name trimming and length boundaries.
- `test/document_tools_security_test.dart` — safe restore tokens and literal OCR LIKE escaping.
- `test/folder_repository_validation_test.dart` — traversal, separators and invalid folder names.
- `test/history_model_test.dart` — malformed optional history metadata.
- `test/portable_snapshot_manifest_test.dart` — manifest schema, hashes and safe paths.
- `test/reminder_notifications_test.dart` and `test/reminder_repository_test.dart` — stable IDs, recurrence and reminder mapping.
- `test/storage_model_test.dart` — storage status, URI and malformed document metadata.
- `test/widget_test.dart` — app smoke/widget coverage.

## Audit completion gate

Do not mark this audit complete until the latest branch passes Flutter analyze, all unit/widget tests, Android debug APK build and iOS unsigned build. A green hosted CI run does not replace real Android SAF, iOS Files/bookmark, provider, notification or recovery device checks.
