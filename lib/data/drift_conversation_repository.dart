import 'dart:convert';

import 'package:drift/drift.dart';

import 'conversation_repository.dart';
// Hide drift's generated `Conversation` data class so our domain model wins;
// the drift `Message` row type is still used below for mapping.
import 'db/app_database.dart' hide Conversation;
import 'models.dart';

/// Drift/SQLite-backed [ConversationRepository]. A drop-in replacement for
/// [JsonConversationRepository]: it implements the same `loadAll`/`saveAll`
/// contract (syncing the in-memory list to the DB) and adds full-text-ish
/// [search] over titles and message bodies.
class DriftConversationRepository implements ConversationRepository {
  DriftConversationRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<Conversation>> loadAll() async {
    final convoRows = await (_db.select(_db.conversations)
          ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)]))
        .get();
    final msgRows = await (_db.select(_db.messages)
          ..orderBy([(m) => OrderingTerm.asc(m.seq)]))
        .get();

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

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    final keepIds = conversations.map((c) => c.id).toSet();
    await _db.transaction(() async {
      // Drop conversations no longer present (messages cascade).
      final existing = await _db.select(_db.conversations).get();
      for (final row in existing) {
        if (!keepIds.contains(row.id)) {
          await (_db.delete(_db.conversations)
                ..where((c) => c.id.equals(row.id)))
              .go();
        }
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

  /// Upsert one conversation header and replace its message rows. Replacing the
  /// rows wholesale is fine because this runs at stream end, not per token.
  Future<void> _writeConversation(Conversation convo) async {
    await _db.into(_db.conversations).insertOnConflictUpdate(
          ConversationsCompanion.insert(
            id: convo.id,
            title: Value(convo.title),
            updatedAt: convo.updatedAt,
            activeChildrenJson: Value(
              convo.activeChildren.isEmpty
                  ? null
                  : jsonEncode(convo.activeChildren),
            ),
          ),
        );
    await (_db.delete(_db.messages)..where((m) => m.convoId.equals(convo.id)))
        .go();
    var seq = 0;
    for (final m in convo.messages) {
      await _db.into(_db.messages).insert(_toCompanion(m, convo.id, seq++));
    }
  }

  /// Returns conversations whose title or any message content matches [query]
  /// (case-insensitive LIKE). Empty query returns everything.
  Future<List<Conversation>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return loadAll();
    final like = '%${q.toLowerCase()}%';
    final matchingIds = <String>{};

    final titleRows = await (_db.select(_db.conversations)
          ..where((c) => c.title.lower().like(like)))
        .get();
    matchingIds.addAll(titleRows.map((c) => c.id));

    final msgRows = await (_db.select(_db.messages)
          ..where((m) => m.content.lower().like(like)))
        .get();
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
        createdAt: m.createdAt,
        attachments: _decodeList(
            m.attachmentsJson, (e) => Attachment.fromJson(e)),
        citations:
            _decodeList(m.citationsJson, (e) => Citation.fromJson(e)),
      );

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
        attachmentsJson: Value(m.attachments.isEmpty
            ? null
            : jsonEncode(m.attachments.map((a) => a.toJson()).toList())),
        citationsJson: Value(m.citations.isEmpty
            ? null
            : jsonEncode(m.citations.map((c) => c.toJson()).toList())),
        createdAt: m.createdAt,
        seq: Value(seq),
      );

  List<T> _decodeList<T>(
      String? raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }
}
