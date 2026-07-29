import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'memory_transfer.dart';

/// Native implementation. Phones use the system share sheet; desktop uses a
/// save dialog. Import remains a normal file picker on every native platform.
class MemoryBackupFileService {
  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<String?> exportMarkdown({
    required String markdown,
    required String fileName,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(markdown));
    if (_isMobile) {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile(file.path, mimeType: 'text/markdown', name: fileName),
            ],
            subject: 'Expert Chat 长期记忆备份',
          ),
        );
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      return fileName;
    }

    final path = await FilePicker.saveFile(
      dialogTitle: '导出记忆备份',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['md'],
    );
    if (path == null) return null;
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
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
    if (bytes != null) return _decode(bytes);
    final path = file.path;
    if (path == null || path.isEmpty) {
      throw const MemoryImportFormatException('无法读取所选文件。');
    }
    final nativeFile = File(path);
    if (await nativeFile.length() > MemoryTransferService.maxBackupBytes) {
      throw const MemoryImportFormatException('记忆备份不能超过 2 MB。');
    }
    return _decode(await nativeFile.readAsBytes());
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const MemoryImportFormatException('记忆备份不是有效的 UTF-8 文本。');
    }
  }
}
