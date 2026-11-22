# DocsGrid targeted fix — Home navigation and missing Grid PDF records

## Root causes and scope

1. Phone → Home displays 0 PDFs indefinitely: Flutter reused a StatefulWidget element because both tabs used DocumentsScreen with no keys. A former phoneOnly state then never calls Home's _load(). Distinct ValueKey identities for Phone and Home force correct initialization.

2. The error "Grid PDF has an unsupported storage location" can be caused by a missing:// metadata-only reference from a database-only restore or metadata recovery. Rendering a stored database name and size does not prove the PDF bytes are physically present. The Grid and Home menus now expose existing SHA-256 verified Relink PDF. Explicit missing/invalid locations display File unavailable. Users must choose a real matching PDF to relink.

## Safety and coverage

No automatic restore, relink, relocation, cleanup or removal. Manual relink verifies SHA-256 before updating the existing record. Original records remain visible for future recovery; no deletions. Four extra tests check real Flutter State key lifecycle (including Grid → Phone → Home), storage reference classification, and Insurance Save → SHA-256 → 24-hour aged file → physical SQLite close/reopen → identical PDF Bytes and URI.

Existing full test suite and Android/iOS builds remain required. No actual Samsung PDF was read or changed. An existing physically deleted file cannot be recreated without a verified original or Full Backup. 24-hour aging is simulated, not a day-long wall-clock test.

## PR isolation

This fix is a separate Draft PR, branched from tested PR #35 and proposed against main for independent CI. Neither PR #35 nor main nor DocsGrid-Stable-V1 is modified.
