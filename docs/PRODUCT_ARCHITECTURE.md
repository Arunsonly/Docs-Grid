# DocsGrid Product & Technical Architecture

Status: approved product direction; implementation is incremental and must be verified on Android and iOS devices.

## Product promise

DocsGrid is a personal, offline-first document manager. The ten feature areas share one document library and one source of truth. No account, cloud service, or paid AI API is required for core operation.

## Platform and storage policy

### Android
- The user's canonical library is a user-visible folder named `Documents/DocsGrid` (or a user-selected equivalent).
- Use Android's Storage Access Framework / system folder picker. Ask the user to grant access to the DocsGrid folder; persist the granted tree URI where the OS allows it.
- Store PDFs as real files in that folder. Mirror the folder/subfolder tree there.
- Keep only app metadata, indexes, preferences, and persisted access references in app-private storage.
- Never request broad storage access when the picker-based approach is sufficient.
- If access is revoked or a file is moved/deleted outside DocsGrid, show a clear relink/repair flow. Do not silently discard metadata.

### iOS
- Use the Files document picker and security-scoped access for a user-selected Files location where supported.
- The app must clearly explain the chosen location and provide a “Change storage folder” action.
- iOS sandbox rules differ from Android. Files kept in the app's own Documents container may be removed when the app is uninstalled. To preserve files independently, the user must choose/export to a Files location outside the app container (for example another On My iPhone folder or a cloud Files provider). Do not promise uninstall survival unless the selected location has been verified to be outside the app container.
- Store document access bookmarks/references and metadata in app-private storage; handle expired access gracefully.

### Shared storage rules
- One canonical PDF file per imported document; do not create a second hidden copy as the normal workflow.
- The database stores a stable document UUID, display name, storage location/reference, relative path where available, size, MIME type, SHA-256, category, timestamps, and status.
- Folder tree metadata and the physical DocsGrid folder tree must stay in sync. Operations that cannot be completed on the physical file must not report success.
- Explain storage permission in plain language and request it only when the user first sets up the library or changes its location.
- Provide a guided first-run setup: choose/create DocsGrid folder, verify read/write access, then continue.

## Application architecture

Use a layered, feature-first Flutter architecture:

1. **Presentation**: screens, reusable widgets, navigation, dialogs, bottom sheets, accessibility and UI state.
2. **Domain**: document/folder entities, use cases, validation, duplicate rules, reminder scheduling rules, backup/restore rules.
3. **Data**: repositories, SQLite database, file-system adapter, local search index, backup archive adapter.
4. **Platform adapters**: Android SAF, iOS Files/document picker, notifications, camera/scanner, share sheet, biometrics.

UI widgets must not directly manipulate files or SQL. Screens call use cases; use cases coordinate repositories; repositories own database and file operations. Long-running operations run asynchronously and report progress/cancellation where safe.

## Ten feature modules

1. **Smart Import & Auto Rename**: multi-select PDFs from system picker/share sheet; inspect metadata and extractable text locally; suggest filename and category; preview/edit suggestions; confirm before saving. Sanitize names and handle collisions.
2. **Folders & Subfolders**: unlimited nested folder tree; create, rename, move, delete; create inside current folder; sort; breadcrumb navigation; multi-select move; mirror physical folders. Deleting a non-empty folder requires an explicit choice to move contents to parent or send the whole tree to Recycle Bin.
3. **Categories & Tags**: editable built-in categories plus user categories; many-to-many tags; filter chips; suggested category never silently overrides the user's choice.
4. **Search**: fast name search, category/tag/folder/date filters, and full-text search for extractable PDF text. Local OCR is an optional on-device step for scanned PDFs; show indexing state and allow retry. No cloud OCR.
5. **Duplicate Detection**: SHA-256 calculated during import and re-check; identify exact duplicates; compare name, size, date and location; never delete automatically; user chooses keep/replace/skip.
6. **Favorites & Recent**: star/unstar, recently opened and recently modified, stable sorting, clear recent history without deleting source PDFs.
7. **Expiry Reminders**: date and reminder offsets (defaults such as 30/15/7/1 days, user-editable); local notifications; permission request in context; notification tap opens the document; handle timezone/date changes.
8. **Scanner & Quick Share**: camera scan, crop/rotate, multi-page PDF creation, save to chosen folder, native share sheet; camera permission only when scanning.
9. **History & Recycle Bin**: audit events for import/rename/move/category/tag/delete/restore; soft delete with original folder/path metadata; restore conflict handling; permanent delete requires confirmation.
10. **Backup & Restore**: ZIP archive with PDFs and versioned JSON manifest; include folder tree, categories, tags, favorites, reminders and metadata; verify archive integrity before restore; preview conflicts; restore transactionally where possible; never overwrite silently.

## Data model (SQLite)

- `documents`: id, name, original_name, storage_uri, relative_path, mime_type, size_bytes, sha256, folder_id, category_id, extracted_text_status, expiry_date, created_at, updated_at, last_opened_at, deleted_at, source, metadata_json.
- `folders`: id, name, parent_id, storage_uri_or_relative_path, created_at, updated_at, deleted_at.
- `categories`: id, name, icon_key, color_key, is_builtin, created_at.
- `tags`: id, name, created_at.
- `document_tags`: document_id, tag_id (unique pair).
- `reminders`: id, document_id (nullable only for a general app reminder; otherwise required), title, note, remind_at_utc, timezone_id, recurrence_rule, recurrence_end_at, lead_days, enabled, status (scheduled/snoozed/completed/cancelled), snoozed_until, next_fire_at_utc, notification_id, created_at, updated_at, completed_at. Support multiple reminder rows per document; index document_id, next_fire_at_utc, status. Store enough recurrence/timezone data to recalculate the next occurrence safely.
- `history`: id, document_id, action, details_json, created_at.
- `favorites`: document_id, created_at.
- `settings`: key, value_json.
- `schema_migrations`: version, applied_at.

Use foreign keys, indexes for names/folder/category/dates/hash, transactions for multi-step metadata changes, and versioned migrations. Store large PDF bytes in the selected file folder, not in SQLite.

## Cross-platform permissions & notification compliance

- Ask for notification authorization only when the user first saves a reminder that needs a notification, after a short in-app explanation; never block document management if permission is declined.
- Android 13+ (API 33+) must declare and request `POST_NOTIFICATIONS` at runtime. Check permission/channel state again when the app resumes because the user can change it in system Settings. Android versions below 13 do not show this runtime prompt, but app-level notification settings can still disable delivery.
- Do not request `USE_EXACT_ALARM` or `SCHEDULE_EXACT_ALARM` by default. Ordinary document reminders can use inexact local scheduling. Only add exact-alarm access if a later, explicitly justified user-facing requirement truly needs minute-precise delivery and the applicable Android/Google Play policy permits it; otherwise avoid the extra permission and settings burden.
- iOS must request notification authorization in context before scheduling alerts, and re-check `UNNotificationSettings`/authorization when the app becomes active. If denied, provide a Settings deep-link/help state rather than repeatedly prompting (iOS does not re-show the initial prompt after a decision).
- Use local notifications only; configure notification channels on Android and appropriate alert/sound/badge options on iOS. Handle permission denied, provisional/quiet authorization where available, disabled channels, and OS scheduling failures without losing the reminder record.
- Rebuild the OS pending-notification queue from the SQLite reminder source of truth when the app starts/resumes and after edits, restore, timezone changes, clock changes, reboot, or app upgrade. Use stable notification IDs and cancel obsolete schedules before replacing them. For recurring reminders, calculate and persist the next occurrence rather than assuming the OS will repeat forever.
- Account for platform scheduling limits by scheduling the nearest upcoming reminders and replenishing the queue as reminders fire or the app next opens. Keep all future and overdue reminders in the app database regardless of the OS queue.
- Keep permission requests least-privilege: no contacts, location, microphone, or broad file access for reminders. Camera permission is only for scanning; file/folder access follows the platform storage picker rules above.
- Test Android API 32 and 33+ permission flows, denied/revoked permission, notification channel disabled, reboot/timezone change, and iOS authorized/denied/provisional states on real devices.

## Important interaction standards

- Every visible control must have a real action, disabled state, or be clearly labelled as informational. No dead buttons.
- Use clear labels, large touch targets, accessible contrast, screen-reader semantics, and scalable text.
- Prefer contextual bottom sheets for common actions and native pickers for file/folder selection.
- Use confirmation for destructive actions; offer Undo for reversible actions.
- Show progress, current file, completed/failed counts, and safe cancellation for batch import, indexing, backup, and restore.
- Preserve selection when returning from a preview or picker where the OS permits.
- Support single tap to open, long-press to enter multi-select, and a visible overflow menu for secondary actions.
- Provide useful empty states, validation messages, permission explanations, offline status, and recovery paths.
- Use subtle, short transitions and haptics only where helpful; never delay an action for animation.
- Never silently overwrite, move, delete, or change the user's source files.

## Navigation

Bottom navigation: **Files**, **Folders**, **Saved**, **Settings**.

- Files: all documents, search, filters, sort, import, document preview.
- Folders: folder tree, create folder/subfolder, folder actions and breadcrumbs.
- Saved: Favorites, Recent, Expiry reminders shortcuts.
- Settings: storage location, backup/restore, recycle bin, privacy/app lock, notifications, about.

## Delivery and quality gates

Build one vertical slice at a time. Each slice must include UI, persistence, error handling, accessibility, and tests before moving on.

1. App foundation, storage setup, database and migrations.
2. Folder tree with create/rename/move/delete and persistent storage.
3. PDF import, verification, preview and share.
4. Auto rename, categories and tags.
5. Search and local indexing/OCR.
6. Duplicate detection.
7. Favorites and Recent.
8. Expiry reminders.
9. Scanner and sharing polish.
10. History, Recycle Bin, backup and restore.

Required tests: unit tests for use cases and validation; repository/database tests; widget tests for every major dialog and interaction; platform integration tests for file/folder permissions, imports, notifications, sharing, and restore. Test Android and iOS separately. Never mark a feature complete solely because its screen renders.
