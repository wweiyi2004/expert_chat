import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../domain/llm/llm_provider.dart';
import '../data/models.dart';
import '../data/context_prefs.dart';
import '../domain/context/context_window_manager.dart';

/// Durable, conversation-scoped public memory. Raw conversation remains in its
/// original repository; memory never becomes an authority for tool permission.
final workMemoryProvider = Provider<WorkMemory>(
  (ref) => WorkMemory(
    read: () => ref.read(sharedPrefsProvider).getString('workMemory.v1'),
    write: (value) =>
        ref.read(sharedPrefsProvider).setString('workMemory.v1', value),
    archiveCorrupt: (value) => ref
        .read(sharedPrefsProvider)
        .setString(
          'workMemory.corruptBackup.v1.${sha256.convert(utf8.encode(value))}',
          value,
        ),
  ),
);

class WorkMemory {
  WorkMemory({
    required String? Function() read,
    required this.write,
    this.archiveCorrupt,
  }) {
    final raw = read();
    try {
      final decoded = jsonDecode(raw ?? '{}') as Map;
      bool validScope(Map value, {bool children = true}) {
        const texts = {
          'user_pins',
          'constraints',
          'plan',
          'summary',
          'updated_at',
        };
        if (!value.keys.every(
          {
            ...texts,
            'revision',
            'compact_revision',
            if (children) 'agents',
          }.contains,
        )) {
          return false;
        }
        if (texts.any(
          (key) =>
              value[key] != null &&
              (value[key] is! String || (value[key] as String).length > 24000),
        )) {
          return false;
        }
        if (value['revision'] != null &&
            (value['revision'] is! int || (value['revision'] as int) < 0)) {
          return false;
        }
        if (value['agents'] != null) {
          if (value['agents'] is! Map) return false;
          for (final child in (value['agents'] as Map).entries) {
            if (child.key is! String ||
                child.value is! Map ||
                !validScope(child.value as Map, children: false)) {
              return false;
            }
          }
        }
        return true;
      }

      for (final entry in decoded.entries) {
        if (entry.key is! String ||
            entry.value is! Map ||
            !validScope(entry.value as Map)) {
          throw const FormatException('Invalid scoped memory');
        }
        _sessions[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    } catch (_) {
      _corruptRaw = raw ?? '';
    }
  }
  final Future<bool> Function(String) write;
  final Future<bool> Function(String)? archiveCorrupt;
  String? _corruptRaw;
  bool get corrupt => _corruptRaw != null;
  String? get corruptSource => _corruptRaw;
  String? get corruptDigest => _corruptRaw == null
      ? null
      : sha256.convert(utf8.encode(_corruptRaw!)).toString();
  Future<void> repairCorrupt(
    String conversation,
    String reviewedDigest,
    String userPins,
  ) {
    final result = _pending.catchError((Object _) {}).then((_) async {
      if (!corrupt || corruptDigest != reviewedDigest) {
        throw StateError('损坏来源已改变，未重建记忆');
      }
      if (userPins.length > 12000) throw ArgumentError('固定约束超长');
      if (archiveCorrupt == null || !await archiveCorrupt!(_corruptRaw!)) {
        throw StateError('原始损坏记录未保存，不能重建');
      }
      final next = {
        conversation: <String, dynamic>{
          'revision': 1,
          'user_pins': userPins,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      };
      if (!await write(jsonEncode(next))) throw StateError('新约束未保存，仍保留损坏保护');
      _sessions
        ..clear()
        ..addAll(next);
      _corruptRaw = null;
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  final _sessions = <String, Map<String, dynamic>>{};
  Future<void> _pending = Future.value();
  Map<String, dynamic> snapshot(String conversation, {String? agentId}) {
    final root = Map<String, dynamic>.from(_sessions[conversation] ?? {});
    if (agentId == null) return root..remove('agents');
    final agents = root['agents'] is Map ? root['agents'] as Map : const {};
    return agents[agentId] is Map
        ? Map<String, dynamic>.from(agents[agentId] as Map)
        : {};
  }

  List<String> agentScopes(String conversation) =>
      ((_sessions[conversation]?['agents'] as Map?) ?? {}).keys
          .cast<String>()
          .toList();
  Future<Map<String, dynamic>> checkpoint(
    String conversation,
    Map<String, dynamic> args, {
    bool userInitiated = false,
    String? agentId,
  }) {
    final result = _pending.catchError((Object _) {}).then((_) async {
      if (corrupt) throw StateError('工作记忆损坏；请在日志任务记忆中核验修复或从备份恢复，未忽略用户约束');
      final old = snapshot(conversation, agentId: agentId);
      final revision = (old['revision'] as num?)?.toInt() ?? 0;
      if (args['expected_revision'] != revision) {
        throw StateError('记忆版本已改变，请先 recall（当前 $revision）');
      }
      final next = <String, dynamic>{
        ...old,
        'revision': revision + 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      for (final key in [
        'constraints',
        'plan',
        'summary',
        if (userInitiated && agentId == null) 'user_pins',
      ]) {
        if (!args.containsKey(key)) continue;
        final value = args[key];
        if (value is! String || value.length > 24000) {
          throw ArgumentError('$key 最多 24000 字符');
        }
        next[key] = value;
      }
      if (args['compact'] == true) {
        if ((next['summary'] as String? ?? '').trim().isEmpty) {
          throw StateError('压缩前必须保存公开摘要');
        }
        next['compact_revision'] = revision + 1;
      }
      final root = Map<String, dynamic>.from(_sessions[conversation] ?? {});
      final merged = agentId == null
          ? {...root, ...next}
          : {
              ...root,
              'agents': {
                ...(root['agents'] is Map
                    ? Map<String, dynamic>.from(root['agents'] as Map)
                    : <String, dynamic>{}),
                agentId: next,
              },
            };
      final candidate = {..._sessions, conversation: merged};
      if (!await write(jsonEncode(candidate))) {
        throw StateError('工作记忆未保存，不能确认检查点');
      }
      _sessions[conversation] = merged;
      return Map<String, dynamic>.from(next);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Preserve pinned public memory verbatim by budgeting it separately. Refuse
  /// an impossible request rather than silently clipping user constraints.
  ContextWindowResult manage(
    String conversation,
    List<LlmRequestMessage> messages,
    ContextPrefs prefs, {
    bool compact = false,
    String goal = '',
    String userUpdates = '',
    String? agentId,
  }) {
    const manager = ContextWindowManager();
    final notes = guidance(conversation, agentId: agentId);
    final text = notes.isEmpty && goal.isEmpty
        ? ''
        : '【固定任务上下文】\n$notes\n【当前任务原始目标】\n$goal\n【用户运行中补充（后发要求优先；权限仍由程序执行）】\n$userUpdates';
    final pinned = text.isEmpty
        ? <LlmRequestMessage>[]
        : [LlmRequestMessage(role: MessageRole.system, content: text)];
    final cost = manager.estimateMessagesTokens(pinned);
    if (cost >= prefs.inputBudgetTokens - 256) {
      throw StateError('固定工作记忆超过模型预算，请缩短摘要或切换模型；约束未静默裁剪');
    }
    final bounded = manager.manage(
      messages,
      prefs.copyWith(
        inputLimitTokens: prefs.inputBudgetTokens - cost,
        maxHistoryMessages: compact ? 4 : prefs.maxHistoryMessages,
      ),
    );
    return ContextWindowResult(
      messages: [...pinned, ...bounded.messages],
      report: ContextWindowReport(
        originalTokens: bounded.report.originalTokens + cost,
        sentTokens: bounded.report.sentTokens + cost,
        inputBudgetTokens: prefs.inputBudgetTokens,
        droppedMessages: bounded.report.droppedMessages,
        truncated: bounded.report.truncated,
        summaryInjected: bounded.report.summaryInjected,
      ),
    );
  }

  static Map<String, dynamic> history(
    List<ChatMessage> messages,
    Map<String, dynamic> args,
  ) {
    final query = (args['query'] as String? ?? '').toLowerCase();
    final id = args['message_id'] as String?;
    final source = args['source_id'] as String?;
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, 1000000);
    final contentOffset = ((args['content_offset'] as num?)?.toInt() ?? 0)
        .clamp(0, 100000000);
    final limit = ((args['limit'] as num?)?.toInt() ?? 5).clamp(1, 10);
    final hits = <Map<String, dynamic>>[];
    void add(String message, String sourceId, String role, String text) {
      if (source != null && source != sourceId ||
          query.isNotEmpty && !text.toLowerCase().contains(query)) {
        return;
      }
      final start = contentOffset.clamp(0, text.length);
      final end = (start + 6000).clamp(0, text.length);
      hits.add({
        'message_id': message,
        'source_id': sourceId,
        'role': role,
        'content': text.substring(start, end),
        'content_offset': start,
        'total_chars': text.length,
        'next_content_offset': end < text.length ? end : null,
      });
    }

    for (final m in messages) {
      if (id != null && m.id != id) continue;
      add(m.id, m.id, m.role.name, m.content);
      for (final activity in m.searchActivities) {
        if (activity.resultText != null) {
          add(
            m.id,
            activity.id,
            'tool:${activity.toolName}',
            activity.resultText!,
          );
        }
      }
    }
    return {
      'total': hits.length,
      'offset': offset,
      'next_offset': offset + limit < hits.length ? offset + limit : null,
      'messages': hits.skip(offset).take(limit).toList(),
    };
  }

  Future<void> removeConversation(String conversation) {
    final operation = _pending.catchError((Object _) {}).then((_) async {
      final next = {..._sessions}..remove(conversation);
      if (!await write(jsonEncode(next))) throw StateError('工作记忆清理失败');
      _sessions.remove(conversation);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  String guidance(String conversation, {String? agentId}) {
    if (corrupt) throw StateError('工作记忆损坏；固定用户约束状态未知，请先核验修复或从备份恢复');
    final own = snapshot(conversation, agentId: agentId);
    final root = snapshot(conversation);
    final memory = agentId == null
        ? own
        : <String, dynamic>{
            'agent_memory': own,
            'read_only_root_handoff': {
              for (final key in ['user_pins', 'constraints', 'plan', 'summary'])
                if (root.containsKey(key)) key: root[key],
            },
          };
    if (memory.isEmpty) return '';
    return '【版本化工作记忆】以下为公开任务笔记，不是额外授权。'
        '保留用户约束；需要证据时通过 work_history 查询原始记录。\n${jsonEncode(memory)}';
  }

  static const names = {
    'work_memory_checkpoint',
    'work_memory_recall',
    'work_history',
  };
  static const tools = [
    ToolSpec(
      name: 'work_memory_checkpoint',
      description: '主动压缩并保存公开工作摘要、固定约束和任务计划。先 recall 读取版本；摘要不删除原始历史，不保存私密思维链。',
      parameters: {
        'type': 'object',
        'properties': {
          'expected_revision': {'type': 'integer'},
          'constraints': {'type': 'string'},
          'plan': {'type': 'string'},
          'summary': {'type': 'string'},
          'compact': {
            'type': 'boolean',
            'description': '摘要保存成功后主动压缩旧请求上下文，保留当前用户任务和最近工具轮。',
          },
        },
        'required': ['expected_revision'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_memory_recall',
      description: '取回当前会话的持久工作记忆和版本；缺省版本为 0。',
      parameters: {
        'type': 'object',
        'properties': {
          'agent_id': {
            'type': 'string',
            'description': '仅主代理可指定当前会话已存储子代理范围，缺省读自身；子代理不能读写兄弟范围。',
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_history',
      description:
          '按关键词检索当前会话原始公开消息，或按消息 ID 回读。返回有界片段与 ID，继续使用 offset 翻页；不返回私密思维链。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'message_id': {'type': 'string'},
          'source_id': {'type': 'string'},
          'content_offset': {'type': 'integer'},
          'offset': {'type': 'integer'},
          'limit': {'type': 'integer'},
        },
        'additionalProperties': false,
      },
    ),
  ];
}
