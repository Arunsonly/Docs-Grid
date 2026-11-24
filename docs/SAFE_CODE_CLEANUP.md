# Safe cleanup phase 1
Baseline: 49393e0753b548e87f926210790360d3a42e5721, Flutter CI 45389313055 (Android, iOS, emulator and aggregate pass).
Separate cleanup branch; no merge or release authorized.
- Remove unreferenced OCR preference helper and obsolete internal PDF viewer. Keep existing OCR engine and search mode tests until separate verified phase.
- Remove no-action Default view tile and obsolete camera/gallery spinner branches. Remove explicit camera/photo permissions and usage strings from generated build setup; preserve notification, storage and PDF handling.
- Remove only obsolete preference persistence assertions; preserve explicit indexing, cancellation and toggle tests. Add a source contract guarding retired paths and retained sharing, opening, thumbnails and emergency recovery.
- No database/table/schema changes, no native source changes, no dependency changes. Preserve backup/recovery and exact duplicate detection.
- Pending: OCR indexing/UI/ML Kit removal and legacy OCR metadata compatibility, old tools UI, legacy storage migration and incremental writer review; full function/native reachability, binary size, device and advanced testing. Do not claim PASS before CI completes.
