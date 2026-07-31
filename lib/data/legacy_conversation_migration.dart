import 'conversation_repository.dart';
import 'models.dart';

/// Imports the legacy JSON store once, gated on the JSON side rather than the
/// drift side.
///
/// M1 conversations were persisted as ordered message lists without tree
/// metadata. Rebuild that linear tree before saving so the active path retains
/// the complete history. The JSON source is cleared only after drift succeeds;
/// a drift store that is already non-empty must not skip the import, or data
/// left behind by an interrupted migration (drift saved, JSON clear failed)
/// would be orphaned forever. Existing drift conversations are merged by id so
/// the re-import neither duplicates them nor drops conversations the user
/// created since; drift's save is an idempotent upsert.
Future<void> migrateLegacyJsonToDrift(
  ConversationRepository drift, {
  ConversationRepository? json,
}) async {
  try {
    final jsonRepository = json ?? JsonConversationRepository();
    final legacy = await jsonRepository.loadAll();
    if (legacy.isEmpty) return;

    final existing = await drift.loadAll();
    final existingIds = {for (final conversation in existing) conversation.id};
    final merged = [
      ...existing,
      for (final conversation in legacy)
        if (!existingIds.contains(conversation.id))
          _restoreLinearTree(conversation),
    ];

    await drift.saveAll(merged);
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
