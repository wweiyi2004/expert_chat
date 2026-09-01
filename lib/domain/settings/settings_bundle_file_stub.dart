import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../data/settings_bundle.dart';

/// Web: FilePicker downloads / reads bytes; no dart:io.
class SettingsBundleFileService {
  Future<String?> exportJson({
    required String json,
    String fileName = SettingsBundle.fileName,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(json));
    await FilePicker.saveFile(
      dialogTitle: '导出 API 配置',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: bytes,
    );
    return fileName;
  }

  Future<String?> pickJson() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '导入 API 配置',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.size > SettingsBundle.maxBytes) {
      throw const SettingsBundleException('配置文件不能超过 1 MB。');
    }
    final bytes = file.bytes;
    if (bytes == null) {
      throw const SettingsBundleException('无法读取所选文件。');
    }
    return SettingsBundle.decodeUtf8(bytes);
  }
}
