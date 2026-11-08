# DocsGrid Portable Data Layout

Status: approved recovery format; implementation must be completed and tested on Android SAF and iOS Files before release.

## Goals

The user-selected DocsGrid folder is the portable source for both document bytes and recoverable metadata. A restore must not depend on the old installation's private SQLite database. The portable data is versioned, human-inspectable JSON plus the original files.

## Folder layout

```text
DocsGrid/
├── Documents/                     # Imported/original document files
├── Folders/                       # User-created folder hierarchy and files
├── Database/                      # Portable metadata and snapshot manifest
└── Recovery/                      # Snapshots and restore reports

<!-- Legacy My Files/System folders, if present, are retained during migration. -->

<!-- Database/ contains:
    ├── manifest.json          # Format/schema versions, snapshot ID, hashes
    ├── documents.json         # Document metadata and relative paths
    ├── folders.json           # Folder IDs, names, parent IDs
    ├── categories.json        # Built-in and user categories
    ├── tags.json              # Tag definitions
    ├── document_tags.json     # Document-to-tag relationships
    ├── reminders.json         # All reminder records and recurrence state
    ├── favorites.json         # Favorite document references
    ├── history.json           # Recoverable history records
    ├── settings.json          # Portable user preferences only
    └── document_text_index.json # Optional OCR/search text index
-->
```

The app-private SQLite database remains the live runtime database. These portable files are its versioned recovery representation, not a replacement for SQLite.

## Snapshot manifest

Every completed snapshot must include:
- `format: "DocsGridPortableData"`
- `formatVersion` and `databaseSchemaVersion`
- `snapshotId`, `createdAtUtc`, and app version
- per-file relative path, byte length, SHA-256 and record count
- required/optional file declarations

Write a snapshot to a temporary staging directory first. Verify every file and hash, then publish the completed manifest last. Never treat a partial snapshot as valid. Keep at least one previous verified snapshot until the new one is fully committed.

## Recovery rules

1. Read and validate the manifest before changing the live database.
2. Verify every declared file's size and SHA-256; reject unsupported major format versions.
3. Preview document/folder counts, missing files, duplicate hashes, and ID conflicts.
4. Build explicit old-ID to new-ID maps for documents, folders, categories and tags. Rewrite all foreign references, including reminders, favorites, history and OCR index rows.
5. Preserve existing local records. Never silently overwrite. Identical document hashes may be offered as a duplicate/skip choice; different bytes with the same name must remain separate.
6. Apply metadata in a database transaction. Copy document bytes to staging, verify hashes, then finalize file placement. If the transaction fails, remove only newly staged files and keep all pre-existing data.
7. Rebuild OS notification schedules from restored reminder records; notification scheduling failure must not discard the reminder.
8. Write a restore report with restored, skipped, duplicate and failed counts.

## Legacy folder behavior

A legacy DocsGrid folder without `System/Database/manifest.json` can recover only files and directory hierarchy that are physically present. It cannot recreate tags, reminders, favorites, history or settings that existed only in the removed app's private database. Show this limitation before restore; never invent missing metadata.

## Platform requirements

- Android: use persisted Storage Access Framework tree/document URIs and stream APIs. Do not convert SAF URIs to filesystem paths or request broad storage permission.
- iOS: use security-scoped bookmarks and keep access active while enumerating, reading or writing. Refresh stale bookmarks safely.
- Both platforms: create/read/write generic JSON and binary files, enumerate child files/directories, and perform safe temp-file replacement. Do not route JSON through PDF-only APIs.
- On permission revocation, keep the private database untouched and offer folder re-link/recovery.

## Required tests

- Round-trip all tables and relationships, including tags, multiple reminders, favorites, history, settings and OCR index.
- Restore snapshots across supported schema versions and reject corrupt/truncated snapshots.
- Test duplicate IDs, duplicate content hashes, same-name/different-content files, missing files and invalid paths.
- Simulate failure during copy, hash verification, database transaction and final manifest publication.
- Verify Android SAF permission revocation/re-link and iOS stale bookmark/security-scope behavior on real devices.
