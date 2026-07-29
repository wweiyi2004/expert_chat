import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'memory_transfer.dart';

/// Browser implementation: export starts a download; import reads picker bytes.
class MemoryBackupFileService {
  Future<String?> exportMarkdown({
    required String markdown,
    required String fileName,
  }) async {
    await FilePicker.saveFile(
      dialogTitle: '导出记忆备份',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['md'],
      bytes: Uint8List.fromList(utf8.encode(markdown)),
    );
    return fileName;
  }

  Future<String?> pickMarkdown() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '导入记忆备份',
      type: FileType.custom,
      allowedExtensions: const ['md'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.size > MemoryTransferService.maxBackupBytes) {
      throw const MemoryImportFormatException('记忆备份不能超过 2 MB。');
    }
    final bytes = file.bytes;
    if (bytes == null) {
      throw const MemoryImportFormatException('无法读取所选文件。');
    }
    return _decode(bytes);
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const MemoryImportFormatException('记忆备份不是有效的 UTF-8 文本。');
    }
  }
}
