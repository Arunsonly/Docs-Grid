import 'dart:convert';
import 'package:sqflite/sqflite.dart';

/// Existing same-name labels win. No rename or reassignment during upgrade.
class DocumentDefaults {
  static const categories = {
    'identity':'Identity', 'insurance':'Insurance', 'finance':'Finance',
    'medical':'Medical', 'property':'Property', 'vehicle':'Vehicle',
    'education':'Education', 'other':'Other',
    'builtin-category-business':'Business', 'builtin-category-government':'Government',
    'builtin-category-employment':'Employment', 'builtin-category-bills-receipts':'Bills & Receipts',
  };
  static const tagGroups = <String,List<String>>{
    'Priority':['Important','Urgent','Confidential'],
    'Work Status':['Pending','Completed','Under Review'],
    'Document Status':['Verified','Original','Duplicate','Expired'],
    'Usage':['Personal','Official','Renewal'],
  };
  static String tagId(String name) => 'builtin-tag-' + name.toLowerCase().replaceAll(' ', '-');
  static bool isDefaultTagId(String id) =>
    tagGroups.values.expand((names) => names).any((name) => tagId(name) == id);

  static Future<void> seed(DatabaseExecutor db) async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final entry in categories.entries) {
      await db.insert('categories', {'id':entry.key,'name':entry.value,'is_builtin':1,'created_at':now},
        conflictAlgorithm:ConflictAlgorithm.ignore);
    }
    for (final name in tagGroups.values.expand((names) => names)) {
      await db.insert('tags', {'id':tagId(name),'name':name,'created_at':now},
        conflictAlgorithm:ConflictAlgorithm.ignore);
    }
  }

  static const collectionTags = {
    'Important Documents':'Important','Pending Work':'Pending','Urgent Documents':'Urgent',
    'Completed Work':'Completed','Renewal Documents':'Renewal','Confidential Documents':'Confidential',
  };
  static const hiddenKey = 'hidden_builtin_smart_collections_v1';

  // Virtual definitions are not stored as user-created collections.
  static List<Map<String,Object?>> collections(List<Map<String,Object?>> tags) {
    final byName = {for (final tag in tags) (tag['name'] as String).toLowerCase():tag['id'] as String};
    return [
      for (final entry in collectionTags.entries)
        {'id':'builtin-collection-'+tagId(entry.value),'name':entry.key,'built_in':true,
         'rule_label':'Tag: '+entry.value,
         'tag_ids_json':jsonEncode([byName[entry.value.toLowerCase()] ?? tagId(entry.value)])},
      {'id':'builtin-collection-uncategorised','name':'Uncategorised Documents',
        'built_in':true,'rule_label':'No category assigned','missing_category':true},
      {'id':'builtin-collection-untagged','name':'Untagged Documents',
        'built_in':true,'rule_label':'No tags assigned','missing_tags':true},
    ];
  }
}
