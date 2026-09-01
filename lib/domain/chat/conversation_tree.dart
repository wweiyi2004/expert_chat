import 'package:characters/characters.dart';

import '../../data/models.dart';

/// Pure operations on the conversation message tree: `ChatMessage.parentId`
/// links plus the `Conversation.activeChildren` branch selections. None of
/// these read or write controller state.

/// Root-to-node path across any branch, used to retry the exact failed turn
/// even if the user briefly switched branches before pressing retry.
List<ChatMessage> pathToMessage(Conversation convo, String messageId) {
  final byId = {for (final m in convo.messages) m.id: m};
  final reversed = <ChatMessage>[];
  final seen = <String>{};
  ChatMessage? current = byId[messageId];
  while (current != null && seen.add(current.id)) {
    reversed.add(current);
    final parentId = current.parentId;
    current = parentId == null ? null : byId[parentId];
  }
  return reversed.reversed.toList();
}

/// [pathToMessage] for an optional target: a null id (the root) maps to the
/// empty path.
List<ChatMessage> pathToOptionalMessage(
  Conversation convo,
  String? messageId,
) => messageId == null ? const [] : pathToMessage(convo, messageId);

/// Branch selections with every message on [path] marked as the active child
/// of its parent.
Map<String, String> activatePath(
  Map<String, String> current,
  List<ChatMessage> path,
) {
  final next = Map<String, String>.of(current);
  for (final message in path) {
    next[message.parentId ?? kRootKey] = message.id;
  }
  return next;
}

/// Branch selections after appending a new turn: every message on
/// [pathToParent] is activated, [parentId] (or the root) selects the appended
/// [childId], and [childId] in turn selects [grandchildId] when the turn added
/// a second message (the assistant placeholder under a new user message).
Map<String, String> activeChildrenAfterAppending(
  Map<String, String> current,
  List<ChatMessage> pathToParent, {
  String? parentId,
  required String childId,
  String? grandchildId,
}) {
  final next = activatePath(current, pathToParent);
  next[parentId ?? kRootKey] = childId;
  if (grandchildId != null) next[childId] = grandchildId;
  return next;
}

/// Grapheme-aware truncation so a 20-cut can't split an emoji/surrogate pair.
String truncateTitle(String seed) {
  final chars = seed.characters;
  return chars.length > 20 ? '${chars.take(20)}…' : seed;
}
