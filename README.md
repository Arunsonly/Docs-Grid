# DocsGrid

Offline-first personal document organiser for Android and iPhone.

## Approved product direction
- One Flutter codebase for Android and iOS.
- Ten connected feature modules: smart import/rename, folders/subfolders, categories/tags, search/OCR, duplicate detection, favourites/recent, expiry reminders, scanner/share, history/recycle bin, backup/restore.
- No mandatory account, cloud service, or paid AI API for core operation.
- One canonical PDF file per document; the app manages it and keeps metadata in a local database.

## Storage policy
- Android: use a user-visible `Documents/DocsGrid` folder (or a user-selected equivalent) through the Storage Access Framework. Persist access grants where supported.
- iOS: use Files document-picker access. iOS sandbox and uninstall behaviour differ: files inside the app's own container may be removed on uninstall. For uninstall-independent storage, the user must select/export to a Files location outside the app container.
- The app stores metadata, indexes, settings, and access references locally. PDFs are not duplicated as a normal workflow.
- If a file is moved, deleted, or access is revoked outside DocsGrid, provide a repair/relink flow rather than silently losing its record.
- WhatsApp originals are never deleted automatically; any deletion handoff must be user-controlled.

## Architecture
See [docs/PRODUCT_ARCHITECTURE.md](docs/PRODUCT_ARCHITECTURE.md) for the approved modules, database model, interaction standards, platform storage rules, and delivery plan.

## Project status
The repository currently contains an initial Flutter UI shell and the approved product architecture. The ten feature modules are not yet fully implemented. Each module will be built and tested incrementally on Android and iOS.

## Run
1. Install the current stable Flutter SDK.
2. Run `flutter pub get`.
3. Run `flutter run` on an Android or iOS development device (iOS build/signing requires macOS with Xcode).
