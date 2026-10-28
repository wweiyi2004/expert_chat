import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';

/// Small, rebuildable sidebar excerpts. Updated once after an answer, never
/// during token streaming, and don't require another model request.
String conversationExcerpt(String answer) {
  final text = answer
      .replaceAll(RegExp(r'```[\s\S]*?```'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'[*#`>|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.characters.length <= 76) return text;
  return '${text.characters.take(76)}…';
}

final conversationPreviewsProvider =
    NotifierProvider<ConversationPreviews, Map<String, String>>(
      ConversationPreviews.new,
    );

class ConversationPreviews extends Notifier<Map<String, String>> {
  static const storageKey = 'conversationSidebarPreviews';
  Future<void> _pending = Future.value();
  @override
  Map<String, String> build() {
    final raw = ref.read(sharedPrefsProvider).getString(storageKey);
    if (raw == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } on FormatException {
      return {};
    }
  }

  Future<void> record(String id, String answer) {
    final excerpt = conversationExcerpt(answer);
    if (excerpt.isEmpty || state[id] == excerpt) return Future.value();
    state = {...state, id: excerpt};
    return _save();
  }

  Future<void> remove(String id) {
    if (!state.containsKey(id)) return Future.value();
    state = {...state}..remove(id);
    return _save();
  }

  Future<void> _save() {
    final prefs = ref.read(sharedPrefsProvider);
    final encoded = jsonEncode(state);
    final save = _pending.then((_) async {
      if (!await prefs.setString(storageKey, encoded)) {
        throw StateError('会话摘要未保存');
      }
    });
    _pending = save.catchError((Object _) {});
    return save;
  }
}
