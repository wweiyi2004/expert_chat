import 'package:dio/dio.dart';

import '../../data/models.dart';
import '../chat/error_describe.dart';
import '../llm/llm_provider.dart';
import 'tool_engine.dart' show SearchActivityListener;
import 'vision_tools.dart';

class VisionToolResult {
  const VisionToolResult(this.content, {this.error});
  final String content;
  final Object? error;
}

/// Shared vision request path for model tools and pre-generation image analysis.
/// Budget admission and live activity publication are supplied by the caller.
class VisionToolExecutor {
  const VisionToolExecutor({
    required this.getProvider,
    required this.onActivity,
    required this.checkBudget,
  });

  final LlmProvider Function() getProvider;
  final SearchActivityListener onActivity;
  final ({bool allowed, String? reason}) Function() checkBudget;

  void _reject(String query, String error) {
    final activity = SearchActivity(
      kind: SearchActivityKind.vision,
      query: query,
    );
    onActivity(activity);
    onActivity(
      activity.copyWith(
        status: SearchActivityStatus.failed,
        resultCount: 0,
        error: error,
        items: const [],
      ),
    );
  }

  Future<VisionToolResult> execute({
    required ToolCall call,
    required LlmConfig? config,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    if (config == null) {
      _reject('识图', '未配置视觉 API');
      return const VisionToolResult('未配置视觉 API，无法识图。');
    }
    final args = VisionTools.parseArgs(call.argumentsJson);
    final image = VisionTools.pickImage(sources, args.attachmentName);
    if (image == null) {
      _reject(
        args.attachmentName.isNotEmpty ? args.attachmentName : '识图',
        '没有可识图附件',
      );
      return VisionToolResult(
        args.attachmentName.isNotEmpty
            ? '找不到图片「${args.attachmentName}」。可用： ${VisionTools.availableNames(sources)}'
            : '本轮没有可识图的图片附件。',
      );
    }
    final result = await analyze(
      config: config,
      image: image,
      question: args.resolvedQuestion,
      cancelToken: cancelToken,
    );
    return VisionToolResult(
      result.content.isEmpty
          ? '识图服务没有返回可用内容。'
          : '【图片：${image.name}】\n${result.content}',
      error: result.error,
    );
  }

  Future<VisionToolResult> analyze({
    required LlmConfig config,
    required Attachment image,
    required String question,
    required CancelToken cancelToken,
  }) async {
    final activity = SearchActivity(
      kind: SearchActivityKind.vision,
      query: image.name,
    );
    onActivity(activity);
    final admission = checkBudget();
    if (!admission.allowed) {
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: admission.reason,
        ),
      );
      return const VisionToolResult('识图未执行：任务预算已用完。');
    }
    try {
      final buffer = StringBuffer();
      await for (final chunk in getProvider().streamChat(
        config: config,
        cancelToken: cancelToken,
        messages: [
          const LlmRequestMessage(
            role: MessageRole.system,
            content:
                '你是视觉理解助手。只根据图片中可见内容作答，不要编造看不到的文字或物体。'
                '用简洁中文；若图中有文字请如实转录。',
          ),
          LlmRequestMessage(
            role: MessageRole.user,
            content: question,
            imageDataUrls: [image.imageDataUrl],
          ),
        ],
      )) {
        if (cancelToken.isCancelled) break;
        if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
          buffer.write(chunk.contentDelta);
        }
      }
      final text = buffer.toString().trim();
      onActivity(
        activity.copyWith(
          status: text.isEmpty
              ? SearchActivityStatus.failed
              : SearchActivityStatus.done,
          resultCount: text.isEmpty ? 0 : 1,
          error: text.isEmpty ? '空结果' : null,
        ),
      );
      return VisionToolResult(text);
    } catch (error) {
      if (isCancelError(error) || cancelToken.isCancelled) {
        onActivity(
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return const VisionToolResult('识图已取消。');
      }
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: describeError(error),
        ),
      );
      return VisionToolResult('识图失败：$error', error: error);
    }
  }
}
