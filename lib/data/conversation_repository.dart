import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

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

class JsonConversationRepository implements ConversationRepository {
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
