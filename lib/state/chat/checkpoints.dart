part of '../chat_controller.dart';

extension ConversationCheckpoints on ChatController {
  Future<void> flushHostState() async {
    for (final token in _titleTokens.values) {
      token.cancel('宿主退出');
    }
    for (final run in _sessionRuns.values) {
      run.flush?.call();
    }
    await _persistence.enqueueWrite(() async {});
    await _journalWrite;
    await _runtimeRef.read(memoryRepositoryProvider).flush();
  }

  Future<T> withCheckpointMaintenance<T>(
    String id,
    Future<T> Function() action,
  ) async {
    if (isConversationRunning(id) ||
        isContextCompacting(id) ||
        _runtimeRef
            .read(workAgentsProvider)
            .records
            .any((a) => a.conversationId == id && !a.terminal) ||
        _runtimeRef
            .read(workProcessesProvider)
            .records
            .any((p) => p.conversationId == id && p.active)) {
      throw StateError('会话仍有活动任务，请先停止后再操作检查点');
    }
    _maintenanceSessions.add(id);
    try {
      await loadSession(id);
      final conversation = _rawState.conversations.firstWhere(
        (c) => c.id == id,
      );
      if (conversation.messages.any((m) => m.longTask?.isActive == true)) {
        throw StateError('后台文档任务尚未结束');
      }
      await _persistence.enqueueWrite(() async {});
      return await action();
    } finally {
      _maintenanceSessions.remove(id);
    }
  }

  Future<String> restoreConversationCheckpoint(
    String id,
    String userMessage, {
    required bool branch,
  }) async {
    if (!_maintenanceSessions.contains(id)) throw StateError('检查点操作尚未锁定会话');
    final conversation = _rawState.conversations.firstWhere((c) => c.id == id);
    final point = conversation.messages.firstWhere(
      (m) => m.id == userMessage && m.role == MessageRole.user,
    );
    final path = pathToOptionalMessage(conversation, point.parentId);
    if (branch) {
      final ids = {for (final m in path) m.id: const Uuid().v4()};
      final copied = Conversation.fromJson({
        ...conversation.toJson(),
        'id': const Uuid().v4(),
        'title': '${conversation.title} · 分支',
        'updatedAt': DateTime.now().toIso8601String(),
        'messages': [
          for (final m in path)
            {
              ...m.toJson(),
              'id': ids[m.id],
              'parentId': m.parentId == null ? null : ids[m.parentId],
            },
        ],
        'activeChildren': {
          for (final m in path)
            m.parentId == null ? kRootKey : ids[m.parentId]!: ids[m.id],
        },
      });
      await _runtimeRef
          .read(conversationRepositoryProvider)
          .saveConversation(copied);
      final binding = _runtimeRef.read(
        conversationWorkspaceBindingsProvider,
      )[id];
      await _runtimeRef
          .read(conversationWorkspaceBindingsProvider.notifier)
          .select(copied.id, binding);
      await _runtimeRef.read(sessionPolicyProvider.notifier).saveMany({
        copied.id:
            _runtimeRef.read(sessionPolicyProvider)[id] ??
            const SessionPolicy(),
      });
      _set(
        _rawState.copyWith(conversations: [copied, ..._rawState.conversations]),
      );
      return copied.id;
    }
    // Preserve every old message and branch; only move the selected tail.
    final updated = conversation.copyWith(
      activeChildren: {
        ...activatePath(conversation.activeChildren, path),
        point.parentId ?? kRootKey: kCheckpointEnd,
      },
    );
    await _runtimeRef
        .read(conversationRepositoryProvider)
        .saveConversation(updated);
    final run = _sessionRuns[id];
    if (run != null) {
      run.userCancelled = true;
      run.awaitingEvents = false;
      run.core?.cancel();
      run.inbox.clear();
      await _checkpointSession(
        run,
        SessionExecutionStatus.cancelled,
        '会话已回到检查点，旧任务不会自动恢复',
      );
    }
    final plan = _runtimeRef.read(taskPlansProvider)[id];
    if (plan != null && plan.status != TaskPlanStatus.cancelled) {
      await _runtimeRef
          .read(taskPlansProvider.notifier)
          .cancel(id, plan.revision);
    }
    _set(
      _rawState.copyWith(
        conversations: [
          for (final c in _rawState.conversations)
            if (c.id == id) updated else c,
        ],
      ),
    );
    return id;
  }
}
