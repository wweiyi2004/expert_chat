import '../llm/llm_provider.dart';

/// A task-local registry of capabilities that the host has already configured
/// and permitted as discoverable. Discovery cannot enable a disabled adapter,
/// install code, choose another service, or enlarge a workspace grant.
class TaskToolRegistry {
  TaskToolRegistry({
    required List<ToolSpec> catalog,
    Set<String> initiallyActive = const {},
  }) : _catalog = {for (final tool in catalog) tool.name: tool},
       _active = {...initiallyActive};
  Map<String, ToolSpec> _catalog;
  final Set<String> _active, _pending = {};
  int revision = 0;
  Set<String> get pendingNames => Set.unmodifiable(_pending);
  void discardPending(Set<String> names) {
    final before = _pending.length;
    _pending.removeAll(names);
    if (_pending.length != before) revision++;
  }

  static const searchSpec = ToolSpec(
    name: 'tool_registry_search',
    description:
        '搜索本任务已配置且允许发现的工具。只返回工具说明；未激活工具需 tool_registry_request，经现有权限批准后在下一完整工具轮可用。不会开启用户禁用的能力或自动安装。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    },
  );
  static const requestSpec = ToolSpec(
    name: 'tool_registry_request',
    description: '申请在本任务按需加载已发现工具。通过当前权限系统后于下一完整工具轮提供；不授予额外文件、网络或设备权限。',
    parameters: {
      'type': 'object',
      'properties': {
        'tools': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': 12,
        },
      },
      'required': ['tools'],
    },
  );
  List<ToolSpec> get visibleTools => [
    for (final name in _active)
      if (_catalog[name] != null) _catalog[name]!,
    searchSpec,
    requestSpec,
  ];
  List<String> get discoverableNames => _catalog.keys.toList();
  Map<String, dynamic> search(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final matches = _catalog.values
        .where(
          (tool) =>
              words.isEmpty ||
              words.any(
                (word) => '${tool.name} ${tool.description}'
                    .toLowerCase()
                    .contains(word),
              ),
        )
        .take(30);
    return {
      'revision': revision,
      'tools': [
        for (final tool in matches)
          {
            'name': tool.name,
            'description': tool.description,
            'active': _active.contains(tool.name),
            'pending': _pending.contains(tool.name),
            'parameters': tool.parameters,
          },
      ],
      'scope':
          'Only task-authorized configured capabilities; user-disabled adapters are excluded.',
    };
  }

  Future<Map<String, dynamic>> request(
    List<String> names, {
    required Future<bool> Function(ToolSpec) authorize,
  }) async {
    if (names.isEmpty || names.length > 12) {
      throw ArgumentError('一次申请 1–12 个工具');
    }
    final requested = names.toSet();
    if (requested.any((name) => !_catalog.containsKey(name))) {
      return {'ok': false, 'error': '请求包含未发现、已关闭或无权限工具'};
    }
    final accepted = <String>[], rejected = <String>[];
    for (final name in requested) {
      final tool = _catalog[name]!;
      if (_active.contains(name)) {
        accepted.add(name);
        continue;
      }
      if (await authorize(tool)) {
        // A setting may be revoked while an approval is open.
        if (_catalog[name] == tool) {
          _pending.add(name);
          accepted.add(name);
        } else {
          rejected.add(name);
        }
      } else {
        rejected.add(name);
      }
    }
    return {
      'ok': rejected.isEmpty,
      'pending_until_next_boundary': accepted,
      'rejected': rejected,
    };
  }

  /// Call only after all calls in the preceding round have returned.
  List<String> applyBoundary() {
    final applied = _pending.where(_catalog.containsKey).toList();
    _active.addAll(applied);
    _pending.clear();
    if (applied.isNotEmpty) revision++;
    return applied;
  }

  void updateCatalog(List<ToolSpec> catalog) {
    _catalog = {for (final tool in catalog) tool.name: tool};
    _active.removeWhere((name) => !_catalog.containsKey(name));
    _pending.removeWhere((name) => !_catalog.containsKey(name));
    revision++;
  }
}
