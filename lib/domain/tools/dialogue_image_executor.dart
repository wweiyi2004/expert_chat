import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/media_api_config.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../chat/error_describe.dart';
import '../media/image_prompt_safety.dart';
import '../media/image_generation_service.dart';
import '../media/openai_compatible_media_provider.dart';
import 'tool_engine.dart' show SearchActivityListener;

class DialogueImageOutput {
  const DialogueImageOutput({
    required this.attachment,
    required this.sentPrompt,
    this.revisedPrompt,
  });
  final Attachment attachment;
  final String sentPrompt;
  final String? revisedPrompt;
}

/// Dialogue illustration execution; the caller owns admission and publication.
class DialogueImageExecutor {
  const DialogueImageExecutor({
    required this.getProvider,
    required this.isActive,
    required this.checkBudget,
    required this.onActivity,
    required this.onGeneratingChanged,
    required this.onGenerated,
  });
  final OpenAiCompatibleMediaProvider Function() getProvider;
  final bool Function() isActive;
  final ({bool allowed, String? reason}) Function() checkBudget;
  final SearchActivityListener onActivity;
  final void Function(bool) onGeneratingChanged;
  final Future<void> Function(DialogueImageOutput) onGenerated;

  Future<({bool ok, String? error})> execute({
    required MediaApiConfig? config,
    required String apiKey,
    required CharacterCard? character,
    required String userText,
    required String? modelPrompt,
    required String? briefHint,
    required CancelToken cancelToken,
    Future<String> Function(String)? optimizePrompt,
    bool countTool = true,
  }) async {
    if (config == null) {
      return (ok: false, error: '请先在设置中完整配置图片生成 API。');
    }
    if (cancelToken.isCancelled || !isActive()) {
      return (ok: false, error: null);
    }

    if (countTool) {
      final admission = checkBudget();
      if (!admission.allowed) return (ok: false, error: admission.reason);
    }
    String prompt;
    if (character != null) {
      // Character book: portrait from card only. Never inject R18 user prose.
      prompt = ImagePromptSafety.characterPortrait(
        character,
        userHint: briefHint,
      );
    } else {
      final draft = (modelPrompt != null && modelPrompt.trim().isNotEmpty)
          ? modelPrompt
          : userText;
      prompt = ImagePromptSafety.freeform(draft);
      if (optimizePrompt != null) {
        final optimizing = SearchActivity(
          kind: SearchActivityKind.image,
          query: '优化提示词',
        );
        onActivity(optimizing);
        try {
          final refined = await optimizePrompt(prompt);
          if (refined.isNotEmpty) {
            prompt = ImagePromptSafety.freeform(refined);
          }
          onActivity(
            optimizing.copyWith(
              status: cancelToken.isCancelled
                  ? SearchActivityStatus.failed
                  : SearchActivityStatus.done,
              error: cancelToken.isCancelled ? '已取消' : null,
            ),
          );
        } catch (e) {
          onActivity(
            optimizing.copyWith(
              status: SearchActivityStatus.failed,
              error: cancelToken.isCancelled ? '已取消' : '提示词优化未完成，使用原始描述',
            ),
          );
          if (isCancelError(e) || cancelToken.isCancelled) {
            return (ok: false, error: null);
          }
          // Fall through with the scrubbed draft.
        }
      }
    }
    if (cancelToken.isCancelled || !isActive()) {
      return (ok: false, error: null);
    }
    final activity = SearchActivity(
      kind: SearchActivityKind.image,
      query: '配图',
      toolName: 'generate_image',
      toolArguments: jsonEncode({'prompt': prompt}),
    );
    onActivity(activity);
    onGeneratingChanged(true);
    if (prompt.trim().isEmpty) {
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: '生图提示词为空',
        ),
      );
      onGeneratingChanged(false);
      return (ok: false, error: '生图提示词为空。');
    }
    try {
      final generated = await ImageGenerationService(getProvider: getProvider)
          .generate(
            config: config,
            apiKey: apiKey,
            prompt: prompt,
            cancelToken: cancelToken,
          );
      if (cancelToken.isCancelled || !isActive()) {
        onActivity(
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return (ok: false, error: null);
      }
      final attachment = generated.attachment;
      await onGenerated(
        DialogueImageOutput(
          attachment: attachment,
          sentPrompt: prompt,
          revisedPrompt: generated.revisedPrompt,
        ),
      );
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.done,
          resultCount: 1,
          items: [SearchActivityItem(title: attachment.name)],
        ),
      );
      return (ok: true, error: null);
    } catch (e) {
      onActivity(
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: isCancelError(e) || cancelToken.isCancelled
              ? '已取消'
              : describeError(e),
        ),
      );
      if (isCancelError(e) || cancelToken.isCancelled) {
        return (ok: false, error: null);
      }
      return (ok: false, error: describeError(e));
    } finally {
      onGeneratingChanged(false);
    }
  }

  static ({String? prompt, String? briefHint}) parseToolArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final prompt = decoded['prompt'] is String
            ? (decoded['prompt'] as String).trim()
            : null;
        final hint = decoded['brief_hint'] is String
            ? (decoded['brief_hint'] as String).trim()
            : (decoded['briefHint'] is String
                  ? (decoded['briefHint'] as String).trim()
                  : null);
        return (
          prompt: prompt?.isEmpty ?? true ? null : prompt,
          briefHint: hint?.isEmpty ?? true ? null : hint,
        );
      }
    } catch (_) {
      // Malformed JSON from the model.
    }
    return (prompt: null, briefHint: null);
  }
}
