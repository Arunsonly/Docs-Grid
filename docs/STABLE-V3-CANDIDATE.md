# DocsGrid V3 integration candidate — 24 November 2026

This is a release candidate, not a certification that the final integrated build has passed.
Stable V2 restore point: DocsGrid-Stable-V2-2026-11-22, commit 1b4fef0ebc4c98d927cdb6df8704e18351fa19bd. Do not change that branch.

Integration parents:
- PR #52 171433514345f1511dd15b58d30bfdc4afabd275: latest Smart Collections, Reminder inbox, sound channel, details without Storage URI, name-only Phone search, storage information, private operational storage, and recovery fixes.
- PR #53 5b3f971571bd023745c4ee2b0f0add60f28a0197: standalone Full ZIP creation, simplified Backup & Recovery UI, legacy chain restoration, verified export and database backups.
- PR #51 38607027366f014b0f6296457f767f22a517224f: Recycle Bin multi-selection, Back-to-clear, and quiet routine success actions.

Keep #52 as the advanced base. Apply only the changes unique to #51 and #53, retaining newer implementations where overlapping actions have already been improved. Keep database migration safeguards, original PDF bytes, duplicate detection, restore validation and all existing regression suites. Version: 3.0.0+3.

Gate stable designation on successful Android and iOS analysis/tests/builds, and fresh-install Grid/Android emulator verification from the integrated commit. Internal evaluation signing is not Play Store production signing.
