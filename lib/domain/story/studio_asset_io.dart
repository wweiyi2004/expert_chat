import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import '../../data/story_models.dart';
import 'studio_asset_codec.dart';

/// File-picker wrappers around [StudioAssetCodec] for Web and native targets.
class StudioAssetIo {
  StudioAssetIo({StudioAssetCodec? codec})
    : _codec = codec ?? const StudioAssetCodec();

  final StudioAssetCodec _codec;

  static bool get _isNativeMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<String?> exportCharacter(CharacterCard card) async {
    final text = _codec.encodeCharacter(card);
    final safe = _safeFileName(card.name, fallback: 'character');
    return _saveText(dialogTitle: '导出角色卡', fileName: '$safe.json', text: text);
  }

  Future<String?> exportCharacters(List<CharacterCard> cards) async {
    final text = _codec.encodeCharacters(cards);
    return _saveText(
      dialogTitle: '导出角色库',
      fileName: 'characters.json',
      text: text,
    );
  }

  Future<String?> exportWorldInfoEntry(WorldInfoEntry entry) async {
    final text = _codec.encodeWorldInfoEntry(entry);
    final safe = _safeFileName(entry.title, fallback: 'world_info');
    return _saveText(
      dialogTitle: '导出世界书条目',
      fileName: '$safe.json',
      text: text,
    );
  }

  Future<String?> exportWorldInfoEntries(List<WorldInfoEntry> entries) async {
    final text = _codec.encodeWorldInfoEntries(entries);
    return _saveText(
      dialogTitle: '导出世界书',
      fileName: 'world_info.json',
      text: text,
    );
  }

  Future<List<CharacterCard>?> importCharacters() async {
    final raw = await _pickJsonText(dialogTitle: '导入角色卡 JSON');
    if (raw == null) return null;
    final cards = _codec.decodeCharacters(raw);
    if (cards.isEmpty) {
      throw const FormatException('文件中没有可用的角色卡。');
    }
    return cards;
  }

  Future<List<WorldInfoEntry>?> importWorldInfo() async {
    final raw = await _pickJsonText(dialogTitle: '导入世界书 JSON');
    if (raw == null) return null;
    final entries = _codec.decodeWorldInfoEntries(raw);
    if (entries.isEmpty) {
      throw const FormatException('文件中没有可用的世界书条目。');
    }
    return entries;
  }

  Future<String?> _saveText({
    required String dialogTitle,
    required String fileName,
    required String text,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final path = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      // Browser downloads and native mobile both require the picker to write
      // the bytes. Desktop returns a path that we write below.
      bytes: kIsWeb || _isNativeMobile ? bytes : null,
    );
    // file_picker starts the browser download but intentionally returns null
    // on Web because there is no local filesystem path to expose.
    if (kIsWeb) return fileName;
    if (path == null) return null;
    if (!_isNativeMobile) {
      await File(path).writeAsBytes(bytes);
    }
    return path;
  }

  Future<String?> _pickJsonText({required String dialogTitle}) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.bytes != null) {
      return decodeJsonText(file.bytes!);
    }
    final path = file.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('无法读取所选文件。');
    }
    return decodeJsonText(await File(path).readAsBytes());
  }

  /// JSON 导入文本必须为 UTF-8：解码失败时说明原因，而不是笼统的「导入失败」。
  @visibleForTesting
  static String decodeJsonText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('文件不是 UTF-8 编码，请转换为 UTF-8 后重试。');
    }
  }

  String _safeFileName(String name, {required String fallback}) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (cleaned.isEmpty) return fallback;
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }
}
