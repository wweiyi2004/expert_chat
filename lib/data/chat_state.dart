import 'models.dart';
import 'composer_modes.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/story/story_generation_intent.dart';

/// Exact operation represented by an error banner's retry action.
///
/// A transcript alone is not enough to infer this safely: pure image turns,
/// ensemble turns and plot rewrites all need different replay semantics.
enum ChatRetryKind { regenerate, image, ensemble, loadConversation }

class ChatRetryOperation {
  const ChatRetryOperation({
    required this.kind,
    required this.conversationId,
    required this.assistantMessageId,
    this.promptPlotCursor,
    this.commitPlotAdvance = false,
    this.storyIntent,
    this.ensembleSpeakerId,
  });

  const ChatRetryOperation.loadConversation(this.conversationId)
    : kind = ChatRetryKind.loadConversation,
      assistantMessageId = '',
      promptPlotCursor = null,
      commitPlotAdvance = false,
      storyIntent = null,
      ensembleSpeakerId = null;

  final ChatRetryKind kind;
  final String conversationId;
  final String assistantMessageId;

  /// Story cursor used only while assembling the retry prompt.
  final int? promptPlotCursor;

  /// Whether a successful retry should commit one plot beat.
  final bool commitPlotAdvance;

  /// Director-story action used to rebuild the same scoped prompt on retry.
  final StoryGenerationIntent? storyIntent;

  /// Speaker to preserve when retrying an ensemble turn.
  final String? ensembleSpeakerId;
}

class ChatState {
  const ChatState({
    this.conversations = const [],
    this.currentId,
    this.streamingConvoId,
    this.deepThink = false,
    this.reasoningEffort = ReasoningEffort.high,
    this.searchMode = SearchMode.auto,
    this.imageGenMode = ImageGenMode.auto,
    this.isSearching = false,
    this.isGeneratingImage = false,
    this.isProcessingDocument = false,
    this.contextReports = const {},
    this.error,
    this.errorConvoId,
    this.retryOperation,
  });

  final List<Conversation> conversations;
  final String? currentId;

  /// Id of the conversation a generation is currently streaming into, or null
  /// when idle. Kept as an id (not a bool) so switching conversations mid-
  /// stream can't mis-attribute the stream to the newly selected one.
  final String? streamingConvoId;

  bool get isStreaming => streamingConvoId != null;

  /// When true the next send enables thinking (the "深度思考" toggle).
  /// DeepSeek V4 stays on the selected model and only flips `thinking`;
  /// providers without that field still switch to [SettingsState.reasonerModel].
  final bool deepThink;

  /// DeepSeek/Grok thinking intensity while [deepThink] is on.
  final ReasoningEffort reasoningEffort;

  /// Current "联网" switch position (off / auto / always).
  final SearchMode searchMode;

  /// Dialogue illustration mode (off / auto / always). Independent of the
  /// composer's pure "图片生成" mode, which bypasses chat entirely.
  final ImageGenMode imageGenMode;

  /// True while a web-search / fetch-url tool call is running (composer hint).
  final bool isSearching;

  /// True while an image generation request is in flight (composer hint).
  /// Kept separate from [isSearching] so 配图 / 生图 never show "正在联网搜索".
  final bool isGeneratingImage;

  /// True while inspect/edit/convert document tools are running.
  final bool isProcessingDocument;
  final Map<String, ContextWindowReport> contextReports;
  final String? error;

  /// Conversation the [error] belongs to. Banner must not show on other
  /// threads (e.g. A fails while the user is viewing B). Null = global /
  /// settings-style errors that apply regardless of selection.
  final String? errorConvoId;

  /// Exact failed operation, if the current error can be safely retried.
  final ChatRetryOperation? retryOperation;

  /// Whether [error] should be shown for the currently selected conversation.
  bool errorVisibleFor(String? convoId) {
    if (error == null) return false;
    if (errorConvoId == null) return true;
    return errorConvoId == convoId;
  }

  Conversation? get current {
    if (conversations.isEmpty) return null;
    return conversations.firstWhere(
      (c) => c.id == currentId,
      orElse: () => conversations.first,
    );
  }

  ChatState copyWith({
    List<Conversation>? conversations,
    String? currentId,
    Object? streamingConvoId = _sentinel,
    bool? deepThink,
    ReasoningEffort? reasoningEffort,
    SearchMode? searchMode,
    ImageGenMode? imageGenMode,
    bool? isSearching,
    bool? isGeneratingImage,
    bool? isProcessingDocument,
    Map<String, ContextWindowReport>? contextReports,
    Object? error = _sentinel,
    Object? errorConvoId = _sentinel,
    Object? retryOperation = _sentinel,
  }) {
    final nextError = identical(error, _sentinel)
        ? this.error
        : error as String?;
    final String? nextErrorConvoId;
    final ChatRetryOperation? nextRetryOperation;
    if (identical(error, _sentinel)) {
      nextErrorConvoId = identical(errorConvoId, _sentinel)
          ? this.errorConvoId
          : errorConvoId as String?;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? this.retryOperation
          : retryOperation as ChatRetryOperation?;
    } else if (nextError == null) {
      // Clearing the message always clears the scope.
      nextErrorConvoId = null;
      nextRetryOperation = null;
    } else if (identical(errorConvoId, _sentinel)) {
      // New error without an explicit scope → global (settings / setup).
      // Generation failures must pass [errorConvoId] through the controller.
      nextErrorConvoId = null;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? null
          : retryOperation as ChatRetryOperation?;
    } else {
      nextErrorConvoId = errorConvoId as String?;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? null
          : retryOperation as ChatRetryOperation?;
    }
    return ChatState(
      conversations: conversations ?? this.conversations,
      currentId: currentId ?? this.currentId,
      streamingConvoId: identical(streamingConvoId, _sentinel)
          ? this.streamingConvoId
          : streamingConvoId as String?,
      deepThink: deepThink ?? this.deepThink,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      searchMode: searchMode ?? this.searchMode,
      imageGenMode: imageGenMode ?? this.imageGenMode,
      isSearching: isSearching ?? this.isSearching,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      isProcessingDocument: isProcessingDocument ?? this.isProcessingDocument,
      contextReports: contextReports ?? this.contextReports,
      error: nextError,
      errorConvoId: nextErrorConvoId,
      retryOperation: nextRetryOperation,
    );
  }

  static const _sentinel = Object();
}
