import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Role of a chat message, mapped 1:1 to the OpenAI-compatible `role` field.
enum MessageRole { system, user, assistant, tool }

extension MessageRoleApi on MessageRole {
  String get wire => switch (this) {
        MessageRole.system => 'system',
        MessageRole.user => 'user',
        MessageRole.assistant => 'assistant',
        MessageRole.tool => 'tool',
      };

  static MessageRole fromWire(String value) => MessageRole.values
      .firstWhere((r) => r.wire == value, orElse: () => MessageRole.user);
}

/// A file the user attached to a message. The body is parsed to [text] locally
/// (M4) and injected into the prompt; raw bytes are never sent to the API.
class Attachment {
  Attachment({
    String? id,
    required this.name,
    required this.mimeType,
    this.sizeBytes = 0,
    this.text = '',
    this.truncated = false,
    this.parseError,
    this.imageBase64,
  }) : id = id ?? _uuid.v4();

  final String id;
  final String name;
  final String mimeType;
  final int sizeBytes;

  /// Extracted text content (may be truncated to fit the context window).
  final String text;
  final bool truncated;

  /// Set when local parsing failed; surfaced in the UI.
  final String? parseError;

  /// Base64-encoded image bytes, retained for vision-capable models. Null for
  /// non-images or images too large to attach.
  final String? imageBase64;

  bool get isImage => mimeType.startsWith('image/');

  /// True when this image can be sent to a vision model.
  bool get hasImageData => imageBase64 != null && imageBase64!.isNotEmpty;

  /// `data:` URL for the OpenAI `image_url` content part (vision models).
  String get imageDataUrl => 'data:$mimeType;base64,$imageBase64';

  Attachment copyWith({
    String? text,
    bool? truncated,
    String? parseError,
    String? imageBase64,
  }) => Attachment(
    id: id,
    name: name,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    text: text ?? this.text,
    truncated: truncated ?? this.truncated,
    parseError: parseError ?? this.parseError,
    imageBase64: imageBase64 ?? this.imageBase64,
  );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'text': text,
        'truncated': truncated,
        if (parseError != null) 'parseError': parseError,
        if (imageBase64 != null) 'imageBase64': imageBase64,
      };

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        text: json['text'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
        parseError: json['parseError'] as String?,
        imageBase64: json['imageBase64'] as String?,
      );
}

/// A web source cited by the assistant after a search (M5). Rendered as a
/// numbered badge that opens [url].
class Citation {
  const Citation({
    required this.index,
    required this.title,
    required this.url,
    this.snippet = '',
  });

  /// 1-based citation number as referenced inline (e.g. `[1]`).
  final int index;
  final String title;
  final String url;
  final String snippet;

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'url': url,
        'snippet': snippet,
      };

  factory Citation.fromJson(Map<String, dynamic> json) => Citation(
        index: (json['index'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
      );
}

/// A single chat message. [reasoning] holds the model's chain-of-thought
/// (only populated for reasoning models); it is shown in a collapsible panel
/// and is NOT sent back to the API in later turns.
class ChatMessage {
  ChatMessage({
    String? id,
    required this.role,
    required this.content,
    this.parentId,
    this.reasoning = '',
    this.model,
    this.thinkingMillis = 0,
    List<Attachment>? attachments,
    List<Citation>? citations,
    DateTime? createdAt,
  })  : id = id ?? _uuid.v4(),
        attachments = attachments ?? const [],
        citations = citations ?? const [],
        createdAt = createdAt ?? DateTime.now();

  final String id;

  /// Parent node id in the conversation tree; null for a root-level message.
  /// Branching (edit / regenerate) creates siblings sharing the same parent.
  final String? parentId;

  final MessageRole role;
  final String content;
  final String reasoning;

  /// Model that produced this message (assistant only), e.g. `deepseek-reasoner`.
  final String? model;

  /// Wall-clock time the reasoning phase took, in milliseconds (assistant only).
  final int thinkingMillis;

  /// Files attached by the user (user messages) — M4.
  final List<Attachment> attachments;

  /// Web sources cited by the assistant — M5.
  final List<Citation> citations;

  final DateTime createdAt;

  ChatMessage copyWith({
    String? content,
    String? reasoning,
    String? model,
    int? thinkingMillis,
    List<Attachment>? attachments,
    List<Citation>? citations,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        parentId: parentId,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        model: model ?? this.model,
        thinkingMillis: thinkingMillis ?? this.thinkingMillis,
        attachments: attachments ?? this.attachments,
        citations: citations ?? this.citations,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.wire,
        if (parentId != null) 'parentId': parentId,
        'content': content,
        'reasoning': reasoning,
        if (model != null) 'model': model,
        'thinkingMillis': thinkingMillis,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
        if (citations.isNotEmpty)
          'citations': citations.map((c) => c.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String?,
        role: MessageRoleApi.fromWire(json['role'] as String? ?? 'user'),
        parentId: json['parentId'] as String?,
        content: json['content'] as String? ?? '',
        reasoning: json['reasoning'] as String? ?? '',
        model: json['model'] as String?,
        thinkingMillis: (json['thinkingMillis'] as num?)?.toInt() ?? 0,
        attachments: (json['attachments'] as List<dynamic>? ?? [])
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
        citations: (json['citations'] as List<dynamic>? ?? [])
            .map((e) => Citation.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      );
}

/// Root-level key for [Conversation.activeChildren] (messages with no parent).
const String kRootKey = '';

/// A conversation. [messages] holds ALL nodes across every branch (a tree);
/// [activeChildren] records, per parent id, which child is currently selected,
/// so [activePath] yields the linear list of visible messages. Editing or
/// regenerating adds sibling nodes rather than discarding the old ones.
class Conversation {
  Conversation({
    String? id,
    this.title = '新对话',
    List<ChatMessage>? messages,
    Map<String, String>? activeChildren,
    DateTime? updatedAt,
  })  : id = id ?? _uuid.v4(),
        messages = messages ?? [],
        activeChildren = activeChildren ?? {},
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final List<ChatMessage> messages;

  /// parentId (or [kRootKey]) → selected child id.
  final Map<String, String> activeChildren;
  final DateTime updatedAt;

  /// Children of a parent, oldest-first, across all branches.
  List<ChatMessage> childrenOf(String parentKey) {
    final out = [
      for (final m in messages) if ((m.parentId ?? kRootKey) == parentKey) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  /// The currently visible linear path from root to the active leaf.
  List<ChatMessage> get activePath {
    final path = <ChatMessage>[];
    var key = kRootKey;
    final guard = <String>{};
    while (true) {
      final children = childrenOf(key);
      if (children.isEmpty) break;
      final activeId = activeChildren[key];
      final next = children.firstWhere(
        (c) => c.id == activeId,
        orElse: () => children.last, // default to the newest branch
      );
      if (!guard.add(next.id)) break; // cycle safety
      path.add(next);
      key = next.id;
    }
    return path;
  }

  /// (index, total) of [messageId] among its siblings; total>1 means a branch.
  (int, int) branchInfo(String messageId) {
    final m = messages.firstWhere((x) => x.id == messageId,
        orElse: () => messages.first);
    final sibs = childrenOf(m.parentId ?? kRootKey);
    final idx = sibs.indexWhere((x) => x.id == messageId);
    return (idx, sibs.length);
  }

  Conversation copyWith({
    String? title,
    List<ChatMessage>? messages,
    Map<String, String>? activeChildren,
    DateTime? updatedAt,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        messages: messages ?? this.messages,
        activeChildren: activeChildren ?? this.activeChildren,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'activeChildren': activeChildren,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String?,
        title: json['title'] as String? ?? '新对话',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        activeChildren: (json['activeChildren'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
