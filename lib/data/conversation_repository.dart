import 'dart:convert';
import 'dart:io';

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

class JsonConversationRepository implements ConversationRepository {
  File? _cachedFile;

  Future<File> _file() async {
    if (_cachedFile != null) return _cachedFile!;
    final dir = await getApplicationSupportDirectory();
    _cachedFile = File(
      '${dir.path}${Platform.pathSeparator}conversations.json',
    );
    return _cachedFile!;
  }

  @override
  Future<List<Conversation>> loadAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    final file = await _file();
    final data = conversations.map((c) => c.toJson()).toList();
    await file.writeAsString(jsonEncode(data));
  }

  // JSON storage is a single file, so per-item ops just rewrite the whole list.
  @override
  Future<void> saveConversation(Conversation conversation) async {
    final all = await loadAll();
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
    final all = await loadAll()
      ..removeWhere((c) => c.id == id);
    await saveAll(all);
  }
}
