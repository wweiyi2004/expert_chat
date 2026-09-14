import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'backup_codec.dart';

class BackupFile {
  Future<String?> save(Uint8List bytes) async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final path = await FilePicker.saveFile(
      dialogTitle: '导出完整备份',
      fileName: 'ExpertChat-${DateTime.now().millisecondsSinceEpoch}.ecbackup',
      type: FileType.custom,
      allowedExtensions: const ['ecbackup'],
      bytes: mobile ? bytes : null,
    );
    if (path == null) return null;
    if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<Uint8List?> pick() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择完整备份',
      type: FileType.custom,
      allowedExtensions: const ['ecbackup'],
      withData: false,
      withReadStream: true,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    if (file.size > BackupCodec.maxBytes) {
      throw const FormatException('备份不能超过 128 MB。');
    }
    final stream =
        file.readStream ??
        (file.path == null ? null : File(file.path!).openRead());
    if (stream == null) throw const FormatException('无法读取所选备份。');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > BackupCodec.maxBytes) {
        throw const FormatException('备份不能超过 128 MB。');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
