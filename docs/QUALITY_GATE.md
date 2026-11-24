# DocsGrid Quality Shield

Status: phase 1, automated CI gate. This is development infrastructure, not app runtime code.

## Required check
Configure main branch protection / ruleset to require **DocsGrid Quality Gate** (Flutter CI), strict up-to-date branches, review of workflow changes and no bypass except controlled emergency policy. Do not merge if checks are missing, skipped, cancelled or failed. The aggregate job requires Android analysis/tests/APK, iOS analysis/tests/unsigned build and Android fresh-install/cold-start emulator benchmark to succeed. It does not prove device parity or production signing. Repository-level rules and release publication enforcement must be separately configured and verified; the workflow alone does not prevent all merges or releases.

## Initial feature regression inventory
Existing test files identified on this branch (presence is not proof of complete behavioral coverage):
- Smart collections: test/smart_collection_selection_test.dart, test/smart_collection_editor_contract_test.dart
- Phone storage/search: test/phone_storage_browser_screen_test.dart
- PDF details: test/pdf_details_dialog_test.dart
- Reminder inbox: test/reminder_inbox_sheet_test.dart
- Grid startup and loading: test/fresh_grid_database_test.dart, test/grid_first_load_timeout_test.dart, scripts/smoke_android_fresh_grid.py
- Backup/restore: test/document_backup_restore_integration_test.dart, test/backup_validation_test.dart, test/zip_restore_regression_contract_test.dart
- Data and file operations: test/durable_file_operations_test.dart, test/grid_storage_boundary_test.dart
- iOS recovery: test/ios_recovery_parity_contract_test.dart; see docs/IOS_RECOVERY_PARITY.md for outstanding native/device checks.
- Performance: test/performance (10k documents), scripts/benchmark_android_cold_launch.py.

## Outstanding gates (not PASS until independently implemented and verified)
1. Required branch protection and release publication rules.
2. Feature-level coverage and native device testing for every supported action, including notifications, OCR, permissions, import/share, and destructive recovery.
3. Security/dependency scanning, coverage baseline and regression limits, mutation and fuzz tests.
4. Fault injection, memory profiling, 50k/100k stress and performance baseline comparison.
5. Upgrade from supported older versions, cross-platform backup restore, device matrix, signed iOS IPA/TestFlight and real-device verification.
6. Scheduled security and heavy testing, artifact provenance and rollback/restore policy.

No Android/iOS runtime or database changes are needed for the aggregate CI gate. Do not weaken existing checks to obtain a green result. Report untested capabilities explicitly. Production releases require signing and device evidence in addition to the automated gate.
