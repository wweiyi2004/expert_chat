import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models.dart';
import '../features/shell/shell_tab.dart';
import 'chat_controller.dart';

/// UI visibility only; never changes saved conversations or execution state.
final conversationRouteVisibleProvider =
    NotifierProvider<ConversationRouteVisible, bool>(
      ConversationRouteVisible.new,
    );

class ConversationRouteVisible extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool value) {
    if (state != value) state = value;
  }
}

final conversationAttentionProvider =
    NotifierProvider<ConversationAttention, Set<String>>(
      ConversationAttention.new,
    );

class ConversationAttention extends Notifier<Set<String>> {
  final _signatures = <String, String>{};
  @override
  Set<String> build() {
    ref.listen(chatControllerProvider, (_, next) => _capture(next.value));
    ref.listen(
      shellTabProvider,
      (_, _) => _capture(ref.read(chatControllerProvider).value),
    );
    ref.listen(
      conversationRouteVisibleProvider,
      (_, _) => _capture(ref.read(chatControllerProvider).value),
    );
    final initial = ref.read(chatControllerProvider).value;
    if (initial != null) {
      for (final c in initial.conversations) {
        _signatures[c.id] = _signature(initial, c.id);
      }
    }
    return {};
  }

  String _signature(ChatState chat, String id) {
    final c = chat.conversations.where((c) => c.id == id).firstOrNull;
    final last = c?.activePath
        .where((m) => m.role == MessageRole.assistant)
        .lastOrNull;
    final checkpoint = chat.sessionCheckpoints[id];
    return '${last?.id}:${last?.content.hashCode}:${checkpoint?.status}:${checkpoint?.updatedAt.microsecondsSinceEpoch}';
  }

  void _capture(ChatState? chat) {
    if (chat == null) return;
    final next = {...state};
    final visible =
        ref.read(shellTabProvider) == ShellTab.chat &&
        ref.read(conversationRouteVisibleProvider);
    for (final c in chat.conversations) {
      final signature = _signature(chat, c.id);
      final prior = _signatures[c.id];
      if (visible && chat.currentId == c.id) {
        next.remove(c.id);
      } else if (prior != null && prior != signature) {
        next.add(c.id);
      }
      _signatures[c.id] = signature;
    }
    next.removeWhere((id) => !chat.conversations.any((c) => c.id == id));
    if (next.length != state.length || !next.containsAll(state)) state = next;
  }
}
