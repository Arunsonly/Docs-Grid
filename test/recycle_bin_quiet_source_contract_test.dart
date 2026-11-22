import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful Grid folder move and recycle do not show blocking snackbars', () {
    final grid = File('lib/features/folders/presentation/folders_screen.dart')
        .readAsStringSync();

    expect(grid, isNot(contains("Moved ${selected.length} folder(s) and "
        "\$pdfCount PDF(s) to Recycle Bin.")));
    expect(grid, isNot(contains("_message('Moved ${selected.length} folder(s).')")));
    expect(grid, contains("if (mounted) _message('Could not delete folders: \$error')"));
    expect(grid, contains("if (mounted) _message('Could not move folders: \$error')"));
  });

  test('Recycle Bin selection uses only existing safe repository actions', () {
    final dialog = File('lib/features/documents/presentation/recycle_bin_dialog.dart')
        .readAsStringSync();
    final home = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();

    expect(dialog, contains("onLongPress: _busy || _selecting ? null"));
    expect(dialog, contains("key: const ValueKey('recycle-select-all')"));
    expect(dialog, contains("key: const ValueKey('recycle-delete-selected')"));
    expect(dialog, contains('canPop: !_selecting && !_busy'));
    expect(dialog, contains('if (!didPop && _selecting && !_busy) _clearSelection()'));
    expect(home, contains("deleteFolder: _folderRepository.permanentlyDeleteTrashFolderTree"));
    expect(home, contains("deletePdf: _repository.permanentlyDelete"));
    expect(home, contains("restorePdf: _repository.restoreFromTrash"));
  });
}
