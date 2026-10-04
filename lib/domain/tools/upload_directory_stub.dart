import 'dart:typed_data';

import 'upload_directory_models.dart';

bool get uploadDirectorySupported => false;

Future<UploadDirectory?> restoreUploadDirectory() async => null;

Future<UploadDirectory?> chooseUploadDirectory() async => null;

Future<UploadDirectory> listUploadDirectory({
  required String root,
  required String uri,
}) => Future.error(UnsupportedError('当前平台不支持目录浏览'));

Future<Uint8List?> readUploadDirectoryFile({
  required String root,
  required UploadDirectoryEntry entry,
}) => Future.error(UnsupportedError('当前平台不支持目录浏览'));
