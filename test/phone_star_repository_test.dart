import 'package:docs_grid/features/documents/data/phone_star_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Phone PDF star persists independently of Grid and preserves location', () async {
    expect(await PhoneStarRepository.list(), isEmpty);
    expect(await PhoneStarRepository.toggle(
      uri: 'content://media/external_primary/file/8',
      name: 'Policy.pdf',
      folderPath: 'Internal/Download',
      sizeBytes: 250,
    ), isTrue);
    final items = await PhoneStarRepository.list();
    expect(items, hasLength(1));
    expect(items.single['uri'], 'content://media/external_primary/file/8');
    expect(items.single['name'], 'Policy.pdf');
    expect(items.single['folderPath'], 'Internal/Download');
    expect(items.single['sizeBytes'], 250);
    // Starred entries live in phone-only preferences, not a new Grid PDF.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PhoneStarRepository.storageKey), hasLength(1));
  });

  test('toggling an existing Star removes only that URI and is reversible', () async {
    const a = 'content://media/external_primary/file/1';
    const b = 'content://media/external_primary/file/2';
    await PhoneStarRepository.toggle(uri: a, name: 'A.pdf');
    await PhoneStarRepository.toggle(uri: b, name: 'B.pdf');
    expect(await PhoneStarRepository.toggle(uri: a, name: 'A.pdf'), isFalse);
    final left = await PhoneStarRepository.list();
    expect(left, hasLength(1));
    expect(left.single['uri'], b);
    expect(await PhoneStarRepository.toggle(uri: a, name: 'A.pdf'), isTrue);
    expect(await PhoneStarRepository.list(), hasLength(2));
  });

  test('renaming a starred URI keeps exactly one Star', () async {
    const before = 'content://provider/document/a';
    const after = 'content://provider/document/b';
    await PhoneStarRepository.toggle(uri: before, name: 'Old.pdf');
    await PhoneStarRepository.updateRenamedReference(before, after, 'New.pdf');
    await PhoneStarRepository.updateRenamedReference(before, after, 'New.pdf');
    final saved = await PhoneStarRepository.list();
    expect(saved, hasLength(1));
    expect(saved.single['uri'], after);
    expect(saved.single['name'], 'New.pdf');
  });

  test('remove stale Star only after successful move/delete', () async {
    const uri = 'content://provider/doc/5';
    await PhoneStarRepository.toggle(uri: uri, name: 'Invoice.pdf');
    // Failed Move: no cleanup call, original starred and original file intact.
    expect(await PhoneStarRepository.list(), hasLength(1));
    await PhoneStarRepository.remove(uri);
    expect(await PhoneStarRepository.list(), isEmpty);
    await PhoneStarRepository.remove(uri); // Idempotent.
    expect(await PhoneStarRepository.list(), isEmpty);
  });

  test('malformed legacy Star metadata is ignored without losing good entries', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(PhoneStarRepository.storageKey, [
      'damaged entry',
      '{"uri":"content://provider/doc/12","name":"Saved.pdf"}',
    ]);
    final items = await PhoneStarRepository.list();
    expect(items, hasLength(1));
    expect(items.single['name'], 'Saved.pdf');
  });
}
