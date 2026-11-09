# DocsGrid — Large-file, OCR and physical-device validation runbook

Status: preparation and source-level hardening only. No physical Android/iPhone test is claimed complete by hosted CI.

## 1. Large PDF and provider-backed import

### Automated coverage added on the work branch
- Provider byte streams are staged to cache with IOSink.addStream; imports no longer call readAsBytes() for pathless provider files.
- The same streaming staging path is used by PDF import, relink and pathless backup ZIP restore.
- A 24 MiB / 384-chunk test verifies staged file length and SHA-256.
- An interrupted-stream test verifies partial staging files are removed.
- The existing import pipeline checks the %PDF- header, hashes source bytes by stream, copies and verifies destination SHA-256, and commits the DB record only after verification.

### Physical test matrix
Use PDFs of approximately 5 MiB, 50 MiB, 200 MiB and the largest supported real-world sample available. Include text-based, image-only scanned, mixed, 300+ page, malformed/truncated and zero-byte PDFs; Android SAF, cloud providers, iOS Files/iCloud Drive; slow network and revoked access.

For each file:
1. Import from provider into root and a nested DocsGrid folder.
2. Confirm import completes and app remains responsive.
3. Compare source and stored SHA-256; verify DB size matches actual bytes.
4. Open the imported PDF, scroll to last page, close and reopen.
5. Repeat import and confirm duplicate detection creates no second row.
6. Cancel/interrupt provider download where supported; confirm no DB row or partial staged/copied file remains.
7. Monitor peak memory, process termination, UI jank and temporary storage usage.

Pass criteria: byte-for-byte SHA-256 match, one DB record per unique PDF, no partial/orphan file after failure, no OOM/process death, and no unbounded UI stall. Record device model, OS, PDF size/page count, provider, peak memory and elapsed time.

## 2. OCR _dependents.isEmpty assertion

The exact cause remains unconfirmed. The assertion screenshot alone cannot identify the widget or lifecycle owner. Do not label this fixed until a full stack trace is captured and correlated with a reproducible action sequence.

### Android capture
1. Install the exact candidate APK and note its commit SHA.
2. Enable USB debugging and connect with adb devices.
3. Run: adb logcat -c
4. Reproduce once; note exact taps and whether OCR search or indexing was running.
5. Immediately run: adb logcat -d -v threadtime > docsgrid-ocr-crash.txt
6. Preserve the original log. A filtered copy may be made with:
   adb logcat -d -v threadtime | grep -E -i 'flutter|Dart|AndroidRuntime|Exception|dependents|DocsGrid|MLKit|pdfx' > docsgrid-ocr-filtered.txt

Share the complete original log, app version/commit, Android version/device and precise reproduction steps. The first exception and frames preceding/following the framework assertion are essential.

### Regression sequence
- Open OCR tools, start indexing, immediately leave the route.
- Start OCR search and leave while the DB query is pending.
- Rapidly submit search twice; press Enter and tap Search.
- Search during/after indexing.
- Repeat with selectable-text, image-only, multi-page, malformed and large PDFs.
- Repeat with revoked SAF permission and missing source file.
- Verify no setState-after-dispose, inherited-widget assertion, stuck indexing status, leaked temporary PNG/PDF, or native recognizer/PDF handle.

Current source guards single-flight search, invalidates stale search completions, passes route cancellation into OCR indexing, distinguishes cancellation from failure and closes recognizers/PDF handles in nested finally blocks. These guards reduce known lifecycle hazards but do not establish the root cause.

## 3. Physical Android validation

On a real Android phone:
- SAF: grant an existing tree, browse nested/empty folders, open PDFs, create folders, restart app, revoke permission in system settings, reopen and confirm access is reported as revoked without silently changing paths or deleting records.
- Import: pick from Downloads, local Documents and cloud provider; test single and multi-select; include large PDFs.
- Camera: deny/grant permission, capture one and multiple pages, retake/cancel, crop/reorder, save to root and nested folder.
- Gallery: select multiple images, reorder, crop, export, import and reopen generated PDF.
- OCR: Latin and Devanagari, search, route dismissal during pending work, indexing failure and permission revocation.
- Recovery: use a copied DocsGrid recovery tree, validate snapshot, restore additively, verify hashes and DB links; test missing folders, corrupt manifest, wrong hash and interrupted restore.

## 4. Physical iPhone validation

On a real iPhone:
- Files: select iCloud Drive and On My iPhone folders, restart app, verify bookmark access, revoke/change access and verify recovery behavior.
- Import: Files provider and cloud-backed PDFs, including large and multi-page files.
- Scanner: camera permission denied/granted, multi-page scan, reorder/crop, cancel and save.
- Gallery: multi-photo selection, page order, crop and generated PDF verification.
- OCR: Latin recognition/search, route dismissal during pending work and repeated search.
- Restore: restore a real backup from Files; confirm additive behavior, hash verification, relinking for missing PDFs and no overwrite/deletion.

## 5. Backup/restore acceptance

Current enforced ZIP limits (from BackupArchiveLimits):
- Compressed ZIP: 128 MiB maximum.
- One expanded ZIP entry: 128 MiB maximum.
- Total expanded archive: 256 MiB maximum.
- ZIP64 and multi-disk archives are not supported.

Direct PDF import/relink streaming is not subject to these ZIP-specific limits. A PDF larger than 128 MiB, or a backup whose expanded contents exceed 256 MiB, is expected to be rejected by ZIP restore. If larger backup restores are a product requirement, raise these bounded limits deliberately and add boundary/ZIP-bomb regression tests before release.

Use a copy of real user data on a test device, never the only production copy.
1. Create a backup and copy it to a separate location.
2. Verify the archive before restore.
3. Restore into a clean test profile and into a profile with existing records.
4. Confirm existing files are not overwritten, duplicate content is handled safely, and imported PDFs match manifest SHA-256.
5. Test corrupt ZIP, traversal path, missing PDF payload, hash mismatch, duplicate IDs and interrupted restore.
6. Confirm missing files remain visible as relink-required records and are not represented as successfully linked.
7. Reopen restored PDFs and compare counts, sizes and hashes.

## Evidence required before release
- Full Android and iOS CI for the exact final PR head.
- Automated large-stream staging tests and a real large-PDF import test on both platforms.
- Android and iPhone test logs, device/OS details, memory measurements and screenshots/video for physical flows.
- Complete OCR crash log plus deterministic regression evidence, or explicit unresolved-risk acceptance.
- Backup manifest/hash report and restore outcome from a real test backup.

Hosted CI passing is necessary but does not replace these device and real-data checks.


## Personal-use Android storage and complete recovery

- On a personal-use sideloaded build, grant **Full internal storage access** from DocsGrid Settings. Android opens the app-specific All files access settings page; return to DocsGrid and the pending recovery scan resumes automatically.
- With access granted, the Files dashboard browses shared internal storage from its root. Android-protected `Android/data` and `Android/obb` branches may remain inaccessible by OS design and are skipped without stopping the scan.
- First-launch recovery checks the existing `Android/media/DocsGrid` tree (`Documents`, `Folders`, `Database`, and `Recovery`) and verifies a portable snapshot. It must not create a new empty tree or change the backup source into a new save location.
- Portable recovery restores folder hierarchy, PDF metadata and SHA-256 relinks, categories, tags, document-tag links, reminders, activity/history, OCR text indexes and settings. It is additive and remaps conflicting IDs; missing PDFs retain their metadata and are reported for relinking.
- Reminder records are durable rows in the app-private SQLite database `docs_grid.db`; they are not separate one-file-per-reminder records. When portable storage is configured, creating/updating/snoozing/enabling/disabling/completing/deleting a reminder refreshes a complete portable metadata snapshot containing `reminders.json`. Notification scheduling is reconciled separately from database persistence.
- Verify on device: create a reminder, inspect the newest `Database/snapshot_*/reminders.json`, relaunch, restore to a clean app install, confirm reminder details and linked PDF IDs, and confirm notification scheduling when Android notification permission is granted.
- Delete a folder externally in Samsung My Files / Android Files. Refresh DocsGrid; missing physical folder rows must be soft-deleted from the active folder list, while permission/provider errors must not be mistaken for deletion.
- In a folder containing both subfolders and PDFs, folder drag handles remain visible and PDF long-press enters multi-select without opening a name tooltip.


Implementation note: CI is intentionally deferred for this PR until the owner authorizes it; do not treat this as an automated green build.
