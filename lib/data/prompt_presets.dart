import 'dart:convert';

class PromptPreset {
  const PromptPreset({
    required this.id,
    required this.name,
    required this.prompt,
    this.ownerId = 'local',
    this.updatedAt = 0,
  });
  final String id;
  final String name;
  final String prompt;
  final String ownerId;
  final int updatedAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'ownerId': ownerId,
    'updatedAt': updatedAt,
  };
  factory PromptPreset.fromJson(Map<String, dynamic> json) => PromptPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    prompt: json['prompt'] as String,
    ownerId: json['ownerId'] as String? ?? 'local',
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );
}

class PromptPresets {
  const PromptPresets({this.items = defaults, this.activeId});
  static const storageKey = 'promptPresetsV1';
  static const defaults = [
    PromptPreset(
      id: 'concise',
      name: '简洁助手',
      prompt: '直接回答问题，先给结论，再给必要的解释。默认使用简洁中文，明确指出不确定之处。',
    ),
    PromptPreset(
      id: 'patient',
      name: '耐心讲解',
      prompt: '循序渐进地解释问题，先判断用户已有知识，再用具体例子讲清关键概念。必要时提出一个检查理解的问题。',
    ),
    PromptPreset(
      id: 'research',
      name: '科研伙伴',
      prompt: '协助文献阅读、实验设计与代码分析。区分已知事实、假设和推断，保留来源与验证步骤，不编造文献、数据或执行结果。',
    ),
  ];
  final List<PromptPreset> items;
  final String? activeId;
  PromptPreset? get active {
    for (final item in items) {
      if (item.id == activeId) return item;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'activeId': activeId,
    'items': [for (final item in items) item.toJson()],
  };
  static PromptPresets decode(String? raw, {String legacyPrompt = ''}) {
    if (raw == null) {
      return PromptPresets(
        items: [
          if (legacyPrompt.trim().isNotEmpty)
            PromptPreset(id: 'legacy', name: '原有提示词', prompt: legacyPrompt),
          ...defaults,
        ],
      );
    }
    try {
      final json = jsonDecode(raw) as Map;
      final items = <PromptPreset>[];
      for (final value in json['items'] as List) {
        final item = PromptPreset.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
        if (item.id.isNotEmpty &&
            item.name.trim().isNotEmpty &&
            !items.any((p) => p.id == item.id)) {
          items.add(item);
        }
      }
      final active = json['activeId'] as String?;
      return PromptPresets(
        items: items,
        activeId: items.any((p) => p.id == active) ? active : null,
      );
    } catch (_) {
      return decode(null, legacyPrompt: legacyPrompt);
    }
  }
}
