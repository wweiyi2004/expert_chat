import 'package:flutter/material.dart';

import '../../domain/study/structured_output.dart';

Future<void> showStudyGenerationError(
  BuildContext context, {
  required String title,
  required Object error,
}) async {
  if (error is! StudyStructuredOutputException) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$title：$error')));
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
                const Text('模型原始输出：'),
                const SizedBox(height: 6),
                SelectableText(error.rawOutput.trim()),
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
