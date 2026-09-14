import 'package:dio/dio.dart';

import '../../data/models.dart';
import '../llm/llm_provider.dart';

/// Shared prompt rewrite for text-to-image and image-edit requests.
class ImagePromptOptimizer {
  const ImagePromptOptimizer({required this.getProvider});
  final LlmProvider Function() getProvider;

  Future<String> optimize({
    required String userPrompt,
    required LlmConfig config,
    required CancelToken cancelToken,
    required void Function(String reasoning, int thinkingMillis) onReasoning,
  }) async {
    final llm = getProvider();
    final contentBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    final sw = Stopwatch();
    var lastPublishedAt = Duration.zero;
    await for (final chunk in llm.streamChat(
      config: config,
      thinking: true,
      reasoningEffort: ReasoningEffort.low,
      cancelToken: cancelToken,
      messages: [
        const LlmRequestMessage(
          role: MessageRole.system,
          content: systemPrompt,
        ),
        LlmRequestMessage(role: MessageRole.user, content: userPrompt),
      ],
    )) {
      if (cancelToken.isCancelled) break;
      if (chunk.reasoningDelta != null && chunk.reasoningDelta!.isNotEmpty) {
        if (!sw.isRunning) sw.start();
        reasoningBuf.write(chunk.reasoningDelta);
        if (lastPublishedAt == Duration.zero ||
            sw.elapsed - lastPublishedAt >= const Duration(milliseconds: 120)) {
          onReasoning(reasoningBuf.toString(), sw.elapsedMilliseconds);
          lastPublishedAt = sw.elapsed;
        }
      }
      if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
        if (sw.isRunning) sw.stop();
        contentBuf.write(chunk.contentDelta);
      }
    }
    if (sw.isRunning) sw.stop();
    if (reasoningBuf.isNotEmpty) {
      onReasoning(reasoningBuf.toString(), sw.elapsedMilliseconds);
    }
    return cleanPrompt(contentBuf.toString());
  }

  static const systemPrompt =
      '你是文生图提示词优化助手。用户会给出简短、口语化或中文的画面描述。'
      '请改写成高质量的文生图提示词：补全主体、场景、构图、光影、材质、风格与细节，'
      '尽量使用英文（专有名词/书法文字可保留原文），适合常见文生图模型。'
      '只输出最终提示词本身，不要解释、不要标题、不要引号或代码块围栏。';

  /// Strip common model decorations so the image API gets a clean prompt.
  static String cleanPrompt(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$', multiLine: true);
    final m = fence.firstMatch(text);
    if (m != null) text = (m.group(1) ?? '').trim();
    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'")) ||
        (text.startsWith('“') && text.endsWith('”'))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }
}
