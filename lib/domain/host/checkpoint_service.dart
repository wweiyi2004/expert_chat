import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import '../../data/models.dart';
import '../../state/chat_controller.dart';
import '../../state/work_changes.dart';
import '../../state/task_acceptance_provider.dart';
import '../../features/tui_bridge/protocol.dart';
import '../workbench/files/delivery_access.dart';
import '../workbench/changes/restore_work_file_change.dart';

class CheckpointService {
  CheckpointService(this.container);
  final ProviderContainer container;
  ChatController get controller =>
      container.read(chatControllerProvider.notifier);
  Future<Conversation> _conversation(String id) async {
    await controller.loadSession(id);
    return container
        .read(chatControllerProvider)
        .requireValue
        .conversations
        .firstWhere((c) => c.id == id);
  }

  Future<Map<String, Object?>> list(String id) async {
    final conversation = await _conversation(id);
    return {
      'checkpoints': [
        for (final m in conversation.messages)
          if (m.role == MessageRole.user)
            {
              'id': m.id,
              'title': m.content.length > 160
                  ? m.content.substring(0, 160)
                  : m.content,
              'created_at': m.createdAt.toUtc().toIso8601String(),
              'position': 'before_user_message',
            },
      ],
    };
  }

  List<WorkFileChange> _changes(Conversation c, ChatMessage point) {
    return container
        .read(workChangesProvider)
        .where(
          (change) =>
              change.conversationId == c.id &&
              !change.reverted &&
              !change.updatedAt.isBefore(point.createdAt),
        )
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<Map<String, Object?>> preview(String id, String message) async {
    final c = await _conversation(id);
    final point = c.messages
        .where((m) => m.id == message && m.role == MessageRole.user)
        .firstOrNull;
    if (point == null) throw const BridgeFailure('not_found', '检查点不存在');
    await container.read(workChangesProvider.notifier).ready;
    final changes = _changes(c, point);
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'conversation': c.toJson(),
              'point': message,
              'changes': changes.map((c) => c.toJson()).toList(),
            }),
          ),
        )
        .toString();
    final effects = c.messages
        .where((m) => !m.createdAt.isBefore(point.createdAt))
        .expand((m) => m.searchActivities)
        .where(
          (a) =>
              a.toolName == 'work_run_command' || a.toolName == 'device_action',
        )
        .isNotEmpty;
    return {
      'session_id': id,
      'message_id': message,
      'fingerprint': fingerprint,
      'position': 'before_user_message',
      'untracked_effects': effects,
      'warning': '仅回退有记录且当前 SHA 匹配的文本文件。命令、二进制文件、外部服务与设备副作用不能保证撤销。',
      'files': [
        for (final c in changes)
          {
            'id': c.id,
            'path': c.path,
            'target': c.targetLabel,
            'restorable': c.canRestore,
            'new_file': c.isNew,
            'after_hash': c.afterHash,
            'before_hash': c.beforeHash,
            'before': c.before?.substring(0, c.before!.length.clamp(0, 16000)),
            'after': c.after?.substring(0, c.after!.length.clamp(0, 16000)),
            'preview_truncated':
                (c.before?.length ?? 0) > 16000 ||
                (c.after?.length ?? 0) > 16000,
          },
      ],
    };
  }

  Future<Map<String, Object?>> restore(
    String id,
    String message,
    String expected,
    String mode,
  ) => controller.withCheckpointMaintenance(id, () async {
    if (!const {'conversation', 'files', 'both', 'branch'}.contains(mode)) {
      throw const BridgeFailure('invalid_params', '检查点操作类型无效');
    }
    final review = await preview(id, message);
    if (review['fingerprint'] != expected) {
      throw const BridgeFailure('conflict', '检查点或文件记录已变化，请重新查看');
    }
    final c = await _conversation(id),
        point = c.messages.firstWhere((m) => m.id == message);
    final restored = <String>[], skipped = <Map<String, String>>[];
    if (mode == 'files' || mode == 'both') {
      final root = controller.taskSnapshotFor(id)?['rootId'];
      if (root is String &&
          container.read(taskAcceptanceProvider).containsKey(root)) {
        await container
            .read(taskAcceptanceProvider.notifier)
            .update(root, (task) => task.invalidateAfterMutation());
      }
      for (final change in _changes(c, point)) {
        if (!change.canRestore) {
          skipped.add({
            'id': change.id,
            'path': change.path,
            'reason': '没有可安全回退的文本快照',
          });
          continue;
        }
        final token = CancelToken();
        try {
          final session = await openDeliverySessionUsing(
            container.read,
            change,
            token,
          );
          try {
            await restoreReviewedFileChange(session, change, token);
          } finally {
            await session.close();
          }
          await container
              .read(workChangesProvider.notifier)
              .markReverted(change);
          restored.add(change.id);
        } catch (_) {
          skipped.add({
            'id': change.id,
            'path': change.path,
            'reason': '文件版本、权限或目标已变化；请在改动面板核对',
          });
          break;
        }
      }
    }
    var destination = id;
    final restoreConversation =
        mode == 'conversation' ||
        mode == 'branch' ||
        mode == 'both' && skipped.isEmpty;
    if (restoreConversation) {
      destination = await controller.restoreConversationCheckpoint(
        id,
        message,
        branch: mode == 'branch',
      );
    }
    return {
      'session_id': destination,
      'restored_files': restored,
      'skipped_files': skipped,
      'conversation_restored': restoreConversation,
      'branch_created': mode == 'branch',
      'complete': skipped.isEmpty,
      'untracked_effects': review['untracked_effects'],
      'warning': review['warning'],
    };
  });
}
