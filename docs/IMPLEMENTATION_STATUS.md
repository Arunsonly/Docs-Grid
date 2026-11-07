# DocsGrid implementation status

Last updated: 2026-11-07

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
- Relinking accepts a user-selected PDF and checks its header and saved SHA-256 before changing the record. Current implementation requires FilePicker to expose a readable local path; provider selections without a local path are rejected with an actionable error instead of being treated as valid.
- Import can read provider selections into memory when FilePicker does not expose a local path. This is a large-file memory risk and requires cloud-provider/device testing; do not treat provider support as fully validated.
- iOS Files providers (including cloud providers) may need to download a file before it can be read. This requires real-device/provider testing.
- App-private fallback files remain inside the app container and may be removed on uninstall. Files in a verified external location are independent of the app container.
- Streamed SHA-256 and native streamed copy are used where the picker exposes a local path and for provider URI copy operations. Large-file and low-memory-device testing remains outstanding.

## Verification status

- Latest verified CI commit: `bf9574b45dfc667046c7a680db3bec739fe6385d`.
- GitHub Actions run [42364129247](https://github.com/Arunsonly/Docs-Grid/actions/runs/42364129247) completed successfully: Android analyze, widget/unit tests, debug APK build and artifact upload; iOS analyze, widget/unit tests and unsigned build.
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
| 7 | Expiry Reminder System | Device-local scheduled notifications; Android notification permission and reboot receivers; daily and weekly repeating reminders; disable, snooze, complete and delete cancel/reschedule notifications | Monthly recurrence not yet available; iOS/Android notification delivery and reboot must be tested on physical devices; Android uses inexact scheduling |
| 8 | Document Scanner & Quick Share | Camera single-page scan and multi-image gallery-to-PDF; scanner output imported into the library; document menu shares local and provider-backed PDFs | No perspective crop/edge detection or multi-page camera capture workflow yet |
| 9 | Document History & Recycle Bin | Existing action history, soft delete, restore and confirmed permanent delete retained; duplicate cleanup uses Recycle Bin | Verify rollback and history consistency after app restart |
| 10 | Backup & Restore | ZIP backup includes DB tables and local PDFs; manifest and SHA-256 verification; additive restore stages files, inserts metadata transactionally and aborts on ID conflicts | Provider-backed content URIs are copied to temporary local files for inclusion; unavailable providers stop the backup rather than creating a partial archive. Test large archives, rollback, and restore across fresh installs |

### Current branch verification

- The first implementation CI pass (before the latest notification, restore, scanner and duplicate-review changes) passed Android analyze, tests and debug APK build.
- The same run passed iOS analyze and tests but iOS unsigned build failed because the generated deployment target was below the ML Kit minimum. The workflow was updated to raise both Xcode project and Podfile targets to iOS 15.5; that correction still requires a fresh successful CI run.
- The latest branch changes have not yet been certified by a complete fresh CI run or real-device tests. Do not mark all ten features release-ready until both are complete.
