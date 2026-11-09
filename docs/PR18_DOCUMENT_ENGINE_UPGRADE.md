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
- [ ] Provide the complete import dialog with editable PDF name and destination folder, including incoming share imports.
- [ ] Add long-press filename preview/tooltip and accessible context actions.
- [ ] Keep selection and current screen state when returning from nested activities.

### Scanner and gallery
- [ ] Ensure camera scan and gallery-to-PDF launch the scanner/import flow, not the generic Document Tools screen.
- [ ] Add perspective/free-angle four-corner crop with safe inset handles and a centered image viewport.
- [ ] Add a draggable, reorderable multi-page thumbnail filmstrip for camera and gallery selections.
- [ ] Move image enhancement/OCR/encoding to isolates or native background workers where supported; benchmark auto-colour latency.
- [ ] Fix scan-to-PDF export and verify the generated PDF before import; retain source images on failure.

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