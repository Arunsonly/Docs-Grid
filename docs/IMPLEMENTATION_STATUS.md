# DocsGrid implementation status

Last updated: 2026-11-07

This is an implementation tracker, not a release claim. A green CI build does not mean physical-device testing has passed.

## Current status

| Area | Status | Implemented |
|---|---|---|
| Android storage | Implemented in code; CI/device validation pending | SAF folder picker, persisted tree permission, visible folder storage, physical nested folders, verified PDF writes/copies, rename/delete/open, and folder/document URI reconciliation after folder rename |
| iOS Files storage | Implemented in code; CI/device validation pending | Native Files folder picker, persisted security-scoped bookmarks (including previously selected roots), folder/file create/copy/read/rename/delete, and native PDF preview |
| PDF import | Partial | Multi-file PDF picker, PDF header validation, SHA-256 duplicate check, writes to selected Android/iOS storage or app-private fallback; filename collision handling |
| Folder organisation | Partial | Nested folder CRUD; physical folders on selected storage; safe folder rename updates descendant folder and PDF URIs; empty-folder deletion rolls back metadata if physical deletion fails |
| PDF move and migration | Implemented in code; CI/device validation pending | Cross-storage copy/verify → SQLite transaction → source deletion; moves between private and selected storage; guided migration of existing folder tree and PDFs; retry-safe migration |
| PDF recovery | Partial | User can relink a PDF from Files; PDF header and existing SHA-256 are verified before database reference changes |
| Categories and tags | Partial | Built-in/custom categories, custom tags, rename/delete, assign to PDFs |
| Search | Partial | PDF filename search; full-text search and local OCR remain missing |
| Duplicate detection | Partial | Exact SHA-256 duplicate detection; no review/merge workflow |
| Saved and recent | Partial | Favorites and last-opened timestamp; Recently opened screen and query added |
| Reminders | Partial | On-device reminder create/list/edit/enable/disable/complete/snooze/duplicate/delete UI and SQLite storage; scheduled notifications and recurring reminders still missing |
| Scanner and sharing | Not implemented | No scanner or native share flow yet |
| History and recycle bin | Partial | Activity history, soft delete, restore, confirmed permanent delete |
| Backup and restore | Not implemented | No ZIP backup/restore yet |

## Storage behaviour and limitations

- Android uses the Storage Access Framework and retains the user's selected folder permission. PDFs and folders are real provider files; broad storage permission is not requested.
- iOS uses the Files folder picker and security-scoped bookmarks. Previously selected bookmarks are retained so a user can select a new root and migrate files from an older selected root while its access remains valid.
- In Settings → Offline storage, the user can choose a folder and either use it for new imports only or migrate the existing PDF library and folder tree. Migration is retryable: each PDF is copied and verified, its database reference is committed, and only then is the previous copy removed.
- If a migration is interrupted, already-migrated records point to their new verified location and a retry checks for matching destination files by SHA-256.
- PDF moves between app-private storage and selected storage use copy/verify → database transaction → old-copy deletion. If database update fails, the original remains. If source deletion fails after the database commit, both copies are retained and the user is warned.
- Folder rename refreshes all descendant folder and PDF storage references. Empty-folder deletion updates the database first and restores the visible record if physical deletion fails.
- A PDF can be relinked from a user-selected copy. When a saved SHA-256 exists, the replacement must match exactly.
- Android SAF permission revocation or an iOS Files provider revoking access can still require the user to reselect the storage folder and relink inaccessible individual PDFs. A full guided provider-permission repair screen is not yet complete.
- iOS Files providers (including cloud providers) may need to download a file before it can be read; this behaviour requires real-device/provider testing.
- App-private fallback files remain inside the app's container and may be removed on uninstall. Only files stored in a verified external Files location are independent of the app container.
- The current implementation reads PDF bytes into memory during several copy/migration paths. Large-file streaming and low-memory-device testing remain outstanding.

## Verification status

- GitHub Actions runs Flutter analyze, widget/unit tests, Android debug APK build, and an unsigned iOS build.
- The Android SAF and iOS Files integrations are now included in CI. The latest commit must pass both jobs before this work is considered build-verified.
- CI is not a substitute for testing on a real Android phone and iPhone. Folder picker grants, bookmark persistence after app restart, cloud-provider files, rename/move/delete, interrupted migration, and recovery must be exercised on physical devices.
- Android release signing, iOS signing/TestFlight, large-PDF testing, and data-recovery tests remain outstanding.

## Release gate

Do not label DocsGrid final or distribute it as a finished app until the storage limitation is resolved, the remaining required modules are implemented, CI passes on the latest commit, and real-device checks are completed.
