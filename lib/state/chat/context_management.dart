part of '../chat_controller.dart';

extension ChatContextManagement on ChatTools {
  Future<Map<String, dynamic>?> _maybeCompactPublicContext({
    required String conversation,
    required String taskId,
    String? agentId,
    required int round,
    required LlmConfig config,
    required SettingsState settings,
    required String goal,
    required CancelToken token,
    required List<LlmRequestMessage> activeMessages,
    required List<String> Function() readPublicSources,
    required int publicHistoryCount,
    bool hasPublicWork = true,
    bool force = false,
  }) async {
    final prefs = effectiveContextPrefs(settings, config);
    if (!prefs.enabled ||
        token.isCancelled ||
        utf8.encode(goal).length > 4000) {
      return null;
    }
    final memory = _capabilityRef.read(workMemoryProvider);
    final own = memory.snapshot(conversation, agentId: agentId);
    final root = memory.snapshot(conversation);
    final updates = _capabilityRef
        .read(workTaskSteeringProvider)
        .instructions(conversation, taskId);
    final sources = readPublicSources();
    final transcript = sources.join('\n\n');
    final fingerprint = sha256
        .convert(utf8.encode('$transcript\n$updates'))
        .toString();
    final sourceVersion =
        '${own['revision'] ?? 0}:${root['revision'] ?? 0}:$fingerprint';
    final manager = const ContextWindowManager();
    final estimated =
        manager.estimateMessagesTokens(activeMessages) +
        manager.estimateTextTokens(
          memory.guidance(conversation, agentId: agentId),
        ) +
        manager.estimateTextTokens(goal) +
        manager.estimateTextTokens(updates);
    // Normalize to the service's fixed 48-message trigger so the user's actual
    // history cap requests a checkpoint BEFORE local trimming. Zero means no
    // message cap (token budget only), so it adds no history pressure.
    final historyCount = prefs.maxHistoryMessages <= 0
        ? 0
        : (publicHistoryCount * 48 / prefs.maxHistoryMessages).ceil();
    final budget = agentId == null
        ? '$conversation:$taskId'
        : '$conversation:$taskId:$agentId';
    // The history cap deliberately pins the goal even on a first round; token
    // pressure with no public results yet has nothing a checkpoint can shrink.
    if (!force && !hasPublicWork && historyCount < 48) return null;
    if (!force &&
        !_publicCompactor.shouldCompact(
          taskId: budget,
          round: round,
          estimatedTokens: estimated,
          inputBudgetTokens: prefs.inputBudgetTokens,
          historyCount: historyCount,
        )) {
      return null;
    }
    final requestId = 'public-checkpoint:${const Uuid().v4()}';
    _capabilityRef
        .read(workSessionInsightsProvider.notifier)
        .auxiliaryRequest(conversation, requestId, config);
    _runtimeLog(
      conversationId: conversation,
      taskId: taskId,
      phase: 'context_compaction',
      status: 'started',
      config: config,
      requestId: requestId,
      detail:
          '主动公开检查点：估计 $estimated / ${prefs.inputBudgetTokens} tokens；原始消息/工具来源保留。',
    );
    final checkpoint = await _withAuxiliaryRootCapacity(
      rootId: agentId == null ? _run?.agentRootId : null,
      token: token,
      action: () => _publicCompactor.compact(
        force: force,
        taskId: budget,
        sourceVersion: sourceVersion,
        round: round,
        estimatedTokens: estimated,
        inputBudgetTokens: prefs.inputBudgetTokens,
        historyCount: historyCount,
        goal: goal,
        publicText: transcript,
        publicNotes: [
          jsonEncode(own),
          memory.guidance(conversation, agentId: agentId),
          updates,
        ],
        config: config,
        provider: _capabilityRef.read(llmProvider),
        cancelToken: token,
        onChunk: (chunk) {
          if (_capabilityRef.mounted && chunk.usage != null) {
            _capabilityRef
                .read(workSessionInsightsProvider.notifier)
                .usage(conversation, requestId, chunk.usage!);
          }
        },
      ),
    );
    if (!_capabilityRef.mounted || token.isCancelled) return null;
    if (checkpoint == null) {
      _runtimeLog(
        conversationId: conversation,
        taskId: taskId,
        phase: 'context_compaction',
        status: 'not_applied',
        config: config,
        requestId: requestId,
        detail: '自动检查点未完成；保留原始历史，使用本地预算并可 work_history 回读。',
      );
      return null;
    }
    final latestOwn = memory.snapshot(conversation, agentId: agentId);
    final latestRoot = memory.snapshot(conversation);
    final latestUpdates = _capabilityRef
        .read(workTaskSteeringProvider)
        .instructions(conversation, taskId);
    final latestFingerprint = sha256
        .convert(
          utf8.encode('${readPublicSources().join('\n\n')}\n$latestUpdates'),
        )
        .toString();
    if ('${latestOwn['revision'] ?? 0}:${latestRoot['revision'] ?? 0}:$latestFingerprint' !=
        checkpoint.sourceVersion) {
      _runtimeLog(
        conversationId: conversation,
        taskId: taskId,
        phase: 'context_compaction',
        status: 'stale_discarded',
        requestId: requestId,
      );
      return null;
    }
    try {
      final constraints = {
        if ((own['constraints'] as String? ?? '').isNotEmpty)
          own['constraints'] as String,
        if (checkpoint.constraints.isNotEmpty) checkpoint.constraints,
      }.join('\n');
      final saved = await memory.checkpoint(conversation, {
        'expected_revision': own['revision'] ?? 0,
        'summary':
            '${checkpoint.summary}${checkpoint.openQuestions.isEmpty ? '' : '\n待核实：${checkpoint.openQuestions.join('；')}'}',
        'constraints': constraints,
        'plan': checkpoint.plan,
        'compact': true,
      }, agentId: agentId);
      _runtimeLog(
        conversationId: conversation,
        taskId: taskId,
        phase: 'context_compaction',
        status: 'checkpoint_saved',
        requestId: requestId,
        detail: '公开摘要已按版本保存；原始目标/用户固定约束不改写，下一请求压缩旧上下文。',
      );
      return saved;
    } catch (_) {
      _runtimeLog(
        conversationId: conversation,
        taskId: taskId,
        phase: 'context_compaction',
        status: 'checkpoint_not_saved',
        requestId: requestId,
      );
      if (force) rethrow;
    }
    return null;
  }
}
