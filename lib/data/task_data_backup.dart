import 'dart:convert';
import 'backup_codec.dart';
import '../domain/task_core/task_plan.dart';

/// Portable business records, never endpoint bindings or execution authority.
abstract final class TaskDataBackup {
  static const sessionKey = 'chatSessionJournal.v1',
      acceptanceKey = 'taskAcceptance.v1',
      planKey = 'taskPlans.v1';
  static const keys = {sessionKey, acceptanceKey, planKey};
  static Map<String, TaskPlan> plans(Object? raw) {
    final decoded = _decode(raw);
    if (decoded == null) return {};
    if (decoded is! Map<String, dynamic>) _bad();
    final result = <String, TaskPlan>{};
    for (final entry in (decoded as Map<String, dynamic>).entries) {
      final plan = TaskPlan.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (plan.conversationId != entry.key) _bad();
      result[entry.key] = plan;
    }
    return result;
  }

  static Map<String, dynamic> _portablePlan(
    TaskPlan plan,
    String Function(String) remap,
  ) => {
    ...plan.toJson(),
    'id': remap(plan.id),
    'conversationId': remap(plan.conversationId),
    'taskId': plan.taskId == null ? null : remap(plan.taskId!),
    'target': <String, dynamic>{},
    'status': 'cancelled',
    'requiresReview': true,
    'approvedRevision': null,
    'approvedBy': null,
    'steps': [
      for (final step in plan.steps)
        {
          ...step.toJson(),
          'id': remap(step.id),
          'verified': false,
          'evidence': <String>[],
        },
    ],
    'comments': [
      for (final c in plan.comments)
        {
          ...c,
          'id': remap(c['id'] as String),
          'stepId': c['stepId'] == null ? null : remap(c['stepId'] as String),
        },
    ],
    'history': [
      for (final old in plan.history)
        {'revision': old['revision'], 'body': old['body']},
    ],
  };
  static const limit = 100000;
  static void _bad() => throw const FormatException('任务备份记录格式不合法或含未知字段。');
  static Map<String, dynamic> _map(Object? value, Set<String> fields) {
    if (value is! Map<String, dynamic> || !value.keys.every(fields.contains)) {
      _bad();
    }
    return value as Map<String, dynamic>;
  }

  static List _list(Object? value) {
    if (value is! List || value.length > limit) {
      _bad();
    }
    return value as List;
  }

  static void _text(Object? v, {bool nullable = false}) {
    if ((v == null && nullable) || v is String) {
      return;
    }
    _bad();
  }

  static void _id(Object? v) {
    if (v is! String || v.isEmpty) {
      _bad();
    }
  }

  static void _date(Object? v, {bool nullable = false}) {
    if (v == null && nullable) {
      return;
    }
    if (v is! String || DateTime.tryParse(v) == null) {
      _bad();
    }
  }

  static void _bool(Object? v) {
    if (v is! bool) {
      _bad();
    }
  }

  static void _integer(Object? v) {
    if (v is! int || v < 0) {
      _bad();
    }
  }

  static void _strings(Object? v) {
    for (final item in _list(v)) {
      _text(item);
    }
  }

  static Object? _decode(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is! String) {
      _bad();
    }
    if ((raw as String).length > BackupCodec.maxBytes ||
        utf8.encode(raw).length > BackupCodec.maxBytes) {
      _bad();
    }
    final decoded = jsonDecode(raw);
    _nodes(decoded);
    return decoded;
  }

  static int _nodes(Object? value) {
    var count = 0;
    void visit(Object? item, [int depth = 0]) {
      if (depth > 48) {
        _bad();
      }
      if (item is Map) {
        count++;
        for (final v in item.values) {
          visit(v, depth + 1);
        }
      } else if (item is List) {
        for (final v in item) {
          if (v is! Map && v is! List) {
            count++;
          }
          visit(v, depth + 1);
        }
      }
      if (count > limit) {
        _bad();
      }
    }

    visit(value);
    return count;
  }

  static int recordCount(Map<String, dynamic> prefs) =>
      keys.fold(0, (n, key) => n + _nodes(_decode(prefs[key])));
  static void _criteria(Object? raw) {
    final j = _map(raw, {
      'description',
      'checkIds',
      'artifactPaths',
      'manualRequired',
    });
    if (j.containsKey('description')) {
      _text(j['description']);
    }
    if (j.containsKey('manualRequired')) {
      _bool(j['manualRequired']);
    }
    for (final k in ['checkIds', 'artifactPaths']) {
      if (j.containsKey(k)) {
        _strings(j[k]);
      }
    }
  }

  static void _context(Object? raw) {
    if (raw == null) {
      return;
    }
    final j = _map(raw, {'sources', 'warnings', 'skills'});
    if (j.containsKey('warnings')) {
      _strings(j['warnings']);
    }
    for (final source in _list(j['sources'] ?? [])) {
      final s = _map(source, {'path', 'scope', 'kind', 'hash'});
      for (final k in ['path', 'scope', 'kind', 'hash']) {
        _text(s[k]);
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s['hash'] as String)) {
        _bad();
      }
    }
    for (final skill in _list(j['skills'] ?? [])) {
      final s = _map(skill, {'name', 'description', 'path', 'scope'});
      for (final k in ['name', 'description', 'path', 'scope']) {
        _text(s[k]);
      }
    }
  }

  static List<Map<String, dynamic>> sessions(Object? raw) {
    final decoded = _decode(raw);
    if (decoded == null) {
      return [];
    }
    final rows = <Map<String, dynamic>>[], ids = <String>{};
    var count = 0;
    for (final row in _list(decoded)) {
      final j = _map(row, {
        'conversationId',
        'taskId',
        'status',
        'updatedAt',
        'phase',
        'queuedEvents',
        'taskState',
      });
      _id(j['conversationId']);
      if (!ids.add(j['conversationId'] as String)) {
        _bad();
      }
      _text(j['taskId'], nullable: true);
      _date(j['updatedAt']);
      if (!{
        'running',
        'waiting',
        'completed',
        'failed',
        'cancelled',
        'interrupted',
      }.contains(j['status'])) {
        _bad();
      }
      if (j.containsKey('phase')) {
        _text(j['phase']);
      }
      if (j.containsKey('queuedEvents')) {
        _integer(j['queuedEvents']);
      }
      final core = _map(j['taskState'] ?? {}, {
        'version',
        'rootId',
        'goal',
        'agentTaskId',
        'agentRootId',
        'cancelled',
        'resumeRequired',
        'inbox',
        'acknowledged',
        'lineage',
        'budget',
        'rounds',
        'target',
        'repositorySources',
        'repositoryContext',
      });
      if (core.isNotEmpty) {
        _id(core['rootId']);
        if (core.containsKey('version') && core['version'] != 1) {
          _bad();
        }
        for (final k in ['goal', 'agentTaskId', 'agentRootId']) {
          if (core.containsKey(k)) {
            _text(core[k], nullable: k != 'goal');
          }
        }
        for (final k in ['cancelled', 'resumeRequired']) {
          if (core.containsKey(k)) {
            _bool(core[k]);
          }
        }
        for (final k in ['acknowledged', 'lineage']) {
          if (core.containsKey(k)) {
            _strings(core[k]);
            count += (core[k] as List).length;
          }
        }
        final events = <String>{};
        for (final event in _list(core['inbox'] ?? [])) {
          final e = _map(event, {'id', 'content', 'taskId'});
          _id(e['id']);
          if (!events.add(e['id'] as String)) {
            _bad();
          }
          _text(e['content']);
          _text(e['taskId'], nullable: true);
          count++;
        }
        final target = _map(core['target'] ?? {}, {
          'workspaceId',
          'root',
          'sshProfileId',
          'remoteRoot',
          'approval',
          'network',
        });
        for (final e in target.entries) {
          if (e.key == 'network') {
            _bool(e.value);
          } else {
            _text(e.value, nullable: true);
          }
        }
        for (final k in ['budget', 'rounds']) {
          final data = _map(
            core[k] ?? {},
            k == 'budget'
                ? {
                    'workSeconds',
                    'timeLimitEnabled',
                    'maxSearches',
                    'maxToolCalls',
                    'elapsedMs',
                    'searches',
                    'toolCalls',
                  }
                : {'used', 'limit'},
          );
          for (final entry in data.entries) {
            if (entry.key == 'timeLimitEnabled') {
              _bool(entry.value);
            } else {
              _integer(entry.value);
            }
          }
        }
        final sources = core['repositorySources'] ?? {};
        if (sources is! Map<String, dynamic> || sources.length > limit) {
          _bad();
        }
        for (final v in (sources as Map).values) {
          _context(v);
        }
        _context(core['repositoryContext']);
      }
      rows.add(j);
      count++;
      if (count > limit) {
        _bad();
      }
    }
    return rows;
  }

  static Map<String, dynamic> acceptance(Object? raw) {
    final decoded = _decode(raw);
    if (decoded == null) {
      return {'tasks': <dynamic>[], 'drafts': <String, dynamic>{}};
    }
    final top = decoded is List
        ? {'tasks': decoded, 'drafts': <String, dynamic>{}}
        : _map(decoded, {'tasks', 'drafts'});
    final tasks = _list(top['tasks'] ?? []), drafts = top['drafts'] ?? {};
    if (drafts is! Map<String, dynamic> ||
        drafts.length + tasks.length > limit) {
      _bad();
    }
    for (final entry in (drafts as Map).entries) {
      _id(entry.key);
      _criteria(entry.value);
    }
    final ids = <String>{};
    var count = tasks.length + drafts.length;
    for (final task in tasks) {
      final j = _map(task, {
        'taskId',
        'conversationId',
        'criteria',
        'frozenAt',
        'replyComplete',
        'toolsComplete',
        'manuallyAccepted',
        'acceptedBy',
        'acceptedAt',
        'checks',
        'artifacts',
        'mutationRevision',
        'requiresReverification',
      });
      _id(j['taskId']);
      if (!ids.add(j['taskId'] as String)) {
        _bad();
      }
      if (j.containsKey('conversationId')) {
        _text(j['conversationId']);
      }
      _criteria(j['criteria']);
      _date(j['frozenAt']);
      for (final k in [
        'replyComplete',
        'toolsComplete',
        'manuallyAccepted',
        'requiresReverification',
      ]) {
        if (j.containsKey(k)) {
          _bool(j[k]);
        }
      }
      if (j.containsKey('mutationRevision')) {
        _integer(j['mutationRevision']);
      }
      _text(j['acceptedBy'], nullable: true);
      _date(j['acceptedAt'], nullable: true);
      for (final k in ['checks', 'artifacts']) {
        final records = j[k] ?? {};
        if (records is! Map<String, dynamic>) {
          _bad();
        }
        for (final entry in (records as Map).entries) {
          _id(entry.key);
          final r = _map(
            entry.value,
            k == 'checks'
                ? {'exitCode', 'invocationId', 'provenance', 'observedAt'}
                : {'present', 'sha256', 'provenance', 'observedAt'},
          );
          _text(r['provenance']);
          _date(r['observedAt']);
          if (k == 'checks') {
            if (r['exitCode'] is! int) {
              _bad();
            }
            _id(r['invocationId']);
          } else {
            _bool(r['present']);
            _text(r['sha256']);
            if (r['present'] == true &&
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(r['sha256'] as String)) {
              _bad();
            }
          }
          count++;
          if (count > limit) {
            _bad();
          }
        }
      }
    }
    return {'tasks': tasks, 'drafts': drafts};
  }

  static Map<String, String> exportValues(
    Map<String, Object?> raw,
    Set<Object?> conversations,
  ) {
    final rows = sessions(
      raw[sessionKey],
    ).where((j) => conversations.contains(j['conversationId'])).toList();
    final a = acceptance(raw[acceptanceKey]);
    return {
      if (raw[planKey] != null)
        planKey: jsonEncode({
          for (final entry in plans(raw[planKey]).entries)
            if (conversations.contains(entry.key))
              entry.key: _portablePlan(entry.value, (id) => id),
        }),
      if (raw[sessionKey] != null) sessionKey: jsonEncode(rows),
      if (raw[acceptanceKey] != null)
        acceptanceKey: jsonEncode({
          'tasks': [
            for (final t in a['tasks'] as List)
              if ((t['conversationId'] as String? ?? '').isEmpty ||
                  conversations.contains(t['conversationId']))
                t,
          ],
          'drafts': {
            for (final e in (a['drafts'] as Map).entries)
              if (conversations.contains(e.key)) e.key: e.value,
          },
        }),
    };
  }

  static void validateAssociations(
    Map<String, dynamic> prefs,
    Set<Object?> conversations,
  ) {
    if (!plans(prefs[planKey]).keys.every(conversations.contains)) _bad();
    if (sessions(
      prefs[sessionKey],
    ).any((j) => !conversations.contains(j['conversationId']))) {
      _bad();
    }
    final a = acceptance(prefs[acceptanceKey]);
    if (!(a['drafts'] as Map).keys.every(conversations.contains)) {
      _bad();
    }
    for (final t in a['tasks'] as List) {
      final c = t['conversationId'] as String? ?? '';
      if (c.isNotEmpty && !conversations.contains(c)) {
        _bad();
      }
    }
  }

  static Map<String, String> restoreValues(
    Map<String, Object?> local,
    Map<String, dynamic> imported,
    String Function(String) remap,
  ) {
    final result = <String, String>{};
    if (imported.containsKey(planKey)) {
      result[planKey] = jsonEncode({
        for (final entry in plans(local[planKey]).entries)
          entry.key: entry.value.toJson(),
        for (final entry in plans(imported[planKey]).entries)
          remap(entry.key): _portablePlan(entry.value, remap),
      });
    }
    if (imported.containsKey(sessionKey)) {
      final merged = sessions(local[sessionKey]);
      for (final row in sessions(imported[sessionKey])) {
        final j = Map<String, dynamic>.from(row);
        j['conversationId'] = remap(j['conversationId'] as String);
        if (j['taskId'] is String && (j['taskId'] as String).isNotEmpty) {
          j['taskId'] = remap(j['taskId'] as String);
        }
        j['status'] = 'interrupted';
        j['phase'] = '从备份导入的历史记录；未恢复执行授权，未重放命令。原目标需在新任务中重新选择。';
        final core = Map<String, dynamic>.from(j['taskState'] as Map? ?? {});
        if (core.isNotEmpty) {
          core['rootId'] = remap(core['rootId'] as String);
          core['target'] = <String, dynamic>{};
          core['agentRootId'] = null;
          core['resumeRequired'] = true;
          if (core['agentTaskId'] is String &&
              (core['agentTaskId'] as String).isNotEmpty) {
            core['agentTaskId'] = remap(core['agentTaskId'] as String);
          }
          for (final k in ['acknowledged', 'lineage']) {
            if (core[k] is List) {
              core[k] = [for (final id in core[k] as List) remap(id as String)];
            }
          }
          if (core['inbox'] is List) {
            core['inbox'] = [
              for (final event in core['inbox'] as List)
                {
                  ...event as Map,
                  'id': remap(event['id'] as String),
                  'taskId': event['taskId'] == null || event['taskId'] == ''
                      ? event['taskId']
                      : remap(event['taskId'] as String),
                },
            ];
          }
          // Sources remain historical provenance. Child bindings are not portable.
          final sources = core['repositorySources'] as Map?;
          if (sources != null) {
            core['repositorySources'] = {
              if (sources.containsKey('main')) 'main': sources['main'],
            };
          }
          j['taskState'] = core;
        }
        merged.add(j);
      }
      result[sessionKey] = jsonEncode(merged);
    }
    if (imported.containsKey(acceptanceKey)) {
      final existing = acceptance(local[acceptanceKey]),
          incoming = acceptance(imported[acceptanceKey]);
      final tasks = [...existing['tasks'] as List];
      for (final value in incoming['tasks'] as List) {
        final t = Map<String, dynamic>.from(value as Map);
        t['taskId'] = remap(t['taskId'] as String);
        final c = t['conversationId'] as String? ?? '';
        if (c.isNotEmpty) {
          t['conversationId'] = remap(c);
        }
        t['manuallyAccepted'] = false;
        t['requiresReverification'] = true;
        tasks.add(t);
      }
      result[acceptanceKey] = jsonEncode({
        'tasks': tasks,
        'drafts': {
          ...existing['drafts'] as Map,
          for (final e in (incoming['drafts'] as Map).entries)
            remap(e.key as String): e.value,
        },
      });
    }
    if (recordCount(result) > limit ||
        result.values.fold<int>(
              0,
              (total, raw) => total + utf8.encode(raw).length,
            ) >
            BackupCodec.maxBytes) {
      _bad();
    }
    return result;
  }
}
