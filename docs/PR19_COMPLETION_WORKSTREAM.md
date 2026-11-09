# DocsGrid PR 19 — completion workstream

Base: PR 18 merge commit `6c92c310d35d0f22b3b32ddb0824bc8678979f15`.
This PR carries forward every unchecked PR 18 acceptance item and the seven completion areas requested after PR 18. A checked item means code and automated evidence exist; physical-device gates remain separate.

## PR 18 carry-forward — incomplete acceptance items

- [x] Full-screen SAF folder browser: navigates granted-root folders, displays PDF counts, preserves opaque provider URIs, opens PDFs, and handles Android Back within the current folder path. The PDF-focused discovery default still omits empty branches; the full-screen phone browser explicitly opts into including every folder.
- [x] Single-PDF import dialog parity: editable filename, destination selection, create-folder, Cancel/Save and current folder preselected. WhatsApp share import also presents editable name and destination with Cancel/Save.
- [x] Multi-PDF import uses one batch picker and the current folder as a shared destination without opening a review dialog per file.
- [x] Multi-select supports long-press entry, tap toggling, clear/back dismissal, bulk move/share/trash and returns to the library after actions. Full route-stack preservation remains a device validation gate.
- [x] Dedicated scanner route launches camera capture directly; gallery action launches the multi-image page workflow directly. Both use the shared verified PDF export/import pipeline.
- [x] Persistent reorderable page filmstrip remains visible during every crop; dragging thumbnails updates the remaining scan order without replacing the active crop page. Physical camera/gallery validation remains open.
- [x] Folder breadcrumb/title opens a bounded, scrollable recursive tree with expandable descendants and selected-folder feedback; Android Back is scoped within the SAF browser. Physical small-screen validation remains open.
- [ ] OCR assertion root cause confirmed from full device stack and regression. Search/index lifecycle guards and route-disposal cancellation are present; the exact inherited-widget assertion cannot be attributed without the full Android stack trace.
- [x] Android recovery folder selection validates an existing DocsGrid tree and requires Documents, Folders, Database, Recovery and at least one snapshot before updating storage preferences; it does not create missing folders. Snapshot manifests and file hashes are then validated before additive restore. Real provider restore still requires device verification.
- [ ] Large PDF and provider-backed import tests; physical Android/iOS validation.

## Newly prepared in this unpublished change-set

- [x] Persistent folder ordering (`sort_order`, database v7 migration, reorder transaction and long-press drag handle).
- [x] Hide child-folder cards when the current folder contains both PDFs and subfolders; open the recursive folder tree from the current folder title instead.
- [x] Full-screen SAF folder browser with folder drill-down, PDF counts, breadcrumbs, empty-folder display and Android Back handling.
- [x] Regression tests for nested browser navigation, PDF URI opening, Back navigation, full-tree empty-folder discovery, folder-order migration and sibling-order validation.
- [x] Dedicated camera/gallery scanner route with a shared verified PDF export/import flow.
- [x] Recovery folder picker validates the existing portable DocsGrid layout without creating empty replacement folders.

## Seven completion areas

1. Storage browser and folder-wise PDF discovery.
2. Startup responsiveness, progressive PDF viewer and bounded memory/cache.
3. OCR crash lifecycle, indexing/search and back-navigation regression.
4. Single/batch import, WhatsApp share, multi-select and file context actions.
5. Direct scanner, gallery-to-PDF, crop filmstrip, auto-colour and verified export.
6. Folder hierarchy, breadcrumbs, responsive navigation and Android Back.
7. Recovery discovery, validation, rollback safety and real restore verification.

## Verification gates

- [ ] Flutter analyze and full unit/widget tests on final PR head (not run yet for this unpublished change-set).
- [ ] Android analyze/tests/debug APK CI on final PR head.
- [ ] iOS analyze/tests/unsigned build CI on final PR head.
- [ ] Large-PDF and 10k-library performance tests.
- [ ] Physical Android: SAF grant/revoke, folder browser, camera/gallery, OCR and restore.
- [ ] Physical iOS: Files bookmarks, scanner/gallery and restore.
- [ ] Capture and correlate the complete Flutter stack for the Flutter inherited-widget disposal assertion; do not infer a root cause from the assertion line alone.

Hosted CI is not a substitute for device verification. Do not merge until all feasible automated gates pass and remaining device-only checks are explicitly reported.
