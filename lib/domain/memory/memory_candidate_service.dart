import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:uuid/uuid.dart';

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'memory_entry.dart';
import 'memory_safety.dart';

const _uuid = Uuid();

enum MemoryCandidateCategory {
  preference,
  profileFact,
  projectFact,
  decision,
  ongoingTask,
  other,
}

extension MemoryCandidateCategoryInfo on MemoryCandidateCategory {
  String get wire => switch (this) {
    MemoryCandidateCategory.preference => 'preference',
    MemoryCandidateCategory.profileFact => 'profile_fact',
    MemoryCandidateCategory.projectFact => 'project_fact',
    MemoryCandidateCategory.decision => 'decision',
    MemoryCandidateCategory.ongoingTask => 'ongoing_task',
    MemoryCandidateCategory.other => 'other',
  };

  String get label => switch (this) {
    MemoryCandidateCategory.preference => '偏好',
    MemoryCandidateCategory.profileFact => '个人资料',
    MemoryCandidateCategory.projectFact => '项目事实',
    MemoryCandidateCategory.decision => '长期决定',
    MemoryCandidateCategory.ongoingTask => '持续任务',
    MemoryCandidateCategory.other => '其他',
  };

  static MemoryCandidateCategory? fromWire(String value) {
    for (final category in MemoryCandidateCategory.values) {
      if (category.wire == value.trim().toLowerCase()) return category;
    }
    return null;
  }
}

enum MemoryCandidateRelation { newFact, update, conflict }

extension MemoryCandidateRelationInfo on MemoryCandidateRelation {
  String get wire => switch (this) {
    MemoryCandidateRelation.newFact => 'new',
    MemoryCandidateRelation.update => 'update',
    MemoryCandidateRelation.conflict => 'conflict',
  };

  String get label => switch (this) {
    MemoryCandidateRelation.newFact => '新记忆',
    MemoryCandidateRelation.update => '可能更新',
    MemoryCandidateRelation.conflict => '存在冲突',
  };

  static MemoryCandidateRelation? fromWire(String value) {
    for (final relation in MemoryCandidateRelation.values) {
      if (relation.wire == value.trim().toLowerCase()) return relation;
    }
    return null;
  }
}

/// The two persistence choices offered after a candidate has been reviewed.
/// Omitting a candidate from the returned selection means "暂不保存".
enum MemoryCandidateWriteMode { add, replace }

class MemoryCandidateSelection {
  const MemoryCandidateSelection({required this.candidate, required this.mode});

  final MemoryCandidate candidate;
  final MemoryCandidateWriteMode mode;
}

/// A model-proposed memory. It is deliberately not persisted until the user
/// selects it in the confirmation sheet.
class MemoryCandidate {
  MemoryCandidate({
    String? id,
    required this.content,
    required this.category,
    required this.confidence,
    required this.reason,
    required this.sourceMessageIds,
    this.relation = MemoryCandidateRelation.newFact,
    this.relatedMemories = const [],
  }) : id = id ?? _uuid.v4();

  final String id;
  final String content;
  final MemoryCandidateCategory category;
  final double confidence;
  final String reason;

  /// Evidence must point to at least one user-authored message in the bounded
  /// transcript sent to the extractor.
  final List<String> sourceMessageIds;

  /// A bounded set of existing entries the model identified as superseded or
  /// incompatible. Their full content is shown to the user before replacement.
  final MemoryCandidateRelation relation;
  final List<MemoryEntry> relatedMemories;

  bool get hasExistingRelation =>
      relation != MemoryCandidateRelation.newFact && relatedMemories.isNotEmpty;
}

class MemoryCandidateFormatException implements Exception {
  const MemoryCandidateFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Extracts a small set of durable facts without writing them to storage.
///
/// The expensive model call happens only when the user explicitly opens
/// "整理候选记忆". Local validation then rejects malformed, unsupported,
/// sensitive, low-confidence and duplicate candidates.
class MemoryCandidateService {
  const MemoryCandidateService(this._llm);

  final LlmProvider _llm;

  static const int maxCandidates = 5;
  static const int maxCandidateChars = 280;
  static const int maxTranscriptMessages = 20;
  static const int maxMessageChars = 1800;
  static const int maxTranscriptChars = 18000;
  static const int maxExistingMemoryChars = 4000;
  static const int maxRelatedMemories = 3;
  static const double minimumConfidence = 0.65;
  static const int _maxModelOutputChars = 32000;

  static const String _systemPrompt = '''
你是一个“长期记忆候选整理器”。你的输出不会自动保存，用户稍后会逐条确认。

只提取未来多次对话仍可能有用、且由用户明确说出或明确确认的信息：
1. 稳定的回答/交互偏好；
2. 用户主动透露且适合长期保存的个人资料；
3. 持续项目的事实、约束、技术选择；
4. 已明确作出的长期决定；
5. 会跨会话持续推进的目标或任务。

不要提取：
- 只对当前一轮有效的请求、临时安排、寒暄或情绪；
- 猜测、假设、问题中的示例、引用文本、附件内容；
- 仅由助手提出而用户没有确认的信息；
- 故事设定、角色扮演内容、模型生成的文章或代码；
- 密码、API Key、Token、私钥、登录凭证及类似敏感信息；
- 已有记忆的同义重复（重复项不要输出）。

每条候选必须是准确、独立、简短的一条事实，最多 280 个字符。
sourceMessageIds 必须引用输入中真正支持该事实的 user 消息 ID；没有用户证据就不要输出。
对照带 ID 的已有长期记忆，并设置 relation：
- new：与已有记忆无关的新事实，relatedMemoryIds 必须为空；
- update：用户明确表达了较新的状态，可能取代旧记忆；
- conflict：新旧内容互不相容，但无法确定旧内容是否已失效。
relation 为 update 或 conflict 时，relatedMemoryIds 必须引用真正相关的已有记忆 ID，最多 3 个。
最多输出 5 条；没有合格内容时输出空数组。
只输出一个 JSON 对象，不要 Markdown、解释或代码围栏，严格使用以下结构：
{"candidates":[{"content":"事实","category":"preference|profile_fact|project_fact|decision|ongoing_task|other","confidence":0.0,"reason":"为何值得跨会话保留","sourceMessageIds":["用户消息ID"],"relation":"new|update|conflict","relatedMemoryIds":["已有记忆ID"]}]}
''';

  Future<List<MemoryCandidate>> extract({
    required LlmConfig config,
    required List<ChatMessage> messages,
    required List<MemoryEntry> existingMemories,
    CancelToken? cancelToken,
  }) async {
    if (!config.isReady) {
      throw const MemoryCandidateFormatException(
        '请先在设置中填写 API Key 与 Base URL。',
      );
    }

    final transcript = _boundedTranscript(messages);
    if (transcript.messages.where((m) => m.role == MessageRole.user).isEmpty) {
      return const [];
    }

    final existingContext = _boundedExistingMemories(existingMemories);
    final prompt = StringBuffer()
      ..writeln('当前普通对话（role | messageId | content）：')
      ..writeln('-----')
      ..writeln(transcript.text)
      ..writeln('-----')
      ..writeln('已有长期记忆（格式为 [memoryId] content）：')
      ..writeln('-----')
      ..writeln(existingContext.text)
      ..writeln('-----')
      ..writeln('请输出候选 JSON。');

    final output = StringBuffer();
    await for (final chunk in _llm.streamChat(
      config: config,
      messages: [
        const LlmRequestMessage(
          role: MessageRole.system,
          content: _systemPrompt,
        ),
        LlmRequestMessage(role: MessageRole.user, content: prompt.toString()),
      ],
      thinking: false,
      cancelToken: cancelToken,
    )) {
      final delta = chunk.contentDelta;
      if (delta == null || delta.isEmpty) continue;
      if (output.length + delta.length > _maxModelOutputChars) {
        throw const MemoryCandidateFormatException('模型返回内容过长，已停止解析。');
      }
      output.write(delta);
    }

    if (output.toString().trim().isEmpty) {
      throw const MemoryCandidateFormatException('模型没有返回候选内容，请重试。');
    }
    return parse(
      output.toString(),
      validUserMessageIds: transcript.userMessageIds,
      existingMemories: existingMemories,
      validRelatedMemoryIds: existingContext.ids,
    );
  }

  /// Public for deterministic parser tests and for future offline import.
  static List<MemoryCandidate> parse(
    String raw, {
    required Set<String> validUserMessageIds,
    List<MemoryEntry> existingMemories = const [],
    Set<String>? validRelatedMemoryIds,
  }) {
    final json = _extractJsonObject(raw);
    final rawCandidates = json['candidates'];
    if (rawCandidates is! List) {
      throw const MemoryCandidateFormatException('候选结果缺少 candidates 数组。');
    }

    final existingKeys = {
      for (final entry in existingMemories) _dedupeKey(entry.content),
    };
    final relationIds =
        validRelatedMemoryIds ??
        {for (final entry in existingMemories) entry.id};
    final existingById = {
      for (final entry in existingMemories)
        if (relationIds.contains(entry.id)) entry.id: entry,
    };
    final acceptedKeys = <String>{};
    final result = <MemoryCandidate>[];

    for (final value in rawCandidates) {
      if (result.length >= maxCandidates) break;
      if (value is! Map) continue;
      final item = value.map((key, value) => MapEntry(key.toString(), value));

      final rawContent = item['content'];
      final rawCategory = item['category'];
      final rawConfidence = item['confidence'];
      final rawSources = item['sourceMessageIds'];
      if (rawContent is! String ||
          rawCategory is! String ||
          rawConfidence is! num ||
          rawSources is! List) {
        continue;
      }

      final category = MemoryCandidateCategoryInfo.fromWire(rawCategory);
      final relation = MemoryCandidateRelationInfo.fromWire(
        item['relation'] is String ? item['relation'] as String : 'new',
      );
      final confidence = rawConfidence.toDouble();
      if (category == null ||
          relation == null ||
          !confidence.isFinite ||
          confidence < minimumConfidence ||
          confidence > 1) {
        continue;
      }

      String content;
      try {
        content = MemorySafety.normalize(rawContent);
      } on MemoryValidationException {
        continue;
      }
      if (content.characters.length > maxCandidateChars) continue;

      final sources = <String>[];
      for (final source in rawSources) {
        if (source is! String ||
            !validUserMessageIds.contains(source) ||
            sources.contains(source)) {
          continue;
        }
        sources.add(source);
      }
      if (sources.isEmpty) continue;

      final relatedMemories = <MemoryEntry>[];
      final rawRelated = item['relatedMemoryIds'];
      if (rawRelated is List) {
        for (final relatedId in rawRelated) {
          if (relatedMemories.length >= maxRelatedMemories) break;
          if (relatedId is! String) continue;
          final memory = existingById[relatedId];
          if (memory == null ||
              relatedMemories.any((entry) => entry.id == memory.id)) {
            continue;
          }
          relatedMemories.add(memory);
        }
      }
      if (relation != MemoryCandidateRelation.newFact &&
          relatedMemories.isEmpty) {
        continue;
      }

      final key = _dedupeKey(content);
      if (existingKeys.contains(key) || !acceptedKeys.add(key)) continue;

      final reason = _normalizeReason(item['reason']);
      result.add(
        MemoryCandidate(
          content: content,
          category: category,
          confidence: confidence,
          reason: reason,
          sourceMessageIds: List.unmodifiable(sources),
          relation: relation,
          relatedMemories: relation == MemoryCandidateRelation.newFact
              ? const []
              : List.unmodifiable(relatedMemories),
        ),
      );
    }
    return List.unmodifiable(result);
  }

  static ({String text, Set<String> userMessageIds, List<ChatMessage> messages})
  _boundedTranscript(List<ChatMessage> messages) {
    final eligible = messages
        .where(
          (message) =>
              (message.role == MessageRole.user ||
                  message.role == MessageRole.assistant) &&
              message.kind == MessageKind.text &&
              message.content.trim().isNotEmpty,
        )
        .toList(growable: false);
    final tail = eligible.length <= maxTranscriptMessages
        ? eligible
        : eligible.sublist(eligible.length - maxTranscriptMessages);

    final selected = <ChatMessage>[];
    final lines = <String>[];
    var used = 0;
    for (final message in tail.reversed) {
      final content = _clip(
        message.content.trim(),
        maxMessageChars,
      ).replaceAll(RegExp(r'\s+'), ' ');
      final line = '${message.role.wire} | ${message.id} | $content';
      if (used + line.length > maxTranscriptChars && selected.isNotEmpty) {
        break;
      }
      selected.add(message);
      lines.add(line);
      used += line.length;
    }
    final chronologicalMessages = selected.reversed.toList(growable: false);
    return (
      text: lines.reversed.join('\n'),
      userMessageIds: {
        for (final message in chronologicalMessages)
          if (message.role == MessageRole.user) message.id,
      },
      messages: List.unmodifiable(chronologicalMessages),
    );
  }

  static ({String text, Set<String> ids}) _boundedExistingMemories(
    List<MemoryEntry> entries,
  ) {
    if (entries.isEmpty) return (text: '（无）', ids: const {});
    final lines = <String>[];
    final ids = <String>{};
    var used = 0;
    for (final entry in entries.reversed) {
      final line =
          '- [${entry.id}] '
          '${entry.content.replaceAll(RegExp(r'\s+'), ' ').trim()}';
      if (used + line.length > maxExistingMemoryChars && lines.isNotEmpty) {
        break;
      }
      lines.add(line);
      ids.add(entry.id);
      used += line.length;
    }
    return (text: lines.join('\n'), ids: Set.unmodifiable(ids));
  }

  static Map<String, dynamic> _extractJsonObject(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      text = text.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const MemoryCandidateFormatException('模型没有返回有效的 JSON 对象。');
    }
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      throw const MemoryCandidateFormatException('候选 JSON 格式不正确，请重试。');
    }
    throw const MemoryCandidateFormatException('候选结果不是 JSON 对象。');
  }

  static String _normalizeReason(Object? value) {
    if (value is! String) return '';
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _clip(normalized, 160);
  }

  static String _clip(String value, int maxChars) {
    if (value.characters.length <= maxChars) return value;
    return '${value.characters.take(maxChars).toString()}…';
  }

  static String _dedupeKey(String value) {
    // 与 memory_repository 保持一致:连续空白压成一个空格而非删除,
    // 避免 "api key" 与 "apikey" 被误判为重复;与汉字相邻的空格视为排版差异。
    final collapsed = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final cjk = RegExp(r'[㐀-鿿]');
    final result = StringBuffer();
    for (var i = 0; i < collapsed.length; i++) {
      final char = collapsed[i];
      final spaceTouchesCjk =
          char == ' ' &&
          ((i > 0 && cjk.hasMatch(collapsed[i - 1])) ||
              (i + 1 < collapsed.length && cjk.hasMatch(collapsed[i + 1])));
      if (!spaceTouchesCjk) result.write(char);
    }
    return result.toString();
  }
}
