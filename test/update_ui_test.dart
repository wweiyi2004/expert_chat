import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/app_update.dart';
import 'package:expert_chat/domain/update/update_downloader.dart';
import 'package:expert_chat/domain/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resumePendingApkInstall', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('expert_chat/install');

    test('does not install when the cached APK file was evicted', () async {
      final installs = <String>[];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'canRequestPackageInstalls') return true;
        if (call.method == 'installApk') {
          installs.add((call.arguments as Map)['path'] as String);
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      // 缓存被系统清理:文件已不存在。
      final missing = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}evicted-update.apk',
      );
      expect(missing.existsSync(), isFalse);
      pendingInstallApkPathForTest = missing.path;

      await resumePendingApkInstall();

      expect(installs, isEmpty);
      expect(pendingInstallApkPathForTest, isNull);
    });

    test('clears the pending path after an install failure', () async {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'canRequestPackageInstalls') return true;
        if (call.method == 'installApk') {
          throw PlatformException(code: 'install_failed');
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final apk = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}broken-update.apk',
      );
      await apk.writeAsBytes([1, 2, 3]);
      addTearDown(() {
        try {
          apk.deleteSync();
        } catch (_) {}
      });
      pendingInstallApkPathForTest = apk.path;

      await resumePendingApkInstall();

      // 安装永久失败:清除 pending,下次回前台不再重试。
      expect(pendingInstallApkPathForTest, isNull);
    });

    test('keeps the pending path while permission is not granted', () async {
      var allowed = false;
      final installs = <String>[];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'canRequestPackageInstalls') return allowed;
        if (call.method == 'installApk') {
          installs.add((call.arguments as Map)['path'] as String);
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final apk = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}pending-update.apk',
      );
      await apk.writeAsBytes([1, 2, 3]);
      addTearDown(() {
        try {
          apk.deleteSync();
        } catch (_) {}
      });
      pendingInstallApkPathForTest = apk.path;

      // 用户尚未授权:保留路径,等待授权后继续。
      await resumePendingApkInstall();
      expect(pendingInstallApkPathForTest, apk.path);
      expect(installs, isEmpty);

      // 授权后回前台:自动继续安装。
      allowed = true;
      await resumePendingApkInstall();
      expect(installs, [apk.path]);
    });
  });

  testWidgets('cancel does not pop the route below the progress dialog', (
    tester,
  ) async {
    final downloader = _CancelOnDemandDownloader();
    final result = _updateResult();

    await tester.pumpWidget(_testApp(onDownload: (ctx) {
      downloadAndApplyUpdate(ctx, result, downloader: downloader);
    }));

    // 下层页面(模拟设置页)在导航栈上。
    await tester.tap(find.text('进入设置'));
    await tester.pumpAndSettle();
    expect(find.text('下载更新'), findsOneWidget);

    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // dialog 动画
    expect(find.text('正在下载更新'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 取消提示可见。
    expect(find.text('已取消下载'), findsOneWidget);
    // 进度对话框已关闭。
    expect(find.text('正在下载更新'), findsNothing);
    // 下层页面未被误关。
    expect(find.text('下载更新'), findsOneWidget);
  });

  testWidgets('non-cancel download error still closes the progress dialog', (
    tester,
  ) async {
    final downloader = _FailingDownloader(
      DioException(
        requestOptions: RequestOptions(path: 'https://example/update.apk'),
        type: DioExceptionType.connectionTimeout,
        error: 'timeout',
      ),
    );
    final result = _updateResult();

    await tester.pumpWidget(_testApp(onDownload: (ctx) {
      downloadAndApplyUpdate(ctx, result, downloader: downloader);
    }));

    await tester.tap(find.text('进入设置'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 失败时进度对话框被关闭,错误提示可见。
    expect(find.text('正在下载更新'), findsNothing);
    expect(find.textContaining('下载失败'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
  });
}

UpdateCheckResult _updateResult() {
  return const UpdateCheckResult(
    currentVersion: '2.0.0',
    latestVersion: '2.1.0',
    hasUpdate: true,
    releaseUrl: 'https://github.com/wweiyi2004/expert_chat/releases',
    releaseNotes: '',
    downloadUrl: 'https://example/update.apk',
    assetName: 'expert-chat-v2.1.0.apk',
  );
}

Widget _testApp({required void Function(BuildContext) onDownload}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Center(
                    child: Builder(
                      builder: (ctx) => ElevatedButton(
                        onPressed: () => onDownload(ctx),
                        child: const Text('下载更新'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('进入设置'),
          ),
        ),
      ),
    ),
  );
}

/// Mimics dio: blocks until the token is cancelled, then throws the same
/// DioException a cancelled request would produce.
class _CancelOnDemandDownloader implements UpdateDownloader {
  @override
  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return cancelToken!.whenCancel.then((_) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.cancel,
        error: cancelToken.cancelError,
      );
    });
  }
}

class _FailingDownloader implements UpdateDownloader {
  _FailingDownloader(this.error);

  final DioException error;

  @override
  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    throw error;
  }
}
