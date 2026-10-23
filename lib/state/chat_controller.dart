import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/desktop_providers.dart';
import '../domain/desktop/workspace_tools.dart';
import 'conversation_workspace_bindings.dart';
import 'conversation_model_choice.dart';
import '../data/chat_skill.dart';
import '../data/gateway_config.dart' show GatewayConnection;
import '../data/composer_modes.dart';
import '../data/db/app_database.dart' show GenerationRecord;
import '../data/generation_repository.dart';
import '../data/models.dart';
import '../data/story_models.dart';
import '../data/study_models.dart';
import '../domain/chat/chat_skill_router.dart';
import '../domain/chat/request_context_builder.dart';
import '../domain/chat/client_tool_prompt.dart';
import '../domain/chat/study_request_context.dart';
import '../domain/chat/conversation_persistence.dart';
import '../domain/chat/conversation_tree.dart';
import '../domain/chat/error_describe.dart';
import '../domain/chat/long_task_runner.dart';
import '../domain/chat/long_task_configuration.dart';
import '../domain/chat/tool_loop_policy.dart';
import '../domain/chat/tool_markup_filter.dart';
import '../domain/chat/generation_execution.dart';
import '../domain/chat/generation_stream.dart';
import '../domain/chat/tool_call_runner.dart';
import '../domain/chat/tool_image_context.dart';
import '../domain/chat/stream_ui_coalescer.dart';
import '../domain/chat/stream_answer_buffer.dart';
import '../domain/chat/stream_answer_presenter.dart';
import '../domain/mcp/mcp_host_tools.dart';
import '../domain/mcp/computer_use_policy.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/workbench/changes/delivery_snapshot.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/llm_request_policy.dart';
import '../domain/media/image_reference_preparer.dart';
import '../domain/media/image_generation_service.dart';
import '../domain/media/image_prompt_optimizer.dart';
import '../domain/media/image_edit_reference.dart';
import '../domain/media/image_prompt_safety.dart';
import '../domain/notify/generation_notify.dart';
import '../domain/story/story_constraint_compiler.dart';
import '../domain/story/story_generation_intent.dart';
import '../domain/story/story_prompt_assembler.dart';
import '../domain/study/tutor_style.dart';
import '../domain/document/document_edit_tools.dart';
import '../domain/tools/search_orchestrator.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/search_query.dart';
import '../domain/tools/tool_engine.dart';
import '../domain/tools/search_tool_executor.dart';
import '../domain/tools/vision_tools.dart';
import '../domain/tools/vision_tool_executor.dart';
import '../domain/tools/dialogue_image_executor.dart';
import '../domain/tools/document_tool_executor.dart';
import '../domain/tools/url_extract.dart';
import 'settings_controller.dart';
import 'work_session_insights.dart';
import 'work_runtime_logs.dart';
import 'reasoning_translation.dart';
import '../domain/llm/llm_http_errors.dart';
import 'conversation_previews.dart';
import 'session_policy.dart';
import 'work_approvals.dart';
import 'work_questions.dart';
import 'work_task_runtime.dart';
import 'work_rounds.dart';
import 'work_changes.dart';
import 'work_agents.dart';
import 'work_processes.dart';
import 'model_context.dart';
import 'model_service_routing.dart';
import 'deepseek_search.dart';
import '../domain/workbench/agents/agent_instructions.dart';
import '../domain/workbench/agents/subagent_role_router.dart';
import 'research_terminal_controller.dart';
import 'study_controller.dart';

import '../data/chat_state.dart';
export '../data/chat_state.dart';
export '../data/composer_modes.dart';

part 'chat/sessions.dart';
part 'chat/turns.dart';
part 'chat/media.dart';
part 'chat/generation.dart';
part 'chat/streaming.dart';
part 'chat/tools.dart';
part 'chat/mutations.dart';
part 'chat/task_recovery.dart';
part 'chat/session_runtime.dart';

/// Which client tool to force this turn, or [kToolChoiceRequired] when more
/// than one "强制" chip is on. Document-edit force always wins.
String? forcedClientToolName({
  required bool forceDocument,
  required bool forceImage,
  required bool forceClientSearch,
}) {
  return LlmRequestPolicy.forcedToolChoice(
    documentTool: forceDocument ? DocumentEditTools.editDocumentToolName : null,
    imageTool: forceImage ? ToolEngine.generateImageTool.name : null,
    searchTool: forceClientSearch ? ToolEngine.webSearchTool.name : null,
  );
}

/// Per-user-turn budget: dialogue may produce at most one image.
class _TurnImageBudget {
  int used = 0;
  static const maxPerTurn = 1;
  bool get canGenerate => used < maxPerTurn;
  void markUsed() => used++;
}

/// Shown when the final (tool-withheld) model round still answers with tool
/// calls instead of text, so the turn is never left blank.
const _emptyReplyFallback = '模型未能输出有效回复，请重试。';

/// A reasoning model can consume its entire output allowance before it
/// reaches the public answer channel. In that case the reasoning is not a
/// safe substitute for a final answer because it may be incomplete.
const _reasoningLimitFallback =
    '模型的思考过程占满了输出额度，未能生成最终正文。'
    '请重试；若已开启深度思考，可关闭后再试。';

const _maxToolCallsPerRound = ToolLoopPolicy.chatCallsPerRound;

/// Shared notifier kernel: Riverpod lifecycle, live chat state, persistence
/// and long-task runners. Feature methods live in the mixins below so this
/// library stays one class with a stable public API.
abstract class _ChatControllerBase extends AsyncNotifier<ChatState> {
  int _conversationSelectionRevision = 0;
  final _sessionRuns = <String, _SessionRun>{};
  final _unselectedExecution = GenerationExecution();
  _SessionRun? get _zoneRun => Zone.current[_sessionZoneKey] as _SessionRun?;
  _SessionRun? get _selectedRun => _sessionRuns[_rawState.currentId];
  _SessionRun? get _run => _zoneRun ?? _selectedRun;
  GenerationExecution get _execution => _run?.execution ?? _unselectedExecution;
  ChatState get _rawState => state.value ?? const ChatState();

  Set<String> get runningConversationIds => Set.unmodifiable(
    _sessionRuns.values
        .where((r) => r.execution.isActive)
        .map((r) => r.conversationId),
  );
  bool isConversationRunning(String id) =>
      _sessionRuns[id]?.execution.isActive ?? false;
  SessionPendingConfiguration? pendingSessionConfigFor(String id) {
    final run = _sessionRuns[id];
    if (run == null || !run.execution.isActive || run.configuration == null)
      return null;
    final changes = _desiredConfiguration(id).changesFrom(run.configuration!);
    return changes.isEmpty ? null : SessionPendingConfiguration(changes);
  }

  T _withSession<T>(T Function() action, {String? conversationId}) {
    final id =
        conversationId ?? _zoneRun?.conversationId ?? _rawState.currentId;
    if (id == null || _zoneRun?.conversationId == id) return action();
    final run = _sessionRuns.putIfAbsent(id, () => _SessionRun(id));
    return runZoned(action, zoneValues: {_sessionZoneKey: run});
  }

  Future<T> _inSession<T>(
    Future<T> Function() action, {
    String? conversationId,
  }) {
    final existing = _zoneRun;
    final id =
        conversationId ?? existing?.conversationId ?? _rawState.currentId;
    if (id == null) return action();
    if (existing != null && existing.conversationId == id) return action();
    final run = _sessionRuns.putIfAbsent(id, () => _SessionRun(id));
    return runZoned(action, zoneValues: {_sessionZoneKey: run});
  }

  _SessionConfiguration _desiredConfiguration(String id) =>
      _SessionConfiguration(
        policy: ref.read(sessionPolicyProvider)[id] ?? const SessionPolicy(),
        workspaceId: ref.read(conversationWorkspaceBindingsProvider)[id],
        modelChoice: ref.read(conversationModelChoiceProvider)[id],
        thinking: _composerThinking[id] ?? _rawState.deepThink,
        effort: _composerEffort[id] ?? _rawState.reasoningEffort,
        settings: ref.read(settingsControllerProvider).value,
        mcpServerIds:
            _rawState.conversations
                .where((c) => c.id == id)
                .firstOrNull
                ?.customMcpServerIds ??
            const [],
        servicePriorities: ref.read(modelServiceRoutingProvider),
      );
  final _sessionFailures = <String, _SessionFailure>{};
  final _composerThinking = <String, bool>{};
  final _composerEffort = <String, ReasoningEffort>{};
  SessionPolicy _policyFor(String id) =>
      (_zoneRun?.conversationId == id
          ? _zoneRun?.configuration?.policy
          : null) ??
      ref.read(sessionPolicyProvider)[id] ??
      const SessionPolicy();

  void _publishRuntimeState() {
    if (!ref.mounted || state.value == null) return;
    final raw = _rawState;
    final selected = _sessionRuns[raw.currentId];
    final savedFailure = _sessionFailures[raw.currentId];
    final failure = savedFailure?.dismissed == true ? null : savedFailure;
    final hasGlobalError = raw.error != null && raw.errorConvoId == null;
    state = AsyncData(
      raw.copyWith(
        runningConversationIds: runningConversationIds,
        sessionCheckpoints: Map.unmodifiable(_sessionCheckpoints),
        pendingSessionConfigurations: {
          for (final run in _sessionRuns.values)
            if (pendingSessionConfigFor(run.conversationId) case final pending?)
              run.conversationId: pending,
        },
        error: failure?.message ?? (hasGlobalError ? raw.error : null),
        errorConvoId: failure == null ? null : raw.currentId,
        retryOperation:
            failure?.retry ?? (hasGlobalError ? raw.retryOperation : null),
        streamingConvoId: selected?.streamingId,
        isSearching: selected?.searching ?? false,
        isGeneratingImage: selected?.generatingImage ?? false,
        isProcessingDocument: selected?.processingDocument ?? false,
      ),
    );
  }

  /// Completion notifications are scoped to the originating task, deduplicated,
  /// and delivered at a model-idle boundary. They never replay tool commands.
  void enqueueSessionEvent({
    required String conversationId,
    required String eventId,
    required String content,
    String? taskId,
    bool explicitFollowup = false,
  }) {
    if (!ref.mounted ||
        _deletedWhileStartingIds.contains(conversationId) ||
        !_rawState.conversations.any((c) => c.id == conversationId))
      return;
    final run = _sessionRuns.putIfAbsent(
      conversationId,
      () => _SessionRun(conversationId),
    );
    // A deliberate user follow-up is new authorization; completion callbacks
    // never set this flag and cannot reopen a closed task lineage.
    if (explicitFollowup &&
        taskId != null &&
        !run.userCancelled &&
        run.agentTaskId == taskId) {
      run.acceptedTaskIds.add(taskId);
      run.awaitingEvents = true;
    }
    if (run.userCancelled ||
        (!run.execution.isActive && !run.awaitingEvents) ||
        (taskId != null &&
            (run.cancelledTaskIds.contains(taskId) ||
                !run.acceptedTaskIds.contains(taskId))) ||
        !run.receivedEventIds.add(eventId))
      return;
    run.inbox.add(_SessionEvent(eventId, content, taskId));
    while (run.receivedEventIds.length > 2048) {
      run.receivedEventIds.remove(run.receivedEventIds.first);
    }
    _checkpointSession(
      run,
      run.execution.isActive
          ? SessionExecutionStatus.running
          : SessionExecutionStatus.waiting,
      '后台完成事件已进入会话收件箱',
    );
    _scheduleSessionWake(run);
  }

  List<_SessionEvent> _takeSessionEvents(_SessionRun run) {
    final events = run.inbox
        .where(
          (event) =>
              !run.userCancelled &&
              (event.taskId == null ||
                  !run.cancelledTaskIds.contains(event.taskId)) &&
              (event.taskId == null ||
                  run.acceptedTaskIds.contains(event.taskId)),
        )
        .toList();
    run.inbox.clear();
    return events;
  }

  void _scheduleSessionWake(_SessionRun run) {
    if (run.execution.isActive ||
        !run.awaitingEvents ||
        run.userCancelled ||
        run.wakeScheduled ||
        run.inbox.isEmpty)
      return;
    run.wakeScheduled = true;
    unawaited(
      Future<void>.delayed(Duration.zero, () async {
        run.wakeScheduled = false;
        if (!ref.mounted ||
            run.execution.isActive ||
            !run.awaitingEvents ||
            run.userCancelled ||
            _deletedWhileStartingIds.contains(run.conversationId))
          return;
        try {
          await _inSession(
            () => _dispatchSessionEvents(run),
            conversationId: run.conversationId,
          );
        } catch (error) {
          if (ref.mounted)
            _setScopedError('后台事件处理失败：$error', convoId: run.conversationId);
        }
      }),
    );
  }

  Future<void> _dispatchSessionEvents(_SessionRun run);

  /// Services intentionally outlive a turn. Only finite commands and children
  /// owned by the current lineage keep an otherwise idle task waiting.
  bool _hasPendingSessionWork(_SessionRun run) {
    if (run.inbox.isNotEmpty) return true;
    final agents = ref.read(workAgentsProvider);
    if (agents.records.any(
      (agent) =>
          agent.conversationId == run.conversationId &&
          run.acceptedTaskIds.contains(agent.taskId) &&
          !agent.external &&
          !agent.terminal,
    ))
      return true;
    return ref
        .read(workProcessesProvider)
        .records
        .any(
          (process) =>
              process.conversationId == run.conversationId &&
              run.acceptedTaskIds.contains(process.taskId) &&
              process.active &&
              !process.service &&
              process.hookId == null,
        );
  }

  String? get _sourceAgentId {
    final id = _zoneRun?.agentRootId;
    if (id == null) return null;
    return ref.read(workAgentsProvider).record(id)?.external == false
        ? id
        : null;
  }

  final _activeWorkTaskIds = <String, String>{};
  final _sessionCheckpoints = <String, SessionExecutionCheckpoint>{};
  Future<void> _journalWrite = Future.value();
  void _checkpointSession(
    _SessionRun run,
    SessionExecutionStatus status,
    String phase,
  ) {
    if (!ref.mounted || _deletedWhileStartingIds.contains(run.conversationId))
      return;
    _sessionCheckpoints[run.conversationId] = SessionExecutionCheckpoint(
      conversationId: run.conversationId,
      taskId: run.taskId,
      status: status,
      updatedAt: DateTime.now(),
      phase: phase,
      queuedEvents: run.inbox.length,
    );
    _runtimeLog(
      conversationId: run.conversationId,
      taskId: run.taskId,
      phase: 'session',
      status: status.name,
      detail: phase,
      level: status == SessionExecutionStatus.failed
          ? WorkRuntimeLogLevel.error
          : status == SessionExecutionStatus.cancelled ||
                status == SessionExecutionStatus.interrupted
          ? WorkRuntimeLogLevel.warning
          : WorkRuntimeLogLevel.info,
    );
    final saved = jsonEncode(
      _sessionCheckpoints.values.map((entry) => entry.toJson()).toList(),
    );
    final prefs = ref.read(sharedPrefsProvider);
    _journalWrite = _journalWrite
        .catchError((Object _) {})
        .then((_) async {
          if (!await prefs.setString('chatSessionJournal.v1', saved)) {
            throw StateError('会话执行检查点未保存');
          }
        })
        .catchError((Object error) {
          debugPrint('Session checkpoint: $error');
        });
  }

  Future<GenerationStreamResult> _consumeSessionStream<T>(
    Stream<T> source, {
    required CancelToken cancelToken,
    required void Function(T) onData,
    required LlmConfig config,
    required String requestId,
  }) async {
    final elapsed = Stopwatch()..start();
    var routedConfig = config;
    var firstResponse = false;
    final root = _run?.agentRootId;
    final agents = root == null ? null : ref.read(workAgentsProvider);
    _runtimeLog(
      phase: 'request',
      status: 'queued',
      config: config,
      requestId: requestId,
    );
    try {
      if (root != null) await agents!.acquireRootSlot(root, cancelToken);
      _runtimeLog(
        phase: 'request',
        status: 'awaiting_response',
        config: config,
        requestId: requestId,
        durationMs: elapsed.elapsedMilliseconds,
        detail: '请求已启动，等待首个模型响应；日志不包含请求正文',
      );
      final result = await _execution.consumeStream(
        source,
        cancelToken: cancelToken,
        onData: (chunk) {
          if (chunk is ChatChunk) {
            if (chunk.actualConfig case final actual?) {
              routedConfig = actual;
              _runtimeLog(
                phase: 'request',
                status: 'routed',
                config: actual,
                requestId: requestId,
                durationMs: elapsed.elapsedMilliseconds,
              );
            }
            if (!firstResponse &&
                (chunk.contentDelta != null ||
                    chunk.reasoningDelta != null ||
                    chunk.toolCalls != null ||
                    chunk.usage != null ||
                    chunk.finishReason != null)) {
              firstResponse = true;
              _runtimeLog(
                phase: 'request',
                status: 'response_started',
                config: routedConfig,
                requestId: requestId,
                durationMs: elapsed.elapsedMilliseconds,
              );
            }
          }
          onData(chunk);
        },
      );
      _runtimeLog(
        phase: 'request',
        status: result.end.name,
        config: routedConfig,
        requestId: requestId,
        durationMs: elapsed.elapsedMilliseconds,
        error: result.error,
        level: result.end == GenerationStreamEnd.failed
            ? WorkRuntimeLogLevel.error
            : result.end == GenerationStreamEnd.cancelled
            ? WorkRuntimeLogLevel.warning
            : WorkRuntimeLogLevel.info,
      );
      return result;
    } catch (error) {
      _runtimeLog(
        phase: 'request',
        status: cancelToken.isCancelled ? 'cancelled' : 'failed',
        config: routedConfig,
        requestId: requestId,
        durationMs: elapsed.elapsedMilliseconds,
        error: error,
        level: cancelToken.isCancelled
            ? WorkRuntimeLogLevel.warning
            : WorkRuntimeLogLevel.error,
      );
      rethrow;
    } finally {
      if (root != null) agents!.releaseRootSlot(root);
    }
  }

  /// Only structured client metadata reaches persistent diagnostics. In
  /// particular, generic exception messages and HTTP bodies may echo user data.
  void _runtimeLog({
    String? conversationId,
    String? taskId,
    required String phase,
    required String status,
    WorkRuntimeLogLevel level = WorkRuntimeLogLevel.info,
    LlmConfig? config,
    String? requestId,
    String? toolCallId,
    String? toolName,
    String? detail,
    Object? error,
    int? durationMs,
  }) {
    if (!ref.mounted) return;
    final id = conversationId ?? _run?.conversationId;
    if (id == null || _deletedWhileStartingIds.contains(id)) return;
    final selected = config ?? _run?.configuration?.settings?.config;
    int? httpStatus;
    if (error is LlmHttpException) {
      httpStatus = error.statusCode;
      detail = [
        if (error.apiCode != null &&
            RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(error.apiCode!))
          'code=${error.apiCode}',
        if (error.diagnostic != null) error.diagnostic!,
        if (error.diagnostic == null) 'HTTP 请求失败，响应正文未写入日志',
      ].join('\n');
    } else if (error is DioException) {
      httpStatus = error.response?.statusCode;
      detail =
          'Dio ${error.type.name}; underlying=${error.error?.runtimeType ?? 'none'}';
    } else if (error is TimeoutException) {
      detail =
          'TimeoutException; duration=${error.duration?.inMilliseconds ?? 'unknown'}ms';
    } else if (error != null) {
      detail = '${error.runtimeType}；详细业务错误见本轮消息，日志不复制工具内容';
    }
    try {
      ref
          .read(workRuntimeLogsProvider.notifier)
          .add(
            conversationId: id,
            taskId: taskId ?? _run?.taskId,
            phase: phase,
            status: status,
            level: level,
            requestId: requestId,
            toolCallId: toolCallId,
            toolName: toolName,
            model: selected?.model,
            endpoint: selected?.baseUrl,
            durationMs: durationMs,
            detail: detail,
            errorType: error?.runtimeType.toString(),
            httpStatus: httpStatus,
            timeoutSeconds: selected?.responseHeaderTimeout?.inSeconds,
            secrets: [
              if (selected != null) selected.apiKey,
              if (_run?.configuration?.settings?.searchApiKey case final key?)
                key,
            ],
          );
    } catch (_) {
      debugPrint('Runtime diagnostic recording unavailable');
    }
  }

  void _beginTaskBudget(SettingsState settings) {
    _execution.beginBudget(
      settings.taskBudget,
      beforeCancel: () {
        if (ref.mounted) _flushActiveStream?.call();
      },
    );
  }

  /// Invoked by [stop] before it snapshots the conversation, so a scheduled UI
  /// flush cannot leave the last received tokens out of the saved transcript.
  void Function()? get _flushActiveStream => _run?.flush;
  set _flushActiveStream(void Function()? value) {
    _run?.flush = value;
  }

  /// Stick-to-bottom: the user is following the live tail.
  bool get _streamFollowingTail => _run?.followingTail ?? true;
  set _streamFollowingTail(bool value) {
    _run?.followingTail = value;
  }

  /// Thinking panel expanded on the in-flight assistant bubble.
  bool get _streamThinkingExpanded => _run?.thinkingExpanded ?? true;
  set _streamThinkingExpanded(bool value) {
    _run?.thinkingExpanded = value;
  }

  /// True once the current stream has emitted visible answer tokens.
  bool get _streamHasLiveContent => _run?.hasLiveContent ?? false;
  set _streamHasLiveContent(bool value) {
    _run?.hasLiveContent = value;
  }

  bool _appInBackground = false;
  bool _chatVisible = true;

  StreamUiFocus get _streamUiFocus =>
      _appInBackground ||
          !_chatVisible ||
          (_zoneRun != null && _zoneRun!.conversationId != _rawState.currentId)
      ? StreamUiFocus.away
      : streamUiFocusFor(
          followingTail: _streamFollowingTail,
          hasContent: _streamHasLiveContent,
          thinkingExpanded: _streamThinkingExpanded,
        );

  /// Live catch-up when the user looks back at a streaming pane.
  void Function()? get _nudgeStreamUi => _run?.nudge;
  set _nudgeStreamUi(void Function()? value) {
    _run?.nudge = value;
  }

  /// Lifecycle changes flush/checkpoint the existing stream; never cancel it.
  void reportAppBackground(bool background) {
    if (_appInBackground == background) return;
    _appInBackground = background;
    for (final run in _sessionRuns.values) {
      run.flush?.call();
      if (background && run.execution.isActive)
        _persistence.checkpointSoon(run.conversationId);
    }
  }

  /// Navigation changes presentation only; the controller still owns the SSE.
  void reportChatVisible(bool visible) {
    if (_chatVisible == visible) return;
    _chatVisible = visible;
    _flushActiveStream?.call();
    final id = _s.streamingConvoId;
    if (!visible && id != null) _persistence.checkpointSoon(id);
    if (visible) _nudgeStreamUi?.call();
  }

  /// Chat page reports scroll/thinking-panel attention during a live stream.
  void reportStreamView({
    required bool followingTail,
    required bool thinkingExpanded,
  }) {
    if (_streamFollowingTail == followingTail &&
        _streamThinkingExpanded == thinkingExpanded) {
      return;
    }
    final before = _streamUiFocus;
    _streamFollowingTail = followingTail;
    _streamThinkingExpanded = thinkingExpanded;
    if (_streamUiFocus != before && _streamUiFocus != StreamUiFocus.away) {
      _nudgeStreamUi?.call();
    }
  }

  /// Conversations deleted while a generation was still in the [_execution.isActive]
  /// preflight window. [_generate] consults this tombstone to abandon (not
  /// resurrect) a turn whose target was deleted before streaming began.
  final Set<String> _deletedWhileStartingIds = {};

  /// Background document jobs are independent from the one ordinary chat SSE
  /// stream. Several conversations may have one running at the same time.
  /// Lazily created because [ref] is not readable during field
  /// initialization; the injected closures defer every [ref] access.
  LongTaskRunner? _longTaskRunner;
  LongTaskRunner get _longTasks => _longTaskRunner ??= LongTaskRunner(
    client: () => ref.read(longTaskGatewayClientProvider),
    readSettings: () async {
      final settings = await ref.read(settingsControllerProvider.future);
      return LongTaskConfiguration(
        gateway: settings.gateway,
        gatewayToken: settings.gatewayToken,
        systemPrompt: settings.systemPrompt,
        gatewayTokenProvider: settings.gatewayTokenProvider,
      );
    },
    conversations: () => _s.conversations,
    findTask: _findLongTask,
    writeTask: _writeLongTask,
    reportError: (error, {convoId}) => _setScopedError(error, convoId: convoId),
  );

  /// Serialized conversation persistence (write queue + stream checkpoints).
  /// Lazily created because [ref] is not readable during field
  /// initialization; the injected closures defer every [ref] access.
  ConversationPersistence? _conversationPersistence;
  ConversationPersistence get _persistence =>
      _conversationPersistence ??= ConversationPersistence(
        repository: () => ref.read(conversationRepositoryProvider),
        currentConversation: () => _s.current,
        conversations: () => _s.conversations,
        mounted: () => ref.mounted,
        reportFailure: (message, {convoId}) =>
            _setScopedError(message, convoId: convoId),
      );

  @override
  Future<ChatState> build() async {
    // Reading conversation history must not wait for secure-storage/settings
    // I/O. Restore composer defaults once both independent loads are ready.
    void configurationChanged() {
      _publishRuntimeState();
    }

    ref.listen(sessionPolicyProvider, (_, _) => configurationChanged());
    ref.listen(
      conversationModelChoiceProvider,
      (_, _) => configurationChanged(),
    );
    ref.listen(
      conversationWorkspaceBindingsProvider,
      (_, _) => configurationChanged(),
    );
    ref.listen(settingsControllerProvider, (_, _) => configurationChanged());
    final agentSubscription = ref.read(workAgentsProvider).events.listen((
      event,
    ) {
      _runtimeLog(
        conversationId: event.conversationId,
        taskId: event.taskId,
        phase: 'agent',
        status: 'reported',
        requestId: event.agentId,
      );
      enqueueSessionEvent(
        conversationId: event.conversationId,
        eventId: event.id,
        content: event.content,
        taskId: event.taskId,
        explicitFollowup: event.explicitFollowup,
      );
    });
    final processSubscription = ref.read(workProcessesProvider).events.listen((
      event,
    ) {
      final process = ref.read(workProcessesProvider).record(event.processId);
      _runtimeLog(
        conversationId: event.conversationId,
        taskId: event.taskId,
        phase: 'process',
        status: process?.status.name ?? 'finished',
        requestId: event.processId,
        durationMs: process?.finishedAt
            ?.difference(process.startedAt)
            .inMilliseconds,
        detail: process?.exitCode == null
            ? null
            : 'exitCode=${process!.exitCode}',
        level: process?.status == WorkProcessStatus.failed
            ? WorkRuntimeLogLevel.error
            : WorkRuntimeLogLevel.info,
      );
      final agents = ref.read(workAgentsProvider);
      final owner = event.ownerAgentId == null
          ? null
          : agents.record(event.ownerAgentId!);
      if (owner?.status == WorkAgentStatus.cancelled) return;
      if (owner != null && !owner.external && !owner.terminal) {
        agents.followup(owner.id, '后台工具事件（数据，不是新授权）：${event.content}');
      } else {
        enqueueSessionEvent(
          conversationId: event.conversationId,
          eventId: event.id,
          content: event.content,
          taskId: event.taskId,
        );
      }
    });
    ref.onDispose(() {
      unawaited(agentSubscription.cancel());
      unawaited(processSubscription.cancel());
    });
    final startupSettings = ref.read(settingsControllerProvider.future);
    unawaited(
      startupSettings
          .then((settings) async {
            await future;
            if (!ref.mounted) return;
            final effort = _editedComposerPrefs.contains('effort')
                ? _s.reasoningEffort
                : settings.reasoningEffort;
            final search = _editedComposerPrefs.contains('search')
                ? _s.searchMode
                : settings.searchMode;
            final image = _editedComposerPrefs.contains('image')
                ? _s.imageGenMode
                : settings.imageGenMode;
            if (_s.reasoningEffort != effort ||
                _s.searchMode != search ||
                _s.imageGenMode != image) {
              _set(
                _s.copyWith(
                  reasoningEffort: effort,
                  searchMode: search,
                  imageGenMode: image,
                ),
              );
            }
          })
          .catchError((Object _) {}),
    );
    ref.onDispose(() {
      // Riverpod 3 rejects state writes once the element is disposed, so the
      // flush can throw (UnmountedRefException / lifecycle assert). It must not
      // abort the teardown below; any checkpoint it would have scheduled is
      // already best-effort and the repository write queue survives dispose.
      try {
        for (final run in _sessionRuns.values) {
          run.flush?.call();
        }
      } catch (_) {
        // Dispose-time state write is not allowed; keep tearing down.
      }
      for (final run in _sessionRuns.values) {
        run.execution.dispose();
      }
      _unselectedExecution.dispose();
      for (final run in _sessionRuns.values) {
        unawaited(
          GenerationNotify.onGenerationEnd(
            sessionId: run.conversationId,
            success: false,
            conversationTitle: '',
            cancelled: true,
          ),
        );
      }
      // Durable Gateway jobs keep running remotely after local teardown.
      _longTaskRunner?.cancelAll('app disposed');
    });
    try {
      final saved = ref
          .read(sharedPrefsProvider)
          .getString('chatSessionJournal.v1');
      if (saved != null) {
        for (final value in jsonDecode(saved) as List) {
          try {
            final checkpoint = SessionExecutionCheckpoint.fromJson(
              Map<String, dynamic>.from(value as Map),
            );
            _sessionCheckpoints[checkpoint.conversationId] = checkpoint;
          } catch (_) {
            /* Skip an invalid checkpoint without replaying work. */
          }
        }
      }
    } catch (_) {
      /* History must remain available if a journal is corrupt. */
    }
    final repo = ref.read(conversationRepositoryProvider);
    final summaries = await repo.loadSummaries();
    final settings = ref.read(settingsControllerProvider).value;
    final effort = settings?.reasoningEffort ?? ReasoningEffort.high;
    final searchMode = settings?.searchMode ?? SearchMode.auto;
    final imageGenMode = settings?.imageGenMode ?? ImageGenMode.auto;
    if (summaries.isEmpty) {
      final fresh = Conversation();
      return ChatState(
        sessionCheckpoints: Map.unmodifiable(_sessionCheckpoints),
        conversations: [fresh],
        currentId: fresh.id,
        reasoningEffort: effort,
        searchMode: searchMode,
        imageGenMode: imageGenMode,
      );
    }
    final currentId = summaries.first.id;
    final loadedById = <String, Conversation>{};
    String? loadError;
    try {
      loadedById[currentId] = await repo.loadConversation(currentId);
    } catch (error) {
      // An empty placeholder is not an empty archive. Keeping it unloaded
      // makes metadata-only saves preserve every existing message row.
      loadedById[currentId] = summaries.first.toPlaceholder();
      loadError = '无法加载会话：$error';
    }
    for (final summary in summaries) {
      if (!summary.hasActiveLongTask || loadedById.containsKey(summary.id)) {
        continue;
      }
      try {
        loadedById[summary.id] = await repo.loadConversation(summary.id);
      } catch (_) {
        // Resume is best-effort; the placeholder stays unloaded.
      }
    }
    final conversations = [
      for (final summary in summaries)
        loadedById[summary.id] ?? summary.toPlaceholder(),
    ];
    if (loadError != null) {
      _sessionFailures[currentId] = _SessionFailure(
        loadError,
        ChatRetryOperation.loadConversation(currentId),
      );
    }
    final initial = ChatState(
      conversations: conversations,
      sessionCheckpoints: Map.unmodifiable(_sessionCheckpoints),
      currentId: currentId,
      reasoningEffort: effort,
      searchMode: searchMode,
      imageGenMode: imageGenMode,
      error: loadError,
      errorConvoId: loadError == null ? null : currentId,
      retryOperation: loadError == null
          ? null
          : ChatRetryOperation.loadConversation(currentId),
    );
    // Let Riverpod publish [initial] before task runners begin mutating state.
    unawaited(Future<void>.delayed(Duration.zero, _resumeLongTasks));
    return initial;
  }

  ChatState get _s {
    final raw = _rawState;
    final run = _zoneRun;
    if (run == null) return raw;
    return raw.copyWith(
      currentId: run.conversationId,
      error:
          _sessionFailures[run.conversationId]?.message ??
          (raw.errorConvoId == null ? raw.error : null),
      errorConvoId: _sessionFailures.containsKey(run.conversationId)
          ? run.conversationId
          : null,
      retryOperation: _sessionFailures[run.conversationId]?.retry,
      streamingConvoId: run.streamingId,
      runningConversationIds: run.execution.isActive
          ? {run.conversationId}
          : const {},
      deepThink: run.configuration?.thinking,
      reasoningEffort: run.configuration?.effort,
      isSearching: run.searching,
      isGeneratingImage: run.generatingImage,
      isProcessingDocument: run.processingDocument,
    );
  }

  final Set<String> _editedComposerPrefs = {};

  bool _tryStartGeneration() {
    if (!_execution.tryStart()) return false;
    final run = _run;
    if (run != null) {
      run.userCancelled = false;
      run.awaitingEvents = false;
      if (!run.resumingAgentTree) {
        run.agentRootId = null;
        run.agentTaskId = null;
        run.acceptedTaskIds.clear();
        run.inbox.clear();
      }
      _composerThinking.putIfAbsent(
        run.conversationId,
        () => _rawState.deepThink,
      );
      _composerEffort.putIfAbsent(
        run.conversationId,
        () => _rawState.reasoningEffort,
      );
      run.configuration = _desiredConfiguration(run.conversationId);
      _checkpointSession(run, SessionExecutionStatus.running, '准备本轮请求');
    }
    _publishRuntimeState();
    // Protect preflight/upload as well as the response. Android must see this
    // while the send/regenerate action still has a foreground Activity.
    unawaited(
      GenerationNotify.onGenerationStart(sessionId: _run?.conversationId),
    );
    return true;
  }

  void _releaseGenerationProtection() {
    // Idempotent: a normal completion already ended the notification session.
    // Also covers rejected preflight, unexpected exceptions and disposal.
    unawaited(
      GenerationNotify.onGenerationEnd(
        sessionId: _run?.conversationId,
        success: false,
        conversationTitle: '',
        cancelled: true,
      ),
    );
  }

  void _finishStarting() {
    _releaseGenerationProtection();
    if (!ref.mounted) {
      _execution.finish();
      return;
    }
    final timedOutId = _run?.streamingId;
    if ((_execution.budget?.finishing ?? false) &&
        timedOutId != null &&
        !_execution.isCancelled) {
      _set(
        _s.copyWith(
          streamingConvoId: null,
          isSearching: false,
          isGeneratingImage: false,
          isProcessingDocument: false,
          error: '${_execution.budget!.reason}；已停止本地等待，远端状态未确认。',
          errorConvoId: timedOutId,
        ),
      );
      _persistence.persistSoon(_persistence.persistById(timedOutId));
    }
    final finalRun = _run;
    if (finalRun != null) {
      finalRun.awaitingEvents =
          !_execution.isCancelled &&
          !_sessionFailures.containsKey(finalRun.conversationId) &&
          _hasPendingSessionWork(finalRun);
      if (!finalRun.awaitingEvents) {
        finalRun.acceptedTaskIds.clear();
        finalRun.inbox.clear();
      }
      _checkpointSession(
        finalRun,
        _execution.isCancelled
            ? SessionExecutionStatus.cancelled
            : _sessionFailures.containsKey(finalRun.conversationId)
            ? SessionExecutionStatus.failed
            : finalRun.awaitingEvents
            ? SessionExecutionStatus.waiting
            : SessionExecutionStatus.completed,
        _execution.isCancelled
            ? '用户已停止，后台事件不会自动唤醒此任务'
            : finalRun.awaitingEvents
            ? '等待子任务或后台命令完成'
            : '本轮请求已结束，迟到事件不会自动重新执行',
      );
    }
    _execution.finish();
    final run = _run;
    if (run != null) {
      run.streamingId = null;
      run.searching = run.generatingImage = run.processingDocument = false;
      _scheduleSessionWake(run);
    }
    _publishRuntimeState();
  }

  void _set(ChatState next) {
    final raw = _rawState;
    final run = _zoneRun;
    final scope = run?.conversationId ?? next.currentId;
    if (next.error != null && (run != null || next.errorConvoId != null)) {
      final failureId = run?.conversationId ?? next.errorConvoId!;
      final previous = _sessionFailures[failureId];
      _sessionFailures[failureId] = _SessionFailure(
        next.error!,
        next.retryOperation,
        dismissed:
            previous?.dismissed == true &&
            previous?.message == next.error &&
            identical(previous?.retry, next.retryOperation),
      );
    } else if (next.error == null &&
        scope != null &&
        (run != null || raw.currentId == next.currentId) &&
        (run != null || _sessionFailures[scope]?.dismissed != true)) {
      _sessionFailures.remove(scope);
    }
    if (run != null) {
      run.streamingId = next.streamingConvoId;
      run.searching = next.isSearching;
      run.generatingImage = next.isGeneratingImage;
      run.processingDocument = next.isProcessingDocument;
      final updated = next.conversations
          .where((c) => c.id == run.conversationId)
          .firstOrNull;
      // Async callers own only this conversation. Never install another run's
      // stale transcript, selected id, or a conversation deleted during await.
      final canMerge =
          updated != null &&
          !_deletedWhileStartingIds.contains(run.conversationId) &&
          raw.conversations.any((c) => c.id == run.conversationId);
      next = raw.copyWith(
        conversations: canMerge
            ? [
                for (final c in raw.conversations)
                  c.id == run.conversationId ? updated : c,
              ]
            : raw.conversations,
        contextReports: {
          ...raw.contextReports,
          if (next.contextReports[run.conversationId] case final report?)
            run.conversationId: report,
        },
      );
    }
    state = AsyncData(next);
    _publishRuntimeState();
  }

  /// Error banner scoped to a conversation (in-flight stream or current).
  /// Dismissing presentation never cancels work or changes its outcome.
  void dismissError({String? conversationId}) {
    final id = conversationId ?? _rawState.currentId;
    final failure = _sessionFailures[id];
    if (id != null && failure != null) {
      // Keep the execution outcome while hiding its presentation. Finalization
      // can still be awaiting persistence when the user closes the banner.
      _sessionFailures[id] = _SessionFailure(
        failure.message,
        failure.retry,
        dismissed: true,
      );
    }
    final raw = _rawState;
    if (raw.errorConvoId == id || raw.errorConvoId == null) {
      state = AsyncData(
        raw.copyWith(error: null, errorConvoId: null, retryOperation: null),
      );
    }
    _publishRuntimeState();
  }

  void _setScopedError(
    String message, {
    String? convoId,
    ChatRetryOperation? retryOperation,
  }) {
    _set(
      _s.copyWith(
        error: message,
        errorConvoId: convoId ?? _s.streamingConvoId ?? _s.currentId,
        retryOperation: retryOperation,
      ),
    );
  }

  /// Replace the current conversation in the list with [updated].
  List<Conversation> _replace(Conversation updated) => [
    for (final c in _s.conversations) c.id == updated.id ? updated : c,
  ];

  Future<SettingsState> _settingsForSession() async {
    final captured = _run?.configuration?.settings;
    if (captured != null) return captured;
    return ref.read(settingsControllerProvider.future);
  }

  /// Validate settings; returns null (and sets an error) when not ready.
  Future<SettingsState?> _readySettings() async {
    final settings = await _settingsForSession();
    if (!settings.config.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  Future<SettingsState?> _readySettingsForTurn({
    bool requireVision = false,
  }) async {
    final settings = await _settingsForSession();
    final selectedConfig = await resolveConversationModel(
      ref,
      _s.currentId ?? '',
      _configForTurn(settings, hasImages: requireVision),
      work: _s.current?.workMode ?? false,
      images: requireVision,
      thinking: _s.deepThink,
      choiceOverride: _run?.configuration?.modelChoice,
      useChoiceOverride: _zoneRun != null,
      settingsOverride: _run?.configuration?.settings,
      servicePrioritiesOverride: _run?.configuration?.servicePriorities,
    );
    if (requireVision) {
      final config = selectedConfig;
      if (!settings.visionConfigured && !config.capabilities.supportsVision) {
        _set(
          _s.copyWith(
            error:
                '当前模型不支持看图。请选用视觉模型（如 ${KnownModels.vision}），'
                '或在设置中配置独立视觉 API。',
          ),
        );
        return null;
      }
    }
    if (!selectedConfig.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  /// Deep-think config for this turn.
  ///
  /// Models that accept DeepSeek's `thinking` field (V4 flash/pro/vision)
  /// stay on the selected model and only enable thinking. Providers without
  /// that field still switch to the profile's dedicated reasoner model.
  LlmConfig _configFor(SettingsState settings) =>
      _configForTurn(settings, hasImages: false);

  /// Image turns stay on a vision-capable chat model when deep-think's
  /// reasoner cannot accept pixels and no separate vision API is configured.
  LlmConfig _configForTurn(SettingsState settings, {required bool hasImages}) {
    return LlmRequestPolicy.selectModel(
      selected: settings.config,
      reasonerModel: settings.reasonerModel,
      thinking: _s.deepThink,
      hasImages: hasImages,
      hasVisionFallback: settings.visionConfigured,
    ).copyWith(routingSessionId: const Uuid().v4());
  }

  LongTaskState? _findLongTask(String convoId, String assistantId);
  Future<void> _writeLongTask(
    String convoId,
    String assistantId,
    LongTaskState task, {
    String? content,
  });
  Future<void> _resumeLongTasks();

  Future<void> _ensureConversationLoaded(String id) async {
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    if (_s.conversations[idx].messagesLoaded) return;
    try {
      late Conversation loaded;
      // A queued rename or other metadata save must finish before reading.
      await _persistence.enqueueWrite(() async {
        loaded = await ref
            .read(conversationRepositoryProvider)
            .loadConversation(id);
      });
      if (!ref.mounted) return;
      final current = _s.conversations.indexWhere((c) => c.id == id);
      if (current < 0) return;
      if (_s.conversations[current].messagesLoaded) return;
      // Metadata can also change while the read itself is in flight. The live
      // header owns those edits; only install the previously unloaded body.
      final restored = _s.conversations[current].copyWith(
        messages: loaded.messages,
        messagesLoaded: true,
      );
      final clearsLoadError =
          _s.retryOperation?.kind == ChatRetryKind.loadConversation &&
          _s.retryOperation?.conversationId == id;
      _set(
        _s.copyWith(
          conversations: _replace(restored),
          error: clearsLoadError ? null : _s.error,
        ),
      );
    } catch (error) {
      if (!ref.mounted) return;
      _setScopedError(
        '无法加载会话：$error',
        convoId: id,
        retryOperation: ChatRetryOperation.loadConversation(id),
      );
    }
  }

  bool _requireLoadedConversation(Conversation conversation) {
    if (conversation.messagesLoaded) return true;
    _setScopedError(
      '会话尚未加载，请先点击重试恢复历史记录。',
      convoId: conversation.id,
      retryOperation: ChatRetryOperation.loadConversation(conversation.id),
    );
    return false;
  }

  Future<void> selectConversation(String id) async {
    final revision = ++_conversationSelectionRevision;
    final previousCurrentId = _s.currentId;
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx >= 0 && !_s.conversations[idx].messagesLoaded) {
      await _ensureConversationLoaded(id);
      if (!ref.mounted) return;
      // Loading a large archive must not steal focus from a newer selection,
      // newly created conversation, or deletion fallback.
      if (revision != _conversationSelectionRevision ||
          _s.currentId != previousCurrentId) {
        return;
      }
    }
    if (!_s.conversations.any((c) => c.id == id)) return;
    final desired = _sessionRuns[id]?.configuration;
    if (!_composerThinking.containsKey(id))
      _composerThinking[id] = desired?.thinking ?? _s.deepThink;
    if (!_composerEffort.containsKey(id))
      _composerEffort[id] = desired?.effort ?? _s.reasoningEffort;
    // A failure that belongs to another conversation stays parked until the
    // user returns to it. Clearing it here made background failures impossible
    // to discover: hidden on B, then erased while selecting A.
    if (_s.error != null && _s.errorConvoId != null) {
      _set(
        _s.copyWith(
          currentId: id,
          deepThink: _composerThinking[id],
          reasoningEffort: _composerEffort[id],
        ),
      );
    } else {
      _set(
        _s.copyWith(
          currentId: id,
          error: null,
          deepThink: _composerThinking[id],
          reasoningEffort: _composerEffort[id],
        ),
      );
    }
  }

  String _titleFor(String? convoId) {
    if (convoId == null) return _s.current?.title ?? '对话';
    for (final c in _s.conversations) {
      if (c.id == convoId) return c.title;
    }
    return _s.current?.title ?? '对话';
  }

  String _previewFor(String convoId, String assistantId) {
    for (final c in _s.conversations) {
      if (c.id != convoId) continue;
      for (final m in c.messages) {
        if (m.id == assistantId) {
          final t = m.content.trim();
          return t.isEmpty ? m.reasoning.trim() : t;
        }
      }
    }
    return '';
  }

  Future<String> _studySystemPrompt(Conversation convo) async =>
      StudyRequestContext.build(
        convo,
        await ref.read(studyRepositoryProvider).load(),
      );
}

class ChatController extends _ChatControllerBase
    with
        ChatMutations,
        ChatTools,
        ChatStreaming,
        ChatGeneration,
        ChatMedia,
        ChatTurns,
        ChatSessions,
        ChatTaskRecovery {}

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
