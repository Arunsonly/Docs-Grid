# Safe code cleanup — batch candidate
Baseline: 49393e0753b548e87f926210790360d3a42e5721, Flutter CI 45389313055 (Android, iOS, emulator and aggregate pass).
Phase 1: 759d73d69ad964859b213ec9fb2249892f55057e. Separate batch branch; no merge or new CI until user approval.
Phase 2: 6428faeb8a4ada20f41f6b0151407349fc287597.

## Removed with authorization
- Obsolete OCR preferences, mode toggle, Phone OCR index, Phone/Home/Grid OCR branches, OCR indexing engine, SQL text search and OCR duplicate review UI/grouping. Removed Latin/Devanagari ML Kit dependency, direct/transitive lockfile entries and Android native dependency injection/R8 rules. Kept existing iOS deployment target.
- Unused internal PDF viewer, capture spinner branches, explicitly injected camera/photo usage descriptions and permission, no-action Default view tile.
- Obsolete automatic legacy migration wrapper and reference checker. Explicit tested copy-only migration and storage/recovery locking remain.
- Legacy incremental backup writer and creation planner; old archive validation, reading, composition, export, cleanup and restore remain.
- Removed tests exclusively exercising retired functions; adapted mixed tests to retain filename search, real SHA-256 duplicate detection, existing OCR metadata compatibility, active filename-search performance, and legacy chain reader coverage.

## Protected code
No changes to native Android/iOS source or database schema. Keep legacy document_text_index records, old backup sections, exact duplicate handling, imported shared PDFs, pdfx thumbnails, open_filex PDF opening, daily backups, old weekly task cancellation, storage access, notifications and recovery. Do not drop database records. All normal UI search branches are the same filename-based branches that previously ran with OCR disabled.

## Verification limits
Source reference scan only. No new CI until user approval. Runtime/compiled APK, analyzer, coverage, performance and security scan results are not measured for this candidate. Actual Android/iPhone device testing, memory leak, CPU, battery, full mutation/fuzz and full device compatibility require separate evidence. Do not claim zero regression before tests.
