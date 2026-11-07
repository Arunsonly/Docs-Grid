# DocsGrid

Offline-first personal document organiser for Android and iPhone.

## Approved product direction
- One Flutter codebase for Android and iOS.
- Ten connected feature modules: smart import/rename, folders/subfolders, categories/tags, search/OCR, duplicate detection, favourites/recent, expiry and manual per-document reminders, scanner/share, history/recycle bin, backup/restore.
- No mandatory account, cloud service, or paid AI API for core operation.
- One canonical PDF file per document; the app manages it and keeps metadata in a local database.

## Storage policy
- Android: use a user-visible `Documents/DocsGrid` folder (or a user-selected equivalent) through the Storage Access Framework. Persist access grants where supported.
- iOS: use Files document-picker access. iOS sandbox and uninstall behaviour differ: files inside the app's own container may be removed on uninstall. For uninstall-independent storage, the user must select/export to a Files location outside the app container.
- The app stores metadata, indexes, settings, and access references locally. PDFs are not duplicated as a normal workflow.
- If a file is moved, deleted, or access is revoked outside DocsGrid, provide a repair/relink flow rather than silently losing its record.
- WhatsApp originals are never deleted automatically; any deletion handoff must be user-controlled.
- Users can add multiple one-time or recurring reminders to any PDF (for example, fine review/removal date or policy renewal); a reminder never auto-deletes the file.
- Notifications use platform-native local notifications. Ask permission in context, respect Android 13+ `POST_NOTIFICATIONS` and iOS authorization, re-check Settings changes, and keep reminders visible in-app if notifications are disabled. Avoid exact-alarm permission unless a future requirement and store policy clearly justify it.

## Architecture
See [docs/PRODUCT_ARCHITECTURE.md](docs/PRODUCT_ARCHITECTURE.md) for the approved modules, database model, interaction standards, platform storage rules, and delivery plan.

## Project status
The repository contains a working Flutter document-library foundation. Android SAF and iOS Files storage adapters are implemented in code, including real folder trees, verified PDF moves, existing-library migration, relinking, and recovery safeguards. These integrations still require successful CI and physical-device validation; the remaining feature modules are being completed incrementally. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for exact status and limitations.

## Run
1. Install the current stable Flutter SDK.
2. Run `flutter pub get`.
3. Run `flutter run` on an Android or iOS development device (iOS build/signing requires macOS with Xcode).
