import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../database/app_database.dart';
import 'storage_location_service.dart';

/// Only application-owned regeneratable files may be cleared. Never walk a
/// user-selected portable root for deletion, or remove a whole cache/temp tree.
class StorageInformationScreen extends StatefulWidget {
  const StorageInformationScreen({super.key});
  @override
  State<StorageInformationScreen> createState() => _StorageInformationScreenState();
}

class _StorageInformationScreenState extends State<StorageInformationScreen> {
  Map<String,Object?>? _data;
  bool _loading = true;
  bool _clearing = false;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<List<Directory>> _previewDirectories() async {
    final support = await getApplicationSupportDirectory();
    return [
      Directory(p.join(support.path,'docsgrid','Cache','Thumbnails')),
      Directory(p.join(support.path,'docsgrid','thumbnails')),
      Directory(p.join(support.path,'docsgrid_folder_previews_v1')),
    ];
  }

  Future<List<File>> _safePreviews() async {
    final support = await getApplicationSupportDirectory();
    final root = await support.resolveSymbolicLinks();
    final result = <File>[];
    for(final dir in await _previewDirectories()) {
      if (!await dir.exists()) continue;
      final actual = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root,actual) || actual != p.join(root,p.relative(dir.path,from:support.path))) continue;
      await for(final entry in dir.list(followLinks:false)) {
        if(entry is! File) continue;
        final extension = p.extension(entry.path).toLowerCase();
        if (extension == '.png' || (extension == '.json' && p.basename(dir.path)=='docsgrid_folder_previews_v1')) {
          result.add(entry);
        }
      }
    }
    return result;
  }

  Future<int> _previewBytes() async {
    var total=0;
    for(final file in await _safePreviews()) {
      try { total += await file.length(); } on FileSystemException { /* regenerated concurrently */ }
    }
    return total;
  }

  Future<({int bytes,int zipFiles})?> _portableBytes(List<String?> roots) async {
    if (roots.whereType<String>().isEmpty) return null;
    final storage=StorageLocationService.instance;
    final visited=<String>{};
    final pending=roots.whereType<String>().toList();
    var bytes=0, zipFiles=0, entries=0;
    while(pending.isNotEmpty) {
      final uri=pending.removeLast();
      if(!visited.add(uri)) continue;
      final children=await storage.listDirectory(uri).timeout(const Duration(seconds:5));
      for(final entry in children) {
        if (++entries>100000) return null;
        final child=entry['uri'] as String;
        if(entry['isDirectory']==true) {
          pending.add(child);
        } else if(visited.add(child)) {
          final size=entry['size'];
          if(size is! num || size<0) return null;
          bytes+=size.toInt();
          if((entry['name'] as String).toLowerCase().endsWith('.zip')) zipFiles++;
        }
      }
    }
    return (bytes:bytes,zipFiles:zipFiles);
  }

  Future<void> _load() async {
    if(!mounted) return;
    setState(() { _loading=true; _error=null; });
    try {
      final db=await AppDatabase.instance.database;
      final docs=(await db.rawQuery('SELECT COUNT(*) AS n, COALESCE(SUM(size_bytes),0) AS bytes FROM documents WHERE deleted_at IS NULL')).single;
      final folders=(await db.rawQuery('SELECT COUNT(*) AS n FROM folders WHERE deleted_at IS NULL')).single;
      final cache=await _previewBytes();
      var database=0;
      for(final suffix in ['', '-wal','-shm']) {
        final f=File(db.path+suffix);
        if(await f.exists()) database+=await f.length();
      }
      int? free;
      try {
        free=await const MethodChannel('docsgrid/storage').invokeMethod<int>('getFreeStorageBytes');
      } catch (_) {}
      final locations=Platform.isIOS
          ? await StorageLocationService.iosPrivateArchiveLocations()
          : await StorageLocationService.instance.portableDataLocationsIfAvailable();
      ({int bytes,int zipFiles})? backups;
      try {
        if (Platform.isIOS) {
          var bytes=0, zipFiles=0;
          for (final key in ['backupsUri','recoveryUri']) {
            final uri=locations[key];
            if (uri==null) continue;
            final dir=Directory(Uri.parse(uri).toFilePath());
            if (!await dir.exists()) continue;
            await for (final entry in dir.list(recursive:true,followLinks:false)) {
              if(entry is File) {
                bytes+=await entry.length();
                if(entry.path.toLowerCase().endsWith('.zip')) zipFiles++;
              }
            }
          }
          backups=(bytes:bytes,zipFiles:zipFiles);
        } else {
          backups=await _portableBytes([locations['backupsUri'],locations['databaseUri'],locations['recoveryUri']]).timeout(const Duration(seconds:15));
        }
      } catch (_) {}
      if(!mounted) return;
      setState(() {
        _data={'docs':docs['n'],'pdfBytes':docs['bytes'],'folders':folders['n'],
          'cache':cache,'db':database,'backupBytes':backups?.bytes,'backupCount':backups?.zipFiles,
          'free':free,'root':locations['rootUri']};
        _loading=false;
      });
    } catch(error) {
      if(mounted) setState(() { _error=error.toString(); _loading=false; });
    }
  }

  Future<void> _clearCache() async {
    if(_clearing||_loading) return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Clear preview cache?'),
      content:const Text('Only regeneratable PDF thumbnails and folder previews will be deleted. Original PDFs, backups, database, reminders and other data will remain unchanged.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Clear Cache')),
      ]));
    if(ok!=true||!mounted) return;
    setState(()=>_clearing=true);
    try {
      for(final file in await _safePreviews()) {
        try {
          if(await FileSystemEntity.type(file.path,followLinks:false)==FileSystemEntityType.file) await file.delete();
        } on FileSystemException { /* active previews can be regenerated */ }
      }
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Preview cache cleared.')));
    } catch(error) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Cache could not be fully cleared: $error')));
    } finally {
      if(mounted) {setState(()=>_clearing=false);await _load();}
    }
  }

  String _size(Object? value) {
    if(value is! num) return 'Unavailable';
    if(value>=1073741824) return (value/1073741824).toStringAsFixed(2)+' GB';
    if(value>=1048576) return (value/1048576).toStringAsFixed(1)+' MB';
    if(value>=1024) return (value/1024).toStringAsFixed(1)+' KB';
    return value.toString()+' B';
  }

  @override
  Widget build(BuildContext context) {
    final d=_data;
    return Scaffold(appBar:AppBar(title:const Text('Storage Information'),actions:[
      IconButton(onPressed:_loading||_clearing?null:_load,icon:const Icon(Icons.refresh),tooltip:'Refresh')
    ]),body:_loading?const Center(child:CircularProgressIndicator()):
      _error!=null||d==null?Center(child:TextButton(onPressed:_load,child:const Text('Could not read storage. Retry'))):
      ListView(padding:const EdgeInsets.all(16),children:[
        Text('DOCSGRID STORAGE USAGE',style:Theme.of(context).textTheme.labelLarge),
        if (d['backupBytes'] is num) ...[
          Text(_size((d['pdfBytes'] as num)+(d['backupBytes'] as num)+(d['cache'] as num)+(d['db'] as num)), style:Theme.of(context).textTheme.headlineMedium),
          const Text('Accounted usage (registered PDFs + measured storage)'),
        ],
        Card(child:Column(children:[
          ListTile(leading:const Icon(Icons.picture_as_pdf_outlined),title:const Text('PDF Documents'),subtitle:const Text('Registered active Grid PDFs'),trailing:Text(_size(d['pdfBytes']))),
          const Divider(height:1),
          ListTile(leading:const Icon(Icons.archive_outlined),title:const Text('Backup & Recovery'),trailing:Text(_size(d['backupBytes']))),
          const Divider(height:1),
          ListTile(leading:const Icon(Icons.image_outlined),title:const Text('Cache & Thumbnails'),subtitle:const Text('Clearable preview files'),trailing:Text(_size(d['cache']))),
          const Divider(height:1),
          ListTile(leading:const Icon(Icons.storage_outlined),title:const Text('Database'),trailing:Text(_size(d['db']))),
        ])),
        const SizedBox(height:16),
        Text('LIBRARY INFORMATION',style:Theme.of(context).textTheme.labelLarge),
        Card(child:Column(children:[
          ListTile(title:const Text('Total PDFs'),trailing:Text(d['docs'].toString())),
          ListTile(title:const Text('Total folders'),trailing:Text(d['folders'].toString())),
          ListTile(title:const Text('Backup ZIP files'),trailing:Text(d['backupCount']?.toString()??'Unavailable')),
          ListTile(title:const Text('Free device storage'),trailing:Text(_size(d['free']))),
          ListTile(title:const Text('Storage location'),subtitle:Text(d['root']?.toString()??'App-managed storage')),
        ])),
        const SizedBox(height:16),
        OutlinedButton.icon(onPressed:_clearing||d['cache']==0?null:_clearCache,
          icon:const Icon(Icons.delete_outline),label:const Text('Clear Cache')),
        const Text('Only preview files are cleared. Temporary imports, exports, PDFs, backups and database are not touched. Values describe registered PDFs and measured folders; they are not the total Android/iOS application size.'),
      ]));
  }
}
