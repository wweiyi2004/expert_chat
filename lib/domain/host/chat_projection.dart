import 'dart:convert';
import '../../data/chat_state.dart';
import 'wire_models.dart';

/// Per-client acknowledged baselines avoid losing deltas after a dropped reply.
class HostChatProjection {
  ChatState? _acknowledged, _pending;
  String? _visible, _pendingVisible;
  int _cursor = 0, _next = 0, _pendingCursor = -1;

  Map<String, Object?> project(
    ChatState current,
    String? visible,
    int clientCursor,
  ) {
    if (clientCursor == _pendingCursor) {
      _acknowledged = _pending;
      _visible = _pendingVisible;
      _cursor = _pendingCursor;
    } else if (clientCursor != _cursor) {
      _acknowledged = null;
      _visible = null;
      _cursor = clientCursor;
    }
    final previous = _acknowledged;
    final reset = previous == null || _visible != visible;
    final old = {
      if (!reset)
        for (final c in previous.conversations) c.id: c,
    };
    final headers = <Map<String, Object?>>[],
        messages = <Map<String, Object?>>[];
    final removedMessages = <String>[];
    for (final conversation in current.conversations) {
      final before = old[conversation.id];
      if (reset || !identical(before, conversation)) {
        headers.add({
          ...conversation.copyWith(messages: []).toJson(),
          'messagesLoaded':
              conversation.id == visible && conversation.messagesLoaded,
        });
      }
      if (conversation.id != visible) continue;
      final oldMessages = {
        if (before != null)
          for (final m in before.messages) m.id: m,
      };
      for (final message in conversation.messages) {
        final prior = oldMessages.remove(message.id);
        if (identical(prior, message)) continue;
        if (prior == null || reset) {
          messages.add({'id': message.id, 'replace': message.toJson()});
          continue;
        }
        final fields = Map<String, Object?>.from(message.toJson());
        final oldFields = prior.toJson();
        if (identical(prior.attachments, message.attachments)) {
          fields.remove('attachments');
        }
        if (identical(prior.searchActivities, message.searchActivities)) {
          fields.remove('searchActivities');
        }
        if (identical(prior.citations, message.citations)) {
          fields.remove('citations');
        }
        final append = <String, String>{};
        for (final key in ['content', 'reasoning']) {
          final next = fields[key], oldText = oldFields[key];
          if (next is String && oldText is String && next.startsWith(oldText)) {
            if (next.length > oldText.length) {
              append[key] = next.substring(oldText.length);
            }
            fields.remove(key);
          }
        }
        fields.removeWhere(
          (key, value) =>
              identical(value, oldFields[key]) ||
              jsonEncode(value) == jsonEncode(oldFields[key]),
        );
        final currentFields = message.toJson();
        final removed = oldFields.keys
            .where((key) => !currentFields.containsKey(key))
            .toList();
        messages.add({
          'id': message.id,
          'fields': fields,
          'append': append,
          'remove': removed,
        });
      }
      removedMessages.addAll(oldMessages.keys);
    }
    final global = encodeChatState(current.copyWith(conversations: []))
      ..remove('conversations');
    final selected = current.conversations
        .where((c) => c.id == visible)
        .firstOrNull;
    final next = ++_next;
    _pending = current;
    _pendingVisible = visible;
    _pendingCursor = next;
    return {
      'base_cursor': _cursor,
      'cursor': next,
      'reset': reset,
      'state': global,
      'headers': headers,
      'order': current.conversations.map((c) => c.id).toList(),
      'visible': visible,
      'messages': messages,
      'message_order': selected?.messages.map((m) => m.id).toList() ?? [],
      'removed_messages': removedMessages,
    };
  }
}

Map<String, dynamic> applyChatProjection(
  Map<String, dynamic>? previous,
  Map<String, dynamic> patch,
) {
  final reset = patch['reset'] == true;
  final conversations = <String, Map<String, dynamic>>{
    if (!reset)
      for (final c in wireRows(previous?['conversations']))
        c['id'] as String: c,
  };
  for (final header in wireRows(patch['headers'])) {
    final id = header['id'] as String;
    final messages = conversations[id]?['messages'] ?? <Object>[];
    conversations[id] = {
      ...header,
      'messages': header['messagesLoaded'] == true ? messages : <Object>[],
    };
  }
  final visible = patch['visible'] as String?;
  if (visible != null && conversations.containsKey(visible)) {
    final messageMap = {
      for (final message in wireRows(conversations[visible]!['messages']))
        message['id'] as String: message,
    };
    for (final change in wireRows(patch['messages'])) {
      final id = change['id'] as String;
      if (change['replace'] != null) {
        messageMap[id] = wireMap(change['replace']);
        continue;
      }
      final old = messageMap[id];
      if (old == null) throw const FormatException('Missing message baseline');
      final next = <String, dynamic>{...old, ...wireMap(change['fields'])};
      for (final entry in wireMap(change['append']).entries) {
        next[entry.key] = '${old[entry.key] ?? ''}${entry.value}';
      }
      for (final key in change['remove'] as List? ?? []) {
        next.remove(key);
      }
      messageMap[id] = next;
    }
    for (final id in patch['removed_messages'] as List? ?? []) {
      messageMap.remove(id);
    }
    conversations[visible]!['messages'] = [
      for (final id in patch['message_order'] as List? ?? [])
        if (messageMap.containsKey(id)) messageMap[id],
    ];
  }
  return {
    ...wireMap(patch['state']),
    'conversations': [
      for (final id in patch['order'] as List? ?? [])
        if (conversations.containsKey(id)) conversations[id],
    ],
  };
}
