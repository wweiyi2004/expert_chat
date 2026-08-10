/// Selectable prose-style preferences for director mode.
///
/// Each preset expands into enforceable instruction text that is merged into
/// generation prompts and the session author-note.
class DirectorProseStyle {
  const DirectorProseStyle({
    required this.id,
    required this.label,
    required this.constraint,
    this.subtitle = '',
  });

  final String id;
  final String label;

  /// Short hint under the chip.
  final String subtitle;

  /// Full style paragraph injected once into the story's persistent context.
  final String constraint;

  static const noneId = 'none';

  static const presets = <DirectorProseStyle>[
    DirectorProseStyle(
      id: 'jp_ln',
      label: '日本轻小说',
      subtitle: '对白驱动·一场戏',
      constraint:
          '文风必须接近日本轻小说（日轻），不是中国网文流水账：\n'
          '1) 对白驱动：对白约占篇幅一半以上；叙述用短句；情绪用动作、口吻与停顿表现，禁止说明文式心理总结。\n'
          '2) 标点：角色对白统一用「」；嵌套引用可用『』；内心吐槽/独白可用（）；不同角色换段。\n'
          '3) 场景公式：开场 1–2 句定场 → 对白与互动推进 → 收束带小钩子；禁止大段世界观说明书开场。\n'
          '4) 角色：每人有可辨口癖/语气；可轻标签化（傲娇、天然、吐槽役等），但勿全员同一种腔。\n'
          '5) 节奏：先日常/气氛再卷入异常；每节只推进一场戏的一个冲突点，忌信息密网文连射与章末大总结。\n'
          '6) 未单独选择叙事视角时，默认贴近主角的第三人称有限视角；禁止论文腔、文言堆砌与无节制网梗。',
    ),
    DirectorProseStyle(
      id: 'classical_cn',
      label: '古典章回',
      subtitle: '说书感·起承转合',
      constraint:
          '文风必须接近中国古典章回体白话小说：可用简短场景起笔与收束；'
          '叙述带说书人的稳重节奏，善用白描与对仗感，但不要强行每段都对偶；'
          '对话可略文雅，仍需可懂；禁止日轻口癖与现代网络用语。',
    ),
    DirectorProseStyle(
      id: 'wenyan',
      label: '文言文',
      subtitle: '文言叙事',
      constraint:
          '全文（含对白，除非导演另示）必须以浅近文言文书写：用词典雅凝练，句式偏短；'
          '可适当用「曰」「遂」「乃」等，但避免生造难懂僻字堆砌；'
          '禁止白话口语、网络用语与日轻吐槽腔。',
    ),
    DirectorProseStyle(
      id: 'web_novel',
      label: '现代网文',
      subtitle: '强钩子·爽点节奏',
      constraint:
          '文风接近当代网络小说：段落短、信息密度高、章末可留钩子；'
          '冲突推进明确，少空泛风景描写；对白生活化；'
          '可有适度爽感，但不得违背导演的硬性禁忌与慢热/克制要求。',
    ),
    DirectorProseStyle(
      id: 'wuxia',
      label: '武侠',
      subtitle: '江湖气·招式意象',
      constraint:
          '文风偏武侠：动作带招式意象与空间感，人物有江湖气与规矩感；'
          '可用适度古典词汇，但主体仍为通顺现代白话（非纯文言）；'
          '避免日轻萌系口癖与科幻术语，除非导演明确要求混搭。',
    ),
    DirectorProseStyle(
      id: 'epic_fantasy',
      label: '史诗奇幻',
      subtitle: '宏大场景·庄重',
      constraint:
          '文风偏西方史诗奇幻中译调性：场景与世界观可略宏大，语气庄重；'
          '专名保持一致；少用现代口语与网络梗；'
          '描写可稍丰，但每节仍须推进当前大纲节拍，禁止无目的的风光巡礼。',
    ),
    DirectorProseStyle(
      id: 'hard_sf',
      label: '硬核科幻',
      subtitle: '技术细节·克制',
      constraint:
          '文风偏硬科幻：技术与设定表述力求自洽，少玄学比喻；'
          '情绪克制，逻辑优先；对白可冷静专业；'
          '禁止无依据的魔法化解决与日轻喜剧节奏，除非导演允许。',
    ),
    DirectorProseStyle(
      id: 'realism',
      label: '现实主义',
      subtitle: '生活质感·克制',
      constraint:
          '文风现实主义：细节生活化、因果可信，避免夸张戏剧与超自然；'
          '心理与对话贴近真实人物；少用华丽辞藻与类型文套路开挂。',
    ),
    DirectorProseStyle(
      id: 'mystery_cool',
      label: '克制悬疑',
      subtitle: '信息控制·不剧透',
      constraint:
          '文风克制悬疑：信息投放有控制，多暗示少直说；'
          '禁止提前揭晓核心真相与凶手；氛围冷感，避免无意义的血腥堆砌与尬萌。',
    ),
    DirectorProseStyle(
      id: 'first_person',
      label: '第一人称',
      subtitle: '限知视角',
      constraint:
          '必须使用第一人称叙事（「我」）；仅能写叙述者所知所见所感；'
          '禁止全知视角跳转与上帝旁白；其他角色内心只能通过观察与对白暗示。',
    ),
  ];

  static DirectorProseStyle? byId(String id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Mutual-exclusion group. Only presets controlling the same dimension are
  /// exclusive. Point of view is independent from prose register, so a
  /// first-person light novel remains a valid combination.
  /// Empty = combinable with anything.
  String get exclusiveGroup {
    switch (id) {
      case 'jp_ln':
      case 'wenyan':
      case 'web_novel':
      case 'classical_cn':
        return 'register';
      case 'first_person':
        return 'perspective';
      default:
        return '';
    }
  }

  /// Toggle [id] in [selected], dropping any other style in the same
  /// [exclusiveGroup].
  static Set<String> toggleSelection(Set<String> selected, String id) {
    final next = Set<String>.from(selected);
    if (next.contains(id)) {
      next.remove(id);
      return next;
    }
    final incoming = byId(id);
    final group = incoming?.exclusiveGroup ?? '';
    if (group.isNotEmpty) {
      next.removeWhere((other) {
        final g = byId(other)?.exclusiveGroup ?? '';
        return g == group;
      });
    }
    next.add(id);
    return next;
  }

  /// Merge selected style constraints with free-form requirements.
  static String mergeRequirements({
    required Iterable<String> styleIds,
    String freeform = '',
  }) {
    // Resolve exclusivity even if callers pass a raw multi-select set.
    var resolved = <String>{};
    for (final id in styleIds) {
      resolved = toggleSelection(resolved, id);
    }
    final parts = <String>[];
    for (final id in resolved) {
      final style = byId(id);
      if (style == null) continue;
      parts.add('【文风偏好·${style.label}】\n${style.constraint}');
    }
    final extra = freeform.trim();
    if (extra.isNotEmpty) {
      parts.add('【全书硬约束】\n$extra');
    }
    if (parts.length > 1) {
      parts.insert(
        0,
        '【约束解释】\n'
        '全书硬约束高于文风偏好；叙事视角与文体分别执行。'
        '兼容的文风可融合，若同一细节仍有冲突，以用户写得更具体的要求为准。',
      );
    }
    return parts.join('\n\n');
  }
}
