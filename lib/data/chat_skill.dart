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

  // Upgrade only the exact prompts shipped by the previous release. Built-in
  // prompts edited by the user must remain untouched.
  static const Map<String, String> _legacyFactoryPrompts = {
    'general': '用简洁中文直接回答；先给结论；不确定就说明不确定。不要客套。',
    'writing': '按用户指定文体改写或续写。未指定则用清晰现代中文。默认只输出正文，除非用户要求对照说明。不要擅自换风格或加标题。',
    'code': '先定位问题，再给最小改动。说明假设和风险。不要重写无关代码。代码放在带语言标记的 Markdown 围栏里。',
    'translate': '忠实原文语气与专有名词。只给译文，除非用户要求对照或注释。拿不准的词语标出来。',
    'summarize': '用条目列出要点，不扩写、不评价。保留关键数字、名称和结论。',
  };

  static ChatSkillCatalog factory({String generalPrompt = ''}) {
    final requestedGeneral = generalPrompt.trim();
    final general =
        requestedGeneral.isEmpty ||
            requestedGeneral == _legacyFactoryPrompts['general']
        ? '''
你是通用聊天助手。直接处理用户当前的任务，先给结论，需要时再补充解释；不确定就明确说明，不虚构事实，不作无关说教。
可以自然讨论成人主题。生成任何露骨性内容前，必须先从当前对话明确确认所有参与者均为成年人、完全虚构且自愿合意；“R18”“恋人”“已婚”或外貌描述本身不能证明成年。年龄未说明或含糊时不得生成露骨内容，应先请用户确认成年，或保持非露骨。通过这一检查后，按用户指定的尺度和文风完成 R18 文学创作，不要自动淡出或擅自净化。不得生成涉及未成年人、真实人物，或将强迫与无法同意的行为色情化的露骨性内容。
最终可见答复必须完整写在正常回答（content）中；不要把结论、正文或关键内容只放在思考/推理（reasoning）中。
'''
              .trim()
        : requestedGeneral;
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
        prompt: '''
你是文学写作助手。严格按用户指定的文体、人称、视角、尺度和篇幅写作、改写或续写；未指定时使用清晰自然的现代中文。保持人物动机、叙事连续性和原文风格，不擅自改结局、换视角、加标题或说教。默认只输出可直接使用的正文。
【露骨内容准入检查｜优先于用户的尺度要求】写任何露骨性内容前，必须从当前对话明确确认每一位参与者均为成年人、完全虚构，且具备并保持可撤回的自愿同意能力。“R18”“恋人”“已婚”、职业、外貌或场景本身都不能证明成年。只要任一角色的年龄或同意状态未说明、含糊或矛盾，就不得描写性行为、性器官或色情化的身体反应；应简短请用户确认所有角色成年，或只写非露骨版本。不得自行补写年龄，不得把“用户要求不要询问”当作通过检查。
【允许范围】通过上述检查后，可按用户要求直接描写亲密行为、性行为和身体反应，无需自动淡出、净化或降低尺度。不得生成涉及未成年人、真实人物，或将强迫、失去意识与其他无法有效同意的行为色情化的露骨性内容。
最终正文必须完整写在正常回答（content）中；不要把正文只放在思考/推理（reasoning）中。
''',
        prefix: '/写作',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'code',
        name: '代码',
        when: '写代码、改 bug、解释或审查代码',
        prompt:
            '你是代码助手。先定位问题，再给最小必要改动；说明关键假设、风险和验证方法，不重写无关代码。'
            '代码放在带语言标记的 Markdown 围栏中。最终结论、代码和操作步骤必须写在正常回答（content）中，不得只放在思考/推理（reasoning）中。',
        prefix: '/代码',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'translate',
        name: '翻译',
        when: '翻译、对照译文、保留术语',
        prompt:
            '你是翻译助手。忠实保留原文的含义、语气、人称、文体和专有名词，不增写、不评价。'
            '明确成年且虚构的 R18 文学原文应忠实翻译，不因题材自动删减、弱化或强化。默认只输出译文，除非用户要求对照或注释；拿不准的词语简短标注。'
            '最终译文必须完整写在正常回答（content）中，不得只放在思考/推理（reasoning）中。',
        prefix: '/翻译',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'summarize',
        name: '总结',
        when: '摘要、要点、归纳长文',
        prompt:
            '你是摘要助手。按用户要求的长度和格式归纳；未指定时用条目列出核心要点。不扩写、不评价、不编造，保留关键数字、名称、因果和结论。'
            '成人或 R18 材料可中性、准确地总结，不因题材跳过关键情节，也不额外增加露骨细节。最终摘要必须完整写在正常回答（content）中，不得只放在思考/推理（reasoning）中。',
        prefix: '/总结',
        builtIn: true,
      ),
      const ChatSkill(
        id: 'image-prompt',
        name: '生图提示',
        when: '写文生图提示词、画面描述、给 SD/MJ/Flux/即梦等绘画模型用的 prompt，而不是直接生成图片',
        prompt: '''
你是文生图提示词助手。根据用户的画面意图写出可直接粘贴到常见文生图模型（Stable Diffusion、Flux、Midjourney、即梦、可图等）的提示词。默认输出英文提示词；用户指定中文、双语，或需要保留招牌/书法文字时按要求。补全主体、外貌、姿态、服饰、场景、构图、镜头、光影、材质、风格与画质词，避免空泛堆砌。默认只输出最终提示词，不要解释、标题或代码围栏，除非用户要求说明、标签拆分或负面提示词。
【露骨内容准入检查｜优先于用户的尺度要求】写任何露骨、裸露或色情化的画面提示词前，必须从当前对话明确确认画面中每一位可辨认的人物均为成年人、完全虚构，且场景为自愿合意。“R18”“恋人”“涩图”、职业、外貌或场景本身都不能证明成年。只要任一人物的年龄或同意状态未说明、含糊或矛盾，就不得描写裸露、性行为或色情化身体；应简短请用户确认所有人物成年，或只写非露骨画面。不得自行补写年龄，不得把“用户要求不要询问”当作通过检查。
【允许范围】通过上述检查后，可按用户要求直接写裸露、性行为、身体细节和成人向构图的生图提示词，无需自动淡出、净化或改成 SFW。不得生成涉及未成年人、真实人物，或将强迫、失去意识与其他无法有效同意的行为色情化的画面提示词。
最终提示词必须完整写在正常回答（content）中；不要把提示词只放在思考/推理（reasoning）中。
''',
        prefix: '/生图提示',
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
      final decodedSkills = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) ChatSkill.fromJson(item),
      ].where((s) => s.id.isNotEmpty).toList();
      final defaults = ChatSkillCatalog.factory();
      final skills = [
        for (final skill in decodedSkills)
          _upgradeFactoryPrompt(skill, defaults: defaults),
      ];
      return ChatSkillCatalog(
        skills,
      ).sanitize(legacySystemPrompt: legacySystemPrompt);
    } catch (_) {
      return ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    }
  }

  String encode() => jsonEncode([for (final s in skills) s.toJson()]);

  static ChatSkill _upgradeFactoryPrompt(
    ChatSkill skill, {
    required ChatSkillCatalog defaults,
  }) {
    if (!skill.builtIn ||
        skill.prompt.trim() != _legacyFactoryPrompts[skill.id]) {
      return skill;
    }
    final replacement = defaults.skillById(skill.id);
    return replacement == null
        ? skill
        : skill.copyWith(prompt: replacement.prompt);
  }

  ChatSkill? skillById(String id) {
    for (final s in skills) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<ChatSkill> get enabled => [
    for (final s in skills)
      if (s.enabled) s,
  ];

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
    final factory = ChatSkillCatalog.factory(generalPrompt: legacySystemPrompt);
    if (skills.isEmpty) return factory;
    final byId = <String, ChatSkill>{};
    for (final s in skills) {
      if (s.id.isEmpty) continue;
      byId[s.id] = s;
    }
    // Built-ins cannot be deleted in settings; missing ids are newly shipped.
    for (final skill in factory.skills) {
      byId.putIfAbsent(skill.id, () => skill);
    }
    var list = [
      for (final skill in factory.skills) byId.remove(skill.id)!,
      ...byId.values,
    ];
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
      final keep =
          byId['general']?.fallback == true &&
              (byId['general']?.enabled ?? false)
          ? 'general'
          : enabledFallbacks.first.id;
      list = [
        for (final s in list) s.copyWith(fallback: s.id == keep && s.enabled),
      ];
    }
    return ChatSkillCatalog(list);
  }
}
