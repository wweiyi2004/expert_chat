import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../platform/preferences.dart';

import 'file_parser.dart';
import 'upload_directory_models.dart';

const _channel = MethodChannel('expert_chat/upload_directory');
const _savedRoot = 'attachment_upload_directory';
const _maxReadBytes = 10 * 1024 * 1024;

bool get uploadDirectorySupported => true;

UploadDirectory _fromNative(Map<dynamic, dynamic> raw) => UploadDirectory(
  root: raw['root'] as String,
  uri: raw['uri'] as String,
  name: raw['name'] as String,
  entries: sortUploadDirectoryEntries([
    for (final item in raw['entries'] as List)
      UploadDirectoryEntry(
        uri: item['uri'] as String,
        name: item['name'] as String,
        isDirectory: item['isDirectory'] == true,
        sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(
          (item['modifiedAt'] as num?)?.toInt() ?? 0,
        ),
        mimeType: item['mimeType'] as String? ?? '',
      ),
  ]),
);

Future<UploadDirectory?> restoreUploadDirectory() async {
  if (Platform.isAndroid) {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>('restore');
    return raw == null ? null : _fromNative(raw);
  }
  final prefs = await SharedPreferences.getInstance();
  final root = prefs.getString(_savedRoot);
  if (root == null || root.isEmpty) return null;
  return listUploadDirectory(root: root, uri: root);
}

Future<UploadDirectory?> chooseUploadDirectory() async {
  if (Platform.isAndroid) {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>('choose');
    return raw == null ? null : _fromNative(raw);
  }
  final chosen = await FilePicker.getDirectoryPath(dialogTitle: '选择上传目录');
  if (chosen == null || chosen.isEmpty) return null;
  final root = await Directory(chosen).resolveSymbolicLinks();
  final directory = await listUploadDirectory(root: root, uri: root);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_savedRoot, root);
  return directory;
}

Future<String> _withinRoot(String root, String uri) async {
  final canonicalRoot = await Directory(root).resolveSymbolicLinks();
  final isDirectory = await FileSystemEntity.isDirectory(uri);
  final canonical = await (isDirectory
      ? Directory(uri).resolveSymbolicLinks()
      : File(uri).resolveSymbolicLinks());
  if (canonical != canonicalRoot && !p.isWithin(canonicalRoot, canonical)) {
    throw FileSystemException('文件不在所选目录内');
  }
  return canonical;
}

Future<UploadDirectory> listUploadDirectory({
  required String root,
  required String uri,
}) async {
  if (Platform.isAndroid) {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>('list', {
      'root': root,
      'uri': uri,
    });
    if (raw == null) throw const FileSystemException('无法读取所选目录');
    return _fromNative(raw);
  }
  final directory = await _withinRoot(root, uri);
  final entries = <UploadDirectoryEntry>[];
  await for (final item in Directory(directory).list(followLinks: false)) {
    // Links are never followed into directories outside the user's selection.
    if (item is! File && item is! Directory) continue;
    final stat = await item.stat();
    entries.add(
      UploadDirectoryEntry(
        uri: item.path,
        name: p.basename(item.path),
        isDirectory: item is Directory,
        sizeBytes: item is File ? stat.size : 0,
        modifiedAt: stat.modified,
      ),
    );
  }
  return UploadDirectory(
    root: root,
    uri: directory,
    name: p.basename(directory),
    entries: sortUploadDirectoryEntries(entries),
  );
}

Future<Uint8List?> readUploadDirectoryFile({
  required String root,
  required UploadDirectoryEntry entry,
}) async {
  if (entry.isDirectory) throw const FileSystemException('请选择文件');
  if (entry.sizeBytes > _maxReadBytes) {
    throw const FileReadLimitExceeded(_maxReadBytes);
  }
  if (Platform.isAndroid) {
    return _channel.invokeMethod<Uint8List>('read', {
      'root': root,
      'uri': entry.uri,
    });
  }
  final path = await _withinRoot(root, entry.uri);
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File(path).openRead()) {
    if (bytes.length + chunk.length > _maxReadBytes) {
      throw const FileReadLimitExceeded(_maxReadBytes);
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
