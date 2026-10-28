import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import '../../core/providers.dart';
import '../../state/chat_controller.dart';
import '../../state/work_approvals.dart';
import '../../state/work_questions.dart';
import '../../state/work_rounds.dart';
import '../../state/work_task_runtime.dart';
import '../../state/work_runtime_logs.dart';
import '../../state/task_acceptance_provider.dart';
import '../../state/work_agents.dart';
import '../../state/work_processes.dart';
import '../../state/work_changes.dart';
import '../../state/work_memory.dart';
import '../../state/session_policy.dart';
import '../../state/conversation_model_choice.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/role_evolution.dart';
import '../../data/subagent_role.dart';
import '../../features/tui_bridge/protocol.dart';
import '../desktop/workspace_host.dart';
import '../workbench/files/delivery_access.dart';
import '../workbench/changes/restore_work_file_change.dart';
import 'wire_models.dart';

class HostRuntimeApi {
  HostRuntimeApi(this.container);
  final ProviderContainer container;
  Future<Object?> invoke(String operation, Map<String, dynamic> a) async {
    String id(String key) => requiredString(a, key);
    switch (operation) {
      case 'approval.decide':
        container
            .read(workApprovalsProvider.notifier)
            .decideScoped(
              id('conversation'),
              id('id'),
              id('decision'),
              reason: a['reason'] as String?,
            );
      case 'approval.revoke':
        container
            .read(workApprovalsProvider.notifier)
            .revokeSession(id('conversation'));
      case 'question.answer':
        container
            .read(workQuestionsProvider.notifier)
            .answer(id('id'), wireMap(a['answers']));
      case 'rounds.pause':
        container
            .read(workRoundsProvider.notifier)
            .requestPause(id('conversation'));
      case 'rounds.resume':
        container.read(workRoundsProvider.notifier).resume(id('conversation'));
      case 'rounds.add':
        container
            .read(workRoundsProvider.notifier)
            .addRounds(id('conversation'));
      case 'policy.saveMany':
        await container
            .read(sessionPolicyProvider.notifier)
            .saveMany(
              wireMap(
                a['updates'],
              ).map((k, v) => MapEntry(k, SessionPolicy.fromJson(wireMap(v)))),
            );
      case 'model.select':
        await container
            .read(conversationModelChoiceProvider.notifier)
            .select(id('conversation'), id('model'));
      case 'workspace.select':
        await container
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select(id('conversation'), a['workspace'] as String?);
      case 'agents.models':
        await container
            .read(workAgentModelPoolProvider.notifier)
            .save(
              wireRows(a['models']).map(WorkAgentModelOption.fromJson).toList(),
            );
      case 'agents.followup':
        container.read(workAgentsProvider).followup(id('id'), id('text'));
      case 'agents.cancel':
        container
            .read(workAgentsProvider)
            .cancel(id('id'), subtree: a['subtree'] != false);
      case 'process.stop':
        container.read(workProcessesProvider).stop(id('id'));
      case 'process.restart':
        return container
            .read(workProcessesProvider)
            .restart(id('id'), requestedId: a['requestedId'] as String?);
      case 'process.start':
        final target = id('target');
        final marker = WorkFileChange(
          id: 'manual',
          conversationId: id('conversationId'),
          target: target,
          scope: 'root',
          path: '.',
          before: null,
          after: null,
          beforeHash: null,
          afterHash: '',
          updatedAt: DateTime.now(),
          beforeKnown: false,
          textSnapshot: false,
        );
        // Reopen the exact authorized target for every independent process.
        Future<WorkProcessResult> execute(
          CancelToken token,
          dynamic onOutput,
        ) async {
          final session = await openDeliverySessionUsing(
            container.read,
            marker,
            token,
          );
          try {
            return await WorkProcessRuntime.executeInSession(
              session,
              id('command'),
              a['service'] == true,
              token,
              onOutput,
            );
          } finally {
            await session.close();
          }
        }
        return container
            .read(workProcessesProvider)
            .start(
              conversationId: id('conversationId'),
              taskId: id('taskId'),
              command: id('command'),
              target: target,
              execute: execute,
              service: a['service'] == true,
              ownerAgentId: a['ownerAgentId'] as String?,
              hookId: a['hookId'] as String?,
              requestedId: id('id'),
            );
      case 'hooks.save':
        await container
            .read(workHooksProvider)
            .save(WorkHookDefinition.fromJson(wireMap(a['definition'])));
      case 'hooks.remove':
        await container.read(workHooksProvider).remove(id('id'));
      case 'hooks.run':
        await container.read(workHooksProvider).runNow(id('id'));
      case 'tasks.stop':
        await container.read(workTaskRuntimeProvider.notifier).stop(id('id'));
      case 'logs.clear':
        await container
            .read(workRuntimeLogsProvider.notifier)
            .clearConversation(id('conversation'));
      case 'logs.flush':
        await container.read(workRuntimeLogsProvider.notifier).flush();
      case 'usage.clear':
        await container
            .read(modelUsageControllerProvider.notifier)
            .clear(endpoint: a['endpoint'] as String?);
      case 'acceptance.saveDraft':
        await container
            .read(taskAcceptanceProvider.notifier)
            .saveDraft(
              id('conversation'),
              AcceptanceCriteria.fromJson(wireMap(a['criteria'])),
            );
      case 'acceptance.revise':
        await container
            .read(taskAcceptanceProvider.notifier)
            .reviseByUser(
              id('task'),
              AcceptanceCriteria.fromJson(wireMap(a['criteria'])),
            );
      case 'memory.checkpoint':
        return container
            .read(workMemoryProvider)
            .checkpoint(
              id('conversation'),
              wireMap(a['arguments']),
              userInitiated: a['userInitiated'] == true,
              agentId: a['agentId'] as String?,
            );
      case 'memory.repair':
        await container
            .read(workMemoryProvider)
            .repairCorrupt(
              id('conversation'),
              id('reviewedDigest'),
              a['userPins'] as String? ?? '',
            );
      case 'roles.accept':
        await container
            .read(roleEvolutionProvider.notifier)
            .acceptEvidence(
              id('id'),
              a['version'] as int,
              id('taskId'),
              id('criteria'),
            );
      case 'roles.revise':
        final current = container
            .read(roleEvolutionProvider)
            .where((r) => r.role.id == id('id'))
            .firstOrNull;
        if (current == null || current.version != a['expected_version']) {
          throw const BridgeFailure('conflict', '角色在编辑期间已改变，请重新核对');
        }
        await container
            .read(roleEvolutionProvider.notifier)
            .revise(
              id('id'),
              SubagentRole.fromJson(wireMap(a['role'])),
              disabled: a['disabled'] as bool?,
            );
      case 'roles.rollback':
        await container
            .read(roleEvolutionProvider.notifier)
            .rollback(id('id'), a['version'] as int);
      case 'roles.delete':
        await container.read(roleEvolutionProvider.notifier).delete(id('id'));
      case 'changes.restore':
        final expected = id('afterHash');
        final change = container
            .read(workChangesProvider)
            .where((c) => c.id == id('id'))
            .firstOrNull;
        if (change == null || change.afterHash != expected) {
          throw const BridgeFailure('conflict', '改动版本已变化');
        }
        if (container
            .read(chatControllerProvider.notifier)
            .isConversationRunning(change.conversationId)) {
          throw const BridgeFailure('busy', '此会话仍在执行，请先停止任务');
        }
        var requested = a['change'] == null
            ? change
            : WorkFileChange.fromJson(wireMap(a['change']));
        if (requested.id != change.id ||
            requested.target != change.target ||
            requested.path != change.path ||
            requested.scope != change.scope ||
            requested.conversationId != change.conversationId ||
            requested.afterHash != change.afterHash) {
          throw const BridgeFailure('conflict', '回退对象与原始记录不一致');
        }
        if (a['recreate'] == true) {
          requested = change.requestNewFileRecreation();
        }
        if (!requested.canRestore && !requested.recreateNewFile) {
          throw const BridgeFailure('unsupported', '此改动不可回退');
        }
        final token = CancelToken();
        final session = await openDeliverySessionUsing(
          container.read,
          requested,
          token,
        );
        try {
          final taskId = container
              .read(chatControllerProvider.notifier)
              .taskSnapshotFor(change.conversationId)?['rootId'];
          if (taskId is String &&
              container.read(taskAcceptanceProvider).containsKey(taskId)) {
            await container
                .read(taskAcceptanceProvider.notifier)
                .update(taskId, (task) => task.invalidateAfterMutation());
          }
          await restoreReviewedFileChange(session, requested, token);
        } finally {
          await session.close();
        }
        if (!requested.recreateNewFile && requested.before == change.before) {
          await container
              .read(workChangesProvider.notifier)
              .markReverted(change);
        } else {
          final content = requested.recreateNewFile
              ? change.after!
              : requested.before!;
          await container
              .read(workChangesProvider.notifier)
              .record(
                conversationId: change.conversationId,
                assistantId: change.assistantId,
                roundId: 'review:${DateTime.now().microsecondsSinceEpoch}',
                target: change.target,
                scope: change.scope,
                path: change.path,
                before: requested.recreateNewFile ? null : change.after,
                beforeHash: requested.recreateNewFile ? null : change.afterHash,
                after: content,
                afterHash: sha256.convert(utf8.encode(content)).toString(),
              );
        }
      default:
        throw const BridgeFailure('unsupported', '未注册的运行控制操作');
    }
    return null;
  }
}

Map<String, Object?> encodeWorkspace(DesktopWorkspace value) => {
  'id': value.id,
  'name': value.name,
  'root': value.root,
  'scopes': {
    for (final scope in value.scopes)
      scope.name: {
        'name': scope.name,
        'path': scope.path,
        'access': scope.access.wireValue,
      },
  },
};

class HostWorkspaceApi {
  HostWorkspaceApi(this.host);
  final DesktopWorkspaceHost host;
  Future<Object?> invoke(String operation, Map<String, dynamic> a) async {
    String id(String key) => requiredString(a, key);
    switch (operation) {
      case 'list':
        return (await host.list()).map(encodeWorkspace).toList();
      case 'defaultWorkspace':
        return encodeWorkspace(await host.defaultWorkspace());
      case 'processFor':
        return (await host.processFor(id('workspaceId'))).toJson();
      case 'add':
        return encodeWorkspace(
          await host.add(
            id: id('id'),
            name: id('name'),
            path: id('path'),
            access: WorkspaceAccess.parse(id('access')),
          ),
        );
      case 'setScope':
        return encodeWorkspace(
          await host.setScope(
            workspace: id('workspace'),
            name: id('name'),
            path: id('path'),
            access: WorkspaceAccess.parse(id('access')),
          ),
        );
      case 'removeScope':
        return encodeWorkspace(
          await host.removeScope(id('workspace'), id('name')),
        );
      case 'remove':
        await host.remove(id('workspace'));
        return null;
      default:
        throw const BridgeFailure('unsupported', '未注册的工作区操作');
    }
  }
}
