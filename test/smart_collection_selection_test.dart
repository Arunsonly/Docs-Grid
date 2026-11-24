import 'package:docs_grid/features/documents/data/smart_collection_selection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE documents (id TEXT, name TEXT, size_bytes INTEGER, is_favorite INTEGER, storage_uri TEXT, last_opened_at TEXT, category_id TEXT, deleted_at TEXT)');
    await db.execute('CREATE TABLE document_tags (document_id TEXT, tag_id TEXT)');
    for (final id in ['a','b','c','trash']) {
      await db.insert('documents', {'id': id, 'name': 'PDF '+id,
        'category_id': id == 'c' ? 'other' : 'insurance',
        'deleted_at': id == 'trash' ? 'deleted' : null});
      await db.insert('document_tags', {'document_id': id, 'tag_id': 'pending'});
    }
  });
  tearDown(() => db.close());
  Future<void> check(Map<String,Object?> row, List<String> expected) async {
    final filter = SmartCollectionSelection(row);
    expect(await filter.count(db), expected.length);
    expect((await filter.results(db)).map((r) => r['id']), unorderedEquals(expected));
  }
  test('auto, manual and hybrid stay distinct; trash is never included', () async {
    final rule = {'category_id':'insurance','tag_ids_json':'["pending"]'};
    await check(rule, ['a','b']);
    await check({...rule,'selection_mode':'manual','included_ids_json':'["a","trash"]'}, ['a']);
    final hybrid = {...rule,'selection_mode':'hybrid','included_ids_json':'["c"]','excluded_ids_json':'["b"]'};
    await check(hybrid, ['a','c']);
    await db.insert('documents', {'id':'new','name':'Unrelated name','category_id':'insurance'});
    await db.insert('document_tags', {'document_id':'new','tag_id':'pending'});
    await check(hybrid, ['a','c','new']);
    await db.update('documents', {'name':'Renamed'}, where:'id = ?', whereArgs:['a']);
    await check({...rule,'selection_mode':'manual','included_ids_json':'["a"]'}, ['a']);
  });
  test('backup remaps saved IDs', () {
    final mapped = SmartCollectionSelection.remap({
      'category_id':'oldc','tag_ids_json':'["oldt"]',
      'included_ids_json':'["old"]','excluded_ids_json':'["skip"]',
    }, documentIds:{'old':'new','skip':'newskip'},categoryIds:{'oldc':'c'},tagIds:{'oldt':'t'});
    expect(mapped['category_id'],'c');
    expect(SmartCollectionSelection.ids(mapped['tag_ids_json']), {'t'});
    expect(SmartCollectionSelection.ids(mapped['included_ids_json']), {'new'});
    expect(SmartCollectionSelection.ids(mapped['excluded_ids_json']), {'newskip'});
  });
}
