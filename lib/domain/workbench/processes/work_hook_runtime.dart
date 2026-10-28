import 'dart:async';
import '../../../platform/foundation.dart';
import 'work_process_runtime.dart';
import 'workspace_change_feed.dart';

class WorkHookDefinition {
  const WorkHookDefinition({
    required this.id,
    required this.conversationId,
    required this.root,
    required this.command,
    this.watchPath = '',
    this.enabled = true,
    this.debounceMs = 800,
  });
  final String id, conversationId, root, command, watchPath;
  final bool enabled;
  final int debounceMs;
  WorkHookDefinition copyWith({bool? enabled}) => WorkHookDefinition(
    id: id,
    conversationId: conversationId,
    root: root,
    command: command,
    watchPath: watchPath,
    enabled: enabled ?? this.enabled,
    debounceMs: debounceMs,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'root': root,
    'command': command,
    'watchPath': watchPath,
    'enabled': enabled,
    'debounceMs': debounceMs,
  };
  factory WorkHookDefinition.fromJson(Map<String, dynamic> j) =>
      WorkHookDefinition(
        id: j['id'] as String,
        conversationId: j['conversationId'] as String,
        root: j['root'] as String,
        command: j['command'] as String,
        watchPath: j['watchPath'] as String? ?? '',
        enabled: j['enabled'] == true,
        debounceMs: ((j['debounceMs'] as num?)?.toInt() ?? 800).clamp(
          200,
          30000,
        ),
      );
}

class WorkHookRecord {
  WorkHookRecord(this.definition);
  WorkHookDefinition definition;
  String status = '等待会话连接工作区', error = '';
  String? processId;
  DateTime? lastTriggeredAt, suppressUntil;
  final Set<String> pendingPaths = {};
  Timer? debounce;
  StreamSubscription<String>? watcher;
  bool launching = false;
}

class _HookBinding {
  _HookBinding(this.root, this.launch, this.changeFeed);
  final String root;
  final Stream<String> Function(String root)? changeFeed;
  final Future<String> Function(WorkHookDefinition definition) launch;
}

/// Only explicitly configured commands execute; event paths are never expanded
/// into a shell command. Changes during a hook and its settle interval are
/// intentionally dropped, preventing build output from triggering itself.
class WorkHookRuntime extends ChangeNotifier {
  void applyHostProjection(List<Map<String, dynamic>> rows) {
    for (final old in _records.values) {
      old.debounce?.cancel();
      unawaited(old.watcher?.cancel());
    }
    _records.clear();
    for (final row in rows) {
      final definition = WorkHookDefinition.fromJson(
        Map<String, dynamic>.from(row['definition'] as Map),
      );
      _records[definition.id] = WorkHookRecord(definition)
        ..status = row['status'] as String? ?? ''
        ..error = row['error'] as String? ?? ''
        ..processId = row['processId'] as String?
        ..lastTriggeredAt = DateTime.tryParse(
          row['lastTriggeredAt'] as String? ?? '',
        )
        ..launching = row['launching'] == true;
    }
    notifyListeners();
  }

  WorkHookRuntime({
    required this.processes,
    required List<WorkHookDefinition> definitions,
    required this.persist,
    Stream<String> Function(String root)? changeFeed,
  }) : _changeFeed = changeFeed ?? watchWorkspaceChanges {
    for (final definition in definitions) {
      _records[definition.id] = WorkHookRecord(definition);
    }
    _completion = processes.events.listen((event) {
      for (final r in _records.values.where(
        (r) => r.processId == event.processId,
      )) {
        r.processId = null;
        r.suppressUntil = DateTime.now().add(
          Duration(milliseconds: r.definition.debounceMs * 2),
        );
        _settle[r.definition.root] = r.suppressUntil!;
        r.status = r.definition.enabled ? '监控中 · 上次已结束' : '已停用';
      }
      _notify();
    });
  }
  final WorkProcessRuntime processes;
  final Future<void> Function(List<WorkHookDefinition>) persist;
  final Map<String, WorkHookRecord> _records = {};
  final Map<String, _HookBinding> _bindings = {};
  final Map<String, DateTime> _settle = {};
  final Stream<String> Function(String root) _changeFeed;
  late final StreamSubscription<WorkProcessEvent> _completion;
  bool _disposed = false;
  List<WorkHookRecord> get records => List.unmodifiable(_records.values);
  String? boundRoot(String conversationId) => _bindings[conversationId]?.root;

  /// Manual execution uses the same bound launcher and permissions as a file
  /// event. It cannot run an unbound, disabled, busy or settling workspace.
  String? runUnavailableReason(String id) {
    final r = _records[id];
    if (_disposed || r == null) return 'Hook 不可用';
    if (!r.definition.enabled) return '请先启用 Hook';
    final binding = _bindings[r.definition.conversationId];
    if (binding == null || binding.root != r.definition.root) {
      return '等待原会话授权匹配的本机工作区';
    }
    if (_records.values.any(
      (other) =>
          other.definition.root == r.definition.root &&
          (other.launching || other.processId != null),
    )) {
      return '该工作区已有 Hook 正在执行';
    }
    if (_settle[r.definition.root]?.isAfter(DateTime.now()) ?? false) {
      return '等待上次执行结束后的防抖间隔';
    }
    return null;
  }

  Future<void> runNow(String id) async {
    final reason = runUnavailableReason(id);
    if (reason != null) throw StateError(reason);
    await _trigger(_records[id]!);
    final record = _records[id];
    if (record?.error.isNotEmpty == true) throw StateError(record!.error);
  }

  Future<void> save(WorkHookDefinition definition) async {
    if (definition.command.trim().isEmpty || definition.root.trim().isEmpty) {
      throw const FormatException('目录和命令不能为空');
    }
    final path = definition.watchPath.replaceAll('\\', '/');
    if (path.startsWith('/') ||
        path.split('/').contains('..') ||
        path.contains(':')) {
      throw const FormatException('监控路径须为工作区内相对路径');
    }
    final definitions = [
      for (final r in _records.values)
        if (r.definition.id != definition.id) r.definition,
      definition,
    ];
    await persist(definitions);
    final prior = _records[definition.id];
    prior?.debounce?.cancel();
    await prior?.watcher?.cancel();
    _records[definition.id] = prior == null
        ? WorkHookRecord(definition)
        : (prior..definition = definition);
    _attach(_records[definition.id]!);
    _notify();
  }

  Future<void> remove(String id) async {
    await persist([
      for (final r in _records.values)
        if (r.definition.id != id) r.definition,
    ]);
    final r = _records.remove(id);
    r?.debounce?.cancel();
    await r?.watcher?.cancel();
    _notify();
  }

  void bind({
    required String conversationId,
    required String root,
    required Future<String> Function(WorkHookDefinition definition) launch,
    Stream<String> Function(String root)? changeFeed,
  }) {
    _bindings[conversationId] = _HookBinding(root, launch, changeFeed);
    for (final r in _records.values.where(
      (r) => r.definition.conversationId == conversationId,
    )) {
      _attach(r);
    }
    _notify();
  }

  void unbind(String conversationId) {
    _bindings.remove(conversationId);
    for (final r in _records.values.where(
      (r) => r.definition.conversationId == conversationId,
    )) {
      r.debounce?.cancel();
      unawaited(r.watcher?.cancel());
      r.watcher = null;
      r.status = '等待会话连接工作区';
    }
    _notify();
  }

  void _attach(WorkHookRecord r) {
    r.debounce?.cancel();
    unawaited(r.watcher?.cancel());
    r.watcher = null;
    final d = r.definition, binding = _bindings[r.definition.conversationId];
    if (!d.enabled) {
      r.status = '已停用';
      return;
    }
    if (binding == null || binding.root != d.root) {
      r.status = '等待匹配的本机工作区授权';
      return;
    }
    r.status = r.processId == null ? '监控中' : '执行中 · 变化暂不触发';
    r.error = '';
    r.watcher = (binding.changeFeed ?? _changeFeed)(d.root).listen(
      (path) {
        if (_disposed ||
            !r.definition.enabled ||
            _records.values.any(
              (other) =>
                  other.definition.root == d.root &&
                  (other.launching || other.processId != null),
            ) ||
            (_settle[d.root]?.isAfter(DateTime.now()) ?? false) ||
            (r.suppressUntil?.isAfter(DateTime.now()) ?? false)) {
          return;
        }
        final parts = path.split('/');
        if (parts.any(
          (p) => const {
            '.git',
            '.dart_tool',
            'node_modules',
            'build',
            '.next',
            '.worktrees',
            '.expert-agent-worktrees',
          }.contains(p),
        )) {
          return;
        }
        final watched = d.watchPath
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'/+$'), '');
        if (watched.isNotEmpty &&
            path != watched &&
            !path.startsWith('$watched/')) {
          return;
        }
        r.pendingPaths.add(path);
        r.debounce?.cancel();
        r.debounce = Timer(
          Duration(milliseconds: d.debounceMs.clamp(200, 30000)),
          () => unawaited(_trigger(r)),
        );
      },
      onError: (Object error) {
        r.error = '$error';
        r.status = '监控不可用';
        _notify();
      },
    );
  }

  Future<void> _trigger(WorkHookRecord r) async {
    final binding = _bindings[r.definition.conversationId];
    if (_disposed ||
        !identical(_records[r.definition.id], r) ||
        binding == null ||
        binding.root != r.definition.root ||
        r.launching ||
        r.processId != null ||
        _records.values.any(
          (other) =>
              other.definition.root == r.definition.root &&
              (other.launching || other.processId != null),
        ) ||
        (_settle[r.definition.root]?.isAfter(DateTime.now()) ?? false) ||
        !r.definition.enabled) {
      return;
    }
    r.launching = true;
    r.error = '';
    r.lastTriggeredAt = DateTime.now();
    r.pendingPaths.clear();
    r.status = '请求执行配置命令';
    _notify();
    try {
      final id = await binding.launch(r.definition);
      // A fast command may finish before its ID is returned.
      r.processId = processes.record(id)?.active == true ? id : null;
      r.status = r.processId == null ? '监控中 · 上次已结束' : '执行中 · 变化暂不触发';
    } catch (error) {
      r.error = '$error';
      r.status = '上次触发未执行';
    } finally {
      r.launching = false;
      r.suppressUntil = DateTime.now().add(
        Duration(milliseconds: r.definition.debounceMs * 2),
      );
      _settle[r.definition.root] = r.suppressUntil!;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final r in _records.values) {
      r.debounce?.cancel();
      unawaited(r.watcher?.cancel());
    }
    unawaited(_completion.cancel());
    super.dispose();
  }
}
