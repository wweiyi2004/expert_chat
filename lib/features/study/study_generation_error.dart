import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/study/structured_output.dart';

Future<void> showStudyGenerationError(
  BuildContext context, {
  required String title,
  required Object error,
}) async {
  if (error is! StudyStructuredOutputException) {
    AppToastMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title，请重试。'),
        action: SnackBarAction(
          label: '查看详情',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(child: SelectableText('$error')),
              actions: [
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: '$error')),
                  child: const Text('复制详情'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error.toString()),
              if (error.rawOutput.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('查看详情'),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('模型返回的内容'),
                    const SizedBox(height: 6),
                    SelectableText(error.rawOutput.trim()),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: error.rawOutput.trim()),
                      ),
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('复制内容'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
