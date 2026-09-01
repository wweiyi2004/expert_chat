import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/chat_skill.dart';
import '../../data/gateway_config.dart';
import '../../data/models.dart';
import '../../state/settings_controller.dart';
import '../llm/long_task_gateway_client.dart';
import 'conversation_tree.dart';
import 'error_describe.dart';

/// Runs durable Gateway document jobs: upload files, create the remote task,
/// then poll until it finishes. Background document jobs are independent from
/// the one ordinary chat SSE stream, so several conversations may have one
/// running at the same time.
///
/// Chat state stays owned by `ChatController`; this runner reaches it through
/// the injected callbacks below so the polling loop holds no `Ref`.
class LongTaskRunner {
  LongTaskRunner({
    required LongTaskGatewayClient Function() client,
    required Future<SettingsState> Function() readSettings,
    required List<Conversation> Function() conversations,
    required LongTaskState? Function(String convoId, String assistantId)
    findTask,
    required Future<void> Function(
      String convoId,
      String assistantId,
      LongTaskState task, {
      String? content,
    })
    writeTask,
    required void Function(String error, {String? convoId}) reportError,
    // The fields are private so the runner interface stays stable while
    // the named parameters stay public for construction and tests.
    // ignore: prefer_initializing_formals
  }) : _client = client,
       // ignore: prefer_initializing_formals
       _readSettings = readSettings,
       // ignore: prefer_initializing_formals
       _conversations = conversations,
       // ignore: prefer_initializing_formals
       _findTask = findTask,
       // ignore: prefer_initializing_formals
       _writeTask = writeTask,
       // ignore: prefer_initializing_formals
       _reportError = reportError;

  final LongTaskGatewayClient Function() _client;
  final Future<SettingsState> Function() _readSettings;
  final List<Conversation> Function() _conversations;
  final LongTaskState? Function(String convoId, String assistantId) _findTask;
  final Future<void> Function(
    String convoId,
    String assistantId,
    LongTaskState task, {
    String? content,
  })
  _writeTask;
  final void Function(String error, {String? convoId}) _reportError;

  final Set<String> _runs = {};
  final Map<String, CancelToken> _cancelTokens = {};

  /// Cancels every in-flight run. Stops local upload/polling only; once a
  /// Gateway task id exists, the durable server job intentionally keeps
  /// running.
  void cancelAll(String reason) {
    for (final token in _cancelTokens.values) {
      token.cancel(reason);
    }
    _cancelTokens.clear();
  }

  Future<void> run(String convoId, String assistantId) async {
    final runKey = '$convoId/$assistantId';
    if (!_runs.add(runKey)) return;
    final cancelToken = CancelToken();
    _cancelTokens[runKey] = cancelToken;
    try {
      final initialTask = _findTask(convoId, assistantId);
      if (initialTask == null || !initialTask.isActive) return;
      var task = initialTask;
      final connection = await _connectionFor(task);
      if (connection == null) {
        await _fail(
          convoId,
          assistantId,
          task,
          '找不到 Gateway 地址或访问 Token。请恢复长任务 Gateway 配置后重试。',
        );
        return;
      }
      final client = _client();
      final pollSeconds = (await _readSettings()).gateway.taskPollSeconds;

      var taskId = task.taskId;
      var remoteFileIds = List<String>.of(task.remoteFileIds);
      if (taskId == null || taskId.isEmpty) {
        final source = _source(convoId, assistantId);
        if (source == null || source.attachments.isEmpty) {
          await _fail(convoId, assistantId, task, '找不到原始附件，无法恢复上传。请重新发起长任务。');
          return;
        }
        if (source.attachments.any((a) => !a.hasDownloadableBytes)) {
          await _fail(
            convoId,
            assistantId,
            task,
            '旧附件没有保留原始文件，无法恢复上传。请重新选择文件后发起任务。',
          );
          return;
        }

        task = task.copyWith(
          status: LongTaskStatus.uploading,
          detail: '正在上传文件',
          error: null,
        );
        await _writeTask(convoId, assistantId, task);
        for (
          var index = remoteFileIds.length;
          index < source.attachments.length;
          index++
        ) {
          if (cancelToken.isCancelled ||
              _findTask(convoId, assistantId)?.isActive != true) {
            return;
          }
          task = task.copyWith(
            detail:
                '正在上传 ${index + 1}/${source.attachments.length}：'
                '${source.attachments[index].name}',
          );
          await _writeTask(convoId, assistantId, task);
          final fileId = await client.uploadFile(
            connection: connection,
            attachment: source.attachments[index],
            cancelToken: cancelToken,
          );
          if (cancelToken.isCancelled ||
              _findTask(convoId, assistantId)?.isActive != true) {
            await client.deleteFile(connection: connection, fileId: fileId);
            return;
          }
          remoteFileIds.add(fileId);
          task = task.copyWith(remoteFileIds: List.of(remoteFileIds));
          await _writeTask(convoId, assistantId, task);
        }

        task = task.copyWith(
          status: LongTaskStatus.queued,
          detail: '文件已上传，正在创建后台任务',
        );
        await _writeTask(convoId, assistantId, task);
        final messages = _messages(convoId, assistantId);
        final settings = await _readSettings();
        final authoredGeneral = settings.systemPrompt.trim();
        final factoryGeneral = ChatSkillCatalog.factory().fallback.prompt
            .trim();
        final globalPrompt =
            authoredGeneral.isNotEmpty && authoredGeneral != factoryGeneral
            ? authoredGeneral
            : '';
        final instructions = [
          if (globalPrompt.isNotEmpty) globalPrompt,
          '你正在执行一个长时间文档处理任务。请完整阅读所有上传文件，'
              '严格依据文件内容完成用户目标；输出结构清晰、证据充分的最终结果。',
        ].join('\n\n');
        final created = await client.create(
          connection: connection,
          messages: messages,
          fileIds: remoteFileIds,
          cancelToken: cancelToken,
          clientRequestId: assistantId,
          instructions: instructions,
        );
        taskId = created.id;
        task = task.copyWith(
          taskId: taskId,
          remoteFileIds: List.of(remoteFileIds),
          status: _status(created),
          progress: created.progress,
          lastEventId: created.lastEventId,
          detail:
              created.detail ??
              (created.isPending ? '服务端正在处理，可离开此会话' : '正在整理结果'),
        );
        await _writeTask(
          convoId,
          assistantId,
          task,
          content: created.outputText.trim().isEmpty
              ? null
              : created.outputText,
        );
        if (!created.isPending) {
          await _finishSnapshot(
            convoId,
            assistantId,
            task,
            created,
            connection,
            client,
          );
          return;
        }
      }

      var consecutivePollFailures = 0;
      while (!cancelToken.isCancelled) {
        final current = _findTask(convoId, assistantId);
        if (current == null || !current.isActive) return;
        await Future<void>.delayed(
          Duration(seconds: consecutivePollFailures == 0 ? pollSeconds : 10),
        );
        if (cancelToken.isCancelled) return;
        LongTaskSnapshot snapshot;
        try {
          snapshot = await client.retrieve(
            connection: connection,
            taskId: taskId,
            cancelToken: cancelToken,
          );
          consecutivePollFailures = 0;
        } catch (e) {
          if (cancelToken.isCancelled || isCancelError(e)) return;
          consecutivePollFailures++;
          final reconnecting = current.copyWith(
            status: LongTaskStatus.running,
            detail: '连接暂时中断，任务仍在服务端运行；正在重连',
            error: null,
          );
          await _writeTask(convoId, assistantId, reconnecting);
          continue;
        }

        task = current.copyWith(
          status: _status(snapshot),
          progress: snapshot.progress,
          lastEventId: snapshot.lastEventId,
          detail:
              snapshot.detail ??
              (snapshot.isPending ? '服务端正在处理，可离开此会话' : '正在整理结果'),
          error: null,
        );
        await _writeTask(
          convoId,
          assistantId,
          task,
          content: snapshot.outputText.trim().isEmpty
              ? null
              : snapshot.outputText,
        );
        if (!snapshot.isPending) {
          await _finishSnapshot(
            convoId,
            assistantId,
            task,
            snapshot,
            connection,
            client,
          );
          return;
        }
      }
    } catch (e) {
      if (!cancelToken.isCancelled && !isCancelError(e)) {
        final task = _findTask(convoId, assistantId);
        if (task != null && task.isActive) {
          await _fail(convoId, assistantId, task, describeError(e));
        }
      }
    } finally {
      _cancelTokens.remove(runKey);
      _runs.remove(runKey);
    }
  }

  Future<void> _finishSnapshot(
    String convoId,
    String assistantId,
    LongTaskState task,
    LongTaskSnapshot snapshot,
    GatewayConnection connection,
    LongTaskGatewayClient client,
  ) async {
    if (snapshot.isCompleted && snapshot.outputText.trim().isNotEmpty) {
      final completed = task.copyWith(
        status: LongTaskStatus.completed,
        detail: '处理完成',
        error: null,
      );
      await _writeTask(
        convoId,
        assistantId,
        completed,
        content: snapshot.outputText.trim(),
      );
    } else {
      final message =
          snapshot.error ??
          (snapshot.isCompleted
              ? '服务端已完成任务，但没有返回可显示的文本。'
              : snapshot.isCancelled
              ? '任务已取消。'
              : '后台任务未能完成（${snapshot.status}）。');
      final failed = task.copyWith(
        status: snapshot.isCancelled
            ? LongTaskStatus.cancelled
            : LongTaskStatus.failed,
        detail: snapshot.isCancelled ? '已取消' : '处理失败',
        error: message,
      );
      await _writeTask(convoId, assistantId, failed);
    }
    for (final fileId in task.remoteFileIds) {
      await client.deleteFile(connection: connection, fileId: fileId);
    }
  }

  LongTaskStatus _status(LongTaskSnapshot snapshot) {
    if (snapshot.isCompleted) return LongTaskStatus.completed;
    if (snapshot.isCancelled) return LongTaskStatus.cancelled;
    if (snapshot.isFailed) return LongTaskStatus.failed;
    return snapshot.status == 'queued'
        ? LongTaskStatus.queued
        : LongTaskStatus.running;
  }

  Future<GatewayConnection?> _connectionFor(LongTaskState task) async {
    final settings = await _readSettings();
    if (task.baseUrl.trim().isEmpty) return null;
    return GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: task.baseUrl,
        uploadBaseUrl: task.uploadBaseUrl,
        taskModel: task.model,
        taskPollSeconds: settings.gateway.taskPollSeconds,
        requestTimeoutSeconds: settings.gateway.requestTimeoutSeconds,
      ),
      apiToken: settings.gatewayToken,
      tokenProvider: settings.gatewayTokenProvider,
    );
  }

  List<LongTaskInputMessage> _messages(String convoId, String assistantId) {
    final convo = _conversations().where((c) => c.id == convoId).firstOrNull;
    if (convo == null) return const [];
    final assistant = convo.messages
        .where((m) => m.id == assistantId)
        .firstOrNull;
    final userId = assistant?.parentId;
    if (userId == null) return const [];
    final path = pathToMessage(convo, userId)
        .where(
          (m) =>
              (m.role == MessageRole.user || m.role == MessageRole.assistant) &&
              m.content.trim().isNotEmpty,
        )
        .toList();
    final start = path.length > 12 ? path.length - 12 : 0;
    return [
      for (final message in path.skip(start))
        LongTaskInputMessage(role: message.role, text: message.content),
    ];
  }

  ({ChatMessage user, List<Attachment> attachments})? _source(
    String convoId,
    String assistantId,
  ) {
    final convo = _conversations().where((c) => c.id == convoId).firstOrNull;
    if (convo == null) return null;
    final assistant = convo.messages
        .where((m) => m.id == assistantId)
        .firstOrNull;
    if (assistant?.parentId == null) return null;
    final user = convo.messages
        .where((m) => m.id == assistant!.parentId)
        .firstOrNull;
    if (user == null) return null;
    return (
      user: user,
      attachments: [
        for (final a in user.attachments)
          if (!a.isImage) a,
      ],
    );
  }

  Future<void> _fail(
    String convoId,
    String assistantId,
    LongTaskState task,
    String error,
  ) => _writeTask(
    convoId,
    assistantId,
    task.copyWith(status: LongTaskStatus.failed, detail: '处理失败', error: error),
  );

  Future<void> cancel(String convoId, String assistantId) async {
    final task = _findTask(convoId, assistantId);
    if (task == null || !task.isActive) return;
    final runKey = '$convoId/$assistantId';
    _cancelTokens[runKey]?.cancel('user cancelled');
    final cancelled = task.copyWith(
      status: LongTaskStatus.cancelled,
      detail: '已取消',
      error: null,
    );
    await _writeTask(convoId, assistantId, cancelled);
    final connection = await _connectionFor(task);
    if (connection == null) return;
    final client = _client();
    final taskId = task.taskId;
    if (taskId != null && taskId.isNotEmpty) {
      try {
        await client.cancel(connection: connection, taskId: taskId);
      } catch (e) {
        _reportError(describeError(e), convoId: convoId);
      }
    }
    for (final fileId in task.remoteFileIds) {
      // Best-effort cleanup after the user's cancel action: a network hiccup
      // on one file must neither crash the unawaited caller nor abort the
      // remaining deletions (the Gateway reaps orphaned files regardless).
      try {
        await client.deleteFile(connection: connection, fileId: fileId);
      } catch (_) {
        // Ignored on purpose; see comment above.
      }
    }
  }

  Future<void> retry(String convoId, String assistantId) async {
    final task = _findTask(convoId, assistantId);
    if (task == null || !task.canRetry) return;
    final runKey = '$convoId/$assistantId';
    if (_runs.contains(runKey)) {
      // A cancelled poll normally unwinds immediately; retry on the next UI
      // frame so the old runner cannot race the replacement state.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_runs.contains(runKey)) return;
    }
    final reset = task.copyWith(
      status: LongTaskStatus.preparing,
      taskId: null,
      remoteFileIds: const [],
      detail: '正在重新准备',
      error: null,
    );
    await _writeTask(convoId, assistantId, reset, content: '');
    unawaited(run(convoId, assistantId));
  }
}
