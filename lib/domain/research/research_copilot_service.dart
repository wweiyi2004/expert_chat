import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'command_risk.dart';

class CommandProposal {
  const CommandProposal({
    required this.id,
    required this.diagnosis,
    required this.command,
    required this.risk,
    required this.evidence,
    required this.impacts,
    required this.nonImpacts,
    this.rollback,
    this.rawModelText,
    this.parseOk = true,
  });

  final String id;
  final String diagnosis;
  final String command;
  final CommandRisk risk;
  final List<String> evidence;
  final List<String> impacts;
  final List<String> nonImpacts;
  final String? rollback;

  /// When [parseOk] is false, only [rawModelText]/[diagnosis] should be shown.
  final String? rawModelText;
  final bool parseOk;

  bool get canOfferExecute =>
      parseOk && command.trim().isNotEmpty && risk != CommandRisk.blocked;
}

/// Immutable token proving the user confirmed a proposal for a given connection.
class ApprovedCommand {
  const ApprovedCommand({
    required this.proposalId,
    required this.hostId,
    required this.connectionGeneration,
    required this.command,
    required this.risk,
    required this.cwdHint,
  });

  final String proposalId;
  final String hostId;
  final int connectionGeneration;
  final String command;
  final CommandRisk risk;
  final String cwdHint;
}

/// Only this type can be written to the interactive shell by the executor.
class ApprovedCommandExecutor {
  const ApprovedCommandExecutor();

  /// Writes [approved.command] + newline. Caller must validate generation.
  void execute({
    required void Function(List<int> data) writeToShell,
    required ApprovedCommand approved,
    required String activeHostId,
    required int activeConnectionGeneration,
  }) {
    if (approved.hostId != activeHostId ||
        approved.connectionGeneration != activeConnectionGeneration) {
      throw StateError('审批已失效（主机或连接已变更）');
    }
    if (approved.command.trim().isEmpty) {
      throw StateError('命令为空');
    }
    final payload = approved.command.endsWith('\n')
        ? approved.command
        : '${approved.command}\n';
    // Must be UTF-8 bytes — codeUnits are UTF-16 and garble non-ASCII paths.
    writeToShell(utf8.encode(payload));
  }
}

class ResearchCopilotService {
  ResearchCopilotService(this._llm, {CommandRiskClassifier? classifier})
    : _classifier = classifier ?? const CommandRiskClassifier();

  final LlmProvider _llm;
  final CommandRiskClassifier _classifier;

  static const systemPrompt = '''
你是科研服务器终端助手。你可以：
1) 根据用户目标（自然语言）设计一条可执行 bash 命令；
2) 结合可选的终端输出片段做诊断与下一步建议。
你只能建议命令，不能声称已执行任何操作。
只输出一个 JSON 对象（不要 Markdown 代码围栏），字段：
{
  "diagnosis": "简要说明你对用户目标/终端状态的理解",
  "command": "一条可在 bash 执行的完整命令（不要解释性前缀）",
  "risk": "low|medium|high|blocked",
  "evidence": ["依据1", "依据2"],
  "impacts": ["执行后会发生什么"],
  "nonImpacts": ["不会做什么"],
  "rollback": "可选回滚建议或 null"
}
若信息不足，command 可为空字符串，risk 用 low，diagnosis 说明缺什么。
禁止建议包含明文密钥或下载管道执行未知脚本。
优先满足用户明确目标；终端片段只作上下文，不要忽略用户意图。
''';

  Future<CommandProposal> analyze({
    required LlmConfig config,
    required String transcriptPreview,
    required String proposalId,
    String? userGoal,
    CancelToken? cancelToken,
  }) async {
    final goal = userGoal?.trim() ?? '';
    final user = StringBuffer();
    if (goal.isNotEmpty) {
      user
        ..writeln('用户目标（请据此设计命令）：')
        ..writeln('-----')
        ..writeln(goal)
        ..writeln('-----');
    }
    if (transcriptPreview.trim().isNotEmpty) {
      user
        ..writeln('以下是用户确认发送的终端片段（已脱敏，可作上下文）：')
        ..writeln('-----')
        ..writeln(transcriptPreview)
        ..writeln('-----');
    }
    if (goal.isNotEmpty && transcriptPreview.trim().isNotEmpty) {
      user.writeln('请结合用户目标与终端上下文，给出一条最合适的命令。');
    } else if (goal.isNotEmpty) {
      user.writeln('请根据用户目标给出一条最合适的 bash 命令。');
    } else {
      user.writeln('请给出一条最有帮助的下一步命令建议。');
    }

    final text = StringBuffer();
    await for (final chunk in _llm.streamChat(
      config: config,
      messages: [
        LlmRequestMessage(role: MessageRole.system, content: systemPrompt),
        LlmRequestMessage(role: MessageRole.user, content: user.toString()),
      ],
      thinking: false,
      cancelToken: cancelToken,
    )) {
      if (chunk.contentDelta != null) text.write(chunk.contentDelta);
    }

    final raw = text.toString().trim();
    final parsed = _tryParseJson(raw);
    if (parsed == null) {
      return CommandProposal(
        id: proposalId,
        diagnosis: raw.isEmpty ? '模型未返回有效内容' : raw,
        command: '',
        risk: CommandRisk.blocked,
        evidence: const [],
        impacts: const [],
        nonImpacts: const [],
        rawModelText: raw,
        parseOk: false,
      );
    }

    final command = (parsed['command'] as String?)?.trim() ?? '';
    final modelRisk =
        CommandRisk.tryParse(parsed['risk'] as String?) ?? CommandRisk.medium;
    final local = _classifier.classify(command);
    final finalRisk = command.isEmpty
        ? CommandRisk.blocked
        : CommandRisk.max(modelRisk, local.risk);

    List<String> strList(dynamic v) {
      if (v is! List) return const [];
      return [
        for (final e in v)
          if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }

    final evidence = strList(parsed['evidence']);
    // Merge local reasons into evidence for transparency.
    final mergedEvidence = [
      ...evidence,
      for (final r in local.reasons) '本地规则：$r',
    ];

    return CommandProposal(
      id: proposalId,
      diagnosis: (parsed['diagnosis'] as String?)?.trim().isNotEmpty == true
          ? (parsed['diagnosis'] as String).trim()
          : '（无诊断）',
      command: command,
      risk: finalRisk,
      evidence: mergedEvidence,
      impacts: strList(parsed['impacts']),
      nonImpacts: strList(parsed['nonImpacts']),
      rollback: (parsed['rollback'] as String?)?.trim(),
      rawModelText: raw,
      parseOk: true,
    );
  }

  /// Recompute risk after the user edits the command.
  CommandProposal withEditedCommand(CommandProposal base, String newCommand) {
    final local = _classifier.classify(newCommand);
    // Keep model risk floor from original if parse was ok; else local only.
    final modelFloor = base.parseOk ? base.risk : CommandRisk.low;
    // When editing, re-classify fully from local + previous model label loosely:
    final risk = newCommand.trim().isEmpty
        ? CommandRisk.blocked
        : CommandRisk.max(
            local.risk,
            modelFloor == CommandRisk.blocked ? CommandRisk.high : modelFloor,
          );
    return CommandProposal(
      id: base.id,
      diagnosis: base.diagnosis,
      command: newCommand,
      risk: risk,
      evidence: [
        ...base.evidence.where((e) => !e.startsWith('本地规则：')),
        for (final r in local.reasons) '本地规则：$r',
      ],
      impacts: base.impacts,
      nonImpacts: base.nonImpacts,
      rollback: base.rollback,
      rawModelText: base.rawModelText,
      parseOk: base.parseOk && newCommand.trim().isNotEmpty,
    );
  }

  static Map<String, dynamic>? _tryParseJson(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      s = s.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      s = s.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final obj = jsonDecode(s.substring(start, end + 1));
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return Map<String, dynamic>.from(obj);
      return null;
    } catch (_) {
      return null;
    }
  }
}
