# PR 17 — Modern performance and product experience

This document is the implementation and release checklist for the consolidated performance PR.

## Required seven performance techniques

1. **SQL aggregates:** dashboard counts, favorite count, and total bytes must be computed in SQL, without loading every document row.
2. **Keyset pagination:** fetch a bounded 30–50 row page with a stable cursor; avoid OFFSET for deep library pages.
3. **Indexed SQL filtering:** execute name/category/folder/favorite/recent filters in SQLite. Preserve the existing contains-search behavior unless a product change is explicitly reviewed.
4. **Cached dashboard summary:** cache aggregate results and invalidate them on every mutation that can affect totals.
5. **Incremental updates:** patch the changed document/page and relevant summary after actions; do not reload the entire library for a single-row change.
6. **Lazy rendering:** use builder-based list/grid widgets and stable keys so only visible rows are built.
7. **Background isolates:** move CPU-heavy pure Dart OCR normalization/dedup preparation off the UI isolate. Keep platform plugins, file-provider operations, and SQLite database handles on their supported isolate.

## Additional modern app quality work

- Debounced search with cancellation/stale-result protection.
- Bounded work queues and explicit loading states for expensive operations.
- Avoid duplicate database reads, synchronous filesystem checks in build, and needless rebuilds.
- Smooth pagination/refresh affordances and resilient empty/error states.
- Stable keys, compact row composition, and responsive layouts.
- Accessibility: semantic labels, scalable text, sufficient contrast, and practical touch targets.
- Motion and visual effects should remain lightweight in long scrolling lists and respect reduced-motion preferences.
- Measure memory, CPU, frame timing, OCR and import/backup costs rather than assuming a code change is a performance win.

## Acceptance gates

- Unit tests for cursor boundaries, SQL filters, summary values, cache invalidation, and isolate output parity.
- Migration tests for every supported prior schema version, including rollback/data preservation.
- Integration tests covering create/import, search, favorite, move, trash/restore, and pagination consistency.
- Scale benchmarks for 10k/50k/100k rows where practical; report p50/p95, not only averages.
- Flutter analyze, full tests, integration/performance suites, Android build and iOS build must pass on the final head commit.
- Review query plans and verify indexes are used for supported predicates.
- Do not claim physical-device certification from hosted CI. Device profiling remains a release gate.

## Merge rule

Keep all related implementation and fixes in this PR. Do not merge until the acceptance gates pass on the final PR head. If a gate cannot be run in hosted CI, document it as an explicit release gate rather than marking it passed.
