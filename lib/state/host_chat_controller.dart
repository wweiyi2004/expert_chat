import 'dart:async';
import 'package:riverpod/riverpod.dart';
import 'chat_controller.dart';
import '../domain/host/host_client.dart';
import '../domain/host/wire_models.dart';
import '../data/models.dart';
import '../data/story_models.dart';
import '../data/db/app_database.dart' show GenerationRecord;
import '../domain/study/tutor_style.dart';
import '../domain/llm/llm_provider.dart';

/// GUI state adapter. All model/tool execution stays in the independent host.
class HostChatController extends ChatController {
  HostClient get _client => HostClient.current!;
  String? _selected;
  Future<String>? _creating;
  int _selectionVersion = 0;
  Map<String, dynamic> get _metadata => wireMap(_client.state['session_meta']);
  Map<String, dynamic> _meta(String id) => wireMap(_metadata[id]);
  @override
  Future<ChatState> build() async {
    await _client.refresh(force: true);
    final chat = wireMap(_client.state['chat']);
    _selected = _client.selectedSession ?? chat['currentId'] as String?;
    _selected ??= wireRows(chat['conversations']).firstOrNull?['id'] as String?;
    _selected ??=
        await _client.call('chat', 'newConversation', {
              'workMode': false,
              'forceNew': false,
            })
            as String;
    await _client.select(_selected);
    final subscription = _client.updates.listen(_accept);
    ref.onDispose(subscription.cancel);
    return _decode();
  }

  ChatState _decode() {
    var decoded = decodeChatState(
      wireMap(_client.state['chat']),
      selectedId: _selected,
    );
    if (!decoded.conversations.any((c) => c.id == _selected)) {
      _selected = decoded.conversations.firstOrNull?.id;
      decoded = decoded.copyWith(currentId: _selected);
    }
    final meta = _selected == null ? <String, dynamic>{} : _meta(_selected!);
    return decoded.copyWith(
      deepThink: meta['thinking'] as bool? ?? decoded.deepThink,
      reasoningEffort: wireEnum(
        ReasoningEffort.values,
        meta['effort'],
        decoded.reasoningEffort,
      ),
      error: meta['error'],
      errorConvoId: meta['error'] == null ? null : _selected,
      retryOperation: decodeRetry(meta['retry_operation']),
    );
  }

  void _accept(Map<String, dynamic> update) {
    if (!ref.mounted) return;
    if (update['connection_error'] != null ||
        update['operation_error'] != null) {
      final old = state.value;
      if (old != null) {
        state = AsyncData(
          old.copyWith(
            error: update['connection_error'] ?? update['operation_error'],
            errorConvoId: null,
          ),
        );
      }
    } else if (update['chat'] != null) {
      state = AsyncData(_decode());
    }
  }

  Future<Object?> _call(String operation, Map<String, Object?> args) async {
    final target = _creating ?? Future<String?>.value(_selected);
    final id = await target;
    final result = await _client.call('chat', operation, args, session: id);
    if (ref.mounted) _accept(_client.state);
    return result;
  }

  void _fire(String operation, Map<String, Object?> args) {
    unawaited(
      _call(operation, args).catchError((Object error) {
        if (ref.mounted && state.value != null) {
          state = AsyncData(
            state.requireValue.copyWith(
              error: error.toString(),
              errorConvoId: _selected,
            ),
          );
        }
        return null;
      }),
    );
  }

  Future<Object?> _create(String operation, Map<String, Object?> args) async {
    final version = ++_selectionVersion;
    final result = _client.call('chat', operation, args);
    final created = result.then(
      (value) => value is String ? value : wireMap(value)['id'] as String,
    );
    _creating = created;
    try {
      final value = await result;
      final id = await created;
      if (version == _selectionVersion && ref.mounted) {
        await selectConversation(id);
      }
      return value;
    } finally {
      if (identical(_creating, created)) _creating = null;
    }
  }

  @override
  Future<void> selectConversation(String id) async {
    _selectionVersion++;
    _selected = id;
    if (state.value != null) {
      state = AsyncData(
        state.requireValue.copyWith(currentId: id, error: null),
      );
    }
    await _client.select(id);
    if (ref.mounted) _accept(_client.state);
  }

  @override
  Future<void> loadSession(String id) async {
    await _client.invoke('host.loadSession', {'session_id': id, 'view': false});
    await _client.refresh(force: true);
  }

  @override
  Set<String> get runningConversationIds =>
      state.value?.runningConversationIds ?? {};
  @override
  bool isConversationRunning(String id) => runningConversationIds.contains(id);
  @override
  bool isContextCompacting(String id) => _meta(id)['compacting'] == true;
  @override
  SessionPendingConfiguration? pendingSessionConfigFor(String id) =>
      state.value?.pendingSessionConfigurations[id];
  @override
  Map<String, dynamic>? taskSnapshotFor(String conversationId) =>
      _meta(conversationId)['task'] == null
      ? null
      : wireMap(_meta(conversationId)['task']);
  @override
  Map<String, Object?>? retryForSession(String id) =>
      _meta(id)['retry'] == null ? null : wireMap(_meta(id)['retry']);
  @override
  ChatRetryOperation? retryOperationForSession(String id) =>
      decodeRetry(_meta(id)['retry_operation']);
  @override
  bool thinkingForSession(String id) => _meta(id)['thinking'] != false;
  @override
  ReasoningEffort effortForSession(String id) => wireEnum(
    ReasoningEffort.values,
    _meta(id)['effort'],
    ReasoningEffort.high,
  );
  @override
  String? errorForSession(String id) => _meta(id)['error'] as String?;
  @override
  void reportAppBackground(bool background) {}
  @override
  void reportChatVisible(bool visible) {}
  @override
  void reportStreamView({
    required bool followingTail,
    required bool thinkingExpanded,
  }) {}
  // RPC forwarding; keep the host operation allowlist in chat_api.dart in sync.
  @override
  Future<String> addWorkRequirement(String conversation, String text) async {
    return await _call('addWorkRequirement', {
          'conversation': encodeHostValue(conversation),
          'text': encodeHostValue(text),
        })
        as String;
  }

  @override
  void adjustPlotCursor(int delta) {
    _fire('adjustPlotCursor', {'delta': encodeHostValue(delta)});
  }

  @override
  Future<void> advancePlot() async {
    await _call('advancePlot', {});
  }

  @override
  Future<void> answerFromResults(String convoId, String msgId) async {
    await _call('answerFromResults', {
      'convoId': encodeHostValue(convoId),
      'msgId': encodeHostValue(msgId),
    });
  }

  @override
  void applyComposerPrefs({
    required SearchMode searchMode,
    required ImageGenMode imageGenMode,
    required ReasoningEffort reasoningEffort,
  }) {
    _fire('applyComposerPrefs', {
      'searchMode': encodeHostValue(searchMode),
      'imageGenMode': encodeHostValue(imageGenMode),
      'reasoningEffort': encodeHostValue(reasoningEffort),
    });
  }

  @override
  Future<void> assignProject(String conversationId, String? projectId) async {
    await _call('assignProject', {
      'conversationId': encodeHostValue(conversationId),
      'projectId': encodeHostValue(projectId),
    });
  }

  @override
  Future<void> cancelLongTask(String convoId, String assistantId) async {
    await _call('cancelLongTask', {
      'convoId': encodeHostValue(convoId),
      'assistantId': encodeHostValue(assistantId),
    });
  }

  @override
  Future<Map<String, dynamic>> compactSessionContext(String id) async {
    return wireMap(
      await _call('compactSessionContext', {'id': encodeHostValue(id)}),
    );
  }

  @override
  void configureSessionThinking(
    String id,
    bool thinking,
    ReasoningEffort effort,
  ) {
    _fire('configureSessionThinking', {
      'id': encodeHostValue(id),
      'thinking': encodeHostValue(thinking),
      'effort': encodeHostValue(effort),
    });
  }

  @override
  Future<void> continueCurrentScene() async {
    await _call('continueCurrentScene', {});
  }

  @override
  Future<String> createWorkSession({String? title}) async {
    return await _call('createWorkSession', {'title': encodeHostValue(title)})
        as String;
  }

  @override
  Future<void> deleteConversation(String id) async {
    await _call('deleteConversation', {'id': encodeHostValue(id)});
  }

  @override
  Future<void> deleteProject(String projectId) async {
    await _call('deleteProject', {'projectId': encodeHostValue(projectId)});
  }

  @override
  void dismissError({String? conversationId}) {
    _fire('dismissError', {'conversationId': encodeHostValue(conversationId)});
  }

  @override
  Future<void> editMessage(
    String messageId,
    String newText, {
    List<Attachment>? attachments,
  }) async {
    await _call('editMessage', {
      'messageId': encodeHostValue(messageId),
      'newText': encodeHostValue(newText),
      'attachments': encodeHostValue(attachments),
    });
  }

  @override
  Future<void> ensembleAutoPlay({int rounds = 6}) async {
    await _call('ensembleAutoPlay', {'rounds': encodeHostValue(rounds)});
  }

  @override
  Future<void> ensembleNextTurn({
    String? forceCharacterId,

    /// Explicit target conversation (auto-play pins its origin so the loop
    /// keeps writing there even after the user switches conversations).
    String? conversationId,
  }) async {
    await _call('ensembleNextTurn', {
      'forceCharacterId': encodeHostValue(forceCharacterId),
      'conversationId': encodeHostValue(conversationId),
    });
  }

  @override
  Future<void> flushSessionCheckpointWrites() async {
    await _call('flushSessionCheckpointWrites', {});
  }

  @override
  Future<bool> generateImage(
    String prompt, {
    List<Attachment> referenceImages = const [],
  }) async {
    return await _call('generateImage', {
          'prompt': encodeHostValue(prompt),
          'referenceImages': encodeHostValue(referenceImages),
        })
        as bool;
  }

  @override
  void newConversation({
    String? projectId,
    bool workMode = false,
    bool forceNew = false,
  }) {
    unawaited(
      _create('newConversation', {
        'projectId': encodeHostValue(projectId),
        'workMode': encodeHostValue(workMode),
        'forceNew': encodeHostValue(forceNew),
      }).catchError((Object error) {
        if (ref.mounted && state.value != null) {
          state = AsyncData(
            state.requireValue.copyWith(error: error.toString()),
          );
        }
        return null;
      }),
    );
  }

  @override
  Future<void> newDirectorStoryConversation({
    required String title,
    required String premise,
    required List<CharacterCard> cast,
    required String outline,
    String authorNote = '',
    String requirements = '',
    List<String>? worldInfoIds,
    int targetTotalChars = 0,
  }) async {
    await _create('newDirectorStoryConversation', {
      'title': encodeHostValue(title),
      'premise': encodeHostValue(premise),
      'cast': encodeHostValue(cast),
      'outline': encodeHostValue(outline),
      'authorNote': encodeHostValue(authorNote),
      'requirements': encodeHostValue(requirements),
      'worldInfoIds': encodeHostValue(worldInfoIds),
      'targetTotalChars': encodeHostValue(targetTotalChars),
    });
  }

  @override
  Future<void> newEnsembleConversation({
    required List<CharacterCard> cast,
    required String venue,
    String authorNote = '',
    List<String>? worldInfoIds,
  }) async {
    await _create('newEnsembleConversation', {
      'cast': encodeHostValue(cast),
      'venue': encodeHostValue(venue),
      'authorNote': encodeHostValue(authorNote),
      'worldInfoIds': encodeHostValue(worldInfoIds),
    });
  }

  @override
  Future<void> newStoryConversation(
    CharacterCard card, {
    List<String>? worldInfoIds,
  }) async {
    await _create('newStoryConversation', {
      'card': encodeHostValue(card),
      'worldInfoIds': encodeHostValue(worldInfoIds),
    });
  }

  @override
  Future<Conversation> newStudyConversation({
    required String topic,
    TutorStyle tutorStyle = TutorStyle.mixed,
    StudyPath path = StudyPath.tutor,
    String? courseId,
    String? nodeId,
    String? opener,
  }) async {
    return Conversation.fromJson(
      wireMap(
        await _create('newStudyConversation', {
          'topic': encodeHostValue(topic),
          'tutorStyle': encodeHostValue(tutorStyle),
          'path': encodeHostValue(path),
          'courseId': encodeHostValue(courseId),
          'nodeId': encodeHostValue(nodeId),
          'opener': encodeHostValue(opener),
        }),
      ),
    );
  }

  @override
  Future<void> prepareDataMaintenance() async {
    await _call('prepareDataMaintenance', {});
  }

  @override
  Future<void> regenerate({ChatRetryOperation? retryOperation}) async {
    await _call('regenerate', {
      'retryOperation': encodeHostValue(retryOperation),
    });
  }

  @override
  Future<bool> regenerateImageVersion(GenerationRecord record) async {
    return await _call('regenerateImageVersion', {
          'record': encodeHostValue(record),
        })
        as bool;
  }

  @override
  void renameConversation(String id, String title) {
    _fire('renameConversation', {
      'id': encodeHostValue(id),
      'title': encodeHostValue(title),
    });
  }

  @override
  void reportExternalFailure(String id, String message) {
    _fire('reportExternalFailure', {
      'id': encodeHostValue(id),
      'message': encodeHostValue(message),
    });
  }

  @override
  void requestAutomaticTitleForSession(String id) {
    _fire('requestAutomaticTitleForSession', {'id': encodeHostValue(id)});
  }

  @override
  void requestTaskAnswer(String convoId, String msgId) {
    _fire('requestTaskAnswer', {
      'convoId': encodeHostValue(convoId),
      'msgId': encodeHostValue(msgId),
    });
  }

  @override
  Future<bool> resumeChildTask(String conversationId, String agentId) async {
    return await _call('resumeChildTask', {
          'conversationId': encodeHostValue(conversationId),
          'agentId': encodeHostValue(agentId),
        })
        as bool;
  }

  @override
  Future<bool> resumeSessionTask(String conversationId) async {
    return await _call('resumeSessionTask', {
          'conversationId': encodeHostValue(conversationId),
        })
        as bool;
  }

  @override
  Future<void> retryLast() async {
    await _call('retryLast', {});
  }

  @override
  Future<void> retryLongTask(String convoId, String assistantId) async {
    await _call('retryLongTask', {
      'convoId': encodeHostValue(convoId),
      'assistantId': encodeHostValue(assistantId),
    });
  }

  @override
  Future<void> retryTaskStep(
    String convoId,
    String msgId,
    String stepId, {
    bool confirmedPaidRequest = false,
  }) async {
    await _call('retryTaskStep', {
      'convoId': encodeHostValue(convoId),
      'msgId': encodeHostValue(msgId),
      'stepId': encodeHostValue(stepId),
      'confirmedPaidRequest': encodeHostValue(confirmedPaidRequest),
    });
  }

  @override
  Future<bool> sendLongDocumentTask(
    String text, {
    required List<Attachment> attachments,
  }) async {
    return await _call('sendLongDocumentTask', {
          'text': encodeHostValue(text),
          'attachments': encodeHostValue(attachments),
        })
        as bool;
  }

  @override
  Future<bool> sendMessage(
    String text, {
    List<Attachment> attachments = const [],
    bool forceDocumentEdit = false,
  }) async {
    return await _call('sendMessage', {
          'text': encodeHostValue(text),
          'attachments': encodeHostValue(attachments),
          'forceDocumentEdit': encodeHostValue(forceDocumentEdit),
        })
        as bool;
  }

  @override
  Future<bool> sendToSession(
    String id,
    String text, {
    List<Attachment> attachments = const [],
    bool automaticTitle = false,
  }) async {
    return await _call('sendToSession', {
          'id': encodeHostValue(id),
          'text': encodeHostValue(text),
          'attachments': encodeHostValue(attachments),
          'automaticTitle': encodeHostValue(automaticTitle),
        })
        as bool;
  }

  @override
  Future<bool> sendWorkContinuation(String conversationId, int rounds) async {
    return await _call('sendWorkContinuation', {
          'conversationId': encodeHostValue(conversationId),
          'rounds': encodeHostValue(rounds),
        })
        as bool;
  }

  @override
  void setCustomMcpServerIds(List<String> ids) {
    _fire('setCustomMcpServerIds', {'ids': encodeHostValue(ids)});
  }

  @override
  void setImageGenMode(ImageGenMode mode) {
    _fire('setImageGenMode', {'mode': encodeHostValue(mode)});
  }

  @override
  void setReasoningEffort(ReasoningEffort effort) {
    _fire('setReasoningEffort', {'effort': encodeHostValue(effort)});
  }

  @override
  Future<void> setSessionMcpSelection(String id, List<String> selected) async {
    await _call('setSessionMcpSelection', {
      'id': encodeHostValue(id),
      'selected': encodeHostValue(selected),
    });
  }

  @override
  void setWorkMode(bool enabled) {
    _fire('setWorkMode', {'enabled': encodeHostValue(enabled)});
  }

  @override
  void stop({bool persist = true, String? conversationId}) {
    _fire('stop', {
      'persist': encodeHostValue(persist),
      'conversationId': encodeHostValue(conversationId),
    });
  }

  @override
  Future<void> stopAndWait({
    bool persist = true,
    String? conversationId,
  }) async {
    await _call('stopAndWait', {
      'persist': encodeHostValue(persist),
      'conversationId': encodeHostValue(conversationId),
    });
  }

  @override
  void switchBranch(String messageId, int delta) {
    _fire('switchBranch', {
      'messageId': encodeHostValue(messageId),
      'delta': encodeHostValue(delta),
    });
  }

  @override
  void switchConversationMode(bool enabled) {
    _fire('switchConversationMode', {'enabled': encodeHostValue(enabled)});
  }

  @override
  void toggleDeepThink() {
    _fire('toggleDeepThink', {});
  }

  @override
  void toggleImageGenMode() {
    _fire('toggleImageGenMode', {});
  }

  @override
  void toggleSearch() {
    _fire('toggleSearch', {});
  }

  @override
  void updateStoryMeta({
    String? conversationId,
    String? outline,
    String? authorNote,
    List<String>? worldInfoIds,
    int? plotCursor,
    String? venue,
    List<String>? participantIds,
    int? nextSpeakerIndex,
    int? targetTotalChars,
  }) {
    _fire('updateStoryMeta', {
      'conversationId': encodeHostValue(conversationId),
      'outline': encodeHostValue(outline),
      'authorNote': encodeHostValue(authorNote),
      'worldInfoIds': encodeHostValue(worldInfoIds),
      'plotCursor': encodeHostValue(plotCursor),
      'venue': encodeHostValue(venue),
      'participantIds': encodeHostValue(participantIds),
      'nextSpeakerIndex': encodeHostValue(nextSpeakerIndex),
      'targetTotalChars': encodeHostValue(targetTotalChars),
    });
  }

  @override
  Future<bool> verifyAndAcceptTask(String conversationId) async {
    return await _call('verifyAndAcceptTask', {
          'conversationId': encodeHostValue(conversationId),
        })
        as bool;
  }

  @override
  Future<String> withdrawWorkRequirement(String id, String queuedId) async {
    return await _call('withdrawWorkRequirement', {
          'id': encodeHostValue(id),
          'queuedId': encodeHostValue(queuedId),
        })
        as String;
  }
}
