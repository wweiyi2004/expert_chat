import 'package:uuid/uuid.dart';

import '../domain/story/story_prompt_assembler.dart' show WorldInfoHit;
import 'chat_skill.dart';
import 'story_models.dart';

const _uuid = Uuid();

/// Role of a chat message, mapped 1:1 to the OpenAI-compatible `role` field.
enum MessageRole { system, user, assistant, tool }

enum MessageKind { text, generatedImage }

/// Lifecycle of a server-side document job attached to an assistant message.
///
/// This deliberately lives outside [MessageKind]: a long task still produces a
/// normal Markdown assistant answer, while the task metadata only controls the
/// progress card and resume/cancel behavior.
enum LongTaskStatus {
  preparing,
  uploading,
  queued,
  running,
  completed,
  failed,
  cancelled,
}

class LongTaskState {
  LongTaskState({
    required this.status,
    required this.providerProfileId,
    required this.providerName,
    required this.baseUrl,
    this.uploadBaseUrl = '',
    required this.model,
    this.taskId,
    this.remoteFileIds = const [],
    this.progress = 0,
    this.lastEventId = 0,
    this.detail,
    this.error,
    DateTime? startedAt,
    DateTime? updatedAt,
  }) : startedAt = startedAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final LongTaskStatus status;

  /// Retained in the stored schema for tasks created by older app versions.
  /// Gateway tasks leave [providerProfileId] empty and use [providerName] as a
  /// display label only.
  final String providerProfileId;
  final String providerName;

  /// Snapshot the Gateway endpoint/model used to create the remote job so a
  /// later settings change cannot redirect an in-flight task.
  final String baseUrl;
  final String uploadBaseUrl;
  final String model;
  final String? taskId;
  final List<String> remoteFileIds;
  final double progress;
  final int lastEventId;
  final String? detail;
  final String? error;
  final DateTime startedAt;
  final DateTime updatedAt;

  bool get isActive => switch (status) {
    LongTaskStatus.preparing ||
    LongTaskStatus.uploading ||
    LongTaskStatus.queued ||
    LongTaskStatus.running => true,
    _ => false,
  };

  bool get canRetry =>
      status == LongTaskStatus.failed || status == LongTaskStatus.cancelled;

  LongTaskState copyWith({
    LongTaskStatus? status,
    Object? taskId = _longTaskSentinel,
    List<String>? remoteFileIds,
    double? progress,
    int? lastEventId,
    Object? detail = _longTaskSentinel,
    Object? error = _longTaskSentinel,
    DateTime? updatedAt,
  }) => LongTaskState(
    status: status ?? this.status,
    providerProfileId: providerProfileId,
    providerName: providerName,
    baseUrl: baseUrl,
    uploadBaseUrl: uploadBaseUrl,
    model: model,
    taskId: identical(taskId, _longTaskSentinel)
        ? this.taskId
        : taskId as String?,
    remoteFileIds: remoteFileIds ?? this.remoteFileIds,
    progress: progress ?? this.progress,
    lastEventId: lastEventId ?? this.lastEventId,
    detail: identical(detail, _longTaskSentinel)
        ? this.detail
        : detail as String?,
    error: identical(error, _longTaskSentinel) ? this.error : error as String?,
    startedAt: startedAt,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'providerProfileId': providerProfileId,
    'providerName': providerName,
    'baseUrl': baseUrl,
    if (uploadBaseUrl.isNotEmpty) 'uploadBaseUrl': uploadBaseUrl,
    'model': model,
    if (taskId != null) 'taskId': taskId,
    if (remoteFileIds.isNotEmpty) 'remoteFileIds': remoteFileIds,
    'progress': progress,
    'lastEventId': lastEventId,
    if (detail != null) 'detail': detail,
    if (error != null) 'error': error,
    'startedAt': startedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory LongTaskState.fromJson(Map<String, dynamic> json) => LongTaskState(
    status: LongTaskStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => LongTaskStatus.failed,
    ),
    providerProfileId: json['providerProfileId'] as String? ?? '',
    providerName: json['providerName'] as String? ?? 'API 提供商',
    baseUrl: json['baseUrl'] as String? ?? '',
    uploadBaseUrl: json['uploadBaseUrl'] as String? ?? '',
    model: json['model'] as String? ?? '',
    // `responseId` was used by the pre-Gateway OpenAI background prototype.
    taskId: json['taskId'] as String? ?? json['responseId'] as String?,
    remoteFileIds: (json['remoteFileIds'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(),
    progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    lastEventId: (json['lastEventId'] as num?)?.toInt() ?? 0,
    detail: json['detail'] as String?,
    error: json['error'] as String?,
    startedAt: _parseStoredTime(json['startedAt']),
    updatedAt: _parseStoredTime(json['updatedAt']),
  );
}

const _longTaskSentinel = Object();

extension MessageRoleApi on MessageRole {
  String get wire => switch (this) {
    MessageRole.system => 'system',
    MessageRole.user => 'user',
    MessageRole.assistant => 'assistant',
    MessageRole.tool => 'tool',
  };

  static MessageRole fromWire(String value) => MessageRole.values.firstWhere(
    (r) => r.wire == value,
    orElse: () => MessageRole.user,
  );
}

/// A file the user attached to a message. Ordinary chat injects locally parsed
/// [text] into the prompt. Raw bytes are retained only for explicit document
/// editing/download and server-side long-task uploads.
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
    this.remoteUrl,
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

  /// Base64-encoded binary payload. Used for vision images and for
  /// downloadable office files retained for document-edit round-trips.
  final String? imageBase64;

  /// Optional remote image URL returned by a generation API. Base64 output is
  /// preferred because it remains available offline; URLs are retained as a
  /// compatibility fallback for providers that do not return `b64_json`.
  final String? remoteUrl;

  bool get isImage => mimeType.startsWith('image/');

  /// True when this image can be sent to a vision model.
  bool get hasImageData =>
      isImage &&
      ((imageBase64 != null && imageBase64!.isNotEmpty) ||
          (remoteUrl != null && remoteUrl!.isNotEmpty));

  /// Non-empty base64 body available for save/share (image or office file).
  bool get hasDownloadableBytes =>
      imageBase64 != null && imageBase64!.isNotEmpty;

  /// Excel workbook kept for document-service edits.
  bool get isEditableSpreadsheet {
    final n = name.toLowerCase();
    return n.endsWith('.xlsx') && hasDownloadableBytes;
  }

  /// File retained for document-service round-trip
  /// (xlsx/docx/pptx/txt/md/csv/tsv).
  bool get isEditableDocument {
    final n = name.toLowerCase();
    return (n.endsWith('.xlsx') ||
            n.endsWith('.docx') ||
            n.endsWith('.pptx') ||
            n.endsWith('.txt') ||
            n.endsWith('.md') ||
            n.endsWith('.csv') ||
            n.endsWith('.tsv')) &&
        hasDownloadableBytes;
  }

  /// DocumentPatch `format` for this attachment, or null if not editable.
  String? get documentPatchFormat {
    final n = name.toLowerCase();
    if (n.endsWith('.xlsx')) return 'xlsx';
    if (n.endsWith('.docx')) return 'docx';
    if (n.endsWith('.pptx')) return 'pptx';
    if (n.endsWith('.txt')) return 'txt';
    if (n.endsWith('.md')) return 'md';
    if (n.endsWith('.csv')) return 'csv';
    if (n.endsWith('.tsv')) return 'tsv';
    return null;
  }

  /// `data:` URL for the OpenAI `image_url` content part (vision models).
  String get imageDataUrl => imageBase64 != null && imageBase64!.isNotEmpty
      ? 'data:$mimeType;base64,$imageBase64'
      : remoteUrl ?? '';

  Attachment copyWith({
    String? text,
    bool? truncated,
    String? parseError,
    Object? imageBase64 = _attachSentinel,
    Object? remoteUrl = _attachSentinel,
  }) => Attachment(
    id: id,
    name: name,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    text: text ?? this.text,
    truncated: truncated ?? this.truncated,
    parseError: parseError ?? this.parseError,
    imageBase64: identical(imageBase64, _attachSentinel)
        ? this.imageBase64
        : imageBase64 as String?,
    remoteUrl: identical(remoteUrl, _attachSentinel)
        ? this.remoteUrl
        : remoteUrl as String?,
  );

  static const _attachSentinel = Object();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'text': text,
    'truncated': truncated,
    if (parseError != null) 'parseError': parseError,
    if (imageBase64 != null) 'imageBase64': imageBase64,
    if (remoteUrl != null) 'remoteUrl': remoteUrl,
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
    remoteUrl: json['remoteUrl'] as String?,
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

/// What a [SearchActivity] step did: a keyword search or reading one page.
enum SearchActivityKind { search, fetch, vision }

/// Lifecycle of a [SearchActivity]. `running` steps drive the live indicator;
/// terminal states stay in the transcript so past turns show what was done.
enum SearchActivityStatus { running, done, failed }

/// One visible step of the web-search process attached to an assistant
/// message ("searched X → 8 results", "read example.com"). Persisted with the
/// message so history shows how an answer was researched.
class SearchActivity {
  SearchActivity({
    String? id,
    required this.kind,
    required this.query,
    this.status = SearchActivityStatus.running,
    this.resultCount = 0,
    this.error,
  }) : id = id ?? _uuid.v4();

  final String id;
  final SearchActivityKind kind;

  /// Search keywords, page URL, or image filename depending on [kind].
  final String query;
  final SearchActivityStatus status;

  /// Number of usable sources this step contributed (0 while running).
  final int resultCount;

  /// Short human-readable reason when [status] is failed.
  final String? error;

  SearchActivity copyWith({
    SearchActivityStatus? status,
    int? resultCount,
    String? error,
  }) => SearchActivity(
    id: id,
    kind: kind,
    query: query,
    status: status ?? this.status,
    resultCount: resultCount ?? this.resultCount,
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'query': query,
    'status': status.name,
    'resultCount': resultCount,
    if (error != null) 'error': error,
  };

  factory SearchActivity.fromJson(Map<String, dynamic> json) => SearchActivity(
    id: json['id'] as String?,
    kind: SearchActivityKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => SearchActivityKind.search,
    ),
    query: json['query'] as String? ?? '',
    // A step persisted mid-run (app killed during search) can never resume;
    // load it as failed so the UI doesn't show a forever-spinning row.
    status: switch (json['status']) {
      'done' => SearchActivityStatus.done,
      'failed' || 'running' => SearchActivityStatus.failed,
      _ => SearchActivityStatus.failed,
    },
    resultCount: (json['resultCount'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );
}

/// Parses a stored ISO-8601 timestamp. Returns null only when the field is
/// genuinely absent (a fresh object, where the caller defaults to "now"). A
/// present-but-corrupt value falls back to epoch so the record sorts oldest,
/// rather than `now()` which would silently float corrupt data to the top and
/// scramble time-based ordering.
DateTime? _parseStoredTime(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    // A numeric timestamp (epoch millis) drifted in from an older writer;
    // accept it instead of letting the cast throw and drop the record.
    return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
  }
  return DateTime.tryParse(raw.toString()) ??
      DateTime.fromMillisecondsSinceEpoch(0);
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
    this.speakerId,
    this.speakerName,
    this.kind = MessageKind.text,
    List<Attachment>? attachments,
    List<Citation>? citations,
    List<SearchActivity>? searchActivities,
    List<WorldInfoHit>? appliedWorldInfo,
    this.longTask,
    this.turnSkill,
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       attachments = attachments ?? const [],
       citations = citations ?? const [],
       searchActivities = searchActivities ?? const [],
       appliedWorldInfo = appliedWorldInfo ?? const [],
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

  /// Character card id when this line is spoken by a cast member (ensemble).
  final String? speakerId;

  /// Display name for the speaker (ensemble / multi-character).
  final String? speakerName;
  final MessageKind kind;

  /// Files attached by the user (user messages) — M4.
  final List<Attachment> attachments;

  /// Web sources cited by the assistant — M5.
  final List<Citation> citations;

  /// Visible steps of the web-search process for this answer (searches run,
  /// pages read). Empty for messages produced without web access.
  final List<SearchActivity> searchActivities;

  /// World-info / lorebook entries injected into the system prompt for this
  /// assistant turn (story / ensemble). Empty when none fired.
  final List<WorldInfoHit> appliedWorldInfo;

  /// Server-side long-running document job represented by this assistant
  /// message. Null for ordinary chat messages.
  final LongTaskState? longTask;

  /// Skill selected for this assistant turn. Null for ordinary / legacy
  /// messages that were never routed.
  final TurnSkillMark? turnSkill;

  final DateTime createdAt;

  ChatMessage copyWith({
    String? content,
    String? reasoning,
    String? model,
    int? thinkingMillis,
    Object? speakerId = _msgSentinel,
    Object? speakerName = _msgSentinel,
    MessageKind? kind,
    List<Attachment>? attachments,
    List<Citation>? citations,
    List<SearchActivity>? searchActivities,
    List<WorldInfoHit>? appliedWorldInfo,
    Object? longTask = _msgSentinel,
    Object? turnSkill = _msgSentinel,
  }) => ChatMessage(
    id: id,
    role: role,
    parentId: parentId,
    content: content ?? this.content,
    reasoning: reasoning ?? this.reasoning,
    model: model ?? this.model,
    thinkingMillis: thinkingMillis ?? this.thinkingMillis,
    speakerId: identical(speakerId, _msgSentinel)
        ? this.speakerId
        : speakerId as String?,
    speakerName: identical(speakerName, _msgSentinel)
        ? this.speakerName
        : speakerName as String?,
    kind: kind ?? this.kind,
    attachments: attachments ?? this.attachments,
    citations: citations ?? this.citations,
    searchActivities: searchActivities ?? this.searchActivities,
    appliedWorldInfo: appliedWorldInfo ?? this.appliedWorldInfo,
    longTask: identical(longTask, _msgSentinel)
        ? this.longTask
        : longTask as LongTaskState?,
    turnSkill: identical(turnSkill, _msgSentinel)
        ? this.turnSkill
        : turnSkill as TurnSkillMark?,
    createdAt: createdAt,
  );

  static const _msgSentinel = Object();

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.wire,
    if (parentId != null) 'parentId': parentId,
    'content': content,
    'reasoning': reasoning,
    if (model != null) 'model': model,
    'thinkingMillis': thinkingMillis,
    if (speakerId != null) 'speakerId': speakerId,
    if (speakerName != null) 'speakerName': speakerName,
    if (kind != MessageKind.text) 'kind': kind.name,
    if (attachments.isNotEmpty)
      'attachments': attachments.map((a) => a.toJson()).toList(),
    if (citations.isNotEmpty)
      'citations': citations.map((c) => c.toJson()).toList(),
    if (searchActivities.isNotEmpty)
      'searchActivities': searchActivities.map((a) => a.toJson()).toList(),
    if (appliedWorldInfo.isNotEmpty)
      'appliedWorldInfo': appliedWorldInfo.map((a) => a.toJson()).toList(),
    if (longTask != null) 'longTask': longTask!.toJson(),
    if (turnSkill != null) 'turnSkill': turnSkill!.toJson(),
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
    speakerId: json['speakerId'] as String?,
    speakerName: json['speakerName'] as String?,
    kind: MessageKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => MessageKind.text,
    ),
    attachments: (json['attachments'] as List<dynamic>? ?? [])
        .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
        .toList(),
    citations: (json['citations'] as List<dynamic>? ?? [])
        .map((e) => Citation.fromJson(e as Map<String, dynamic>))
        .toList(),
    searchActivities: (json['searchActivities'] as List<dynamic>? ?? [])
        .map((e) => SearchActivity.fromJson(e as Map<String, dynamic>))
        .toList(),
    appliedWorldInfo: (json['appliedWorldInfo'] as List<dynamic>? ?? [])
        .map((e) => WorldInfoHit.fromJson(e as Map<String, dynamic>))
        .toList(),
    longTask: json['longTask'] is Map<String, dynamic>
        ? LongTaskState.fromJson(json['longTask'] as Map<String, dynamic>)
        : null,
    turnSkill: json['turnSkill'] is Map<String, dynamic>
        ? TurnSkillMark.fromJson(json['turnSkill'] as Map<String, dynamic>)
        : null,
    createdAt: _parseStoredTime(json['createdAt']),
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
    this.mode = ConversationMode.chat,
    this.characterId,
    List<String>? participantIds,
    List<CharacterCard>? localCast,
    List<String>? worldInfoIds,
    this.outline = '',
    this.authorNote = '',
    this.plotCursor = 0,
    this.venue = '',
    this.nextSpeakerIndex = 0,
    this.targetTotalChars = 0,
  }) : id = id ?? _uuid.v4(),
       messages = messages ?? [],
       activeChildren = activeChildren ?? {},
       updatedAt = updatedAt ?? DateTime.now(),
       participantIds =
           participantIds ?? (characterId != null ? [characterId] : const []),
       localCast = localCast ?? const [],
       worldInfoIds = worldInfoIds ?? const [];

  final String id;
  final String title;
  final List<ChatMessage> messages;

  /// parentId (or [kRootKey]) → selected child id.
  final Map<String, String> activeChildren;
  final DateTime updatedAt;

  /// Ordinary chat vs character/story session.
  final ConversationMode mode;

  /// Bound character card when [mode] is story (single-character).
  final String? characterId;

  /// Cast for ensemble sessions (and single-story when length == 1).
  final List<String> participantIds;

  /// Character cards generated specifically for this story. Unlike cards in
  /// the global character library, these travel with the conversation and do
  /// not pollute the reusable library.
  final List<CharacterCard> localCast;

  /// World-info entry ids enabled for this session (global library opt-in).
  final List<String> worldInfoIds;

  /// Free-form plot outline; parsed into beats for [plotCursor].
  final String outline;

  /// Director / OOC instructions injected every turn in story mode.
  final String authorNote;

  /// 0-based index of the current outline beat (auto-advanced on successful
  /// plot advance; manually adjustable).
  final int plotCursor;

  /// Shared place / situation for ensemble scenes.
  final String venue;

  /// Round-robin index into [participantIds] for the next AI line.
  final int nextSpeakerIndex;

  /// Target novel length in Unicode grapheme clusters (Chinese-friendly
  /// "字数"). `0` means no length budget is enforced.
  final int targetTotalChars;

  bool get isStory => mode == ConversationMode.story;
  bool get isEnsemble => mode == ConversationMode.ensemble;
  bool get isStudy => mode == ConversationMode.study;
  bool get isStoryLike => isStory || isEnsemble;

  /// User has sent at least one message (branch-wide, not only active path).
  bool get hasUserActivity => messages.any((m) => m.role == MessageRole.user);

  /// Fresh session of this mode with no user turns yet (may still have an
  /// opener / system-style assistant line, e.g. story firstMes).
  bool get isUnusedSession => !hasUserActivity;

  List<String> get outlineBeats => parseOutlineBeats(outline);

  List<String> get castIds {
    if (participantIds.isNotEmpty) return participantIds;
    if (characterId != null) return [characterId!];
    return const [];
  }

  /// Lazily built parent → children index. Conversations are treated as
  /// immutable (every mutation goes through [copyWith], which builds a new
  /// instance), so the index never goes stale. Avoids the O(n²) rescan that
  /// [activePath]/[branchInfo] otherwise cost on every frame while streaming.
  Map<String, List<ChatMessage>>? _childrenIndex;
  Map<String, (int, int)>? _branchInfoIndex;

  Map<String, List<ChatMessage>> get _children {
    final cached = _childrenIndex;
    if (cached != null) return cached;
    // Insertion order (the order messages appear in the list, which the repo
    // preserves via the `seq` column) is the stable tiebreaker: Dart's
    // List.sort is NOT stable, so siblings created in the same millisecond
    // (e.g. a fast regenerate) would otherwise reorder unpredictably across
    // reloads, making branch indices and the default branch jump around.
    final order = <String, int>{};
    for (var i = 0; i < messages.length; i++) {
      order[messages[i].id] = i;
    }
    final map = <String, List<ChatMessage>>{};
    for (final m in messages) {
      (map[m.parentId ?? kRootKey] ??= []).add(m);
    }
    for (final siblings in map.values) {
      siblings.sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
      });
    }
    return _childrenIndex = map;
  }

  /// Children of a parent, oldest-first, across all branches.
  List<ChatMessage> childrenOf(String parentKey) =>
      _children[parentKey] ?? const [];

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

  /// Pre-computed sibling position/count for every message. The chat page asks
  /// for this once per visible bubble during a stream; scanning [messages] for
  /// each bubble turns a long conversation into repeated O(n²) work.
  Map<String, (int, int)> get _branchInfo {
    final cached = _branchInfoIndex;
    if (cached != null) return cached;
    final index = <String, (int, int)>{};
    for (final siblings in _children.values) {
      for (var i = 0; i < siblings.length; i++) {
        index[siblings[i].id] = (i, siblings.length);
      }
    }
    return _branchInfoIndex = index;
  }

  /// (index, total) of [messageId] among its siblings; total>1 means a branch.
  /// Unknown ids yield (0, 1) — i.e. "no branching".
  (int, int) branchInfo(String messageId) => _branchInfo[messageId] ?? (0, 1);

  Conversation copyWith({
    String? title,
    List<ChatMessage>? messages,
    Map<String, String>? activeChildren,
    DateTime? updatedAt,
    ConversationMode? mode,
    Object? characterId = _storySentinel,
    List<String>? participantIds,
    List<CharacterCard>? localCast,
    List<String>? worldInfoIds,
    String? outline,
    String? authorNote,
    int? plotCursor,
    String? venue,
    int? nextSpeakerIndex,
    int? targetTotalChars,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    messages: messages ?? this.messages,
    activeChildren: activeChildren ?? this.activeChildren,
    updatedAt: updatedAt ?? DateTime.now(),
    mode: mode ?? this.mode,
    characterId: identical(characterId, _storySentinel)
        ? this.characterId
        : characterId as String?,
    participantIds: participantIds ?? this.participantIds,
    localCast: localCast ?? this.localCast,
    worldInfoIds: worldInfoIds ?? this.worldInfoIds,
    outline: outline ?? this.outline,
    authorNote: authorNote ?? this.authorNote,
    plotCursor: plotCursor ?? this.plotCursor,
    venue: venue ?? this.venue,
    nextSpeakerIndex: nextSpeakerIndex ?? this.nextSpeakerIndex,
    targetTotalChars: targetTotalChars ?? this.targetTotalChars,
  );

  static const _storySentinel = Object();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
    'activeChildren': activeChildren,
    'messages': messages.map((m) => m.toJson()).toList(),
    'mode': mode.wire,
    if (characterId != null) 'characterId': characterId,
    if (participantIds.isNotEmpty) 'participantIds': participantIds,
    if (localCast.isNotEmpty)
      'localCast': localCast.map((card) => card.toJson()).toList(),
    if (worldInfoIds.isNotEmpty) 'worldInfoIds': worldInfoIds,
    if (outline.isNotEmpty) 'outline': outline,
    if (authorNote.isNotEmpty) 'authorNote': authorNote,
    if (plotCursor != 0) 'plotCursor': plotCursor,
    if (venue.isNotEmpty) 'venue': venue,
    if (nextSpeakerIndex != 0) 'nextSpeakerIndex': nextSpeakerIndex,
    if (targetTotalChars != 0) 'targetTotalChars': targetTotalChars,
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String?,
    title: json['title'] as String? ?? '新对话',
    updatedAt: _parseStoredTime(json['updatedAt']),
    activeChildren: {
      for (final entry
          in (json['activeChildren'] as Map<String, dynamic>? ?? {}).entries)
        // Tolerate non-string values (e.g. numeric ids from an older writer)
        // rather than throwing and dropping the whole record.
        if (entry.value != null) entry.key: entry.value.toString(),
    },
    messages: (json['messages'] as List<dynamic>? ?? [])
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList(),
    mode: ConversationMode.fromWire(json['mode'] as String?),
    characterId: json['characterId'] as String?,
    participantIds: (json['participantIds'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    localCast: (json['localCast'] as List<dynamic>? ?? [])
        .map(
          (e) => CharacterCard.fromJson(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          ),
        )
        .toList(),
    worldInfoIds: (json['worldInfoIds'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList(),
    outline: json['outline'] as String? ?? '',
    authorNote: json['authorNote'] as String? ?? '',
    plotCursor: (json['plotCursor'] as num?)?.toInt() ?? 0,
    venue: json['venue'] as String? ?? '',
    nextSpeakerIndex: (json['nextSpeakerIndex'] as num?)?.toInt() ?? 0,
    targetTotalChars: (json['targetTotalChars'] as num?)?.toInt() ?? 0,
  );
}
