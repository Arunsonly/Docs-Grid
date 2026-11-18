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
