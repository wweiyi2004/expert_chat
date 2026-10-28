import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../workbench/agents/work_agent_runtime.dart';
import '../workbench/processes/work_process_runtime.dart';
import '../workbench/processes/work_hook_runtime.dart';
import 'host_client.dart';
import 'wire_models.dart';
import '../llm/llm_provider.dart';

Map<String, dynamic> _runtime() =>
    wireMap(HostClient.current!.state['runtime']);
void _send(String operation, Map<String, Object?> args) {
  unawaited(
    HostClient.current!.call('runtime', operation, args).catchError((Object e) {
      HostClient.current?.reportError(e.toString());
      return null;
    }),
  );
}

StreamSubscription<Map<String, dynamic>> _observe(
  String field,
  void Function(List<Map<String, dynamic>>) apply,
) {
  var previous = jsonEncode(_runtime()[field]);
  apply(wireRows(_runtime()[field]));
  return HostClient.current!.updates.listen((value) {
    if (value['runtime'] == null) return;
    final rows = wireMap(value['runtime'])[field], signature = jsonEncode(rows);
    if (signature != previous) {
      previous = signature;
      apply(wireRows(rows));
    }
  });
}

class HostAgentRuntime extends WorkAgentRuntime {
  HostAgentRuntime() {
    _subscription = _observe('agents', applyHostProjection);
  }
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  @override
  void followup(String id, String text) =>
      _send('agents.followup', {'id': id, 'text': text});
  @override
  void cancel(String id, {bool subtree = true}) =>
      _send('agents.cancel', {'id': id, 'subtree': subtree});
  @override
  String spawn({
    required String parentId,
    required String task,
    String? model,
    String? candidateId,
    List<String> ownedPaths = const [],
    bool readOnly = false,
    bool isolated = false,
    bool requireOwnership = false,
    LlmConfig? manualConfig,
    ReasoningEffort? manualEffort,
  }) {
    throw StateError('界面不直接派发子代理，请通过当前宿主任务提交要求');
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

class HostProcessRuntime extends WorkProcessRuntime {
  HostProcessRuntime() {
    _subscription = _observe('processes', applyHostProjection);
  }
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  @override
  void stop(String id) => _send('process.stop', {'id': id});
  @override
  String restart(String id, {String? requestedId}) {
    final next = requestedId ?? 'process_${const Uuid().v4()}';
    _send('process.restart', {'id': id, 'requestedId': next});
    return next;
  }

  @override
  String start({
    required String conversationId,
    required String taskId,
    required String command,
    required String target,
    required WorkProcessExecutor execute,
    bool service = false,
    String? ownerAgentId,
    String? hookId,
    String? requestedId,
  }) {
    final next = requestedId ?? 'process_${const Uuid().v4()}';
    _send('process.start', {
      'id': next,
      'conversationId': conversationId,
      'taskId': taskId,
      'command': command,
      'target': target,
      'service': service,
      'ownerAgentId': ownerAgentId,
      'hookId': hookId,
    });
    return next;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

class HostHookRuntime extends WorkHookRuntime {
  HostHookRuntime(WorkProcessRuntime processes)
    : super(
        processes: processes,
        definitions: [],
        persist: (_) async {},
        changeFeed: (_) => const Stream.empty(),
      ) {
    _subscription = _observe('hooks', applyHostProjection);
  }
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  @override
  String? boundRoot(String conversationId) =>
      wireMap(_runtime()['hookBindings'])[conversationId] as String?;
  @override
  String? runUnavailableReason(String id) =>
      wireRows(_runtime()['hooks'])
              .where((r) => wireMap(r['definition'])['id'] == id)
              .firstOrNull?['unavailableReason']
          as String?;
  @override
  Future<void> save(WorkHookDefinition definition) async {
    await HostClient.current!.call('runtime', 'hooks.save', {
      'definition': definition.toJson(),
    });
  }

  @override
  Future<void> remove(String id) async {
    await HostClient.current!.call('runtime', 'hooks.remove', {'id': id});
  }

  @override
  Future<void> runNow(String id) async {
    await HostClient.current!.call('runtime', 'hooks.run', {'id': id});
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
