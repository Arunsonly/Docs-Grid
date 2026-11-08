# DocsGrid implementation status

Last updated: 2026-11-08

This is an implementation tracker, not a release claim. A green CI build does not mean physical-device testing has passed.

## Core Storage and PDF Management

| Area | Current implementation | Remaining verification |
|---|---|---|
| Android storage | SAF folder picker, persisted tree permission, physical nested folders, file create/copy/read/rename/delete/open, permission health check and repair entry point | Real Android device: grant, restart persistence, revoke, reselect, provider removal |
| iOS Files storage | Files folder picker, persisted security-scoped bookmarks, physical folders/files, native PDF preview, permission health check and repair entry point | Real iPhone: bookmark persistence after restart, stale/revoked bookmark, cloud provider download and reconnect |
| PDF import | Multi-file picker, PDF header validation, SHA-256 duplicate detection, safe filename collision handling, external selected storage or private fallback | Large files, provider-backed files and low-memory behaviour on devices |
| Folder organisation | Nested folder CRUD, physical folder creation, descendant folder/PDF URI reconciliation after rename, empty-folder delete rollback | Device test across nested trees and provider-specific rename behaviour |
| PDF move | Copy-and-verify, database commit before source cleanup, rollback cleanup on metadata failure, streamed provider-to-private copy | Device test every direction, interrupted copy and source cleanup failure |
| PDF recovery | Relink verifies PDF header and original SHA-256 before changing DB reference; Settings reports storage access health and reopens folder selection for repair | Device test lost/revoked access and relinking from local and cloud Files providers |
| Migration | Mirrors nested folders, streams and verifies PDF copies, commits each new DB reference before deleting old source, supports safe retry after interruption | Device test interruption, app restart, duplicate destination, provider disconnect and large PDFs |
| Automated checks | Flutter analyze, widget/unit tests, status normalization tests, Android debug APK and unsigned iOS build | Keep CI green on final commit; add platform integration coverage as test harness permits |

## Storage behaviour and limitations

- Android uses the Storage Access Framework and retains the user's selected folder permission; broad storage permission is not requested.
- iOS uses Files and security-scoped bookmarks. Previous selected roots are retained so the user can migrate from an earlier root while access remains valid.
- Settings exposes storage access health. If access is revoked, the repair entry point reopens folder selection; selecting a replacement root does not delete existing PDF records.
- Migration mirrors the folder hierarchy. For each PDF it copies and verifies SHA-256, commits the new database location, and only then removes the old copy. It can be retried after interruption.
- PDF moves use copy-and-verify, then commit metadata, then clean up the old copy. If metadata commit fails, the original remains. If source cleanup fails after commit, the app reports that both copies may remain.
- Folder rename refreshes descendant folder and PDF storage references. Empty-folder deletion restores the visible database record if physical deletion fails.
- Relinking accepts a user-selected PDF, stages pathless provider selections into app cache, and checks its header and saved SHA-256 before changing the record. Cache staging is cleaned after success or failure; provider and large-file behaviour still needs device testing.
- Import can read provider selections into memory when FilePicker does not expose a local path. This is a large-file memory risk and requires cloud-provider/device testing; do not treat provider support as fully validated.
- iOS Files providers (including cloud providers) may need to download a file before it can be read. This requires real-device/provider testing.
- App-private fallback files remain inside the app container and may be removed on uninstall. Files in a verified external location are independent of the app container.
- Streamed SHA-256 and native streamed copy are used where the picker exposes a local path and for provider URI copy operations. Large-file and low-memory-device testing remains outstanding.

## Verification status

- Latest fully successful CI run before the current review fixes: [42369846464](https://github.com/Arunsonly/Docs-Grid/actions/runs/42369846464), commit `b7c199f320c337db9b30050e0da74aa82e28e02b`. Android analyze, tests, debug APK build and artifact upload succeeded; iOS analyze, tests and unsigned build succeeded.
- A subsequent five-pass source review identified and fixed the legacy v1 database-upgrade tracking-table failure, iOS Files `file://` URI handling for OCR/sharing, and stale Settings feature-status copy. These newer commits require a fresh CI run before their APK is considered verified.
- CI does not verify OS permission prompts, real provider behaviour, cloud downloads, app restart persistence or real-device file operations.
- Physical Android and iPhone checks have not yet been performed. They require actual devices with the app installed and cannot be certified by a hosted CI runner.
- Android release signing, iOS signing/TestFlight, large-PDF stress tests and data-recovery drills remain outstanding.

## Release gate

Do not label Core Storage and PDF Management physically verified or release-ready until the device/provider checks above are completed and all failures are fixed. No later product modules should be started before this milestone is closed.


## Ten requested product features — implementation branch update

The following changes are on `feature/complete-ten-features` and remain subject to CI and device verification.

| # | Feature | Current code status | Known limitation / test gate |
|---|---|---|---|
| 1 | Smart Import & Auto Rename | Multi-PDF import, PDF signature validation, SHA-256 duplicate check, safe names/collision suffixes; if the picker has no local path, current fallback reads the selected file into memory | A provider that exposes neither a local path nor a read stream still falls back to in-memory bytes; large-file tests required |
| 2 | Smart Folder & Subfolder Management | Existing nested folder CRUD and physical storage mapping retained | Verify deep folder rename/move on Android and iOS providers |
| 3 | Smart Category & Tags | Existing built-in/custom categories and reusable tags retained | Add migration and multi-document assignment regression tests |
| 4 | Advanced PDF Search (OCR) | On-device PDF page rendering + ML Kit OCR; extracted text persisted in SQLite; text query searches indexed PDFs; provider URI is copied to temporary storage for OCR | Latin script recognizer only in current implementation; OCR is user-triggered and can be CPU/memory intensive |
| 5 | Duplicate Detection | Exact SHA-256 duplicate groups with a review choice; non-kept copies move to Recycle Bin, not permanent deletion | Needs UX/device regression tests and duplicate groups with 3+ copies |
| 6 | Favorites & Recent Documents | Existing Saved and Recently opened screens/actions retained | Verify sort and history after app restart |
| 7 | Expiry Reminder System | Device-local scheduled notifications; Android notification permission and reboot receivers; daily, weekly and monthly repeating reminders; monthly repeats use the selected calendar day and skip months that do not contain it; disable, snooze, complete and delete cancel/reschedule notifications | iOS/Android notification delivery and reboot must be tested on physical devices; Android uses inexact scheduling |
| 8 | Document Scanner & Quick Share | Multi-page camera capture and multi-image gallery-to-PDF; pages can be reordered and cropped before PDF creation; scanner output imported into the library; Android Share sheet receive plus iOS Files Open-In import; document menu shares local and provider-backed PDFs | Automatic perspective/edge detection is not implemented; cropping remains a user-guided crop step |
| 9 | Document History & Recycle Bin | Existing action history, soft delete, restore and confirmed permanent delete retained; duplicate cleanup uses Recycle Bin | Verify rollback and history consistency after app restart |
| 10 | Backup & Restore | ZIP backup includes DB tables and local PDFs; manifest and SHA-256 verification; additive restore stages files, inserts metadata transactionally and aborts on ID conflicts | Provider-backed content URIs are copied to temporary local files for inclusion; unavailable providers stop the backup rather than creating a partial archive. Test large archives, rollback, and restore across fresh installs |

### Current branch verification

- The latest pre-review CI run passed Android analyze, tests and debug APK build/upload, and iOS analyze, tests and unsigned build.
- The current source-review fixes have been committed after that run and must pass a fresh Android/iOS CI run.
- No hosted CI run can certify Android SAF permissions, iOS security-scoped bookmark persistence, physical notification delivery, cloud-provider access or real-device recovery. These remain manual device test gates.


## Audit findings and fixes — 2026-11-08

- Reminder permission review found that ordinary reminders requested Android exact-alarm special access and switched to exact scheduling whenever access was already granted. This contradicted the approved least-privilege architecture, which specifies inexact scheduling for ordinary document reminders.
- The reminder scheduler now requests only notification permission and always uses Android inexact scheduling. The generated CI manifest no longer declares `SCHEDULE_EXACT_ALARM`. This avoids an unnecessary special-access prompt and permission declaration.
- Scanner audit also found that the generated temporary PDF was not cleaned up when the user cancelled naming/folder selection, navigated away, or import failed. The scanner screen now removes its temporary output in a `finally` block after every exit path.
- Portable snapshot manifest validation now rejects mismatches between declared table counts and each JSON file's record count; a regression test covers the inconsistent-count case.
- Scanner import review found a private-storage path mismatch: a scan assigned to a nested folder was physically saved at the library root. It now uses the same nested private-folder resolver as ordinary PDF imports, keeping the physical path and `folder_id` aligned.
- Folder-name security review found that create rejected `.` and `..`, but rename did not. A renamed folder could therefore become a dot-segment path component in private storage. Create and rename now share one validator that rejects empty names, dot segments and both path separators; regression tests cover these cases.
- Restore review found that malformed backup metadata could contain duplicate folder IDs, missing parents or cyclic parent references. Restore now validates folder IDs/parent links and detects cycles before creating nested restore paths, so malformed metadata fails closed and pre-commit rollback can remove staged restore files.
- Portable recovery snapshot review found that dot-segment folder names could reach native directory creation before full graph validation. Snapshot restore now preflights duplicate IDs, missing parents, cycles, separators, dot segments and control characters before any storage-provider writes; legacy folder names are also validated before path construction, and recursive folder traversals detect cycles.
- Reminder notification IDs previously used `String.hashCode`, which is not a persistence contract across process launches. The scheduler now uses deterministic FNV-1a IDs and has a regression test for stable values.
- Portable restore UI now consistently instructs both Android and iOS users to select the parent folder containing `DocsGrid`, matching both native implementations.
- Verification gate: Run #571 passed Android analyze, Flutter unit/widget tests, strict Gradle dependency checksum bootstrap, Android debug APK build and artifact upload; iOS analyze, unit/widget tests and unsigned build also passed. Subsequent folder-path and notification-ID fixes require a fresh full CI run. Physical notification delivery, reboot, scanner camera/gallery flows and vendor-specific scheduling still require device testing.


- Reminder recurrence coverage now includes monthly repeats. Dates such as the 29th–31st are skipped in shorter months that do not contain the selected calendar day; the next month with that day is used. Unit tests cover ordinary monthly recurrence and month-end behaviour.
- Reminder notification reconciliation now retains the linked document ID as the notification payload, so tapping a restored reminder can still open its PDF after backup or portable recovery.
- FilePicker provider selections without a local path are staged in the app cache for import/relink and removed in cleanup. The plugin API used here exposes bytes rather than a stream in this path, so large cloud-provider files remain a memory-pressure test gate; this limitation is documented rather than described as streamed.

- Camera scanning now supports capturing successive pages into one PDF, with a Finish/Scan next page choice after each capture. The existing page ordering and crop steps are then applied to the captured set.
- iOS now registers PDF documents as an Open-In destination, coordinates reads from Files/cloud providers, stages validated PDFs in app cache, and exposes them through the same import handoff used by the Flutter UI. Physical iPhone and cloud-provider testing remains required.
