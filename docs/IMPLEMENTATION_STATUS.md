# DocsGrid implementation status

Last updated: 2026-11-07

This is an implementation tracker, not a release claim. A green CI build does not mean physical-device testing has passed.

## Current status

| Area | Status | Implemented |
|---|---|---|
| PDF import | Partial | Multi-file PDF picker, PDF header check, SHA-256 duplicate check; newly imported PDFs can be written to an Android SAF-selected folder, opened, renamed and permanently deleted through content URIs; legacy private-folder imports remain supported |
| Folder organisation | Partial | Nested folder CRUD, move PDF to folder, view/open PDFs in a folder |
| Categories and tags | Partial | Built-in/custom categories, custom tags, rename/delete, assign to PDFs |
| Search | Partial | PDF filename search; stale async results guarded |
| Duplicate detection | Partial | Exact SHA-256 duplicate detection; no review/merge workflow |
| Saved and recent | Partial | Favorites and last-opened timestamp; Recently opened screen and query added; sorting/filter polish and device verification remain |
| Reminders | Partial | On-device reminder create/list/edit/enable/disable/complete/snooze/duplicate/delete UI and SQLite storage; scheduled notifications, recurring reminders, and expiry-linked reminders still missing |
| Scanner and sharing | Not implemented | No scanner or native share flow yet |
| History and recycle bin | Partial | Activity history, soft delete, restore, confirmed permanent delete |
| Backup and restore | Not implemented | No ZIP backup/restore yet |

## Important storage limitation

Imported PDFs currently live in the app-private ApplicationDocumentsDirectory/DocsGrid/PDFs folder. Android SAF folder selection and persistable tree permission are now wired through a native MethodChannel. New imports use the selected folder and are stored as real provider documents; open, rename and permanent delete use the content URI. Existing PDFs are not automatically migrated when a folder is selected. Physical folder/subfolder mirroring, relinking after permission revocation, a displayed current-folder name, and iOS Files security-scoped storage are **not implemented yet**. This Android integration still requires a successful CI build and real-device validation. Do not treat the current storage implementation as the final storage design or promise that files survive app uninstall.

## Verification status

- GitHub Actions runs Flutter analyze, widget tests, Android debug APK build, and an unsigned iOS build check.
- CI is not a substitute for testing on a real Android phone and iPhone.
- Android release signing, iOS signing/TestFlight, permission flows, large-PDF testing, and data recovery tests remain outstanding.

## Release gate

Do not label DocsGrid final or distribute it as a finished app until the storage limitation is resolved, the remaining required modules are implemented, CI passes on the latest commit, and real-device checks are completed.
