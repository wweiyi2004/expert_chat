import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../data/settings_bundle.dart';

/// Native save / pick. Desktop writes the chosen path; phones use picker bytes.
class SettingsBundleFileService {
  Future<String?> exportJson({
    required String json,
    String fileName = SettingsBundle.fileName,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(json));
    final isNativeMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final path = await FilePicker.saveFile(
      dialogTitle: '导出 API 配置',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: isNativeMobile ? bytes : null,
    );
    if (path == null) return null;
    final withExtension = path.toLowerCase().endsWith('.json')
        ? path
        : '$path.json';
    if (!isNativeMobile) {
      await File(withExtension).writeAsBytes(bytes, flush: true);
    }
    return withExtension;
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
    if (bytes != null) return SettingsBundle.decodeUtf8(bytes);
    final path = file.path;
    if (path == null || path.isEmpty) {
      throw const SettingsBundleException('无法读取所选文件。');
    }
    final nativeFile = File(path);
    if (await nativeFile.length() > SettingsBundle.maxBytes) {
      throw const SettingsBundleException('配置文件不能超过 1 MB。');
    }
    return SettingsBundle.decodeUtf8(await nativeFile.readAsBytes());
  }
}
