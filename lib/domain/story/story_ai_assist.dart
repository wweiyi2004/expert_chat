import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import '../../data/story_models.dart';
import '../llm/llm_provider.dart';

/// Uses the configured LLM to draft / polish character cards and world-info.
class StoryAiAssist {
  StoryAiAssist(this._llm);

  final LlmProvider _llm;

  /// Turn a premise into a complete, story-local cast and an actionable
  /// outline. The AI performs every character; the user remains the director.
  Future<DirectorStoryDraft> generateDirectorStory({
    required LlmConfig config,
    required String premise,
    String? style,
    String? requirements,
    String? length,
    DirectorStoryDraft? seed,
    CancelToken? cancelToken,
  }) async {
    final trimmedPremise = premise.trim();
    if (trimmedPremise.isEmpty) {
      throw Exception('请先输入故事情节。');
    }

    final hardRequirements = (requirements ?? style)?.trim() ?? '';
    final preferences = <String>[
      if (hardRequirements.isNotEmpty) '硬性约束 / 创作要求：\n$hardRequirements',
      if (length != null && length.trim().isNotEmpty) '篇幅结构：${length.trim()}',
    ];
    final seedBlock = seed == null || seed.isEmpty
        ? '（无已有草稿）'
        : jsonEncode(seed.toJson());

    final raw = await _complete(
      config: config,
      cancelToken: cancelToken,
      system: '''
你是“导演故事模式”的首席编剧与选角导演。用户只负责提出情节和后续导演指令；你要创建剧情所需的全部角色，并让 AI 在故事中扮演全部角色。

只输出一个严格合法的 JSON 对象。不要输出 Markdown 代码围栏、注释、前后说明或 JSON 之外的文字。必须使用以下根结构和字段名：
{
  "title": "故事标题",
  "outline": "按发生顺序排列的大纲，每个情节点独占一行并以 - 开头",
  "authorNote": "供后续演绎模型持续遵守的硬性导演说明",
  "characters": [
    {
      "name": "角色名",
      "description": "身份、外貌、经历及与剧情的关系",
      "personality": "性格、动机、弱点、秘密与说话方式",
      "scenario": "角色进入故事时的处境",
      "firstMes": "符合角色口吻的首次登场台词或动作",
      "exampleDialogs": "2–4 轮能体现角色口吻的示例对话",
      "systemPrompt": "后续模型扮演该角色时必须遵守的简洁约束"
    }
  ]
}

硬性要求（优先级从高到低）：
1. 用户给出的「故事情节」与「硬性约束 / 创作要求」不可违背、不可淡化、不可用“艺术加工”绕过。
2. outline 的每一个节拍都必须服务上述情节与约束；禁止加入与用户要求冲突的支线、人设改动或提前剧透。
3. authorNote 必须：
   - 写明 AI 扮演全部角色、用户是导演、不替用户发言；
   - **逐条复述**用户的硬性约束（若有），并写明“演绎时必须遵守”；
   - 写明后续指令优先服从导演。
4. 角色设定不得与用户约束冲突（例如用户要求克制悬疑，则不要设计话痨剧透型角色作为默认主视角）。
5. 除非用户明确要求其它语言，否则使用中文。
6. 根据情节需要创建 1–6 个彼此有明确关系、目标和冲突的角色。
7. outline 必须是可依次演绎的具体情节点，不写空泛的“发展剧情”。
8. 若「篇幅结构」含全书总字数目标，outline 的节拍数量与每拍叙事密度必须服务该目标（长篇不可写成短篇节奏）。
9. 已有草稿仅作参考；与用户约束冲突时以用户约束为准。
10. 所有键和字符串必须使用双引号；不得使用尾随逗号。
''',
      user: [
        '故事情节（必须保留核心，不可擅自改写结局/基调）：\n$trimmedPremise',
        if (preferences.isNotEmpty) preferences.join('\n\n'),
        '已有草稿（JSON，可改但不得违反上方约束）：\n$seedBlock',
      ].join('\n\n'),
    );

    final parsed = DirectorStoryDraft.fromJsonMap(_extractJsonObject(raw));
    if (parsed == null ||
        parsed.outline.trim().isEmpty ||
        parsed.characters.isEmpty) {
      throw Exception('模型返回的故事草稿格式不完整，请重试。');
    }
    return DirectorStoryDraft(
      title: parsed.title.trim().isEmpty ? trimmedPremise : parsed.title,
      outline: parsed.outline,
      authorNote: parsed.authorNote.trim().isEmpty
          ? DirectorStoryDraft.defaultAuthorNote
          : parsed.authorNote,
      characters: parsed.characters,
    );
  }

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
      system:
          '''
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

/// A story package generated from a director's premise.
///
/// Character cards are deliberately drafts: callers may keep them local to the
/// story or explicitly save selected cards to the reusable character library.
class DirectorStoryDraft {
  const DirectorStoryDraft({
    this.title = '',
    this.outline = '',
    this.authorNote = '',
    this.characters = const [],
  });

  static const defaultAuthorNote =
      'AI 扮演故事中的全部角色，用户是导演。'
      '必须优先服从用户的情节设定、创作约束与后续导演指令；'
      '不得擅自改结局、改基调或替用户发言。';

  final String title;
  final String outline;
  final String authorNote;
  final List<CharacterCardDraft> characters;

  bool get isEmpty =>
      title.trim().isEmpty &&
      outline.trim().isEmpty &&
      authorNote.trim().isEmpty &&
      characters.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    'outline': outline,
    'authorNote': authorNote,
    'characters': characters.map((character) => character.toJson()).toList(),
  };

  /// Parses the strict schema while tolerating common harmless model drift:
  /// fenced/prose extraction happens before this call, and an outline returned
  /// as an array is normalized to the line-oriented format used by stories.
  static DirectorStoryDraft? fromJsonMap(Map<String, dynamic>? json) {
    if (json == null) return null;

    final title = _stringValue(json['title'] ?? json['storyTitle']);
    final outline = _outlineValue(json['outline'] ?? json['plot']);
    final authorNote = _stringValue(
      json['authorNote'] ?? json['author_note'] ?? json['directorNote'],
    );
    final rawCharacters =
        json['characters'] ?? json['characterCards'] ?? json['character_cards'];
    final characters = <CharacterCardDraft>[];
    final entries = rawCharacters is List
        ? rawCharacters
        : rawCharacters is Map
        ? rawCharacters.values
        : const <dynamic>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final draft = CharacterCardDraft.fromJsonMap(
        entry.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (draft != null && !draft.isEmpty) characters.add(draft);
    }

    return DirectorStoryDraft(
      title: title,
      outline: outline,
      authorNote: authorNote,
      characters: List.unmodifiable(characters),
    );
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
    String s(String key, [String? alias]) =>
        _stringValue(json[key] ?? (alias == null ? null : json[alias]));
    return CharacterCardDraft(
      name: s('name'),
      description: s('description'),
      personality: s('personality'),
      scenario: s('scenario'),
      firstMes: s('firstMes', 'first_mes'),
      exampleDialogs: s('exampleDialogs', 'example_dialogs'),
      systemPrompt: s('systemPrompt', 'system_prompt'),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'personality': personality,
    'scenario': scenario,
    'firstMes': firstMes,
    'exampleDialogs': exampleDialogs,
    'systemPrompt': systemPrompt,
  };

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
    text = text.replaceFirst(
      RegExp(r'^```(?:json)?\s*', caseSensitive: false),
      '',
    );
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

String _stringValue(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is num || value is bool) return value.toString().trim();
  // Models frequently return list-shaped fields (e.g. exampleDialogs as an
  // array of turns); flatten instead of silently dropping the content.
  if (value is List) {
    return value
        .map(_stringValue)
        .where((part) => part.isNotEmpty)
        .join('\n')
        .trim();
  }
  return '';
}

String _outlineValue(dynamic value) {
  if (value is String) return value.trim();
  if (value is! List) return '';
  final beats = <String>[];
  for (final entry in value) {
    var beat = '';
    if (entry is String || entry is num || entry is bool) {
      beat = entry.toString().trim();
    } else if (entry is Map) {
      final title = _stringValue(
        entry['title'] ?? entry['beat'] ?? entry['name'],
      );
      final detail = _stringValue(
        entry['summary'] ?? entry['description'] ?? entry['content'],
      );
      beat = [
        title,
        detail,
      ].where((part) => part.isNotEmpty).join(title.isEmpty ? '' : '：');
    }
    if (beat.isEmpty) continue;
    // Require whitespace after bullet/number markers (as parseOutlineBeats
    // does) so "-5℃" or "3.5小时" keeps its leading characters. 、 is a pure
    // enumeration mark, so it needs no trailing space.
    beat = beat
        .replaceFirst(RegExp(r'^[-*•]\s+'), '')
        .replaceFirst(RegExp(r'^\d+(?:[.)]\s+|、\s*)'), '')
        .trim();
    if (beat.isNotEmpty) beats.add('- $beat');
  }
  return beats.join('\n');
}
