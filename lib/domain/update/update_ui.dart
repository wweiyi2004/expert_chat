import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update.dart';
import 'install_apk.dart';
import 'update_downloader.dart';
import 'update_prefs.dart';

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<UpdatePrefs> _prefs() async {
  final sp = await SharedPreferences.getInstance();
  return UpdatePrefs(sp);
}

/// Manual check from Settings — always shows a result dialog.
Future<void> checkForUpdatesInteractive(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Expanded(child: Text('正在检查更新…')),
        ],
      ),
    ),
  );

  try {
    final result = await AppUpdateChecker().check();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // loading
    await showUpdateResultDialog(context, result, manual: true);
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger?.showSnackBar(SnackBar(content: Text('检查更新失败：$e')));
  }
}

/// Silent startup check — only prompts when a newer release exists (and not skipped).
Future<void> checkForUpdatesOnLaunch(BuildContext context) async {
  try {
    final result = await AppUpdateChecker().check();
    if (!context.mounted || !result.hasUpdate) return;
    final prefs = await _prefs();
    if (!prefs.shouldPrompt(result.latestVersion)) return;
    if (!context.mounted) return;
    await showUpdateResultDialog(context, result, manual: false);
  } catch (_) {
    // Startup check is best-effort; network errors are silent.
  }
}

Future<void> showUpdateResultDialog(
  BuildContext context,
  UpdateCheckResult result, {
  required bool manual,
}) {
  final notes = result.releaseNotes.trim();
  final shortNotes = notes.length > 600 ? '${notes.substring(0, 600)}…' : notes;
  final canInApp = !kIsWeb &&
      result.downloadUrl != null &&
      result.downloadUrl!.isNotEmpty &&
      ((defaultTargetPlatform == TargetPlatform.android && result.isAndroidApk) ||
          (defaultTargetPlatform == TargetPlatform.windows &&
              (result.isWindowsZip || result.downloadUrl != null)));

  return showDialog<void>(
    context: context,
    builder: (ctx) {
      if (!result.hasUpdate) {
        return AlertDialog(
          icon: const Icon(Icons.verified_outlined),
          title: const Text('已是最新版本'),
          content: Text('当前版本 v${result.currentVersion}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好的'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _open(kGithubReleasesPage);
              },
              child: const Text('打开发布页'),
            ),
          ],
        );
      }

      return AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前 v${result.currentVersion}  →  最新 v${result.latestVersion}',
              ),
              if (result.assetName != null) ...[
                const SizedBox(height: 6),
                Text(
                  '安装包：${result.assetName}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
              if (shortNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(shortNotes, style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (!manual) {
                final prefs = await _prefs();
                await prefs.skipVersion(result.latestVersion);
              }
            },
            child: Text(manual ? '稍后' : '跳过此版本'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _open(result.releaseUrl);
            },
            child: const Text('查看说明'),
          ),
          if (canInApp)
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                downloadAndApplyUpdate(context, result);
              },
              child: Text(
                defaultTargetPlatform == TargetPlatform.android
                    ? '下载并安装'
                    : '下载到本地',
              ),
            )
          else
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _open(result.downloadUrl ?? result.releaseUrl);
              },
              child: const Text('浏览器下载'),
            ),
        ],
      );
    },
  );
}

/// Download the package in-app with a progress dialog, then install / reveal.
Future<void> downloadAndApplyUpdate(
  BuildContext context,
  UpdateCheckResult result,
) async {
  final url = result.downloadUrl;
  if (url == null || url.isEmpty) {
    await _open(result.releaseUrl);
    return;
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  final cancelToken = CancelToken();
  final progress = ValueNotifier<double?>(0);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, value, _) {
            final known = value != null && value >= 0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: known ? value : null),
                const SizedBox(height: 12),
                Text(
                  known
                      ? '已下载 ${(value * 100).clamp(0, 100).toStringAsFixed(0)}%'
                      : '连接中…',
                ),
                if (result.assetName != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    result.assetName!,
                    style: Theme.of(ctx).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelToken.cancel('用户取消');
              Navigator.of(ctx).pop();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );

  try {
    final path = await UpdateDownloader().download(
      url: url,
      fileName: result.assetName,
      cancelToken: cancelToken,
      onProgress: (received, total) {
        if (total > 0) {
          progress.value = received / total;
        } else {
          progress.value = null;
        }
      },
    );
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // progress

    if (defaultTargetPlatform == TargetPlatform.android &&
        path.toLowerCase().endsWith('.apk')) {
      await _installAndroidApk(context, path, messenger);
      return;
    }

    // Desktop: open the containing folder / file location.
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        if (Platform.isWindows) {
          await Process.run('explorer.exe', ['/select,', path]);
        } else if (Platform.isMacOS) {
          await Process.run('open', ['-R', path]);
        } else {
          await Process.run('xdg-open', [File(path).parent.path]);
        }
      } catch (_) {
        // Fall through to snackbar with path.
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已下载到：$path'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    messenger?.showSnackBar(
      SnackBar(content: Text('已下载：$path'), behavior: SnackBarBehavior.floating),
    );
  } on DioException catch (e) {
    if (!context.mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (CancelToken.isCancel(e)) {
      messenger?.showSnackBar(const SnackBar(content: Text('已取消下载')));
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text('下载失败：$e'),
        action: SnackBarAction(
          label: '浏览器',
          onPressed: () => _open(url),
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text('下载失败：$e'),
        action: SnackBarAction(
          label: '浏览器',
          onPressed: () => _open(url),
        ),
      ),
    );
  } finally {
    progress.dispose();
  }
}

Future<void> _installAndroidApk(
  BuildContext context,
  String path,
  ScaffoldMessengerState? messenger,
) async {
  try {
    final allowed = await InstallApk.canRequestPackageInstalls();
    if (!allowed) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要安装权限'),
          content: const Text(
            '系统禁止未知来源安装。请允许 Expert Chat 安装应用，然后再次点击安装。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true) {
        await InstallApk.openUnknownAppSourcesSettings();
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('授权后请回到设置 → 检查整包更新，或重新下载安装'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    await InstallApk.install(path);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('无法打开安装程序：$e'),
        action: SnackBarAction(
          label: '浏览器下载',
          onPressed: () => _open(kGithubReleasesPage),
        ),
      ),
    );
  }
}
