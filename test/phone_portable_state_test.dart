import 'dart:convert';

import 'package:docs_grid/features/documents/data/phone_portable_state.dart';
import 'package:docs_grid/features/documents/data/phone_recent_history.dart';
import 'package:docs_grid/features/documents/data/phone_star_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Star and Recent share a logical UUID independent from location', () async {
    const first = 'content://media/external_primary/file/101';
    const second = 'content://media/external_primary/file/102';
    await PhoneStarRepository.toggle(uri: first, name: 'One.pdf');
    await PhoneRecentHistory.recordOpened(first, 'One.pdf');
    await PhoneStarRepository.toggle(uri: second, name: 'Two.pdf');
    final exported = await PhonePortableState.capture();
    expect(exported['format'], PhonePortableState.format);
    final stars = (exported['stars'] as List).cast<Map<String, Object?>>();
    final recent = (exported['recent'] as List).cast<Map<String, Object?>>();
    expect(stars, hasLength(2));
    expect(recent, hasLength(1));
    final shared = stars.firstWhere((entry) => entry['uri'] == first);
    expect(recent.single['referenceId'], shared['referenceId']);
    expect(stars.firstWhere((entry) => entry['uri'] == second)['referenceId'],
        isNot(shared['referenceId']));
    await PhoneReferenceIdentity.renamed(first, 'content://media/external_primary/file/901');
    expect(await PhoneReferenceIdentity.idForUri(
        'content://media/external_primary/file/901'), shared['referenceId']);
  });

  test('backup import keeps old URI unresolved and does not replace live Star', () async {
    const local = 'content://media/external_primary/file/201';
    await PhoneStarRepository.toggle(uri: local, name: 'Local.pdf');
    final imported = {
      'format': PhonePortableState.format,
      'version': 1,
      'stars': [
        {'referenceId': 'from-other-device', 'uri': 'content://media/old/file/1',
         'name': 'Old.pdf'}
      ],
      'recent': <Object>[],
    };
    await PhonePortableState.restoreAsPending(imported);
    final localStars = await PhoneStarRepository.list();
    expect(localStars, hasLength(2));
    expect(localStars.any((item) => item['uri'] == local), true);
    final unlinked = localStars.singleWhere((item) => item['needsRelinking'] == true);
    expect(unlinked['uri'], 'missing://phone-reference/from-other-device');
    expect(unlinked['wasStarred'], true);
    expect(unlinked['originalUri'], 'content://media/old/file/1');
  });

  test('manual relink restores a shared ID to Star and Recent only once', () async {
    final imported = {
      'format': PhonePortableState.format,
      'version': 1,
      'stars': [
        {'referenceId': 'shared-id', 'uri': 'content://old/1', 'name': 'Old.pdf'}
      ],
      'recent': [
        {'referenceId': 'shared-id', 'uri': 'content://old/1', 'name': 'Old.pdf',
         'openedAt': '2026-11-18T00:00:00Z'}
      ],
    };
    await PhonePortableState.restoreAsPending(imported);
    const selected = 'content://media/external_primary/file/512';
    await PhonePortableState.relink(
      referenceId: 'shared-id', selectedUri: selected, selectedName: 'New.pdf',
    );
    expect(await PhonePortableState.pending(), isEmpty);
    final stars = await PhoneStarRepository.list();
    expect(stars, hasLength(1));
    expect(stars.single['referenceId'], 'shared-id');
    expect(stars.single['uri'], selected);
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(recent, hasLength(1));
    expect(jsonDecode(recent.single)['referenceId'], 'shared-id');
    expect(await PhoneReferenceIdentity.idForUri(selected), 'shared-id');
    await expectLater(
      PhonePortableState.relink(
        referenceId: 'shared-id', selectedUri: selected,
        selectedName: 'New.pdf',
      ),
      throwsStateError,
    );
  });

  test('relink merges into already observed physical PDF without changing its ID',
      () async {
    const sameUri = 'content://media/external_primary/file/77';
    await PhoneRecentHistory.recordOpened(sameUri, 'Same.pdf');
    final localId = await PhoneReferenceIdentity.idForUri(sameUri);
    await PhonePortableState.restoreAsPending({
      'format': PhonePortableState.format,
      'version': 1,
      'stars': [
        {'referenceId': 'imported-id', 'uri': 'content://old/file/77',
         'name': 'Same.pdf'}
      ],
      'recent': <Object>[],
    });
    await PhonePortableState.relink(
      referenceId: 'imported-id', selectedUri: sameUri, selectedName: 'Same.pdf',
    );
    expect(await PhoneReferenceIdentity.idForUri(sameUri), localId);
    final stars = await PhoneStarRepository.list();
    expect(stars, hasLength(1));
    expect(stars.single['referenceId'], localId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), hasLength(1));
    expect(await PhonePortableState.pending(), isEmpty);
  });

  test('untrusted or duplicate Phone state is rejected', () {
    expect(() => PhonePortableState.validate({
      'format': PhonePortableState.format,
      'version': 2, 'stars': [], 'recent': [],
    }), throwsFormatException);
    expect(() => PhonePortableState.validate({
      'format': PhonePortableState.format,
      'version': 1,
      'stars': [
        {'uri': 'content://media/a', 'name': 'A.pdf', 'referenceId': 'same'},
        {'uri': 'content://media/b', 'name': 'B.pdf', 'referenceId': 'same'},
      ],
      'recent': [],
    }), throwsFormatException);
  });

  test('database backup captures only safe display settings', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', true);
    await prefs.setBool('docsgrid_grid_tab_tiles_v1', true);
    await prefs.setBool('docsgrid_enable_ocr_search_v1', false);
    await prefs.setString('docsgrid_portable_locations_v1', 'secret-file-uri');
    final captured = await PhonePortableState.capture();
    final display = captured['displayPrefs'] as Map;
    expect(display['dark_mode'], true);
    expect(display['docsgrid_grid_tab_tiles_v1'], true);
    expect(display.containsKey('docsgrid_portable_locations_v1'), false);

    SharedPreferences.setMockInitialValues({});
    await PhonePortableState.restoreAsPending(captured);
    final restored = await SharedPreferences.getInstance();
    expect(restored.getBool('dark_mode'), true);
    expect(restored.getBool('docsgrid_enable_ocr_search_v1'), false);
    expect(restored.getString('docsgrid_portable_locations_v1'), isNull);
  });

  test('rejects untrusted preference keys and wrong value types', () {
    for (final prefs in [
      {'docsgrid_portable_locations_v1': 'content://secret'},
      {'dark_mode': 'false'},
    ]) {
      expect(() => PhonePortableState.validate({
        'format': PhonePortableState.format, 'version': 1,
        'stars': [], 'recent': [], 'displayPrefs': prefs,
      }), throwsFormatException);
    }
  });

  test('captured sorting preferences are portable but do not overwrite local', () async {
    final prefs = await SharedPreferences.getInstance();
    const original = '{"field":"name","ascending":true,"explicit":true}';
    const imported = '{"field":"date","ascending":false,"explicit":true}';
    await prefs.setString(PhonePortableState.phoneSortKey, original);
    final backup = {
      'format': PhonePortableState.format,
      'version': 1,
      'stars': <Object>[],
      'recent': <Object>[],
      'phoneSort': imported,
    };
    await PhonePortableState.restoreAsPending(backup);
    expect(prefs.getString(PhonePortableState.phoneSortKey), original);
    final state = await PhonePortableState.capture();
    expect(jsonDecode(state['phoneSort'] as String)['field'], 'name');
  });
}
