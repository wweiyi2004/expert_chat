import 'dart:convert';

const kChatSkillMinConfidence = 0.6;

enum ChatSkillSource { prefix, model, fallback }

class TurnSkillMark {
  const TurnSkillMark({
    required this.id,
    required this.name,
    required this.source,
  });

  final String id;
  final String name;
  final ChatSkillSource source;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source.name,
  };

  factory TurnSkillMark.fromJson(Map<String, dynamic> json) => TurnSkillMark(
    id: (json['id'] as String? ?? '').trim(),
    name: (json['name'] as String? ?? '').trim(),
    source: ChatSkillSource.values.firstWhere(
      (value) => value.name == json['source'],
      orElse: () => ChatSkillSource.fallback,
    ),
  );
}

class ChatSkill {
  const ChatSkill({
    required this.id,
    required this.name,
    required this.when,
    required this.prompt,
    this.prefix = '',
    this.enabled = true,
    this.fallback = false,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String when;
  final String prompt;
  final String prefix;
  final bool enabled;
  final bool fallback;
  final bool builtIn;

  ChatSkill copyWith({
    String? name,
    String? when,
    String? prompt,
    String? prefix,
    bool? enabled,
    bool? fallback,
  }) => ChatSkill(
    id: id,
    name: name ?? this.name,
    when: when ?? this.when,
    prompt: prompt ?? this.prompt,
    prefix: prefix ?? this.prefix,
    enabled: enabled ?? this.enabled,
    fallback: fallback ?? this.fallback,
    builtIn: builtIn,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'when': when,
    'prompt': prompt,
    'prefix': prefix,
    'enabled': enabled,
    'fallback': fallback,
    'builtIn': builtIn,
  };

  factory ChatSkill.fromJson(Map<String, dynamic> json) => ChatSkill(
    id: (json['id'] as String? ?? '').trim(),
    name: (json['name'] as String? ?? '').trim(),
    when: (json['when'] as String? ?? '').trim(),
    prompt: json['prompt'] as String? ?? '',
    prefix: (json['prefix'] as String? ?? '').trim(),
    enabled: json['enabled'] as bool? ?? true,
    fallback: json['fallback'] as bool? ?? false,
    builtIn: json['builtIn'] as bool? ?? false,
  );
}

class ChatSkillCatalog {
  const ChatSkillCatalog(this.skills);
  final List<ChatSkill> skills;

  static ChatSkillCatalog factory({String generalPrompt = ''}) {
    final general = generalPrompt.trim().isEmpty
        ? '用简洁中文直接回答；先给结论；不确定就说明不确定。不要客套。'
        : generalPrompt.trim();
    return ChatSkillCatalog([
      ChatSkill(
        id: 'general',
        name: '通用',
        when: '闲聊、问答、无法归入其它种类时',
        prompt: general,
        prefix: '/通用',
        fallback: true,
        builtIn: true,
      ),
      const ChatSkill(
        id: 'writing',
        name: '写作',
        when: '润色、续写、改文体、写正文',
        prompt: '按用户指定文体改写或续写。未指定则用清晰现代中文。默认只输出正文，除非用户要求对照说明。不要擅自换风格或加标题。',
        prefix: '/写作',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'code',
        name: '代码',
        when: '写代码、改 bug、解释或审查代码',
        prompt: '先定位问题，再给最小改动。说明假设和风险。不要重写无关代码。代码放在带语言标记的 Markdown 围栏里。',
        prefix: '/代码',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'translate',
        name: '翻译',
        when: '翻译、对照译文、保留术语',
        prompt: '忠实原文语气与专有名词。只给译文，除非用户要求对照或注释。拿不准的词语标出来。',
        prefix: '/翻译',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'summarize',
        name: '总结',
        when: '摘要、要点、归纳长文',
        prompt: '用条目列出要点，不扩写、不评价。保留关键数字、名称和结论。',
        prefix: '/总结',
        builtIn: true,
      ),
    ]);
  }

  factory ChatSkillCatalog.decode(
    String? raw, {
    String legacySystemPrompt = '',
  }) {
    if (raw == null || raw.trim().isEmpty) {
      return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
      }
      final skills = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) ChatSkill.fromJson(item),
      ].where((s) => s.id.isNotEmpty).toList();
      return ChatSkillCatalog(skills).sanitize(
        legacySystemPrompt: legacySystemPrompt,
      );
    } catch (_) {
      return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    }
  }

  String encode() => jsonEncode([for (final s in skills) s.toJson()]);

  ChatSkill? skillById(String id) {
    for (final s in skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<ChatSkill> get enabled =>
      [for (final s in skills) if (s.enabled) s];

  ChatSkill get fallback {
    for (final s in skills) {
      if (s.fallback && s.enabled) return s;
    }
    return ChatSkillCatalog.factory().fallback;
  }

  ChatSkill? matchPrefix(String userText) {
    final value = userText.trimLeft();
    ChatSkill? best;
    var bestLen = 0;
    for (final s in enabled) {
      final prefix = s.prefix.trim();
      if (prefix.isEmpty) continue;
      if (value.startsWith(prefix) && prefix.length > bestLen) {
        best = s;
        bestLen = prefix.length;
      }
    }
    return best;
  }

  ChatSkillCatalog update(ChatSkill Function(ChatSkill skill) map) =>
      ChatSkillCatalog([for (final s in skills) map(s)]);

  ChatSkillCatalog sanitize({String legacySystemPrompt = ''}) {
    final factory = ChatSkillCatalog.factory(
      generalPrompt: legacySystemPrompt,
    );
    if (skills.isEmpty) return factory;
    final byId = <String, ChatSkill>{};
    for (final s in skills) {
      if (s.id.isEmpty) continue;
      byId[s.id] = s;
    }
    var list = byId.values.toList();
    final enabledFallbacks = [
      for (final s in list)
        if (s.fallback && s.enabled) s,
    ];
    if (enabledFallbacks.isEmpty) {
      final general = byId['general'] ?? factory.fallback;
      list = [
        for (final s in list)
          if (s.id == general.id)
            general.copyWith(enabled: true, fallback: true)
          else
            s.copyWith(fallback: false),
        if (!byId.containsKey(general.id))
          general.copyWith(enabled: true, fallback: true),
      ];
    } else if (enabledFallbacks.length > 1) {
      final keep = byId['general']?.fallback == true &&
              (byId['general']?.enabled ?? false)
          ? 'general'
          : enabledFallbacks.first.id;
      list = [
        for (final s in list)
          s.copyWith(fallback: s.id == keep && s.enabled),
      ];
    }
    return ChatSkillCatalog(list);
  }
}
