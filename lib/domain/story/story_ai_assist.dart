import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import '../../data/story_models.dart';
import '../llm/llm_provider.dart';

/// Uses the configured LLM to draft / polish character cards and world-info.
class StoryAiAssist {
  StoryAiAssist(this._llm);

  final LlmProvider _llm;

  /// Fill a character card from a short idea (and optional existing fields).
  Future<CharacterCardDraft> generateCharacter({
    required LlmConfig config,
    required String idea,
    CharacterCardDraft? seed,
    CancelToken? cancelToken,
  }) async {
    final seedBlock = seed == null || seed.isEmpty
        ? '（无已有草稿）'
        : '''
已有草稿（可沿用或改写）：
- 名称：${seed.name}
- 简介：${seed.description}
- 性格：${seed.personality}
- 场景：${seed.scenario}
- 开场白：${seed.firstMes}
- 示例对话：${seed.exampleDialogs}
- 系统提示：${seed.systemPrompt}
''';

    final raw = await _complete(
      config: config,
      cancelToken: cancelToken,
      system: '''
你是角色卡编剧助手。根据用户意图生成可用的角色卡字段。
只输出一个 JSON 对象，不要 markdown 代码围栏，不要其它说明。
字段（均为字符串）：
name, description, personality, scenario, firstMes, exampleDialogs, systemPrompt
要求：
- 中文（除非用户明确要求其它语言）
- description：外貌/身份/背景，2–5 句
- personality：性格与说话语气，具体可演
- scenario：默认情境
- firstMes：角色开场白，口语、可带动作
- exampleDialogs：2–4 轮简短示例（用户/角色交替）
- systemPrompt：给模型的扮演约束，简洁
''',
      user: '创作意图：$idea\n\n$seedBlock',
    );

    return CharacterCardDraft.fromJsonMap(_extractJsonObject(raw)) ??
        CharacterCardDraft(
          name: idea.trim().isEmpty ? '未命名角色' : idea.trim(),
          description: raw.trim(),
        );
  }

  /// Polish a single free-text field in place.
  Future<String> polishText({
    required LlmConfig config,
    required String fieldLabel,
    required String text,
    String? context,
    CancelToken? cancelToken,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw Exception('当前字段为空，请先写一点内容或改用「AI 生成」。');
    }
    final raw = await _complete(
      config: config,
      cancelToken: cancelToken,
      system: '''
你是中文写作助手。润色用户给出的「$fieldLabel」文本。
只输出润色后的正文，不要标题、不要解释、不要引号包裹整段。
保持原意与人称；可更生动、具体，但不要无故加长到超过原文约 1.5 倍。
''',
      user: [
        if (context != null && context.trim().isNotEmpty) '上下文：\n$context\n',
        '原文：\n$source',
      ].join('\n'),
    );
    final out = raw.trim();
    if (out.isEmpty) throw Exception('模型未返回有效内容。');
    return out;
  }

  /// Draft a world-info entry from an idea.
  Future<WorldInfoDraft> generateWorldInfo({
    required LlmConfig config,
    required String idea,
    WorldInfoDraft? seed,
    CancelToken? cancelToken,
  }) async {
    final seedBlock = seed == null || seed.isEmpty
        ? '（无已有草稿）'
        : '''
已有草稿：
- 标题：${seed.title}
- 关键词：${seed.keys.join('、')}
- 内容：${seed.content}
- 常驻：${seed.alwaysOn}
''';

    final raw = await _complete(
      config: config,
      cancelToken: cancelToken,
      system: '''
你是世界观 / 世界书条目助手。根据用户意图生成一条 lore 设定。
只输出一个 JSON 对象，不要 markdown 代码围栏。
字段：
- title: 字符串
- keys: 字符串数组（2–8 个触发词，短词优先）
- content: 字符串（设定正文，第三人称说明，200–600 字为宜）
- alwaysOn: 布尔（仅当必须每轮注入时 true，默认 false）
- priority: 整数 0–100（重要度）
''',
      user: '创作意图：$idea\n\n$seedBlock',
    );

    return WorldInfoDraft.fromJsonMap(_extractJsonObject(raw)) ??
        WorldInfoDraft(
          title: idea.trim().isEmpty ? '未命名条目' : idea.trim(),
          content: raw.trim(),
          keys: idea.trim().isEmpty ? const [] : [idea.trim()],
        );
  }

  Future<String> _complete({
    required LlmConfig config,
    required String system,
    required String user,
    CancelToken? cancelToken,
  }) async {
    if (!config.isReady) {
      throw Exception('请先在设置中填写 API Key 与 Base URL。');
    }
    final buffer = StringBuffer();
    await for (final chunk in _llm.streamChat(
      config: config,
      // Prefer non-thinking chat model behaviour for structured JSON.
      thinking: false,
      cancelToken: cancelToken,
      messages: [
        LlmRequestMessage(role: MessageRole.system, content: system),
        LlmRequestMessage(role: MessageRole.user, content: user),
      ],
    )) {
      if (chunk.contentDelta != null) buffer.write(chunk.contentDelta);
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) throw Exception('模型没有返回内容，请重试。');
    return text;
  }
}

/// Mutable draft used by the character editor before save.
class CharacterCardDraft {
  const CharacterCardDraft({
    this.name = '',
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.exampleDialogs = '',
    this.systemPrompt = '',
  });

  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String exampleDialogs;
  final String systemPrompt;

  bool get isEmpty =>
      name.trim().isEmpty &&
      description.trim().isEmpty &&
      personality.trim().isEmpty &&
      scenario.trim().isEmpty &&
      firstMes.trim().isEmpty &&
      exampleDialogs.trim().isEmpty &&
      systemPrompt.trim().isEmpty;

  static CharacterCardDraft? fromJsonMap(Map<String, dynamic>? json) {
    if (json == null) return null;
    String s(String key) => (json[key] as String?)?.trim() ?? '';
    return CharacterCardDraft(
      name: s('name'),
      description: s('description'),
      personality: s('personality'),
      scenario: s('scenario'),
      firstMes: s('firstMes'),
      exampleDialogs: s('exampleDialogs'),
      systemPrompt: s('systemPrompt'),
    );
  }

  CharacterCard toCard({CharacterCard? base}) {
    final name = this.name.trim().isEmpty ? '未命名角色' : this.name.trim();
    return (base ?? CharacterCard(name: name)).copyWith(
      name: name,
      description: description,
      personality: personality,
      scenario: scenario,
      firstMes: firstMes,
      exampleDialogs: exampleDialogs,
      systemPrompt: systemPrompt,
    );
  }
}

class WorldInfoDraft {
  const WorldInfoDraft({
    this.title = '',
    this.keys = const [],
    this.content = '',
    this.alwaysOn = false,
    this.priority = 0,
  });

  final String title;
  final List<String> keys;
  final String content;
  final bool alwaysOn;
  final int priority;

  bool get isEmpty =>
      title.trim().isEmpty && keys.isEmpty && content.trim().isEmpty;

  static WorldInfoDraft? fromJsonMap(Map<String, dynamic>? json) {
    if (json == null) return null;
    final keysRaw = json['keys'];
    final keys = <String>[];
    if (keysRaw is List) {
      for (final e in keysRaw) {
        final k = e.toString().trim();
        if (k.isNotEmpty) keys.add(k);
      }
    } else if (keysRaw is String) {
      keys.addAll(
        keysRaw
            .split(RegExp(r'[,，、\s]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty),
      );
    }
    return WorldInfoDraft(
      title: (json['title'] as String?)?.trim() ?? '',
      keys: keys,
      content: (json['content'] as String?)?.trim() ?? '',
      alwaysOn: json['alwaysOn'] == true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }

  WorldInfoEntry toEntry({WorldInfoEntry? base}) {
    final title = this.title.trim().isEmpty ? '未命名条目' : this.title.trim();
    return (base ?? WorldInfoEntry(title: title)).copyWith(
      title: title,
      keys: keys,
      content: content,
      alwaysOn: alwaysOn,
      priority: priority,
    );
  }
}

/// Best-effort: strip ``` fences and locate the first JSON object.
Map<String, dynamic>? extractJsonObjectForTest(String raw) =>
    _extractJsonObject(raw);

Map<String, dynamic>? _extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');
    text = text.trim();
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } catch (_) {
    // fall through
  }
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
  return null;
}
