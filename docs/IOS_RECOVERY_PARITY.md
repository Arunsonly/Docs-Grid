# iOS recovery parity — isolated development branch

Baseline: b0eb219ef03994bfd1ae28af99c8d3e72bd91a1c (V3 all CI jobs passed before these changes). Android native implementation, database schema, Android storage layout and Android scheduling are unchanged.

Implemented: iOS first-run ZIP and selected PDF folder routes; separate read-only recovery/export bookmarks; verified copies rather than mutable source references; local archive inventory/cleanup and external export; iOS Files date metadata; native notification sound check; foreground daily database backup. App-private archives alone do not survive Delete App. Export a verified Full ZIP to independent Files/iCloud storage. Cloud upload completion is not claimed.

Remaining release gates: test real iPhone offload/delete/reinstall, Files provider permissions/cloud downloads, large ZIP and PDF, cross-platform ZIP restore, iPad sharing, iOS notification capacity and sound, security-scoped file coordination, native Share Extension/App Group, Hindi OCR, Apple signing/TestFlight. No claim of full iOS parity or device verification until those gates pass.
