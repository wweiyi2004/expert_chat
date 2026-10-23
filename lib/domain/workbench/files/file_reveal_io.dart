import 'dart:io';

Future<void> revealWorkFile(String path) async {
  if (!await File(path).exists()) throw StateError('文件已移动或删除');
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [File(path).parent.path]);
  } else {
    throw UnsupportedError('请在文件所在电脑上打开目录');
  }
}
