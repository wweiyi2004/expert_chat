import 'dart:io';

Future<void> revealWorkFile(String path) async {
  final kind = await FileSystemEntity.type(path, followLinks: false);
  if (kind != FileSystemEntityType.file &&
      kind != FileSystemEntityType.directory) {
    throw StateError('成果已移动、删除或变为链接');
  }
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [
      kind == FileSystemEntityType.directory ? path : File(path).parent.path,
    ]);
  } else {
    throw UnsupportedError('请在文件所在电脑上打开目录');
  }
}
