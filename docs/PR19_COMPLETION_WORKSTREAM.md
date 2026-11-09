# DocsGrid PR 19 — completion workstream

Base: PR 18 merge commit `6c92c310d35d0f22b3b32ddb0824bc8678979f15`.
This PR carries forward every unchecked PR 18 acceptance item and the seven completion areas requested after PR 18. A checked item means code and automated evidence exist; physical-device gates remain separate.

## PR 18 carry-forward — incomplete acceptance items

- [ ] Full SAF folder browser: show every folder including empty folders, nested hierarchy, PDF counts, and open PDFs.
- [ ] Single-PDF import dialog parity: editable filename, destination selection, create-folder, cancel/save; current folder preselected.
- [ ] Batch import without per-file dialogs; consistent destination.
- [ ] Discoverable multi-select and accessible context actions; preserve selection on return.
- [ ] Dedicated direct-to-capture scanner route; gallery opens page workflow directly.
- [ ] Persistent reorderable thumbnail strip while cropping.
- [ ] Folder breadcrumb navigator with responsive recursive expansion.
- [ ] OCR assertion root cause confirmed from full device stack and regression.
- [ ] Recovery validates existing Database, Documents, Folders and Recovery locations before restore; no empty-folder false success.
- [ ] Large PDF and provider-backed import tests; physical Android/iOS validation.

## Seven completion areas

1. Storage browser and folder-wise PDF discovery.
2. Startup responsiveness, progressive PDF viewer and bounded memory/cache.
3. OCR crash lifecycle, indexing/search and back-navigation regression.
4. Single/batch import, WhatsApp share, multi-select and file context actions.
5. Direct scanner, gallery-to-PDF, crop filmstrip, auto-colour and verified export.
6. Folder hierarchy, breadcrumbs, responsive navigation and Android Back.
7. Recovery discovery, validation, rollback safety and real restore verification.

## Verification gates

- [ ] Flutter analyze and full unit/widget tests on final PR head.
- [ ] Android analyze/tests/debug APK CI on final PR head.
- [ ] iOS analyze/tests/unsigned build CI on final PR head.
- [ ] Large-PDF and 10k-library performance tests.
- [ ] Physical Android: SAF grant/revoke, folder browser, camera/gallery, OCR and restore.
- [ ] Physical iOS: Files bookmarks, scanner/gallery and restore.
- [ ] Capture and correlate the complete Flutter stack for the Flutter inherited-widget disposal assertion; do not infer a root cause from the assertion line alone.

Hosted CI is not a substitute for device verification. Do not merge until all feasible automated gates pass and remaining device-only checks are explicitly reported.
