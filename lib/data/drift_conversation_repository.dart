import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/story/story_prompt_assembler.dart' show WorldInfoHit;
import 'chat_skill.dart';
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
        _fromConvoRow(
          c,
          messages: [
            for (final m in byConvo[c.id] ?? const <Message>[]) _toMessage(m),
          ],
        ),
    ];
  }

  @override
  Future<List<ConversationSummary>> loadSummaries() async {
    final convoRows = await (_db.select(
      _db.conversations,
    )..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])).get();
    final taskRows = await (_db.select(
      _db.messages,
    )..where((m) => m.longTaskJson.isNotNull())).get();
    final activeIds = <String>{};
    for (final row in taskRows) {
      if (_longTaskJsonIsActive(row.longTaskJson)) {
        activeIds.add(row.convoId);
      }
    }
    return [
      for (final c in convoRows)
        ConversationSummary(
          id: c.id,
          title: c.title,
          updatedAt: c.updatedAt,
          mode: ConversationMode.fromWire(c.mode),
          characterId: c.characterId,
          participantIds: _decodeStringList(c.participantIdsJson),
          localCast: _decodeList(c.localCastJson, CharacterCard.fromJson),
          worldInfoIds: _decodeStringList(c.worldInfoIdsJson),
          customMcpServerIds: _decodeStringList(c.customMcpServerIdsJson),
          outline: c.outline,
          authorNote: c.authorNote,
          plotCursor: c.plotCursor,
          venue: c.venue,
          nextSpeakerIndex: c.nextSpeakerIndex,
          targetTotalChars: c.targetTotalChars,
          workMode: c.workMode,
          activeChildren: _decodeActiveChildren(c.activeChildrenJson),
          hasActiveLongTask: activeIds.contains(c.id),
        ),
    ];
  }

  @override
  Future<Conversation> loadConversation(String id) async {
    final row = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    if (row == null) {
      throw StateError('Conversation $id not found');
    }
    final msgRows =
        await (_db.select(_db.messages)
              ..where((m) => m.convoId.equals(id))
              ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
            .get();
    return _fromConvoRow(
      row,
      messages: [for (final m in msgRows) _toMessage(m)],
    );
  }

  @override
  Future<List<SearchHit>> searchMessages(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final escaped = q
        .toLowerCase()
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final like = '%$escaped%';
    final titleRows = await (_db.select(
      _db.conversations,
    )..where((c) => c.title.lower().like(like, escapeChar: r'\'))).get();
    final msgRows = await (_db.select(
      _db.messages,
    )..where((m) => m.content.lower().like(like, escapeChar: r'\'))).get();
    final titleById = {for (final c in titleRows) c.id: c.title};
    if (titleById.isEmpty && msgRows.isEmpty) return const [];

    final missingTitleIds = <String>{
      for (final m in msgRows)
        if (!titleById.containsKey(m.convoId)) m.convoId,
    };
    if (missingTitleIds.isNotEmpty) {
      final extra = await (_db.select(
        _db.conversations,
      )..where((c) => c.id.isIn(missingTitleIds.toList()))).get();
      for (final c in extra) {
        titleById[c.id] = c.title;
      }
    }

    final hits = <SearchHit>[];
    final matchedConvoIds = <String>{};
    final needle = q.toLowerCase();
    for (final m in msgRows) {
      final idx = m.content.toLowerCase().indexOf(needle);
      if (idx < 0) continue;
      matchedConvoIds.add(m.convoId);
      hits.add(
        SearchHit(
          convoId: m.convoId,
          messageId: m.id,
          snippet: searchSnippetAround(m.content, idx, q.length),
          title: titleById[m.convoId] ?? '',
        ),
      );
    }
    for (final c in titleRows) {
      if (matchedConvoIds.contains(c.id)) continue;
      hits.add(
        SearchHit(
          convoId: c.id,
          messageId: '',
          snippet: c.title,
          title: c.title,
        ),
      );
    }
    return hits;
  }

  Conversation _fromConvoRow(
    dynamic c, {
    required List<ChatMessage> messages,
    bool messagesLoaded = true,
  }) => Conversation(
    id: c.id as String,
    title: c.title as String,
    updatedAt: c.updatedAt as DateTime,
    activeChildren: _decodeActiveChildren(c.activeChildrenJson as String?),
    messages: messages,
    mode: ConversationMode.fromWire(c.mode as String),
    characterId: c.characterId as String?,
    participantIds: _decodeStringList(c.participantIdsJson as String?),
    localCast: _decodeList(c.localCastJson as String?, CharacterCard.fromJson),
    worldInfoIds: _decodeStringList(c.worldInfoIdsJson as String?),
    customMcpServerIds: _decodeStringList(c.customMcpServerIdsJson as String?),
    outline: c.outline as String,
    authorNote: c.authorNote as String,
    plotCursor: c.plotCursor as int,
    venue: c.venue as String,
    nextSpeakerIndex: c.nextSpeakerIndex as int,
    targetTotalChars: c.targetTotalChars as int,
    workMode: c.workMode as bool,
    messagesLoaded: messagesLoaded,
  );

  bool _longTaskJsonIsActive(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final status = map['status'] as String?;
      return status == 'preparing' ||
          status == 'uploading' ||
          status == 'queued' ||
          status == 'running';
    } catch (_) {
      return false;
    }
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
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => e.toString())
          .toList();
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
    final customMcpServerIdsJson = convo.customMcpServerIds.isEmpty
        ? null
        : jsonEncode(convo.customMcpServerIds);
    final participantIdsJson = convo.participantIds.isEmpty
        ? null
        : jsonEncode(convo.participantIds);
    final localCastJson = convo.localCast.isEmpty
        ? null
        : jsonEncode(convo.localCast.map((card) => card.toJson()).toList());
    final storedConvo = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(convo.id))).getSingleOrNull();

    final headerChanged =
        storedConvo == null ||
        storedConvo.title != convo.title ||
        !_matchesStoredTimestamp(storedConvo.updatedAt, convo.updatedAt) ||
        storedConvo.activeChildrenJson != activeChildrenJson ||
        storedConvo.mode != convo.mode.wire ||
        storedConvo.characterId != convo.characterId ||
        storedConvo.worldInfoIdsJson != worldInfoIdsJson ||
        storedConvo.customMcpServerIdsJson != customMcpServerIdsJson ||
        storedConvo.participantIdsJson != participantIdsJson ||
        storedConvo.localCastJson != localCastJson ||
        storedConvo.outline != convo.outline ||
        storedConvo.authorNote != convo.authorNote ||
        storedConvo.plotCursor != convo.plotCursor ||
        storedConvo.venue != convo.venue ||
        storedConvo.nextSpeakerIndex != convo.nextSpeakerIndex ||
        storedConvo.targetTotalChars != convo.targetTotalChars ||
        storedConvo.workMode != convo.workMode;
    if (headerChanged) {
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
              customMcpServerIdsJson: Value(customMcpServerIdsJson),
              participantIdsJson: Value(participantIdsJson),
              localCastJson: Value(localCastJson),
              outline: Value(convo.outline),
              authorNote: Value(convo.authorNote),
              plotCursor: Value(convo.plotCursor),
              venue: Value(convo.venue),
              nextSpeakerIndex: Value(convo.nextSpeakerIndex),
              targetTotalChars: Value(convo.targetTotalChars),
              workMode: Value(convo.workMode),
            ),
          );
    }
    if (!convo.messagesLoaded) return;

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
      // A kind written by a newer build falls back to `text` in memory, so a
      // plain equality would rewrite the row and silently downgrade the kind
      // on disk. Treat an unrecognized stored kind as matching instead — the
      // row is preserved until this build genuinely changes something else.
      (stored.kind == message.kind.name ||
          !MessageKind.values.any((k) => k.name == stored.kind)) &&
      stored.attachmentsJson == _attachmentsJson(message) &&
      stored.citationsJson == _citationsJson(message) &&
      stored.searchActivitiesJson == _searchActivitiesJson(message) &&
      stored.appliedWorldInfoJson == _appliedWorldInfoJson(message) &&
      stored.longTaskJson == _longTaskJson(message) &&
      stored.turnSkillJson == _turnSkillJson(message) &&
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
  /// (case-insensitive LIKE). Empty query returns nothing — it must not
  /// decode the full archive.
  ///
  /// Only matching conversation rows (+ their messages) are loaded — not the
  /// full archive via [loadAll].
  Future<List<Conversation>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Escape LIKE wildcards so user input is matched literally — searching
    // "100%" must not match every row via the wildcard.
    final escaped = q
        .toLowerCase()
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final like = '%$escaped%';
    final matchingIds = <String>{};

    final titleRows = await (_db.select(
      _db.conversations,
    )..where((c) => c.title.lower().like(like, escapeChar: r'\'))).get();
    matchingIds.addAll(titleRows.map((c) => c.id));

    final msgRows = await (_db.select(
      _db.messages,
    )..where((m) => m.content.lower().like(like, escapeChar: r'\'))).get();
    matchingIds.addAll(msgRows.map((m) => m.convoId));

    if (matchingIds.isEmpty) return const [];

    final idList = matchingIds.toList();
    final convoRows =
        await (_db.select(_db.conversations)
              ..where((c) => c.id.isIn(idList))
              ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)]))
            .get();
    final matchedMsgRows =
        await (_db.select(_db.messages)
              ..where((m) => m.convoId.isIn(idList))
              ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
            .get();

    final byConvo = <String, List<Message>>{};
    for (final m in matchedMsgRows) {
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
          localCast: _decodeList(c.localCastJson, CharacterCard.fromJson),
          worldInfoIds: _decodeStringList(c.worldInfoIdsJson),
          customMcpServerIds: _decodeStringList(c.customMcpServerIdsJson),
          outline: c.outline,
          authorNote: c.authorNote,
          plotCursor: c.plotCursor,
          venue: c.venue,
          nextSpeakerIndex: c.nextSpeakerIndex,
          targetTotalChars: c.targetTotalChars,
          workMode: c.workMode,
        ),
    ];
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
    kind: MessageKind.values.firstWhere(
      (value) => value.name == m.kind,
      orElse: () => MessageKind.text,
    ),
    createdAt: m.createdAt,
    attachments: _decodeList(m.attachmentsJson, (e) => Attachment.fromJson(e)),
    citations: _decodeList(m.citationsJson, (e) => Citation.fromJson(e)),
    searchActivities: _decodeList(
      m.searchActivitiesJson,
      (e) => SearchActivity.fromJson(e),
    ),
    appliedWorldInfo: _decodeList(
      m.appliedWorldInfoJson,
      (e) => WorldInfoHit.fromJson(e),
    ),
    longTask: _decodeObject(m.longTaskJson, LongTaskState.fromJson),
    turnSkill: _decodeObject(m.turnSkillJson, TurnSkillMark.fromJson),
  );

  String? _attachmentsJson(ChatMessage message) => message.attachments.isEmpty
      ? null
      : jsonEncode(message.attachments.map((a) => a.toJson()).toList());

  String? _citationsJson(ChatMessage message) => message.citations.isEmpty
      ? null
      : jsonEncode(message.citations.map((c) => c.toJson()).toList());

  String? _searchActivitiesJson(ChatMessage message) =>
      message.searchActivities.isEmpty
      ? null
      : jsonEncode(message.searchActivities.map((a) => a.toJson()).toList());

  String? _appliedWorldInfoJson(ChatMessage message) =>
      message.appliedWorldInfo.isEmpty
      ? null
      : jsonEncode(message.appliedWorldInfo.map((a) => a.toJson()).toList());

  String? _longTaskJson(ChatMessage message) =>
      message.longTask == null ? null : jsonEncode(message.longTask!.toJson());

  String? _turnSkillJson(ChatMessage message) => message.turnSkill == null
      ? null
      : jsonEncode(message.turnSkill!.toJson());

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
        kind: Value(m.kind.name),
        attachmentsJson: Value(_attachmentsJson(m)),
        citationsJson: Value(_citationsJson(m)),
        searchActivitiesJson: Value(_searchActivitiesJson(m)),
        appliedWorldInfoJson: Value(_appliedWorldInfoJson(m)),
        longTaskJson: Value(_longTaskJson(m)),
        turnSkillJson: Value(_turnSkillJson(m)),
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

  T? _decodeObject<T>(String? raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
