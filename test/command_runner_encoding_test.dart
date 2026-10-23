import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/desktop/command_runner.dart';

void main() {
  test('Windows command output preserves Chinese text', () async {
    if (!Platform.isWindows) return;
    final result = await runWorkspaceCommand(
      "Write-Output '中文输出正常'",
      Directory.current.path,
      const Duration(seconds: 15),
      CancelToken(),
    );
    expect(result, contains('中文输出正常'));
    expect(result, contains('退出码：0'));
  });
}
