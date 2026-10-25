part of '../chat_controller.dart';

const _roleLibrarySearchSpec = ToolSpec(
  name: 'role_library_search',
  description: '创建新角色前检索真实的现有角色库、当前工具与资料索引。优先复用已有角色；返回 search_id 用于待验证提案。',
  parameters: {
    'type': 'object',
    'properties': {
      'task': {'type': 'string'},
    },
    'required': ['task'],
  },
);
const _roleProposeSpec = ToolSpec(
  name: 'role_propose',
  description:
      '基于 role_library_search 的 search_id 创建待验证角色，不能直接启用。写清实际指令、范围、来源、所需已开放工具与模型。提示词不会授予权限。',
  parameters: {
    'type': 'object',
    'properties': {
      'search_id': {'type': 'string'},
      'name': {'type': 'string'},
      'when': {'type': 'string'},
      'instructions': {'type': 'string'},
      'model': {'type': 'string'},
      'source': {'type': 'string'},
      'required_tools': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'required': [
      'search_id',
      'name',
      'when',
      'instructions',
      'source',
      'required_tools',
    ],
  },
);

class _CapabilityRound {
  _CapabilityRound(this.tools, this.supervisor);
  final ToolRegistrySettings tools;
  final SupervisorConfig supervisor;
  late final MathToolkit mathematics = tools.mathematics;
}

extension ChatCapabilityExtensions on ChatTools {
  static const _directTraceNames = {
    'math_calculate',
    'tool_registry_search',
    'tool_registry_request',
    'role_library_search',
    'role_propose',
    'work_memory_checkpoint',
    'work_memory_recall',
    'work_history',
  };

  String _safeCapabilityArguments(ToolCall call, SettingsState settings) {
    final secrets = [
      settings.apiKey,
      settings.searchApiKey,
      settings.jevApiKey,
      settings.visionApiKey,
      settings.imageGenerationApiKey,
      settings.ttsApiKey,
      settings.asrApiKey,
      settings.gatewayToken,
      settings.gatewayLegacyToken,
      ...settings.customMcpTokens.values,
    ];
    Object? clean(Object? value, [String key = '']) {
      if (RegExp(
        r'key|token|password|secret|authorization|cookie',
        caseSensitive: false,
      ).hasMatch(key)) {
        return '[redacted]';
      }
      if (value is Map) {
        return {
          for (final entry in value.entries)
            entry.key.toString(): clean(entry.value, entry.key.toString()),
        };
      }
      if (value is List) return value.map((v) => clean(v)).toList();
      if (value is String) {
        return sanitizeRuntimeLogText(value, secrets: secrets);
      }
      return value;
    }

    try {
      return jsonEncode(clean(jsonDecode(call.argumentsJson)));
    } catch (_) {
      return '{"arguments":"[invalid JSON omitted]"}';
    }
  }

  String _directToolOutcome(String content, {required bool cancelled}) {
    if (cancelled) return 'cancelled';
    if (content.startsWith('用户未批准')) return 'denied';
    if (content.startsWith('当前完整工具轮未开放') ||
        content.startsWith('本会话已禁止联网') ||
        content.startsWith('未执行：') ||
        content.startsWith('本轮最多执行')) {
      return 'skipped';
    }
    try {
      final data = jsonDecode(content);
      if (data is Map && data['execution_outcome'] == 'unknown') {
        return 'unknown';
      }
      if (data is Map &&
          ((data['rejected'] is List &&
                  (data['rejected'] as List).isNotEmpty) ||
              (data['error'] is String &&
                  (data['error'] as String).startsWith('请求包含未发现')))) {
        return 'denied';
      }
      if (data is Map &&
          (data['ok'] == false ||
              data['error'] != null ||
              data['execution_outcome'] == 'failed')) {
        return 'failed';
      }
    } catch (_) {}
    return 'completed';
  }

  Future<void> _reviewCompletedRoleTrial(
    WorkAgentRecord record,
    WorkAgentRoleTrial trial, {
    required String convoId,
    required LlmConfig config,
    required SettingsState settings,
    required List<String> availableTools,
    required List<String> allowedModels,
    required CancelToken token,
  }) async {
    final options = _capabilityRef.read(roleValidationSettingsProvider);
    if (!options.enabled ||
        record.status != WorkAgentStatus.completed ||
        token.isCancelled) {
      return;
    }
    final candidate = _capabilityRef
        .read(roleEvolutionProvider)
        .where(
          (c) =>
              c.role.id == trial.candidateId &&
              c.version == trial.version &&
              !c.disabled,
        )
        .firstOrNull;
    if (candidate == null ||
        candidate.requiredTools.any((name) => !availableTools.contains(name)) ||
        candidate.role.model.isNotEmpty &&
            !allowedModels.contains(candidate.role.model)) {
      return;
    }
    var reviewer = record.resolvedConfig ?? config;
    final choice = options.model == '__supervisor__'
        ? _capabilityRef.read(supervisorSettingsProvider).model
        : options.model == '__current__'
        ? reviewer.model
        : options.model;
    if (choice.isEmpty) return;
    reviewer = await resolveConversationModel(
      _capabilityRef,
      convoId,
      reviewer,
      work: false,
      images: false,
      thinking: false,
      choiceOverride: choice,
      useChoiceOverride: true,
      settingsOverride: settings,
    );
    if (reviewer.model != choice || token.isCancelled) return;
    final requestId = 'role-review:${const Uuid().v4()}';
    reviewer = reviewer.copyWith(routingSessionId: requestId);
    final resultHash = sha256.convert(utf8.encode(record.output)).toString();
    String evidenceFingerprint() => sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'task': record.task,
              'result': record.output,
              'tools': [
                for (final message in record.context)
                  if (message.role == MessageRole.tool)
                    {'id': message.toolCallId, 'result': message.content},
              ],
            }),
          ),
        )
        .toString();
    final evidenceHash = evidenceFingerprint();
    if (candidate.evidence.any(
      (entry) =>
          entry['taskId'] == record.id &&
          entry['reviewEvidenceHash'] == evidenceHash,
    )) {
      return;
    }
    final observedTools = [
      for (final message
          in record.context
              .where((m) => m.role == MessageRole.tool)
              .toList()
              .reversed
              .take(12))
        {
          'call_id': message.toolCallId,
          'result': message.content.length > 2000
              ? '${message.content.substring(0, 1000)}\n[中间省略]\n${message.content.substring(message.content.length - 1000)}'
              : message.content,
          'truncated': message.content.length > 2000,
        },
    ];
    final requiresExecutionEvidence =
        candidate.requiredTools.any(
          (name) => !{'math_calculate'}.contains(name),
        ) ||
        RegExp(
          r'代码|测试|构建|执行|coding|test|build|run command|implementation',
          caseSensitive: false,
        ).hasMatch('${candidate.role.when} ${candidate.role.instructions}');
    _capabilityRef
        .read(workSessionInsightsProvider.notifier)
        .auxiliaryRequest(convoId, requestId, reviewer);
    final verdict = await _withAuxiliaryRootCapacity(
      rootId: _capabilityRef.read(workAgentsProvider).rootIdFor(record.id),
      token: token,
      action: () => _capabilityRef
          .read(roleTrialValidatorProvider)
          .review(
            settings: options,
            taskId: record.taskId,
            candidateId: trial.candidateId,
            version: trial.version,
            scope: candidate.role.when,
            instructions: candidate.role.instructions,
            task: record.task,
            result: record.output,
            expectedHash: resultHash,
            evidenceHash: evidenceHash,
            acceptanceCriteria: record.task,
            toolEvidence: observedTools,
            requiresExecutionEvidence: requiresExecutionEvidence,
            config: reviewer,
            provider: _capabilityRef.read(llmProvider),
            token: token,
            onChunk: (chunk) {
              if (_capabilityRef.mounted && chunk.usage != null) {
                _capabilityRef
                    .read(workSessionInsightsProvider.notifier)
                    .usage(convoId, requestId, chunk.usage!);
              }
            },
          ),
    );
    if (verdict == null ||
        !_capabilityRef.mounted ||
        token.isCancelled ||
        evidenceFingerprint() != evidenceHash ||
        !identical(
          _capabilityRef.read(roleValidationSettingsProvider),
          options,
        )) {
      return;
    }
    await _capabilityRef
        .read(roleEvolutionProvider.notifier)
        .recordModelReview(
          id: trial.candidateId,
          version: trial.version,
          taskId: record.id,
          resultHash: resultHash,
          passed: verdict.passed,
          criteria: verdict.criteria,
          limitations: verdict.limitations,
          model: verdict.model,
          evidenceHash: evidenceHash,
        );
    if (!_capabilityRef.mounted || token.isCancelled || !verdict.passed) return;
    final currentCandidate = _capabilityRef
        .read(roleEvolutionProvider)
        .where(
          (c) =>
              c.role.id == trial.candidateId &&
              c.version == trial.version &&
              !c.disabled,
        )
        .firstOrNull;
    if (!options.autoPromote ||
        currentCandidate?.verified != true ||
        token.isCancelled) {
      return;
    }
    bool stillAuthorized() {
      if (!_capabilityRef.mounted || token.isCancelled) return false;
      final latestOptions = _capabilityRef.read(roleValidationSettingsProvider);
      if (token.isCancelled ||
          !latestOptions.enabled ||
          !latestOptions.autoPromote ||
          !identical(latestOptions, options) ||
          evidenceFingerprint() != evidenceHash) {
        return false;
      }
      final latestCandidate = _capabilityRef
          .read(roleEvolutionProvider)
          .where(
            (c) =>
                c.role.id == trial.candidateId &&
                c.version == trial.version &&
                !c.disabled &&
                c.verified,
          )
          .firstOrNull;
      if (latestCandidate == null) return false;
      if (latestCandidate.requiredTools.contains('math_calculate') &&
          !_capabilityRef.read(toolRegistrySettingsProvider).mathEnabled) {
        return false;
      }
      final latestSettings = _capabilityRef
          .read(settingsControllerProvider)
          .requireValue;
      final latestPool =
          _capabilityRef
              .read(workAgentModelPoolProvider)
              ?.map((entry) => entry.model)
              .toList() ??
          [latestSettings.model];
      if (latestCandidate.role.model.isNotEmpty &&
          !latestPool.contains(latestCandidate.role.model)) {
        return false;
      }
      if (_run?.configuration != null &&
          _desiredConfiguration(
            convoId,
          ).changesFrom(_run!.configuration!).isNotEmpty) {
        return false;
      }
      return true;
    }

    final promoted = await _capabilityRef
        .read(settingsControllerProvider.notifier)
        .appendValidatedRoleIfAbsent(
          currentCandidate!.role.copyWith(
            enabled: true,
            version: currentCandidate.version,
            source: currentCandidate.source,
            requiredTools: currentCandidate.requiredTools,
            validation:
                'model:${verdict.model}; ${verdict.resultHash}; ${verdict.criteria}; ${verdict.limitations}',
          ),
          stillValid: stillAuthorized,
        );
    if (!promoted) return;
    _runtimeLog(
      conversationId: convoId,
      taskId: record.taskId,
      phase: 'role_validation',
      status: 'model_reviewed_promoted',
      config: reviewer,
      requestId: requestId,
    );
  }

  _CapabilityRound _captureCapabilities() => _CapabilityRound(
    _capabilityRef.read(toolRegistrySettingsProvider),
    _capabilityRef.read(supervisorSettingsProvider),
  );

  List<ToolSpec> _capabilityTools(
    _CapabilityRound snapshot, {
    required bool workMode,
  }) => [
    if (snapshot.tools.mathEnabled) MathToolkit.spec,
    if (workMode) _roleLibrarySearchSpec,
    if (workMode) _roleProposeSpec,
  ];

  Future<String?> _executeCapabilityTool(
    ToolCall call, {
    required _CapabilityRound snapshot,
    required CancelToken token,
    required List<ToolSpec> availableTools,
    required SettingsState settings,
    required List<String> allowedModels,
    TaskToolRegistry? registry,
    Future<bool> Function(ToolSpec)? authorizeTool,
  }) async {
    if (!{
      'math_calculate',
      'role_library_search',
      'role_propose',
      'tool_registry_search',
      'tool_registry_request',
    }.contains(call.name)) {
      return null;
    }
    if (token.isCancelled) throw token.cancelError!;
    final arguments = Map<String, dynamic>.from(
      jsonDecode(call.argumentsJson) as Map,
    );
    if (call.name == 'tool_registry_search') {
      return jsonEncode(
        registry?.search(arguments['query'] as String) ??
            {'ok': false, 'error': '本任务未初始化工具注册表'},
      );
    }
    if (call.name == 'tool_registry_request') {
      if (registry == null || authorizeTool == null) {
        return jsonEncode({'ok': false, 'error': '本任务没有按需加载权限入口'});
      }
      return jsonEncode(
        await registry.request(
          (arguments['tools'] as List).cast<String>(),
          authorize: authorizeTool,
        ),
      );
    }
    if (call.name == 'math_calculate') {
      if (!snapshot.tools.mathEnabled) {
        return jsonEncode({'ok': false, 'error': '数学工具未在本轮启用'});
      }
      return jsonEncode(
        await snapshot.mathematics.execute(arguments, cancelToken: token),
      );
    }
    final roles = _capabilityRef.read(roleEvolutionProvider.notifier);
    if (call.name == 'role_library_search') {
      final task = arguments['task'] as String;
      final terms = task
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((term) => term.isNotEmpty)
          .toList();
      final library = await _capabilityRef
          .read(libraryRepositoryProvider)
          .list();
      final materials = library
          .where(
            (item) => terms.any(
              (term) =>
                  item.name.toLowerCase().contains(term) ||
                  term.contains(item.name.toLowerCase()),
            ),
          )
          .take(20)
          .map((item) => '${item.id}: ${item.name} [${item.sha256}]')
          .toList();
      return jsonEncode(
        roles.search(
          task: task,
          roles: settings.effectiveSubagentRoles,
          availableTools: availableTools.map((t) => t.name).toList(),
          materials: materials,
        ),
      );
    }
    final model = arguments['model'] as String? ?? '';
    if (model.isNotEmpty && !allowedModels.contains(model)) {
      return jsonEncode({'ok': false, 'error': '候选角色模型不在当前允许池'});
    }
    final candidate = await roles.propose(
      searchId: arguments['search_id'] as String,
      name: arguments['name'] as String,
      when: arguments['when'] as String,
      instructions: arguments['instructions'] as String,
      model: model,
      requiredTools: (arguments['required_tools'] as List).cast<String>(),
      source: arguments['source'] as String,
    );
    return jsonEncode({
      'ok': true,
      'candidate': candidate.toJson(),
      'next': '使用候选 ID 通过正常子代理执行试用，验收证据匹配本版本后可在设置中加入复用库；当前未启用',
    });
  }

  Future<SupervisorSuggestion?> _reviewCapabilityBoundary({
    required TaskSupervisor supervisor,
    required _CapabilityRound snapshot,
    required String convoId,
    required String taskId,
    required String version,
    required int round,
    required String trigger,
    required String goal,
    required String publicPlan,
    required List<String> resultSummaries,
    required Map<String, String> artifacts,
    required List<ToolSpec> tools,
    required List<String> allowedModels,
    required LlmConfig config,
    required SettingsState settings,
    required CancelToken token,
  }) async {
    final reviewSnapshot = SupervisorSnapshot(
      taskId: taskId,
      version: version,
      round: round,
      trigger: trigger,
      goal: goal,
      publicPlan: publicPlan,
      resultSummaries: resultSummaries,
      artifacts: artifacts,
      availableTools: tools.map((t) => t.name).toList(),
      allowedModels: allowedModels,
    );
    if (!supervisor.shouldReview(snapshot.supervisor, reviewSnapshot)) {
      return null;
    }
    var selected = await resolveConversationModel(
      _capabilityRef,
      convoId,
      config,
      work: false,
      images: false,
      thinking: false,
      choiceOverride: snapshot.supervisor.model,
      useChoiceOverride: true,
      settingsOverride: settings,
    );
    if (selected.model != snapshot.supervisor.model) return null;
    final requestId = 'supervisor:${const Uuid().v4()}';
    selected = selected.copyWith(routingSessionId: requestId);
    _capabilityRef
        .read(workSessionInsightsProvider.notifier)
        .auxiliaryRequest(convoId, requestId, selected);
    _runtimeLog(
      conversationId: convoId,
      taskId: taskId,
      phase: 'supervisor',
      status: 'started',
      config: selected,
      requestId: requestId,
    );
    final suggestion = await _withAuxiliaryRootCapacity(
      rootId: _run?.agentRootId,
      token: token,
      action: () => supervisor.review(
        settings: snapshot.supervisor,
        snapshot: reviewSnapshot,
        provider: _capabilityRef.read(llmProvider),
        config: selected,
        cancelToken: token,
        onChunk: (chunk) {
          if (!_capabilityRef.mounted) return;
          if (chunk.usage != null) {
            _capabilityRef
                .read(workSessionInsightsProvider.notifier)
                .usage(convoId, requestId, chunk.usage!);
          }
        },
      ),
    );
    _runtimeLog(
      conversationId: convoId,
      taskId: taskId,
      phase: 'supervisor',
      status: suggestion?.isIntervention == true
          ? 'suggested'
          : 'no_intervention',
      config: selected,
      requestId: requestId,
    );
    return supervisor.takeAtBoundary(
      taskId: taskId,
      version: version,
      completedRound: round,
    );
  }
}
