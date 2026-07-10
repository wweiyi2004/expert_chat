import 'conversation_repository.dart';
import 'models.dart';

/// Imports the legacy JSON store once when the drift store is empty.
///
/// M1 conversations were persisted as ordered message lists without tree
/// metadata. Rebuild that linear tree before saving so the active path retains
/// the complete history. The JSON source is cleared only after drift succeeds.
Future<void> migrateLegacyJsonToDrift(
  ConversationRepository drift, {
  ConversationRepository? json,
}) async {
  try {
    if ((await drift.loadAll()).isNotEmpty) return;

    final jsonRepository = json ?? JsonConversationRepository();
    final legacy = await jsonRepository.loadAll();
    if (legacy.isEmpty) return;

    await drift.saveAll(legacy.map(_restoreLinearTree).toList());
    await jsonRepository.saveAll(const []);
  } catch (_) {
    // Migration is best-effort; a failure must not block app start.
  }
}

Conversation _restoreLinearTree(Conversation conversation) {
  final messages = conversation.messages;
  final hasTreeMetadata =
      conversation.activeChildren.isNotEmpty ||
      messages.any((message) => message.parentId != null);
  if (messages.isEmpty || hasTreeMetadata) return conversation;

  final linkedMessages = <ChatMessage>[];
  final activeChildren = <String, String>{};
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final parentId = index == 0 ? null : messages[index - 1].id;
    linkedMessages.add(
      parentId == null
          ? message
          : ChatMessage(
              id: message.id,
              parentId: parentId,
              role: message.role,
              content: message.content,
              reasoning: message.reasoning,
              model: message.model,
              thinkingMillis: message.thinkingMillis,
              attachments: message.attachments,
              citations: message.citations,
              createdAt: message.createdAt,
            ),
    );
    activeChildren[parentId ?? kRootKey] = message.id;
  }

  return conversation.copyWith(
    messages: linkedMessages,
    activeChildren: activeChildren,
    updatedAt: conversation.updatedAt,
  );
}
