# DocsGrid — Independent Release Hardening Review

Date: 2026-11-14  
Base: PR #24 head `a2cf44649b88e6817d7e85d344853a72857e2cda`  
Working branch: `audit/release-hardening-2026-11`

## Scope

This change set is based on the current Grid/UI implementation and preserves the existing product modules. It does not modify `main`, close PR #22, or close PR #24.

The review concentrated on the cross-module boundaries most likely to cause user-data loss or incorrect recovery:

- Phone storage discovery versus the managed DocsGrid library
- Reinstall recovery and legacy storage layouts
- Backup discovery across Full, Database, local and SAF locations
- Snapshot consistency during concurrent database writes
- iOS Files bookmark and selected-root lifecycle
- Trash exclusion during recovery scans

## Changes applied

### 1. Phone / Grid isolation

`recoverLoosePortablePdfs()` now scans only the DocsGrid portable Documents/Unfiled and Folders roots, plus explicitly enumerated legacy DocsGrid library roots. It no longer imports every PDF returned by MediaStore or broad Phone/SAF scan roots.

The Phone tab remains a general storage browser. Moving an individual Phone PDF into Grid continues to use the existing explicit copy, SHA-256 verification, database commit and source-cleanup flow.

A testable whitelist of legacy managed recovery roots was added in `DocumentToolsService.legacyManagedRecoveryPaths()`.

### 2. Trash-safe PDF discovery

The PDF-only recursive scanner now applies the same system-trash exclusion used by the Phone storage tree. PDFs in `.Trash`, `.trashed`, recycle and recycle-bin directories are not candidates for reinstall recovery.

A regression assertion exercises both the general storage tree and PDF-only recovery traversal.

### 3. Backup discovery and restore order

Portable archive discovery now inspects the current `Full` and `Database` archive directories separately, legacy backup layouts, and the private iOS backup path. User-selected Android SAF backup directories are enumerated through the storage provider and staged to a dedicated temporary folder using the native file-copy path.

Restore classification checks archive bounds before inspecting a manifest. Full backups are attempted before Database-only archives, regardless of modification time. Invalid archives are tried last; one damaged candidate does not prevent trying the remaining candidates.

### 4. Portable snapshot consistency

All durable SQLite tables and the snapshot revision are captured within one SQLite read transaction. The resulting JSON files therefore represent one database state rather than a sequence of potentially different states observed during a long export.

The existing revision-compare/dirty-state mechanism still schedules a later snapshot when writes occur after the captured transaction.

### 5. iOS Files access

A selected folder named `DocsGrid` or `com.docsgrid` is now reused as the portable root instead of creating a nested `DocsGrid/DocsGrid` tree.

A revoked legacy bookmark no longer blocks unrelated operations in another valid Files folder. Security-scoped resources are released with `defer`, including when bookmark resolution or refresh fails part-way through the list. Invalid bookmarks are retained rather than silently discarded.

## Regression coverage added

- `test/portable_recovery_scope_test.dart`: verifies the legacy recovery whitelist contains only DocsGrid-managed locations and excludes general Phone folders.
- `test/storage_location_channel_test.dart`: verifies the PDF-only recovery scan excludes PDFs in system trash folders.

Existing database migration tests already cover schema v9 → v10 revision tracking and conditional snapshot completion.

## Verification state

GitHub Actions for PR #22 and PR #24 previously passed independently. Those historical runs do not certify this combined hardening branch.

The exact current branch still requires a fresh CI run for:
- Flutter analyze
- Complete widget/unit tests
- End-to-end integration tests
- Performance benchmark
- Android debug APK build
- iOS unsigned build

Physical Android/iPhone checks remain mandatory before release. In particular:
- Reinstall from a real Full backup and a Database-only backup
- Restore from Android SAF and from the app's canonical shared folder
- Revoke/regrant Android SAF and iOS Files permissions
- Verify iOS bookmark persistence across force-quit and restart
- Restore a large real-world archive on a low-memory device
- Confirm Phone-only PDFs never appear in Grid without an explicit Move action

## Release decision

This branch is a source-level hardening candidate, not a release certification. Merge only after its own Android and iOS CI passes and the physical recovery matrix is completed with a disposable copy of real user data.
