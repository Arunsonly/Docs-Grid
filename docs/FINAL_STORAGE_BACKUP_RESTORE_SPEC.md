# DocsGrid — Final Storage, Backup & Restore Requirements

Status: **Product requirements finalized; implementation pending explicit user trigger.**
Scope: Android-first debug work. This document records the decisions agreed for the next implementation sequence. It does not claim that the features are implemented.

## 1. Storage model

Use a hybrid model:

- User PDF files live in shared, user-visible storage so they can be accessed through Android file-management and sharing flows.
- The live SQLite database, indexes, app preferences, and operational metadata remain in app-private storage.
- Portable backup archives and recovery artifacts live in the DocsGrid shared-storage root.
- The database is the source of truth for document metadata; there must not be two independently writable live databases.
- The Android root directory name is `Android/media/com.docsgrid/`. This is a chosen storage-directory name and must not be assumed to equal Android's applicationId.
- Before implementation, verify the actual applicationId and Android storage APIs in the project.

## 2. Final Android directory layout

```text
Android/media/com.docsgrid/
├── My Files/
│   ├── Unfiled/
│   ├── Folders/
│   │   └── <user-created folders and subfolders>/
│   └── Shared/
└── System/
    ├── Database/       # portable snapshots/metadata exports, not the live DB
    ├── Recovery/       # recovery points and restore reports
    ├── Backups/        # Full and Database ZIP archives
    ├── Temp/           # temporary processing area; clean safely
    ├── Logs/           # diagnostic logs; avoid sensitive document contents
    ├── Exports/        # generated exports/reports
    └── Thumbnails/     # regenerable previews
```

Create required directories idempotently on first launch. A fresh install must not require an existing snapshot or pre-existing recovery tree to initialize. Do not create arbitrary category/tag directories: categories, tags, and reminders are database records.

## 3. Document and metadata behavior

- PDFs are stored physically under `My Files/Unfiled/` or `My Files/Folders/<user hierarchy>/`.
- User-created folder/subfolder hierarchy is mirrored in storage.
- Categories are independently managed database entities.
- Tags support many-to-many assignment to documents.
- Each document may have multiple one-time or recurring reminders.
- A document's physical folder, category, tags, reminders, and metadata are separate concepts. Moving a PDF must not silently change its category or tags.
- Support document search, duplicate detection, Trash/recycle bin, history, and repair/relink for missing or externally moved files.
- Preserve one canonical PDF per document during normal operation; avoid hidden duplicate copies.

## 4. Backup formats

Provide two backup types:

### Full Backup (default recommendation)
Include:
- Database snapshot and schema/app version information
- All managed PDFs and relative folder paths
- Folder hierarchy
- Categories and tags and their document relationships
- Reminders and recurrence/time-zone information
- Favorites, settings, supported history, and document metadata
- Versioned manifest and per-file SHA-256 checksums

### Database Backup
Include database and metadata (categories, tags, reminders, settings, and document records), but not the PDF file payloads. Clearly warn that it cannot independently restore missing PDF files.

Archive naming should include product name, backup type, timestamp, and a unique backup identifier. ZIP must be portable across devices and must not encode phone-specific absolute paths as the only file references.

## 5. Backup creation and sharing

1. Take a consistent database snapshot.
2. Collect and validate the selected document payloads.
3. Build the archive and manifest.
4. Verify archive readability, expected entry counts, and checksums.
5. Save the completed archive under `System/Backups/`.
6. Only then enable Share.
7. Use Android's native Sharesheet with a secure `content://` URI (FileProvider or equivalent); never expose raw filesystem paths.
8. Share through user-selected apps/providers such as messaging, email, or cloud-drive apps.
9. Optional password-protected encryption should use a modern authenticated encryption format (AES-256-GCM or a vetted ZIP-compatible AES implementation). Never store the password inside the archive; explain that the password must be shared separately.
10. A failed or cancelled backup must not be presented as complete or shareable.

## 6. Restore modes

Provide all three modes:

### Full Restore
Restore the complete archive. On a device with existing data, clearly explain replacement scope and require explicit confirmation. Create a safety checkpoint first.

### Merge Restore
Preserve existing documents and add backup content. Reconcile IDs and relationships, detect duplicates, and show conflicts. Do not blindly insert source IDs or overwrite existing records.

### Selective Restore
Allow the user to select supported groups such as PDFs, folders, categories, tags, reminders, settings, and supported metadata. Validate dependencies; for example, reminders must not be restored with broken document links.

## 7. Restore pipeline and safety

- Accept ZIP through in-app file picker and Android Open-With/share import.
- Validate archive structure, manifest, schema/app compatibility, encryption/password, entry paths, file sizes, and checksums before committing.
- Reject path traversal, absolute paths, symlinks, duplicate archive paths, malformed metadata, and unsafe filenames.
- Show a preview with counts, backup date, version, verification status, and expected conflicts.
- Create a pre-restore safety checkpoint.
- Extract to a controlled temporary staging area; never write untrusted archive paths directly.
- Verify PDF signatures and checksums and validate database relationships.
- Commit database and files in a recoverable sequence; provide rollback/cleanup for interrupted or failed restores.
- Never silently overwrite or delete existing user documents.
- Produce a restore report and restore history with restored/skipped/failed counts and actionable errors.
- Handle low storage, wrong password, corrupt archive, unsupported version, missing PDF, and interruption explicitly.

## 8. Reinstall recovery

After uninstall/reinstall on Android:

- Scan for `Android/media/com.docsgrid/` and discover the expected My Files and System locations.
- Discover candidate backup archives under `System/Backups/`; validate them rather than trusting filenames or timestamps alone.
- If a valid Full Backup is found, offer it as the recommended restore source. Do not restore without user consent.
- If several valid backups exist, recommend the newest valid Full Backup and let the user choose another.
- If PDFs/folders exist but no usable ZIP exists, offer a file-discovery/relink/import flow. Do not claim that categories, tags, reminders, or database history can be reconstructed from PDFs alone.
- If no user data exists, proceed with fresh setup.
- Never automatically delete existing files during first-launch recovery.
- Rebuild local notifications from restored reminder records after permission/status checks.

Android shared media files may survive uninstall, while app-private database/preferences are removed. This behaviour must be verified on supported Android versions/devices. Do not promise equivalent uninstall survival on iOS; iOS Files-provider locations and app-container storage have different rules.

## 9. Reinstall and restore user experience

First launch should detect existing data and show a recovery choice:
- Restore previous DocsGrid data (when a valid backup is found)
- Recover/import existing PDFs (when files exist but no valid backup exists)
- Start fresh

The user must be able to defer recovery. Explain what can and cannot be recovered. Restore progress should show stage and counts, and completion should show a detailed report.

## 10. Implementation sequence

1. Audit current Android applicationId, storage adapters, current paths, and migration/recovery code.
2. Implement and test the agreed shared-storage root and idempotent first-run directory creation.
3. Implement the hybrid file/database path model and folder mapping.
4. Implement versioned Full and Database backup generation, verification, history, and native sharing.
5. Implement Full, Merge, and Selective restore with staging, validation, safety checkpoint, and rollback.
6. Implement first-launch reinstall detection and recovery choices.
7. Add unit, repository, widget, and Android integration tests, including uninstall/reinstall and interrupted operations.
8. Validate on physical Android devices and verify iOS behaviour separately before making cross-platform claims.

## 11. Explicit non-goals for this requirements PR

- No runtime code changes.
- No APK build or release.
- No deployment, merge, or production trigger.
- No claim that any listed feature is already implemented.
- Existing data migration/compatibility must be designed only after inspecting the actual current implementation; debug validation takes priority, and no user data may be discarded.

