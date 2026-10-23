import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';

/// Device-local grants do not travel in exported chats or imported backups.
final conversationWorkspaceBindingsProvider =
    NotifierProvider<ConversationWorkspaceBindings, Map<String, String>>(
      ConversationWorkspaceBindings.new,
    );

class ConversationWorkspaceBindings extends Notifier<Map<String, String>> {
  static const storageKey = 'desktopConversationWorkspaces';
  Future<void> _pending = Future.value();
  @override
  Map<String, String> build() {
    final raw = ref.read(sharedPrefsProvider).getString(storageKey);
    if (raw == null) return const {};
    return Map<String, String>.unmodifiable(
      Map<String, String>.from(jsonDecode(raw) as Map),
    );
  }

  Future<void> select(String conversationId, String? workspaceId) {
    final prefs = ref.read(sharedPrefsProvider);
    final operation = _pending.then((_) async {
      if (!ref.mounted) return;
      final next = Map<String, String>.from(state);
      if (workspaceId == null) {
        next.remove(conversationId);
      } else {
        next[conversationId] = workspaceId;
      }
      if (!await prefs.setString(storageKey, jsonEncode(next))) {
        throw StateError('工作区选择未保存，请重试。');
      }
      if (ref.mounted) state = Map.unmodifiable(next);
    });
    // Keep later user changes possible after a failed save; the caller still
    // receives the original failed operation.
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
