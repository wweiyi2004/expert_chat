import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/story/story_ai_assist.dart';
import '../../state/settings_controller.dart';

/// Small "AI" action chip used next to field labels.
class AiAssistChip extends StatelessWidget {
  const AiAssistChip({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }
}

Future<LlmReady?> requireLlmReady(WidgetRef ref, BuildContext context) async {
  final settings = await ref.read(settingsControllerProvider.future);
  if (!settings.config.isReady) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先在设置中配置 API Key'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return null;
  }
  return LlmReady(
    config: settings.config,
    assist: StoryAiAssist(ref.read(llmProvider)),
  );
}

class LlmReady {
  const LlmReady({required this.config, required this.assist});
  final LlmConfig config;
  final StoryAiAssist assist;
}

/// Dialog: user types a short idea → AI fills the form.
Future<String?> showAiIdeaDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        decoration: InputDecoration(
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('生成'),
        ),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

String humanizeAiError(Object e) {
  if (e is DioException && CancelToken.isCancel(e)) {
    return '已取消';
  }
  return e.toString().replaceFirst('Exception: ', '');
}

Future<void> showAiError(BuildContext context, Object e) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(humanizeAiError(e)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
