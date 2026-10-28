import 'dart:convert';
import '../platform/preferences.dart';
import 'subagent_role.dart';

/// Inert user configuration only. No login tokens, companion web keys, task
/// queues, operation journals, live browser leases or runtime logs are copied.
abstract final class CapabilitySettingsBundle {
  static const keys = {
    'modelServicePriorities',
    'modelRouteGroups.v1',
    'trustedToolRegistry.v1',
    'taskSupervisor.v1',
    'roleEvolution.v1',
    'roleValidation.v1',
  };
  static Map<String, dynamic> read(SharedPreferences prefs) {
    final result = <String, dynamic>{};
    for (final key in keys) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        result[key] = _normalize(key, jsonDecode(raw));
      } catch (_) {
        /* Do not rewrite damaged local settings during export. */
      }
    }
    return {'version': 1, 'values': result};
  }

  static Map<String, dynamic> validate(Object? raw) {
    if (raw == null) return {};
    if (raw is! Map || raw['version'] != 1 || raw['values'] is! Map) {
      throw const FormatException('能力配置备份格式不受支持');
    }
    if (jsonEncode(raw).length > 8 * 1024 * 1024) {
      throw const FormatException('能力配置备份超过 8 MiB');
    }
    return {
      for (final entry in (raw['values'] as Map).entries)
        if (keys.contains(entry.key))
          entry.key as String: _normalize(entry.key as String, entry.value),
    };
  }

  static Future<Set<String>> apply(
    SharedPreferences prefs,
    Map<String, dynamic> values,
  ) async {
    for (final entry in values.entries) {
      var value = entry.value;
      if (entry.key == 'roleEvolution.v1') {
        List current = [];
        try {
          current = jsonDecode(prefs.getString(entry.key) ?? '[]') as List;
        } catch (_) {}
        final ids = current
            .whereType<Map>()
            .map((c) => (c['role'] as Map?)?['id'])
            .toSet();
        value = [
          ...current,
          ...(value as List).where(
            (c) => !ids.contains((c as Map)['role']['id']),
          ),
        ].take(40).toList();
      }
      if (entry.key == 'modelRouteGroups.v1') {
        Map current = {};
        try {
          current = jsonDecode(prefs.getString(entry.key) ?? '{}') as Map;
        } catch (_) {}
        final groups = (current['groups'] as List? ?? []);
        final ids = groups.whereType<Map>().map((g) => g['id']).toSet();
        value = {
          'groups': [
            ...groups,
            ...(value['groups'] as List).where(
              (g) => !ids.contains((g as Map)['id']),
            ),
          ].take(20).toList(),
          'autoGroup': (current['autoGroup'] as String? ?? '').isNotEmpty
              ? current['autoGroup']
              : value['autoGroup'],
        };
      }
      if (!await prefs.setString(entry.key, jsonEncode(value))) {
        throw StateError('能力配置保存失败：${entry.key}');
      }
    }
    return values.keys.toSet();
  }

  static String _text(Object? value, int max, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is! String || value.length > max) {
      throw const FormatException('能力配置文本超限或类型错误');
    }
    return value;
  }

  static List<String> _strings(Object? value, int count) {
    if (value is! List || value.length > count) {
      throw const FormatException('能力配置列表无效');
    }
    return value.map((v) => _text(v, 1024)).toSet().toList();
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map) throw const FormatException('能力配置应为对象');
    return Map<String, dynamic>.from(value);
  }

  static dynamic _normalize(String key, Object? value) {
    if (key == 'roleEvolution.v1') {
      if (value is! List || value.length > 40) {
        throw const FormatException('候选角色数量超限');
      }
      return value.map((v) => _candidate(_map(v))).toList();
    }
    final map = _map(value);
    if (key == 'modelServicePriorities') {
      if (map.length > 1000) throw const FormatException('模型优先级数量超限');
      return map.map((k, v) => MapEntry(_text(k, 1024), _strings(v, 100)));
    }
    if (key == 'trustedToolRegistry.v1') {
      return {
        'mathEnabled': map['mathEnabled'] == true,
        'pythonExecutable': _text(
          map['pythonExecutable'],
          1024,
          fallback: 'python',
        ),
      };
    }
    if (key == 'modelRouteGroups.v1') {
      final groups = map['groups'];
      if (groups is! List || groups.length > 20) {
        throw const FormatException('路由组数量无效');
      }
      final ids = groups.map((raw) => _text(_map(raw)['id'], 1024)).toList();
      if (ids.any((id) => id.trim().isEmpty) ||
          ids.toSet().length != ids.length ||
          groups.any(
            (raw) =>
                _text(_map(raw)['name'], 200).trim().isEmpty ||
                _strings(_map(raw)['models'], 20).isEmpty,
          )) {
        throw const FormatException('路由组标识、名称或模型列表无效');
      }
      return {
        'autoGroup': _text(map['autoGroup'], 1024),
        'groups': [
          for (final raw in groups)
            {
              'id': _text(_map(raw)['id'], 1024),
              'name': _text(_map(raw)['name'], 200),
              'models': _strings(_map(raw)['models'], 20),
              'failover': _map(raw)['failover'] == true,
            },
        ],
      };
    }
    if (key == 'taskSupervisor.v1' || key == 'roleValidation.v1') {
      final countKey = key == 'taskSupervisor.v1'
          ? 'maxReviews'
          : 'maxReviewsPerTask';
      final count = map[countKey] is num
          ? (map[countKey] as num).toInt()
          : key == 'taskSupervisor.v1'
          ? 3
          : 2;
      return {
        'enabled': map['enabled'] == true,
        'model': _text(map['model'], 1024),
        'prompt': _text(map['prompt'], 16000),
        countKey: count.clamp(1, key == 'taskSupervisor.v1' ? 10 : 5),
        if (key == 'taskSupervisor.v1')
          'minRoundGap': ((map['minRoundGap'] as num?)?.toInt() ?? 2).clamp(
            1,
            10,
          ),
        if (key == 'roleValidation.v1')
          'autoPromote': map['autoPromote'] == true,
      };
    }
    throw const FormatException('未知能力配置');
  }

  static Map<String, dynamic> _candidate(
    Map<String, dynamic> map, {
    bool history = true,
  }) {
    final role = SubagentRole.fromJson(_map(map['role']));
    if (role.id.isEmpty ||
        role.name.isEmpty ||
        role.instructions.length > 24000 ||
        role.requiredTools.length > 100) {
      throw const FormatException('候选角色无效');
    }
    final evidence = map['evidence'] as List? ?? [];
    if (evidence.length > 10) throw const FormatException('角色证据过多');
    final result = <String, dynamic>{
      'role': role.copyWith(enabled: false).toJson(),
      'version': (map['version'] as num?)?.toInt() ?? 1,
      'source': _text(map['source'], 4000),
      'requiredTools': _strings(map['requiredTools'] ?? [], 100),
      'disabled': map['disabled'] == true,
      'evidence': [for (final entry in evidence) _evidence(_map(entry))],
    };
    if (history) {
      final previous = map['history'] as List? ?? [];
      if (previous.length > 5) throw const FormatException('角色版本历史过多');
      result['history'] = previous
          .map((v) => _candidate(_map(v), history: false))
          .toList();
    }
    return result;
  }

  static Map<String, dynamic> _evidence(Map<String, dynamic> value) {
    final artifacts = _map(value['artifacts'] ?? {});
    if (artifacts.length > 30) throw const FormatException('角色产物证据过多');
    return {
      'version': (value['version'] as num?)?.toInt() ?? 1,
      'taskId': _text(value['taskId'], 1024),
      'artifacts': artifacts.map(
        (key, value) => MapEntry(_text(key, 2048), _text(value, 128)),
      ),
      'success': value['success'] == true,
      if (value['reviewPassed'] is bool) 'reviewPassed': value['reviewPassed'],
      for (final key in [
        'summary',
        'at',
        'resultHash',
        'acceptance',
        'acceptedBy',
        'reviewModel',
        'reviewCriteria',
        'reviewLimitations',
        'reviewEvidenceHash',
      ])
        if (value[key] != null)
          key: _text(value[key], key == 'summary' ? 1000 : 2000),
    };
  }
}
