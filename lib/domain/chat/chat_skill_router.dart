import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/chat_skill.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../llm/llm_provider.dart';

/// System preset for one generate turn. Story / study / ensemble never use
/// this catalog; chat uses the routed skill prompt, or [fallbackPrompt] when
/// routing did not produce a skill.
String chatPresetPrompt({
  required ConversationMode mode,
  required ChatSkillRoute? route,
  required String fallbackPrompt,
}) {
  if (mode != ConversationMode.chat) return '';
  return route?.skill.prompt.trim() ?? fallbackPrompt;
}

class ChatSkillRoute {
  const ChatSkillRoute({
    required this.skill,
    required this.source,
    this.confidence,
  });
  final ChatSkill skill;
  final ChatSkillSource source;
  final double? confidence;
}

class ChatSkillRouter {
  const ChatSkillRouter();

  String classifierSystemPrompt(ChatSkillCatalog catalog) {
    final lines = [
      '你是任务分类器。只根据用户本轮任务，从下列种类中选一个 id。',
      '种类：',
      for (final skill in catalog.enabled)
        '- ${skill.id}：${skill.name}。${skill.when}',
      '只输出一个 JSON 对象，不要 Markdown，不要解释：',
      '{"skill":"种类id","confidence":0到1}',
      'skill 必须是上列 id 之一。没有把握时选 ${catalog.fallback.id}，并把 confidence 压低。',
    ];
    return lines.join('\n');
  }

  String classifierUserPrompt({
    required String userText,
    required List<ChatMessage> recent,
  }) {
    final history = [
      for (final message in recent)
        if (message.role == MessageRole.user ||
            message.role == MessageRole.assistant)
          message,
    ];
    final start = history.length > 4 ? history.length - 4 : 0;
    final recentTurns = history.sublist(start);
    final buf = StringBuffer();
    if (recentTurns.isNotEmpty) {
      buf.writeln('最近对话：');
      for (final message in recentTurns) {
        buf.writeln('${message.role.name}: ${_clip(message.content, 400)}');
      }
      buf.writeln();
    }
    buf.writeln('本轮任务：');
    buf.write(userText);
    return buf.toString();
  }

  ChatSkillRoute parseClassifierOutput(
    String raw,
    ChatSkillCatalog catalog,
  ) {
    try {
      final decoded = jsonDecode(_stripFence(raw));
      if (decoded is! Map<String, dynamic>) {
        return _fallback(catalog);
      }
      final skillId = (decoded['skill'] as String? ?? '').trim();
      final confidenceRaw = decoded['confidence'];
      final confidence = confidenceRaw is num ? confidenceRaw.toDouble() : 0.0;
      final enabled = catalog.skillById(skillId);
      if (enabled == null ||
          !enabled.enabled ||
          confidence < kChatSkillMinConfidence) {
        return _fallback(catalog, confidence: confidence);
      }
      return ChatSkillRoute(
        skill: enabled,
        source: ChatSkillSource.model,
        confidence: confidence,
      );
    } catch (_) {
      return _fallback(catalog);
    }
  }

  Future<ChatSkillRoute> route({
    required String userText,
    required List<ChatMessage> recent,
    required ChatSkillCatalog catalog,
    required LlmProvider llm,
    required LlmConfig config,
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final prefixed = catalog.matchPrefix(userText);
    if (prefixed != null) {
      return ChatSkillRoute(skill: prefixed, source: ChatSkillSource.prefix);
    }
    final localCancel = CancelToken();
    if (cancelToken != null) {
      if (cancelToken.isCancelled) {
        return ChatSkillRoute(
          skill: catalog.fallback,
          source: ChatSkillSource.fallback,
        );
      }
      cancelToken.whenCancel.then((_) {
        if (!localCancel.isCancelled) localCancel.cancel();
      });
    }
    final buf = StringBuffer();
    final consume = Future(() async {
      await for (final chunk in llm.streamChat(
        config: config,
        thinking: false,
        cancelToken: localCancel,
        messages: [
          LlmRequestMessage(
            role: MessageRole.system,
            content: classifierSystemPrompt(catalog),
          ),
          LlmRequestMessage(
            role: MessageRole.user,
            content: classifierUserPrompt(
              userText: userText,
              recent: recent,
            ),
          ),
        ],
      )) {
        if (chunk.contentDelta != null) buf.write(chunk.contentDelta);
      }
    });
    try {
      await consume.timeout(timeout);
      return parseClassifierOutput(buf.toString(), catalog);
    } catch (_) {
      if (!localCancel.isCancelled) localCancel.cancel();
      unawaited(consume.then((_) {}, onError: (_) {}));
      return ChatSkillRoute(
        skill: catalog.fallback,
        source: ChatSkillSource.fallback,
      );
    }
  }

  static ChatSkillRoute _fallback(
    ChatSkillCatalog catalog, {
    double? confidence,
  }) => ChatSkillRoute(
    skill: catalog.fallback,
    source: ChatSkillSource.fallback,
    confidence: confidence,
  );

  static String _clip(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return text.substring(0, maxChars);
  }

  static String _stripFence(String raw) {
    var text = raw.trim();
    if (!text.startsWith('```')) return text;
    final firstNl = text.indexOf('\n');
    if (firstNl == -1) return text.replaceAll('```', '').trim();
    text = text.substring(firstNl + 1);
    final close = text.lastIndexOf('```');
    if (close != -1) text = text.substring(0, close);
    return text.trim();
  }
}
