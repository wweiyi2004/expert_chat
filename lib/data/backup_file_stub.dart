import 'dart:typed_data';

class BackupFile {
  Future<String?> save(Uint8List bytes) async =>
      throw UnsupportedError('请使用桌面或移动应用备份。');
  Future<Uint8List?> pick() async => throw UnsupportedError('请使用桌面或移动应用恢复。');
}
