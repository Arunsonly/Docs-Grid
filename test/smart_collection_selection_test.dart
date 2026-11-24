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
  test('all collections automatically match category and tags, including older rows', () async {
    final rule = {'category_id':'insurance','tag_ids_json':'["pending"]'};
    await check(rule, ['a','b']);
    await check({...rule,'selection_mode':'manual','included_ids_json':'["a","trash"]',
      'query_text':'not a matching name','favorites_only':1,'recent_only':1}, ['a','b']);
    final oldHybrid = {...rule,'selection_mode':'hybrid','included_ids_json':'["c"]','excluded_ids_json':'["b"]'};
    await check(oldHybrid, ['a','b']);
    await db.insert('documents', {'id':'new','name':'Unrelated name','category_id':'insurance'});
    await db.insert('document_tags', {'document_id':'new','tag_id':'pending'});
    await check(oldHybrid, ['a','b','new']);
    await db.update('documents', {'name':'Renamed'}, where:'id = ?', whereArgs:['a']);
    await check(rule, ['a','b','new']);
    await db.delete('document_tags', where:'document_id = ?', whereArgs:['a']);
    await check(rule, ['b','new']);
    await check({}, ['a','b','c','new']);
  });
  test('explicit new name and chosen PDF rules, automatic additions and trash exclusion', () async {
    final rule = {'selection_mode':'auto_v2','query_text':'PDF a','category_id':'insurance'};
    await check(rule, ['a']);
    await check({...rule,'query_text':'PDF _'}, []);
    await check({...rule,'selection_mode':'manual_v2','included_ids_json':'["b","trash"]'}, ['b']);
    final hybrid = {'selection_mode':'hybrid_v2','query_text':'PDF','category_id':'insurance',
      'included_ids_json':'["c"]','excluded_ids_json':'["b","trash"]'};
    await check(hybrid, ['a','c']);
    await db.insert('documents', {'id':'next','name':'PDF new','category_id':'insurance'});
    await check(hybrid, ['a','c','next']);
    await db.update('documents', {'name':'Renamed'},where:'id = ?',whereArgs:['c']);
    await check(hybrid, ['a','c','next']);
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
