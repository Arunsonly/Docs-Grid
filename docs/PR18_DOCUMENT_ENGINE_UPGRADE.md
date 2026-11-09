# PR 18 — DocsGrid document engine, scanner and storage UX upgrade

This is the single consolidated workstream for the user-reported Android DocsGrid issues. Do not split these changes across multiple PRs.

## Scope and acceptance checklist

### Startup and library browsing
- [ ] Keep the first frame responsive; defer non-critical startup work and expose incremental content.
- [ ] Add a one-time Android Storage Access Framework folder grant flow, then recursively index PDFs under granted roots and render results grouped by folder.
- [ ] Preserve provider URIs as opaque handles; never fabricate filesystem paths or claim access to ungranted storage.
- [ ] Make large PDF opening progressive/asynchronous with bounded memory, cancellation and cached page rendering.

### OCR and navigation reliability
- [ ] Reproduce and fix the OCR search crash with a regression test and full Flutter stack trace.
- [ ] Keep back navigation scoped to the current route/activity; never exit the app for an in-app back action.
- [ ] Fix Flutter inherited-widget disposal assertion (_dependents.isEmpty) with a targeted widget regression test.

### Import and file interactions
- [ ] For adding exactly one PDF from inside a folder, show the same complete import dialog used by WhatsApp share: editable file name, current/choose destination folder, create-folder action, Cancel and Save. Preselect the folder the user opened.
- [ ] For multi-file imports, do not show a per-file rename/folder dialog; keep the batch import flow fast and apply the selected destination consistently.
- [ ] Preserve the incoming WhatsApp share dialog behaviour; use the same single-file import experience and avoid duplicating different dialogs.
- [x] Replace PDF-row long-press selection with a native floating full-filename tooltip anchored to the filename; holding on a truncated name must reveal the full name without selecting the file.
- [ ] Preserve an obvious alternative selection action (checkbox/select mode) so removing long-press selection does not make multi-select inaccessible.
- [ ] Add accessible context actions.
- [ ] Keep selection and current screen state when returning from nested activities.

### Scanner and gallery
- [ ] Ensure camera scan opens a dedicated scanner capture screen immediately; it must never briefly show the generic Document Tools screen.
- [ ] Ensure gallery-to-PDF opens the image selection / page filmstrip workflow directly, not the generic Document Tools screen.
- [ ] Add perspective/free-angle four-corner crop with safe inset handles and a centered image viewport.
- [ ] Add a draggable, reorderable multi-page thumbnail filmstrip for camera and gallery selections.
- [ ] Move image enhancement/OCR/encoding to isolates or native background workers where supported; benchmark auto-colour latency.
- [ ] Fix scan-to-PDF export and verify the generated PDF before import; retain source images on failure.

### Folder navigation and hierarchy
- [ ] Make the current folder breadcrumb/title (for example, Insurance) open a folder-tree dropdown/bottom-sheet showing only its direct child folders initially.
- [ ] Allow expanding nested folders recursively and navigating to any selected descendant without losing the current folder context.
- [ ] Use a bounded-height, scrollable, responsive overlay/sheet with safe-area insets, indentation, expansion chevrons and clear selected-path feedback; never render an unbounded popup that can overlap/off-screen on small phones or when there are many folders.
- [ ] Keep existing breadcrumb navigation and Android back behaviour consistent with the selected folder path.

### Recovery
- [ ] Explain and implement the real SAF recovery selection flow: select the parent containing the existing DocsGrid folder; verify Database, Documents, Folders, and Recovery before restore.
- [ ] Never treat creating a new empty DocsGrid folder as a successful recovery.
- [ ] Show actionable permission/provider errors and preserve existing records/files on every failed restore.

## Required verification
- [ ] Add focused unit/widget/integration regression tests for each corrected path.
- [ ] Run Flutter analyze and the full test suite.
- [ ] Run Android CI (including APK build) and iOS CI (unsigned build).
- [ ] Verify large files, SAF grants/revocation, OCR and scanner/gallery workflows on a physical Android device.
- [ ] Report hosted CI and physical-device results separately; do not claim device validation from CI alone.

## Known evidence and constraints
- The repository already has Android SAF listDirectory, native storage queues, PDF copy/hash verification and portable recovery snapshot code. Reuse these; do not bypass the existing safety boundaries.
- Android scoped storage does not permit silent unrestricted enumeration of all private/shared storage. Use a persisted user-selected SAF tree grant and clearly explain its scope.
- Existing image crop dependency currently provides rectangular cropping; true perspective correction requires a dedicated four-point transform and tests, not just rotating the rectangle.
- No merge until all hosted automated checks pass on the final PR head.

## Additional requirements confirmed from the user's latest screenshot
- Single PDF added from within a folder must open the full WhatsApp-style import dialog (name, destination folder, create folder); multi-file import intentionally does not need this per-file dialog.
- Scanner action must transition directly to scanner capture, with no Document Tools flash/screen.
- Long-pressing a truncated filename must show a floating full-name tooltip at the touch point while the finger remains held; it must not select the row. Provide another discoverable way to enter multi-select.
- Tapping the current folder breadcrumb/title (e.g. Insurance) opens a mobile-safe hierarchical folder navigator with recursively expandable descendants. The overlay must be scrollable and bounded to avoid overlap on narrow screens or large folder trees.
