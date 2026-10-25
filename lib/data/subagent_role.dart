import 'dart:convert';
import 'agent_defaults.dart';

class SubagentRole {
  const SubagentRole({
    required this.id,
    required this.name,
    required this.when,
    required this.instructions,
    this.model = '',
    this.enabled = true,
    this.version = 1,
    this.source = '',
    this.requiredTools = const [],
    this.validation = '',
  });
  final String id, name, when, instructions, model;
  final bool enabled;
  final int version;
  final String source, validation;
  final List<String> requiredTools;
  SubagentRole copyWith({
    String? name,
    String? when,
    String? instructions,
    String? model,
    bool? enabled,
    int? version,
    String? source,
    List<String>? requiredTools,
    String? validation,
  }) => SubagentRole(
    id: id,
    name: name ?? this.name,
    when: when ?? this.when,
    instructions: instructions ?? this.instructions,
    model: model ?? this.model,
    enabled: enabled ?? this.enabled,
    version:
        version ??
        ((instructions != null && instructions != this.instructions) ||
                (when != null && when != this.when) ||
                (model != null && model != this.model) ||
                (requiredTools != null &&
                    requiredTools.join('\u0000') !=
                        this.requiredTools.join('\u0000'))
            ? this.version + 1
            : this.version),
    source: source ?? this.source,
    requiredTools: requiredTools ?? this.requiredTools,
    validation:
        validation ??
        ((instructions != null && instructions != this.instructions) ||
                (when != null && when != this.when) ||
                (model != null && model != this.model) ||
                (requiredTools != null &&
                    requiredTools.join('\u0000') !=
                        this.requiredTools.join('\u0000'))
            ? ''
            : this.validation),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'when': when,
    'instructions': instructions,
    'model': model,
    'enabled': enabled,
    'version': version,
    if (source.isNotEmpty) 'source': source,
    if (requiredTools.isNotEmpty) 'requiredTools': requiredTools,
    if (validation.isNotEmpty) 'validation': validation,
  };
  factory SubagentRole.fromJson(Map<String, dynamic> j) => SubagentRole(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    when: j['when'] as String? ?? '',
    instructions: j['instructions'] as String? ?? '',
    model: j['model'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
    version: j['version'] as int? ?? 1,
    source: j['source'] as String? ?? '',
    requiredTools: (j['requiredTools'] as List? ?? []).cast<String>(),
    validation: j['validation'] as String? ?? '',
  );
  static List<SubagentRole>? decode(String? value) {
    if (value == null) return null;
    return (jsonDecode(value) as List)
        .map((j) => SubagentRole.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
  }

  static List<SubagentRole> defaults([String legacy = '']) => [
    SubagentRole(
      id: 'general',
      name: '通用执行',
      when: '通用任务、综合处理，或没有其他合适角色',
      instructions: legacy.isNotEmpty ? legacy : AgentDefaults.child,
    ),
    const SubagentRole(
      id: 'coding',
      name: '代码实现',
      when: '实现功能、修改代码、修复已明确的问题',
      instructions:
          '${AgentDefaults.child}\n你负责代码实现。先理解已有结构，再做与任务直接相关的修改。遵循现有风格，以关键行为和失败场景选择必要检查，完成后报告证据。',
    ),
    const SubagentRole(
      id: 'review',
      name: '代码审查',
      when: '代码审计、寻找缺陷、评估安全性和实现质量',
      instructions:
          '${AgentDefaults.child}\n你负责代码审查。默认只读，除非任务明确允许修改。优先寻找跨操作、状态转换、数据身份与恢复路径的实际反例。以文件位置和证据说明缺陷、影响及修复建议，按严重程度排列。没有确认的风险标记为待核实，不把猜测写成事实。',
    ),
    const SubagentRole(
      id: 'research',
      name: '资料调研',
      when: '搜索资料、比较方案、核实事实或技术依据',
      instructions:
          '${AgentDefaults.child}\n你负责资料调研。使用已开放的资料和检索工具，优先原始资料，记录来源、日期和适用范围。核对引用是否支持结论的强度和范围，保留重要反例与限制。区分事实、推断和未验证内容。',
    ),
    const SubagentRole(
      id: 'testing',
      name: '测试排障',
      when: '复现故障、运行针对性测试、诊断错误原因',
      instructions:
          '${AgentDefaults.child}\n你负责测试与故障定位。以最小相关检查复现问题，优先覆盖用户可观察行为和关键规则，考虑操作组合与失败恢复。保留真实日志、复现条件与结论。未经任务授权不改变业务实现；无法执行的检查明确说明。',
    ),
    const SubagentRole(
      id: 'writing',
      name: '文档整理',
      when: '编写文档、整理说明、撰写报告和交付总结',
      instructions:
          '${AgentDefaults.child}\n你负责文档与报告。围绕读者需要组织材料，先给结论，使用简明准确的表达，保留必要来源和示例，校准论断范围与证据，不虚构执行结果。',
    ),
  ];
}

class SubagentAssignment {
  const SubagentAssignment({
    required this.role,
    required this.model,
    required this.reason,
  });
  final SubagentRole role;
  final String model, reason;
}
