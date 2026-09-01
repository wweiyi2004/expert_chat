import 'dart:async';

import '../../data/conversation_repository.dart';
import '../../data/models.dart';

/// Serializes repository writes behind one queue and owns the stream
/// checkpoint throttle. Several UI actions intentionally don't await
/// persistence; without a queue an older snapshot can finish after a newer
/// one and overwrite it (especially around stop / rename / branch switches).
///
/// Chat state stays owned by `ChatController`; persistence reaches it through
/// the injected callbacks below so the write queue holds no `Ref`.
class ConversationPersistence {
  ConversationPersistence({
    required ConversationRepository Function() repository,
    required Conversation? Function() currentConversation,
    required List<Conversation> Function() conversations,
    required bool Function() mounted,
    required void Function(String message, {String? convoId}) reportFailure,
    // The fields are private so the persistence interface stays stable while
    // the named parameters stay public for construction and tests.
    // ignore: prefer_initializing_formals
  }) : _repository = repository,
       // ignore: prefer_initializing_formals
       _currentConversation = currentConversation,
       // ignore: prefer_initializing_formals
       _conversations = conversations,
       // ignore: prefer_initializing_formals
       _mounted = mounted,
       // ignore: prefer_initializing_formals
       _reportFailure = reportFailure;

  final ConversationRepository Function() _repository;
  final Conversation? Function() _currentConversation;
  final List<Conversation> Function() _conversations;
  final bool Function() _mounted;
  final void Function(String message, {String? convoId}) _reportFailure;

  Future<void> _writeQueue = Future<void>.value();

  /// A slow disk must not let periodic stream checkpoints pile up behind one
  /// another. The final turn write is still awaited separately, so dropping an
  /// overlapping best-effort checkpoint cannot lose the completed answer.
  final Set<String> _checkpointWritesInFlight = {};

  /// Persist only the active conversation (cheap; avoids rewriting the whole DB
  /// on every turn).
  Future<void> enqueueWrite(Future<void> Function() operation) {
    // Keep future writes alive even when one write fails. The caller still gets
    // the individual failure, while the queue remains usable for later turns.
    final queued = _writeQueue
        .catchError((Object _) {})
        .then((_) => operation());
    _writeQueue = queued;
    return queued;
  }

  Future<void> persist() {
    final cur = _currentConversation();
    if (cur == null) return Future.value();
    return enqueueWrite(() => _repository().saveConversation(cur));
  }

  /// Persist a specific conversation by id. Used by the generation pipeline so
  /// the streamed conversation is saved even if the user switched to another
  /// one mid-stream. No-op when the conversation was deleted meanwhile (so a
  /// late save can't resurrect it).
  Future<void> persistById(String convoId) {
    final idx = _conversations().indexWhere((c) => c.id == convoId);
    if (idx < 0) return Future.value();
    final convo = _conversations()[idx];
    return enqueueWrite(() => _repository().saveConversation(convo));
  }

  Future<void> deletePersistedConversation(String id) =>
      enqueueWrite(() => _repository().deleteConversation(id));

  /// UI callbacks should remain responsive, but persistence failures must never
  /// become unhandled async errors. Surface them in the existing error banner
  /// so the user knows a local archive operation needs attention.
  void persistSoon(Future<void> write) {
    unawaited(_reportPersistFailure(write));
  }

  Future<void> _reportPersistFailure(Future<void> write) async {
    try {
      await write;
    } catch (e) {
      if (_mounted()) _reportFailure('本地保存失败：$e');
    }
  }

  /// Persist a completed turn like the pipeline's first write: a storage
  /// failure surfaces as a 本地保存失败 banner scoped to [convoId] instead of
  /// escaping the UI await chain as an unhandled async exception.
  Future<void> persistSafely(String convoId) async {
    try {
      await persistById(convoId);
    } catch (e) {
      if (_mounted()) _reportFailure('本地保存失败：$e', convoId: convoId);
    }
  }

  void checkpointSoon(String conversationId) {
    if (!_checkpointWritesInFlight.add(conversationId)) return;
    unawaited(_runCheckpoint(conversationId));
  }

  Future<void> _runCheckpoint(String conversationId) async {
    try {
      await _reportPersistFailure(persistById(conversationId));
    } finally {
      _checkpointWritesInFlight.remove(conversationId);
    }
  }
}
