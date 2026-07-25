import 'dart:convert';

import 'package:drift/drift.dart';

import 'conversation_repository.dart';
// Hide drift's generated `Conversation` data class so our domain model wins;
// the drift `Message` row type is still used below for mapping.
import 'db/app_database.dart' hide Conversation;
import 'models.dart';
import 'story_models.dart';

/// Drift/SQLite-backed [ConversationRepository]. A drop-in replacement for
/// [JsonConversationRepository]: it implements the same `loadAll`/`saveAll`
/// contract (syncing the in-memory list to the DB) and adds full-text-ish
/// [search] over titles and message bodies.
class DriftConversationRepository implements ConversationRepository {
  DriftConversationRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<Conversation>> loadAll() async {
    final convoRows = await (_db.select(
      _db.conversations,
    )..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])).get();
    final msgRows = await (_db.select(
      _db.messages,
    )..orderBy([(m) => OrderingTerm.asc(m.seq)])).get();

    final byConvo = <String, List<Message>>{};
    for (final m in msgRows) {
      (byConvo[m.convoId] ??= []).add(m);
    }

    return [
      for (final c in convoRows)
        Conversation(
          id: c.id,
          title: c.title,
          updatedAt: c.updatedAt,
          activeChildren: _decodeActiveChildren(c.activeChildrenJson),
          messages: [
            for (final m in byConvo[c.id] ?? const <Message>[]) _toMessage(m),
          ],
          mode: ConversationMode.fromWire(c.mode),
          characterId: c.characterId,
          participantIds: _decodeStringList(c.participantIdsJson),
          worldInfoIds: _decodeStringList(c.worldInfoIdsJson),
          outline: c.outline,
          authorNote: c.authorNote,
          plotCursor: c.plotCursor,
          venue: c.venue,
          nextSpeakerIndex: c.nextSpeakerIndex,
        ),
    ];
  }

  Map<String, String> _decodeActiveChildren(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  List<String> _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    final keepIds = conversations.map((c) => c.id).toList();
    await _db.transaction(() async {
      // Drop conversations no longer present in one statement (messages cascade).
      if (keepIds.isEmpty) {
        await _db.delete(_db.conversations).go();
      } else {
        await (_db.delete(
          _db.conversations,
        )..where((c) => c.id.isNotIn(keepIds))).go();
      }
      for (final convo in conversations) {
        await _writeConversation(convo);
      }
    });
  }

  @override
  Future<void> saveConversation(Conversation conversation) =>
      _db.transaction(() => _writeConversation(conversation));

  @override
  Future<void> deleteConversation(String id) =>
      (_db.delete(_db.conversations)..where((c) => c.id.equals(id))).go();

  /// Upsert one conversation header and synchronize only the message rows that
  /// actually changed. This avoids rewriting a long conversation when a new
  /// turn is appended or a single streamed reply is finalized.
  Future<void> _writeConversation(Conversation convo) async {
    final activeChildrenJson = convo.activeChildren.isEmpty
        ? null
        : jsonEncode(convo.activeChildren);
    final worldInfoIdsJson = convo.worldInfoIds.isEmpty
        ? null
        : jsonEncode(convo.worldInfoIds);
    final participantIdsJson = convo.participantIds.isEmpty
        ? null
        : jsonEncode(convo.participantIds);
    final storedConvo = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(convo.id))).getSingleOrNull();

    if (storedConvo == null ||
        storedConvo.title != convo.title ||
        !_matchesStoredTimestamp(storedConvo.updatedAt, convo.updatedAt) ||
        storedConvo.activeChildrenJson != activeChildrenJson ||
        storedConvo.mode != convo.mode.wire ||
        storedConvo.characterId != convo.characterId ||
        storedConvo.worldInfoIdsJson != worldInfoIdsJson ||
        storedConvo.participantIdsJson != participantIdsJson ||
        storedConvo.outline != convo.outline ||
        storedConvo.authorNote != convo.authorNote ||
        storedConvo.plotCursor != convo.plotCursor ||
        storedConvo.venue != convo.venue ||
        storedConvo.nextSpeakerIndex != convo.nextSpeakerIndex) {
      await _db
          .into(_db.conversations)
          .insertOnConflictUpdate(
            ConversationsCompanion.insert(
              id: convo.id,
              title: Value(convo.title),
              updatedAt: convo.updatedAt,
              activeChildrenJson: Value(activeChildrenJson),
              mode: Value(convo.mode.wire),
              characterId: Value(convo.characterId),
              worldInfoIdsJson: Value(worldInfoIdsJson),
              participantIdsJson: Value(participantIdsJson),
              outline: Value(convo.outline),
              authorNote: Value(convo.authorNote),
              plotCursor: Value(convo.plotCursor),
              venue: Value(convo.venue),
              nextSpeakerIndex: Value(convo.nextSpeakerIndex),
            ),
          );
    }

    final storedMessages = await (_db.select(
      _db.messages,
    )..where((m) => m.convoId.equals(convo.id))).get();
    final storedById = {
      for (final message in storedMessages) message.id: message,
    };
    final messageIds = convo.messages.map((message) => message.id).toSet();
    final staleMessages = [
      for (final message in storedMessages)
        if (!messageIds.contains(message.id)) message,
    ];

    var seq = 0;
    final changedRows = <MessagesCompanion>[];
    for (final message in convo.messages) {
      final row = storedById[message.id];
      if (!_matchesStoredMessage(row, message, convo.id, seq)) {
        changedRows.add(_toCompanion(message, convo.id, seq));
      }
      seq++;
    }

    if (staleMessages.isEmpty && changedRows.isEmpty) return;
    await _db.batch((batch) {
      for (final message in staleMessages) {
        batch.delete(_db.messages, message);
      }
      // Upserts are restricted to new or changed rows, and all writes share a
      // single batch to minimize SQLite round-trips.
      batch.insertAllOnConflictUpdate(_db.messages, changedRows);
    });
  }

  bool _matchesStoredMessage(
    Message? stored,
    ChatMessage message,
    String convoId,
    int seq,
  ) =>
      stored != null &&
      stored.convoId == convoId &&
      stored.parentId == message.parentId &&
      stored.role == message.role.wire &&
      stored.content == message.content &&
      stored.reasoning == message.reasoning &&
      stored.model == message.model &&
      stored.thinkingMillis == message.thinkingMillis &&
      stored.speakerId == message.speakerId &&
      stored.speakerName == message.speakerName &&
      stored.attachmentsJson == _attachmentsJson(message) &&
      stored.citationsJson == _citationsJson(message) &&
      _matchesStoredTimestamp(stored.createdAt, message.createdAt) &&
      stored.seq == seq;

  // Drift's default SQLite DateTime mapping stores Unix timestamps at second
  // precision and reads them back as local time. Compare the persisted value
  // at that precision so a timezone representation or sub-second truncation
  // does not turn an otherwise unchanged message into an update.
  bool _matchesStoredTimestamp(DateTime stored, DateTime value) =>
      stored.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond ==
      value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

  /// Returns conversations whose title or any message content matches [query]
  /// (case-insensitive LIKE). Empty query returns everything.
  Future<List<Conversation>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return loadAll();
    final like = '%${q.toLowerCase()}%';
    final matchingIds = <String>{};

    final titleRows = await (_db.select(
      _db.conversations,
    )..where((c) => c.title.lower().like(like))).get();
    matchingIds.addAll(titleRows.map((c) => c.id));

    final msgRows = await (_db.select(
      _db.messages,
    )..where((m) => m.content.lower().like(like))).get();
    matchingIds.addAll(msgRows.map((m) => m.convoId));

    final all = await loadAll();
    return all.where((c) => matchingIds.contains(c.id)).toList();
  }

  ChatMessage _toMessage(Message m) => ChatMessage(
    id: m.id,
    role: MessageRoleApi.fromWire(m.role),
    parentId: m.parentId,
    content: m.content,
    reasoning: m.reasoning,
    model: m.model,
    thinkingMillis: m.thinkingMillis,
    speakerId: m.speakerId,
    speakerName: m.speakerName,
    createdAt: m.createdAt,
    attachments: _decodeList(m.attachmentsJson, (e) => Attachment.fromJson(e)),
    citations: _decodeList(m.citationsJson, (e) => Citation.fromJson(e)),
  );

  String? _attachmentsJson(ChatMessage message) => message.attachments.isEmpty
      ? null
      : jsonEncode(message.attachments.map((a) => a.toJson()).toList());

  String? _citationsJson(ChatMessage message) => message.citations.isEmpty
      ? null
      : jsonEncode(message.citations.map((c) => c.toJson()).toList());

  MessagesCompanion _toCompanion(ChatMessage m, String convoId, int seq) =>
      MessagesCompanion.insert(
        id: m.id,
        convoId: convoId,
        parentId: Value(m.parentId),
        role: m.role.wire,
        content: m.content,
        reasoning: Value(m.reasoning),
        model: Value(m.model),
        thinkingMillis: Value(m.thinkingMillis),
        speakerId: Value(m.speakerId),
        speakerName: Value(m.speakerName),
        attachmentsJson: Value(_attachmentsJson(m)),
        citationsJson: Value(_citationsJson(m)),
        createdAt: m.createdAt,
        seq: Value(seq),
      );

  List<T> _decodeList<T>(
    String? raw,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }
}
