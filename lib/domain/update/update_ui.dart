import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update.dart';

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
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

/// Silent startup check — only prompts when a newer release exists.
Future<void> checkForUpdatesOnLaunch(BuildContext context) async {
  try {
    final result = await AppUpdateChecker().check();
    if (!context.mounted || !result.hasUpdate) return;
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
              if (shortNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(shortNotes, style: Theme.of(ctx).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(manual ? '稍后' : '忽略'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _open(result.releaseUrl);
            },
            child: const Text('查看说明'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _open(result.downloadUrl ?? result.releaseUrl);
            },
            child: const Text('下载更新'),
          ),
        ],
      );
    },
  );
}
