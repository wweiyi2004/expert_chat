import 'package:flutter/material.dart';

import 'shorebird_patch.dart';

/// Manual Shorebird patch check from Settings.
Future<void> checkShorebirdPatchInteractive(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final check = ShorebirdPatchService().check(download: true);
  final result = await showDialog<ShorebirdPatchResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => FutureBuilder<ShorebirdPatchResult>(
      future: check,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        final value =
            snapshot.data ??
            (snapshot.hasError
                ? ShorebirdPatchResult(
                    available: false,
                    failed: true,
                    message: 'Shorebird 检查失败：${snapshot.error}',
                  )
                : null);
        return PopScope(
          canPop: !waiting,
          child: waiting
              ? const AlertDialog(
                  content: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      SizedBox(width: 16),
                      Expanded(child: Text('正在检查并下载代码补丁…')),
                    ],
                  ),
                )
              : AlertDialog(
                  icon: Icon(
                    value!.failed
                        ? Icons.error_outline
                        : value.restartRequired
                        ? Icons.system_security_update_good
                        : value.available
                        ? Icons.system_update
                        : value.unsupported
                        ? Icons.info_outline
                        : Icons.verified_outlined,
                  ),
                  title: Text(
                    value.failed
                        ? '补丁检查失败'
                        : value.restartRequired
                        ? '补丁已就绪'
                        : value.available
                        ? '发现补丁'
                        : value.unsupported
                        ? '未启用代码热更'
                        : '已是最新',
                  ),
                  content: Text(value.message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(value),
                      child: const Text('好的'),
                    ),
                  ],
                ),
        );
      },
    ),
  );

  if (result?.restartRequired == true && messenger != null) {
    messenger.showSnackBar(const SnackBar(content: Text('请完全退出应用后重新打开以应用补丁')));
  }
}
