import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/documents/data/phone_pdf_move_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('docsgrid/storage');
  late Directory root;
  late Directory downloads;
  late Directory insurance;
  late File phone;
  late bool denyOriginalDelete;
  late bool corruptCopiedFile;
  late bool claimAlias;
  late int sourceDeleteCount;

  String local(String uri) {
    final parsed = Uri.tryParse(uri);
    return parsed?.scheme == 'file' ? parsed!.toFilePath() : uri;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('docsgrid-phone-move-');
    downloads = Directory('${root.path}/Download');
    insurance = Directory('${root.path}/Insurance');
    await downloads.create();
    await insurance.create();
    phone = File('${downloads.path}/Policy.pdf');
    await phone.writeAsString('%PDF-1.7 unique source');
    denyOriginalDelete = false;
    corruptCopiedFile = false;
    claimAlias = false;
    sourceDeleteCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'sha256Pdf':
          return (await sha256.bind(
            File(local(args['uri'] as String)).openRead()).first).toString();
        case 'copyPdf':
          final source = File(local(args['sourceUri'] as String));
          final parent = Directory(local(args['parentUri'] as String));
          final name = args['name'] as String;
          var target = File('${parent.path}/$name');
          var suffix = 0;
          while (await target.exists()) {
            suffix++;
            target = File(
              '${parent.path}/${name.substring(0, name.length - 4)} ($suffix).pdf');
          }
          await source.copy(target.path);
          if (corruptCopiedFile) await target.writeAsString('corrupt data');
          return target.uri.toString();
        case 'samePhysicalPdf':
          return claimAlias ||
              local(args['sourceUri'] as String) ==
                  local(args['otherUri'] as String);
        case 'deletePdf':
          final destination = File(local(args['uri'] as String));
          if (destination.path == phone.path) {
            sourceDeleteCount++;
            if (denyOriginalDelete) return false;
          }
          if (!await destination.exists()) return false;
          await destination.delete();
          return true;
        default:
          throw MissingPluginException('Unexpected storage call ${call.method}');
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('Move copies, hashes, deletes Phone source and leaves independent Grid copy',
      () async {
    final gridCopy = File('${root.path}/GridPolicy.pdf');
    await phone.copy(gridCopy.path);
    final destination = await const PhonePdfMoveService().move(
      sourceUri: phone.uri.toString(),
      displayName: 'Policy.pdf',
      destinationFolderUri: insurance.uri.toString(),
    );
    expect(sourceDeleteCount, 1);
    expect(await phone.exists(), isFalse);
    expect(await File.fromUri(Uri.parse(destination)).readAsString(),
        '%PDF-1.7 unique source');
    expect(await gridCopy.readAsString(), '%PDF-1.7 unique source');
  });

  test('existing destination name is never overwritten', () async {
    final existing = File('${insurance.path}/Policy.pdf');
    await existing.writeAsString('%PDF-1.7 unrelated existing policy');
    final dest = await const PhonePdfMoveService().move(
      sourceUri: phone.uri.toString(),
      displayName: 'Policy.pdf',
      destinationFolderUri: insurance.uri.toString(),
    );
    expect(dest, contains('Policy%20%281%29.pdf'));
    expect(await existing.readAsString(), '%PDF-1.7 unrelated existing policy');
    expect(await File.fromUri(Uri.parse(dest)).readAsString(),
        '%PDF-1.7 unique source');
    expect(await phone.exists(), isFalse);
  });

  test('failed checksum rolls back only newly created target; source is untouched',
      () async {
    corruptCopiedFile = true;
    await expectLater(
      const PhonePdfMoveService().move(
        sourceUri: phone.uri.toString(),
        displayName: 'Policy.pdf',
        destinationFolderUri: insurance.uri.toString(),
      ),
      throwsStateError,
    );
    expect(sourceDeleteCount, 0);
    expect(await phone.readAsString(), '%PDF-1.7 unique source');
    expect(await insurance.list().toList(), isEmpty);
  });

  test('denied source deletion keeps verified destination for data safety',
      () async {
    denyOriginalDelete = true;
    await expectLater(
      const PhonePdfMoveService().move(
        sourceUri: phone.uri.toString(),
        displayName: 'Policy.pdf',
        destinationFolderUri: insurance.uri.toString(),
      ),
      throwsStateError,
    );
    expect(sourceDeleteCount, 1);
    expect(await phone.exists(), isTrue);
    expect(await File('${insurance.path}/Policy.pdf').readAsString(),
        '%PDF-1.7 unique source');
  });

  test('untrusted physical identity never deletes the original', () async {
    claimAlias = true;
    await expectLater(
      const PhonePdfMoveService().move(
        sourceUri: phone.uri.toString(),
        displayName: 'Policy.pdf',
        destinationFolderUri: insurance.uri.toString(),
      ),
      throwsStateError,
    );
    expect(sourceDeleteCount, 0);
    expect(await phone.readAsString(), '%PDF-1.7 unique source');
  });

  test('same-folder moves and DocsGrid-owned destinations are rejected', () async {
    await expectLater(
      const PhonePdfMoveService().move(
        sourceUri: phone.uri.toString(),
        displayName: 'Policy.pdf',
        destinationFolderUri: downloads.uri.toString(),
      ),
      throwsStateError,
    );
    await expectLater(
      const PhonePdfMoveService().move(
        sourceUri: phone.uri.toString(),
        displayName: 'Policy.pdf',
        destinationFolderUri:
            'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files',
      ),
      throwsStateError,
    );
    expect(sourceDeleteCount, 0);
    expect(await phone.exists(), isTrue);
  });
}
