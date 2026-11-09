# DocsGrid performance and integration verification

## Automated coverage

- The integration workflow test exercises the OCR-index search, SHA-256 duplicate
  detection, OCR-text duplicate detection, and soft-delete visibility rules as one
  connected library workflow using SQLite and real temporary PDF files.
- The performance benchmark seeds 10,000 document/index rows in one transaction,
  warms the search path, then measures 25 repeated OCR substring searches. It emits
  a `DOCSGRID_BENCHMARK` line with p50/p95 microseconds and enforces a deliberately
  generous 5-second p95 regression ceiling.

## Interpretation and limits

These are deterministic host-side SQLite regression checks, not Android/iOS device
benchmarks. The library screen also now reads the document collection once per refresh
instead of issuing a second full-library query for dashboard totals, and document
tiles no longer synchronously probe the filesystem during widget build. SQLite in-memory performance on GitHub-hosted runners is not a proxy
for physical storage, thermal throttling, low-memory devices, OCR model latency,
or Android Storage Access Framework / iOS Files provider latency.

Release performance qualification must additionally record:
- physical device model, OS version, build mode, and thermal/battery state;
- cold and warm launch, 1k/10k/50k library list and search latency;
- import/copy/hash/backup/restore throughput for representative PDF sizes;
- OCR latency by page count and scan resolution;
- peak memory, CPU, and jank/frame-time traces;
- p50, p95, and p99 across at least 5 repetitions after warm-up.

Do not claim a device-level performance pass until those measurements are captured
on representative low-, mid-, and high-tier Android devices and supported iPhones.
