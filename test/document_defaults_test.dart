import 'package:docs_grid/core/database/document_defaults.dart';
import 'package:docs_grid/features/documents/data/smart_collection_selection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('default seeding is idempotent, preserves custom names and collections are virtual', () async {
    final db=await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT COLLATE NOCASE UNIQUE, is_builtin INTEGER, created_at TEXT)');
    await db.execute('CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT COLLATE NOCASE UNIQUE, created_at TEXT)');
    await db.execute('CREATE TABLE documents (id TEXT PRIMARY KEY, name TEXT, size_bytes INTEGER, storage_uri TEXT, is_favorite INTEGER, category_id TEXT, deleted_at TEXT)');
    await db.execute('CREATE TABLE document_tags (document_id TEXT, tag_id TEXT)');
    await db.insert('tags', {'id':'existing-pending','name':'Pending','created_at':'old'});
    await db.insert('categories', {'id':'existing-business','name':'Business','is_builtin':0,'created_at':'old'});
    await DocumentDefaults.seed(db);
    await DocumentDefaults.seed(db);
    final tags=await db.query('tags');
    expect(tags,hasLength(13));
    expect(await db.query('categories'),hasLength(12));
    expect((await db.query('categories',where:'id = ?',whereArgs:['existing-business'])).single['is_builtin'],0);
    final views=DocumentDefaults.collections(tags);
    expect(views,hasLength(8));
    await db.insert('documents',{'id':'a','name':'A'});
    await db.insert('documents',{'id':'b','name':'B','category_id':'insurance'});
    await db.insert('documents',{'id':'trash','name':'Trash','deleted_at':'deleted'});
    await db.insert('document_tags',{'document_id':'b','tag_id':'existing-pending'});
    Future<int> count(String name)=>SmartCollectionSelection(views.singleWhere((v)=>v['name']==name)).count(db);
    expect(await count('Pending Work'),1);
    expect(await count('Uncategorised Documents'),1);
    expect(await count('Untagged Documents'),1);
    await db.insert('document_tags',{'document_id':'a','tag_id':'existing-pending'});
    expect(await count('Pending Work'),2);
    expect(await count('Untagged Documents'),0);
  });
}
