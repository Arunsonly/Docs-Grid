import 'dart:convert';

import 'package:docs_grid/features/documents/data/phone_recent_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  String item(String uri, String name) => jsonEncode({
        'uri': uri, 'name': name, 'openedAt': '2026-11-17T11:00:00Z',
      });

  test('successful phone move removes only matching URI from durable Recent', () async {
    const moved = 'content://media/external_primary/file/1000702003';
    const retained = 'content://media/external_primary/file/44';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(PhoneRecentHistory.storageKey, [
      item(moved, '10th result.pdf'),
      item(retained, 'Other.pdf'),
      item(moved, 'Earlier duplicate move history'),
      'malformed older metadata',
    ]);
    expect(await PhoneRecentHistory.removeMovedSource(moved), isTrue);
    final recent = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(recent, hasLength(2));
    expect(recent.first, item(retained, 'Other.pdf'));
    expect(recent.last, 'malformed older metadata');
    expect(await PhoneRecentHistory.removeMovedSource(moved), isFalse,
        reason: 'A repeated move/refresh must never remove unrelated history.');
  });

  test('failed or duplicate move should not mutate phone history', () async {
    const source = 'content://media/external_primary/file/1000702003';
    final prefs = await SharedPreferences.getInstance();
    final original = [item(source, 'Insurance.pdf')];
    await prefs.setStringList(PhoneRecentHistory.storageKey, original);
    // The call to removeMovedSource is deliberately not made until the
    // repository has confirmed the source deletion and Grid import.
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), original);
    expect(await PhoneRecentHistory.removeMovedSource(''), isFalse);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), original);
  });

  test('authoritative MediaStore index purges older moved/deleted URI ghosts', () async {
    final prefs = await SharedPreferences.getInstance();
    const gone = 'content://media/external_primary/file/1000702003';
    const alive = 'content://media/external_primary/file/200';
    const saf = 'content://com.android.externalstorage.documents/document/primary';
    const local = 'file:///storage/emulated/0/Download/Document.pdf';
    await prefs.setStringList(PhoneRecentHistory.storageKey, [
      item(gone, '10th result.pdf'),
      item(alive, 'Still on Phone.pdf'),
      item(saf, 'SAF PDF.pdf'),
      item(local, 'Local.pdf'),
      'unparsed legacy entry',
    ]);
    expect(
      await PhoneRecentHistory.pruneAbsentMediaStoreUris(
          {alive}, scannedVolumes: {'external_primary'}), 1,
    );
    final saved = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(saved, hasLength(4));
    expect(saved, isNot(contains(item(gone, '10th result.pdf'))));
    expect(saved, contains(item(alive, 'Still on Phone.pdf')));
    expect(saved, contains(item(saf, 'SAF PDF.pdf')));
    expect(saved, contains(item(local, 'Local.pdf')));
    expect(saved, contains('unparsed legacy entry'));
    expect(await PhoneRecentHistory.pruneAbsentMediaStoreUris(
        {alive}, scannedVolumes: {'external_primary'}), 0);
  });


  test('an unavailable SD card volume is never pruned', () async {
    final prefs = await SharedPreferences.getInstance();
    const onSd = 'content://media/1234-5678/file/30';
    const missingOnMounted = 'content://media/external_primary/file/40';
    final sdHistory = item(onSd, 'Card policy.pdf');
    await prefs.setStringList(PhoneRecentHistory.storageKey, [
      sdHistory,
      item(missingOnMounted, 'Deleted phone.pdf'),
    ]);
    expect(
      await PhoneRecentHistory.pruneAbsentMediaStoreUris(
          {}, scannedVolumes: {'external_primary'}),
      1,
    );
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), [sdHistory]);
  });

  test('empty/unrecognized recent preferences do not trigger removal', () async {
    expect(await PhoneRecentHistory.removeMovedSource('content://media/nope'),
        isFalse);
    expect(await PhoneRecentHistory.pruneAbsentMediaStoreUris(
        {}, scannedVolumes: {}), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), isNull);
  });
}
