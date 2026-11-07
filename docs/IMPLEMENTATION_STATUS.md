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
