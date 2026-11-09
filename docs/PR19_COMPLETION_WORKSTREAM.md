# DocsGrid PR 19 — completion workstream

Base: PR 18 merge commit `6c92c310d35d0f22b3b32ddb0824bc8678979f15`.
This PR carries forward every unchecked PR 18 acceptance item and the seven completion areas requested after PR 18. A checked item means code and automated evidence exist; physical-device gates remain separate.

## PR 18 carry-forward — incomplete acceptance items

- [x] Full-screen SAF folder browser: navigates granted-root folders, displays PDF counts, preserves opaque provider URIs, opens PDFs, and handles Android Back within the current folder path. The PDF-focused discovery default still omits empty branches; the full-screen phone browser explicitly opts into including every folder.
- [x] Single-PDF import dialog parity in the Folders screen: editable filename, destination selection, create-folder, Cancel/Save, and current folder preselected. Confirm the WhatsApp share path uses the same dialog before marking shared-flow parity complete.
- [ ] Batch import without per-file dialogs; consistent destination.
- [ ] Discoverable multi-select and accessible context actions; preserve selection on return. (Basic selection toolbar exists; complete lifecycle/back-stack regression coverage remains open.)
- [ ] Dedicated direct-to-capture scanner route; gallery opens page workflow directly.
- [ ] Persistent reorderable thumbnail strip while cropping.
- [x] Folder breadcrumb/title opens a bounded, scrollable recursive tree with expandable descendants and selected-folder feedback; Android Back is scoped within the SAF browser. Physical small-screen validation remains open.
- [ ] OCR assertion root cause confirmed from full device stack and regression.
- [ ] Recovery validates existing Database, Documents, Folders and Recovery locations before restore; no empty-folder false success.
- [ ] Large PDF and provider-backed import tests; physical Android/iOS validation.

## Newly prepared in this unpublished change-set\n\n- [x] Persistent folder ordering (`sort_order`, database v7 migration, reorder transaction and long-press drag handle).\n- [x] Hide child-folder cards when the current folder contains both PDFs and subfolders; open the recursive folder tree from the current folder title instead.\n- [x] Full-screen SAF folder browser with folder drill-down, PDF counts, breadcrumbs and Android Back handling.\n- [x] Regression test for nested browser navigation, PDF URI opening and Back navigation.\n\n## Seven completion areas

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
