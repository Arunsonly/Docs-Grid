# DocsGrid

Offline-first personal document organiser for Android and iPhone.

## Product direction
- One Flutter codebase for Android and iOS.
- Documents stay on the device by default; no mandatory account, cloud, or AI API.
- Import multiple PDFs, review suggested names/categories, and organise into folders.
- Search, favourites, recent files, reminders, sharing, recycle bin, and backup/restore.
- Portable ZIP backup with a JSON manifest for moving documents to another phone.

## Important platform notes
- Android: use the system document picker / Storage Access Framework; request notification permission only when needed.
- iOS: use the iOS document picker and share sheet. iPhone builds/signing require macOS with Xcode.
- WhatsApp originals are not deleted automatically. DocsGrid can only offer a user-confirmed handoff to WhatsApp.
- App-private files may be removed when the app is uninstalled. Users should export a backup before uninstalling or changing phones.

## Project status
This repository currently contains the initial Flutter app shell. PDF import, local database, indexing, OCR, reminders, and backup/restore will be added in later steps and tested on real devices.

## Run
1. Install Flutter SDK.
2. Run `flutter pub get`.
3. Run `flutter run` on an Android or iOS development device.
