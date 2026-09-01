import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'story_models.dart';

/// List-row metadata without message bodies or attachments.
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.mode,
    this.characterId,
    this.participantIds = const [],
    this.localCast = const [],
    this.worldInfoIds = const [],
    this.customMcpServerIds = const [],
    this.outline = '',
    this.authorNote = '',
    this.plotCursor = 0,
    this.venue = '',
    this.nextSpeakerIndex = 0,
    this.targetTotalChars = 0,
    this.workMode = false,
    this.activeChildren = const {},
    this.hasActiveLongTask = false,
  });

  factory ConversationSummary.fromConversation(Conversation conversation) =>
      ConversationSummary(
        id: conversation.id,
        title: conversation.title,
        updatedAt: conversation.updatedAt,
        mode: conversation.mode,
        characterId: conversation.characterId,
        participantIds: conversation.participantIds,
        localCast: conversation.localCast,
        worldInfoIds: conversation.worldInfoIds,
        customMcpServerIds: conversation.customMcpServerIds,
        outline: conversation.outline,
        authorNote: conversation.authorNote,
        plotCursor: conversation.plotCursor,
        venue: conversation.venue,
        nextSpeakerIndex: conversation.nextSpeakerIndex,
        targetTotalChars: conversation.targetTotalChars,
        workMode: conversation.workMode,
        activeChildren: conversation.activeChildren,
        hasActiveLongTask: conversation.messages.any(
          (message) => message.longTask?.isActive == true,
        ),
      );

  final String id;
  final String title;
  final DateTime updatedAt;
  final ConversationMode mode;
  final String? characterId;
  final List<String> participantIds;
  final List<CharacterCard> localCast;
  final List<String> worldInfoIds;
  final List<String> customMcpServerIds;
  final String outline;
  final String authorNote;
  final int plotCursor;
  final String venue;
  final int nextSpeakerIndex;
  final int targetTotalChars;
  final bool workMode;
  final Map<String, String> activeChildren;
  final bool hasActiveLongTask;

  Conversation toPlaceholder() => Conversation(
    id: id,
    title: title,
    messages: const [],
    activeChildren: activeChildren,
    updatedAt: updatedAt,
    mode: mode,
    characterId: characterId,
    participantIds: participantIds,
    localCast: localCast,
    worldInfoIds: worldInfoIds,
    customMcpServerIds: customMcpServerIds,
    outline: outline,
    authorNote: authorNote,
    plotCursor: plotCursor,
    venue: venue,
    nextSpeakerIndex: nextSpeakerIndex,
    targetTotalChars: targetTotalChars,
    workMode: workMode,
    messagesLoaded: false,
  );
}

/// One title/content match from [ConversationRepository.searchMessages].
class SearchHit {
  const SearchHit({
    required this.convoId,
    required this.messageId,
    required this.snippet,
    this.title = '',
  });

  final String convoId;
  final String messageId;
  final String snippet;
  final String title;
}

String searchSnippetAround(String content, int index, int queryLen) {
  final from = (index - 16).clamp(0, content.length);
  final to = (index + queryLen + 36).clamp(0, content.length);
  var snip = content.substring(from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (from > 0) snip = '…$snip';
  if (to < content.length) snip = '$snip…';
  return snip;
}

/// Persists conversations to disk. M1 uses a single JSON file; the interface is
/// kept narrow so it can be swapped for a drift/SQLite implementation later
/// without touching the controllers.
abstract class ConversationRepository {
  Future<List<Conversation>> loadAll();
  Future<void> saveAll(List<Conversation> conversations);

  /// Persist a single conversation (insert or update). Far cheaper than
  /// [saveAll] for the common case of one mutated conversation.
  Future<void> saveConversation(Conversation conversation);

  /// Remove a single conversation (and its messages).
  Future<void> deleteConversation(String id);

  /// Conversation headers only — does not read the messages table.
  Future<List<ConversationSummary>> loadSummaries();

  /// One conversation header plus its messages.
  Future<Conversation> loadConversation(String id);

  /// SQL/in-memory search over titles and message bodies. Empty query
  /// returns no hits (it must not load the full archive).
  Future<List<SearchHit>> searchMessages(String query);
}

/// Test/legacy helper: derive the on-demand APIs from [loadAll].
mixin ConversationRepositoryViaLoadAll implements ConversationRepository {
  @override
  Future<List<ConversationSummary>> loadSummaries() async {
    final all = await loadAll();
    return [
      for (final conversation in all)
        ConversationSummary.fromConversation(conversation),
    ];
  }

  @override
  Future<Conversation> loadConversation(String id) async {
    final all = await loadAll();
    for (final conversation in all) {
      if (conversation.id == id) return conversation;
    }
    throw StateError('Conversation $id not found');
  }

  @override
  Future<List<SearchHit>> searchMessages(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final lower = q.toLowerCase();
    final all = await loadAll();
    final hits = <SearchHit>[];
    for (final conversation in all) {
      var matched = conversation.title.toLowerCase().contains(lower);
      for (final message in conversation.messages) {
        final idx = message.content.toLowerCase().indexOf(lower);
        if (idx < 0) continue;
        matched = true;
        hits.add(
          SearchHit(
            convoId: conversation.id,
            messageId: message.id,
            snippet: searchSnippetAround(message.content, idx, q.length),
            title: conversation.title,
          ),
        );
      }
      if (matched && !hits.any((hit) => hit.convoId == conversation.id)) {
        hits.add(
          SearchHit(
            convoId: conversation.id,
            messageId: '',
            snippet: conversation.title,
            title: conversation.title,
          ),
        );
      }
    }
    return hits;
  }
}

/// Thrown by [JsonConversationRepository.loadAll] when the history file exists
/// but cannot be decoded (truncated write, hand-edited garbage). Callers must
/// not treat this as an empty store: a subsequent write would overwrite the
/// surviving history.
class JsonHistoryCorruptedException implements Exception {
  JsonHistoryCorruptedException(this.path);

  final String path;

  @override
  String toString() => 'JsonHistoryCorruptedException: $path is corrupt';
}

/// JSON file store used by legacy migration and tests. New on-demand APIs
/// are derived from [loadAll] (the whole file is one blob).
class JsonConversationRepository
    with ConversationRepositoryViaLoadAll
    implements ConversationRepository {
  JsonConversationRepository({File? file}) : _injectedFile = file;

  /// Explicit file override (tests); production resolves the support directory.
  final File? _injectedFile;
  File? _cachedFile;

  Future<File> _file() async {
    if (_cachedFile != null) return _cachedFile!;
    if (_injectedFile != null) {
      _cachedFile = _injectedFile;
      return _cachedFile!;
    }
    final dir = await getApplicationSupportDirectory();
    _cachedFile = File(
      '${dir.path}${Platform.pathSeparator}conversations.json',
    );
    return _cachedFile!;
  }

  @override
  Future<List<Conversation>> loadAll() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final list = _decodeList(raw);
    if (list == null) {
      // A file that exists but cannot be decoded must never read as an empty
      // store: the next write would silently overwrite the surviving history.
      throw JsonHistoryCorruptedException(file.path);
    }
    final conversations = <Conversation>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) {
        debugPrint('conversations.json: skipping non-object entry');
        continue;
      }
      try {
        conversations.add(Conversation.fromJson(entry));
      } catch (error) {
        // A single corrupt record (e.g. a hand-edited field of the wrong
        // type) must not invalidate the rest of the history.
        debugPrint('conversations.json: skipping corrupt entry: $error');
      }
    }
    return conversations;
  }

  /// Decodes the store payload as a JSON array; null when the content is not
  /// a valid JSON list (truncated file, object at the top level, ...).
  List<dynamic>? _decodeList(String raw) {
    try {
      return jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    final file = await _file();
    await _backupCorruptFile(file);
    final data = conversations.map((c) => c.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }

  /// A damaged history file is renamed to `conversations.corrupt-<timestamp>`
  /// before the first write, so the next successful save cannot destroy it.
  Future<void> _backupCorruptFile(File file) async {
    if (!await file.exists()) return;
    final raw = await file.readAsString();
    if (raw.trim().isEmpty || _decodeList(raw) != null) return;
    final backupPath =
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
    debugPrint('conversations.json: backing up corrupt file to $backupPath');
    await file.rename(backupPath);
  }

  // JSON storage is a single file, so per-item ops just rewrite the whole list.
  @override
  Future<void> saveConversation(Conversation conversation) async {
    final all = await _loadAllForWrite();
    final idx = all.indexWhere((c) => c.id == conversation.id);
    if (idx >= 0) {
      all[idx] = conversation;
    } else {
      all.insert(0, conversation);
    }
    await saveAll(all);
  }

  @override
  Future<void> deleteConversation(String id) async {
    final all = await _loadAllForWrite()
      ..removeWhere((c) => c.id == id);
    await saveAll(all);
  }

  /// [loadAll] treats an undecodable file as corruption; writes treat it as
  /// empty and [saveAll] backs the damaged file up before overwriting.
  Future<List<Conversation>> _loadAllForWrite() async {
    try {
      return await loadAll();
    } on JsonHistoryCorruptedException catch (error) {
      debugPrint('conversations.json: $error; will back up before next write');
      return [];
    }
  }
}
