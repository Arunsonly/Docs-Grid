# Four-Area Storage Safety Audit

Date: 2026-11-09
Scope: Database migrations, Android Storage Access Framework recovery, iOS Files bookmarks, and storage/security boundaries.

## 1. Database migration safety

- Kept SQLite schema changes in the sqflite upgrade callback, which executes within the database upgrade transaction.
- Added an explicit supported-version guard (v1 through v3); unknown future schema versions fail closed rather than attempting a partial migration.
- Legacy v1 upgrades now create the migration ledger and record the v1 baseline plus each applied migration version.
- Migration ledger writes use conflict-ignore semantics so a previously recorded version is not duplicated.
- Regression fixture asserts the complete ordered ledger, preservation of folder/document/reminder rows, and a clean foreign-key check.
- Existing failure fixture continues to verify rollback when the v2 schema collides with an existing table.

## 2. Android Storage Recovery

Reviewed the Storage Access Framework recovery path:
- The selected tree URI is persisted separately from the app's portable Documents/Folders/Database/Recovery child URIs.
- Access checks require a persisted read+write grant and a provider query of the selected tree; missing/revoked access is reported as revoked, not silently treated as available.
- Re-selecting a folder re-takes the persistable grant and rebuilds/reconnects the canonical DocsGrid folder layout. Existing content is not deleted by the recovery path.
- Provider failures are not treated as missing children when creating folders.
- Storage work remains bounded by the previously merged 64-operation queue.

Remaining verification: real-device permission revocation/re-grant, removable/cloud provider behaviour, and interrupted folder selection.

## 3. iOS Files bookmarks

- Bookmark resolution is no longer silently compact-mapped; an invalid saved bookmark now fails with a recovery message instead of proceeding without access.
- All stored bookmarks are resolved and security-scoped access is acquired before external storage operations. Started scopes are always released with defer.
- Stale bookmarks are refreshed and persisted back to both the bookmark list and current bookmark.
- Folder selection now verifies that Files actually granted access (or that the URL is inside the app container) before persisting a bookmark.
- Existing document records are not rewritten when a bookmark becomes unavailable; user must reselect the folder to restore access.

Remaining verification: actual Files-provider bookmark persistence across process/device restart and revoked-permission flows on physical iOS devices.

## 4. Security audit

- Added native Android and iOS leaf-name validation for create/copy/rename storage entry points, rejecting blank names, dot segments, path separators, and NUL characters.
- Existing backup restore path-token hashing prevents untrusted imported IDs from becoming filesystem path segments.
- Existing storage API preserves opaque provider URIs and distinguishes NOT_FOUND from permission/provider failures.
- Existing file-copy paths verify SHA-256 before publishing and retain the source until metadata updates are committed.

Remaining verification: adversarial archive corpus, static analysis on native targets, provider-specific race testing, and confirmation that production logging/analytics never contain document contents or sensitive paths.

## CI and release gate

The PR's Android and iOS hosted CI jobs must both pass (Flutter analyze, full Flutter tests, and platform builds) before merge.

Hosted CI is not a substitute for physical-device testing. Do not claim complete release sign-off until the Android SAF and iOS Files recovery scenarios above have been exercised on real devices.
