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


  Map<String, Object?> scannedPdf(String uri, String name, {
    int lastModified = 1794904000000,
    String folder = 'Internal/Download',
  }) => {
    'uri': uri, 'name': name, 'sizeBytes': 100,
    'lastModified': lastModified, 'folderPath': folder,
    'isDirectory': false,
  };

  test('Phone baseline excludes old PDFs; next complete scan records Added once', () async {
    const scope = 'media:external_primary';
    const old = 'content://media/external_primary/file/1';
    const fresh = 'content://media/external_primary/file/2';
    final at = DateTime.utc(2026, 11, 17, 13, 0);
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [scannedPdf(old, 'Old.pdf')],
    }, observedAt: at), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), isNull);
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [
        scannedPdf(old, 'Old.pdf'),
        scannedPdf(fresh, 'Fresh insurance.pdf'),
      ],
    }, observedAt: at), 1);
    final recent = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(recent, hasLength(1));
    final added = jsonDecode(recent.single) as Map;
    expect(added['name'], 'Fresh insurance.pdf');
    expect(added['addedAt'], at.toIso8601String());
    expect(added['openedAt'], isNull);
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [
        scannedPdf(old, 'Old.pdf'),
        scannedPdf(fresh, 'Fresh insurance.pdf'),
      ],
    }), 0);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), recent);
  });

  test('Opened upgrades Added without creating a second Phone Recent entry', () async {
    const scope = 'media:external_primary';
    const uri = 'content://media/external_primary/file/22';
    await PhoneRecentHistory.observeCompletedScans({scope: []});
    await PhoneRecentHistory.observeCompletedScans({
      scope: [scannedPdf(uri, 'Result.pdf')],
    }, observedAt: DateTime.utc(2026, 11, 17, 7));
    await PhoneRecentHistory.recordOpened(
      uri, 'Result.pdf', sizeBytes: 100,
      openedAt: DateTime.utc(2026, 11, 17, 10),
    );
    final prefs = await SharedPreferences.getInstance();
    final recents = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(recents, hasLength(1));
    final opened = jsonDecode(recents.single) as Map;
    expect(opened['addedAt'], DateTime.utc(2026, 11, 17, 7).toIso8601String());
    expect(opened['openedAt'], DateTime.utc(2026, 11, 17, 10).toIso8601String());
    expect(opened['name'], 'Result.pdf');
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [scannedPdf(uri, 'Result.pdf')],
    }), 0);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), recents);
  });

  test('SD reconnect and first SAF scan do not flood old phone files', () async {
    const primary = 'media:external_primary';
    const sd = 'media:1234-5678';
    const saf = 'root:content://provider/tree/document';
    final primaryOld = scannedPdf('content://media/external_primary/file/7', 'Phone.pdf');
    final sdOld = scannedPdf('content://media/1234-5678/file/11', 'Card.pdf');
    final safOld = scannedPdf('content://provider/document/1', 'SAF.pdf');
    await PhoneRecentHistory.observeCompletedScans({
      primary: [primaryOld],
      sd: [sdOld],
    });
    expect(await PhoneRecentHistory.observeCompletedScans({
      primary: [primaryOld],
    }), 0);
    expect(await PhoneRecentHistory.observeCompletedScans({
      sd: [sdOld],
      saf: [safOld],
    }), 0);
    expect(await PhoneRecentHistory.observeCompletedScans({
      sd: [sdOld, scannedPdf('content://media/1234-5678/file/12', 'New card.pdf')],
      saf: [safOld, scannedPdf('content://provider/document/2', 'New SAF.pdf')],
    }), 2);
    final recent = (await SharedPreferences.getInstance())
        .getStringList(PhoneRecentHistory.storageKey)!;
    expect(recent, hasLength(2));
    expect(recent.map((s) => jsonDecode(s)['name']).toSet(),
        {'New card.pdf', 'New SAF.pdf'});
  });

  test('Clear Recent preserves new-file baseline and only future files reappear', () async {
    const scope = 'media:external_primary';
    final old = scannedPdf('content://media/external_primary/file/1', 'Old.pdf');
    final newer = scannedPdf('content://media/external_primary/file/2', 'New.pdf');
    await PhoneRecentHistory.observeCompletedScans({scope: [old]});
    await PhoneRecentHistory.observeCompletedScans({scope: [old, newer]});
    await PhoneRecentHistory.clearRecent();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), isNull);
    expect(await PhoneRecentHistory.observeCompletedScans({scope: [old, newer]}), 0);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), isNull);
    await PhoneRecentHistory.observeCompletedScans({
      scope: [old, newer, scannedPdf('content://media/external_primary/file/3', 'Latest.pdf')],
    });
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), hasLength(1));
  });

  test('1000 existing PDFs are baseline-only; newest 20 of next 30 appear', () async {
    const scope = 'media:external_primary';
    final many = List.generate(1000, (i) =>
        scannedPdf('content://media/external_primary/file/$i', 'Stored $i.pdf'));
    expect(await PhoneRecentHistory.observeCompletedScans({scope: many}), 0);
    final newFiles = List.generate(30, (i) => scannedPdf(
      'content://media/external_primary/file/${1000 + i}',
      'New $i.pdf', lastModified: 1794904000000 + i * 1000,
    ));
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [...many, ...newFiles],
    }), 30);
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(recent, hasLength(20));
    expect(jsonDecode(recent.first)['name'], 'New 29.pdf');
    expect(jsonDecode(recent.last)['name'], 'New 10.pdf');
    expect(await PhoneRecentHistory.observeCompletedScans({
      scope: [...many, ...newFiles],
    }), 0);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), recent);
  });

  test('exclude Grid-managed folders, inaccessibles and non-PDF files', () async {
    const scope = 'root:file:///storage/emulated/0';
    await PhoneRecentHistory.observeCompletedScans({scope: []});
    final count = await PhoneRecentHistory.observeCompletedScans({
      scope: [
        scannedPdf('file:///root/real.pdf', 'Real.pdf'),
        scannedPdf('file:///root/grid.pdf', 'Grid.pdf',
            folder: 'Android/media/com.docsgrid/My Files/Folders/Insurance'),
        scannedPdf('file:///root/recycle.pdf', 'Old.pdf',
            folder: 'Android/media/docsgrid/Recycle'),
        {'uri': 'file:///root/text.txt', 'name': 'text.txt'},
        {'uri': 'file:///root/missing.pdf', 'name': 'missing.pdf',
          'isInaccessible': true},
      ],
    });
    expect(count, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getStringList(PhoneRecentHistory.storageKey)!.single)['name'], 'Real.pdf');
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
