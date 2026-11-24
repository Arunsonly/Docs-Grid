import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clean reinstall uses permission-first recovery and resumes the source', () {
    final main = File('lib/main.dart').readAsStringSync();
    final screen = File('lib/features/tools/document_tools_screen.dart').readAsStringSync();
    expect(main, contains('if (!storageInspected) {'));
    expect(main, contains("quickAction: 'restore_portable', section: 'backup_restore'"));
    final start = screen.indexOf('Future<void> _restorePortableSnapshot({');
    final verify = screen.indexOf('final snapshot = await _tools.verifyLatestPortableMetadataSnapshot', start);
    final preflight = screen.substring(start, verify);
    expect(preflight, contains('!await storage.hasAllFilesAccess()'));
    expect(preflight, contains('_resumeRecoverySource = selectedSource;'));
    expect(preflight, contains('await storage.requestAllFilesAccess();'));
    expect(screen, contains('selectedSource: source);'));
    expect(preflight, contains('await storage.discoverOldDocsGridStorage()'));
  });

  test('loose recovery preserves existing folder paths and never needs a ZIP', () {
    final service = File('lib/features/tools/document_tools_service.dart').readAsStringSync();
    final start = service.indexOf('Future<Map<String, int>> recoverLoosePortablePdfs');
    final end = service.indexOf('Future<String> _readPortableBackupType', start);
    final recovery = service.substring(start, end);
    expect(recovery, contains('retainedFolderPaths.add(path)'));
    expect(recovery, contains('await ensureFolderPath(path)'));
    expect(recovery, contains('reuseExistingPhysical: true'));
    expect(recovery, contains('targetFolderId: folderId'));
    expect(recovery, isNot(contains('deletePdf(')));
  });
}
