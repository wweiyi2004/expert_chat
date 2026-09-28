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
import 'stored_json.dart';

/// Drift/SQLite-backed [ConversationRepository]. A drop-in replacement for
/// [JsonConversationRepository]: it implements the same `loadAll`/`saveAll`
/// contract (syncing the in-memory list to the DB) and adds full-text-ish
/// [search] over titles and message bodies.
class DriftConversationRepository
    implements ConversationRepository, ConversationMetadataRepository {
  DriftConversationRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> renameConversation(
    String id,
    String title,
    DateTime updatedAt,
  ) => (_db.update(_db.conversations)..where((row) => row.id.equals(id)))
      .write(
        ConversationsCompanion(
          title: Value(title),
          updatedAt: Value(updatedAt),
        ),
      )
      .then((_) {});

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
    final taskRows =
        await (_db.selectOnly(_db.messages)
              ..addColumns([_db.messages.convoId, _db.messages.longTaskJson])
              ..where(_db.messages.longTaskJson.isNotNull()))
            .get();
    final activeIds = <String>{};
    for (final row in taskRows) {
      if (_longTaskJsonIsActive(row.read(_db.messages.longTaskJson))) {
        activeIds.add(row.read(_db.messages.convoId)!);
      }
    }
    return [
      for (final c in convoRows)
        ConversationSummary.fromConversation(
          _fromConvoRow(c, messages: const [], messagesLoaded: false),
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
    // Only fetch searchable fields, never large attachment/base64 columns.
    final rows = await _db
        .customSelect(
          "SELECT m.id,m.convo_id,m.content,c.title FROM messages m "
          "JOIN conversations c ON c.id=m.convo_id "
          "WHERE lower(m.content) LIKE ? ESCAPE '\\' "
          "ORDER BY m.created_at DESC,m.id DESC LIMIT ?",
          variables: [Variable(like), const Variable(conversationSearchLimit)],
        )
        .get();
    final hits = <SearchHit>[];
    final matchedConvoIds = <String>{};
    for (final row in rows) {
      final content = row.read<String>('content');
      final index = content.toLowerCase().indexOf(q.toLowerCase());
      if (index < 0) continue;
      final id = row.read<String>('convo_id');
      matchedConvoIds.add(id);
      hits.add(
        SearchHit(
          convoId: id,
          messageId: row.read<String>('id'),
          snippet: searchSnippetAround(content, index, q.length),
          title: row.read<String>('title'),
        ),
      );
    }
    final remaining = conversationSearchLimit - hits.length;
    if (remaining > 0) {
      final titleRows =
          await (_db.select(_db.conversations)
                ..where(
                  (c) =>
                      c.title.lower().like(like, escapeChar: r'\') &
                      c.id.isNotIn(matchedConvoIds),
                )
                ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])
                ..limit(remaining))
              .get();
      hits.addAll(
        titleRows.map(
          (c) => SearchHit(
            convoId: c.id,
            messageId: '',
            snippet: c.title,
            title: c.title,
          ),
        ),
      );
    }
    return hits;
  }

  Conversation _fromConvoRow(
    dynamic c, {
    required List<ChatMessage> messages,
    bool messagesLoaded = true,
  }) {
    final recovery = StoredJsonReader();
    return Conversation(
      id: c.id as String,
      title: c.title as String,
      updatedAt: c.updatedAt as DateTime,
      activeChildren: recovery.stringMap(
        'active_children_json',
        c.activeChildrenJson as String?,
      ),
      messages: messages,
      mode: ConversationMode.fromWire(c.mode as String),
      characterId: c.characterId as String?,
      projectId: c.projectId as String?,
      participantIds: recovery.list(
        'participant_ids_json',
        c.participantIdsJson as String?,
        (v) => v as String,
      ),
      localCast: recovery.list(
        'local_cast_json',
        c.localCastJson as String?,
        (v) => CharacterCard.fromJson(v as Map<String, dynamic>),
      ),
      worldInfoIds: recovery.list(
        'world_info_ids_json',
        c.worldInfoIdsJson as String?,
        (v) => v as String,
      ),
      customMcpServerIds: recovery.list(
        'custom_mcp_server_ids_json',
        c.customMcpServerIdsJson as String?,
        (v) => v as String,
      ),
      outline: c.outline as String,
      authorNote: c.authorNote as String,
      plotCursor: c.plotCursor as int,
      venue: c.venue as String,
      nextSpeakerIndex: c.nextSpeakerIndex as int,
      targetTotalChars: c.targetTotalChars as int,
      workMode: c.workMode as bool,
      messagesLoaded: messagesLoaded,
      recoveredStorage: Map.unmodifiable(recovery.retained),
    );
  }

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
    final activeChildrenJson =
        convo.recoveredStorage['active_children_json'] ??
        (convo.activeChildren.isEmpty
            ? null
            : jsonEncode(convo.activeChildren));
    final worldInfoIdsJson =
        convo.recoveredStorage['world_info_ids_json'] ??
        (convo.worldInfoIds.isEmpty ? null : jsonEncode(convo.worldInfoIds));
    final customMcpServerIdsJson =
        convo.recoveredStorage['custom_mcp_server_ids_json'] ??
        (convo.customMcpServerIds.isEmpty
            ? null
            : jsonEncode(convo.customMcpServerIds));
    final participantIdsJson =
        convo.recoveredStorage['participant_ids_json'] ??
        (convo.participantIds.isEmpty
            ? null
            : jsonEncode(convo.participantIds));
    final localCastJson =
        convo.recoveredStorage['local_cast_json'] ??
        (convo.localCast.isEmpty
            ? null
            : jsonEncode(
                convo.localCast.map((card) => card.toJson()).toList(),
              ));
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
        storedConvo.projectId != convo.projectId ||
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
              projectId: Value(convo.projectId),
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
        _fromConvoRow(
          c,
          messages: [
            for (final m in byConvo[c.id] ?? const <Message>[]) _toMessage(m),
          ],
        ),
    ];
  }

  ChatMessage _toMessage(Message m) {
    final recovery = StoredJsonReader();
    return ChatMessage(
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
      attachments: recovery.list(
        'attachments_json',
        m.attachmentsJson,
        (e) => Attachment.fromJson(e as Map<String, dynamic>),
      ),
      citations: recovery.list(
        'citations_json',
        m.citationsJson,
        (e) => Citation.fromJson(e as Map<String, dynamic>),
      ),
      searchActivities: recovery.list(
        'search_activities_json',
        m.searchActivitiesJson,
        (e) => SearchActivity.fromJson(e as Map<String, dynamic>),
      ),
      appliedWorldInfo: recovery.list(
        'applied_world_info_json',
        m.appliedWorldInfoJson,
        (e) => WorldInfoHit.fromJson(e as Map<String, dynamic>),
      ),
      longTask: recovery.object(
        'long_task_json',
        m.longTaskJson,
        (e) => LongTaskState.fromJson(e as Map<String, dynamic>),
      ),
      turnSkill: recovery.object(
        'turn_skill_json',
        m.turnSkillJson,
        (e) => TurnSkillMark.fromJson(e as Map<String, dynamic>),
      ),
      recoveredStorage: Map.unmodifiable(recovery.retained),
    );
  }

  String? _attachmentsJson(ChatMessage message) =>
      message.recoveredStorage['attachments_json'] ??
      (message.attachments.isEmpty
          ? null
          : jsonEncode(message.attachments.map((a) => a.toJson()).toList()));

  String? _citationsJson(ChatMessage message) =>
      message.recoveredStorage['citations_json'] ??
      (message.citations.isEmpty
          ? null
          : jsonEncode(message.citations.map((c) => c.toJson()).toList()));

  String? _searchActivitiesJson(ChatMessage message) =>
      message.recoveredStorage['search_activities_json'] ??
      (message.searchActivities.isEmpty
          ? null
          : jsonEncode(
              message.searchActivities.map((a) => a.toJson()).toList(),
            ));

  String? _appliedWorldInfoJson(ChatMessage message) =>
      message.recoveredStorage['applied_world_info_json'] ??
      (message.appliedWorldInfo.isEmpty
          ? null
          : jsonEncode(
              message.appliedWorldInfo.map((a) => a.toJson()).toList(),
            ));

  String? _longTaskJson(ChatMessage message) =>
      message.recoveredStorage['long_task_json'] ??
      (message.longTask == null
          ? null
          : jsonEncode(message.longTask!.toJson()));

  String? _turnSkillJson(ChatMessage message) =>
      message.recoveredStorage['turn_skill_json'] ??
      (message.turnSkill == null
          ? null
          : jsonEncode(message.turnSkill!.toJson()));

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
}
