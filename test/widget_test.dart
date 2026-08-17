import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/character_repository.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/domain/export/conversation_export.dart';
import 'package:expert_chat/domain/llm/long_task_gateway_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/speech/mimo_speech_input_service.dart';
import 'package:expert_chat/domain/speech/speech_input_service.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:expert_chat/domain/story/story_length_budget.dart';
import 'package:expert_chat/domain/story/story_prompt_assembler.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LLM provider that replays a scripted list of chunks and records the config
/// it was called with (so tests can assert model routing).
class FakeLlmProvider implements LlmProvider {
  FakeLlmProvider(this.chunks, {this.scriptedChunks});

  final List<ChatChunk> chunks;
  final List<List<ChatChunk>>? scriptedChunks;
  final List<List<LlmRequestMessage>> calls = [];
  final List<List<ToolSpec>?> toolCalls = [];
  final List<LlmConfig> configs = [];
  LlmConfig? lastConfig;
  List<ToolSpec>? lastTools;
  bool? lastThinking;
  int callCount = 0;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    final callIndex = callCount++;
    calls.add(List<LlmRequestMessage>.of(messages));
    toolCalls.add(tools == null ? null : List<ToolSpec>.of(tools));
    configs.add(config);
    lastConfig = config;
    lastTools = tools;
    lastThinking = thinking;
    final scripts = scriptedChunks;
    final scriptIndex = scripts == null
        ? 0
        : (callIndex < scripts.length ? callIndex : scripts.length - 1);
    final activeChunks = scripts == null ? chunks : scripts[scriptIndex];
    for (final c in activeChunks) {
      yield c;
    }
  }
}

class DelayedFailingLlmProvider implements LlmProvider {
  final entered = Completer<void>();
  final gate = Completer<void>();

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    throw Exception('simulated stream failure');
  }
}

class InMemoryRepo implements ConversationRepository {
  List<Conversation> store = [];
  @override
  Future<List<Conversation>> loadAll() async => store;
  @override
  Future<void> saveAll(List<Conversation> conversations) async =>
      store = conversations;
  @override
  Future<void> saveConversation(Conversation c) async {
    final idx = store.indexWhere((x) => x.id == c.id);
    if (idx >= 0) {
      store[idx] = c;
    } else {
      store.insert(0, c);
    }
  }

  @override
  Future<void> deleteConversation(String id) async =>
      store.removeWhere((c) => c.id == id);
}

class DelayedFailDeleteRepo extends InMemoryRepo {
  final deleteStarted = Completer<void>();
  final failDelete = Completer<void>();

  @override
  Future<void> deleteConversation(String id) async {
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await failDelete.future;
    throw Exception('simulated delete failure');
  }
}

class FailingSaveRepo extends InMemoryRepo {
  bool failNextSave = false;

  @override
  Future<void> saveConversation(Conversation c) async {
    if (failNextSave) {
      failNextSave = false;
      throw Exception('simulated storage failure');
    }
    return super.saveConversation(c);
  }
}

/// Repo that fails every save, for the generation pipeline's final-write
/// fallback: the first write already has a try/catch, the closing writes must
/// surface the same 本地保存失败 banner instead of escaping the stream.
class FailingSaveEveryTimeRepo extends InMemoryRepo {
  @override
  Future<void> saveConversation(Conversation c) async {
    throw Exception('simulated storage failure');
  }
}

/// Media provider that returns a canned image without any network I/O.
class FakeMediaProvider extends OpenAiCompatibleMediaProvider {
  FakeMediaProvider({this.failuresRemaining = 0});

  String? lastPrompt;
  final List<String> prompts = [];
  List<int>? lastReferenceBytes;
  int failuresRemaining;

  @override
  Future<GeneratedImage> generateImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    CancelToken? cancelToken,
    List<int>? referenceImageBytes,
    String referenceMimeType = 'image/png',
    String referenceFileName = 'reference.png',
    List<ImageEditReference> referenceImages = const [],
  }) async {
    lastPrompt = prompt;
    prompts.add(prompt);
    lastReferenceBytes = referenceImages.isNotEmpty
        ? referenceImages.first.bytes
        : referenceImageBytes;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw Exception('simulated image failure');
    }
    return const GeneratedImage(base64: 'QUFBQQ==');
  }
}

class FakeLongTaskGatewayClient extends LongTaskGatewayClient {
  final uploadedNames = <String>[];
  final uploadBaseUrls = <String>[];
  var createCount = 0;
  final deletedFileIds = <String>[];

  @override
  Future<String> uploadFile({
    required GatewayConnection connection,
    required Attachment attachment,
    required CancelToken cancelToken,
  }) async {
    uploadedNames.add(attachment.name);
    uploadBaseUrls.add(connection.config.normalizedUploadBaseUrl);
    return 'file_${uploadedNames.length}';
  }

  @override
  Future<LongTaskSnapshot> create({
    required GatewayConnection connection,
    required List<LongTaskInputMessage> messages,
    required List<String> fileIds,
    required CancelToken cancelToken,
    required String clientRequestId,
    String? instructions,
  }) async {
    createCount++;
    return const LongTaskSnapshot(
      id: 'task_test',
      status: 'completed',
      outputText: '长任务最终结果',
    );
  }

  @override
  Future<void> deleteFile({
    required GatewayConnection connection,
    required String fileId,
  }) async {
    deletedFileIds.add(fileId);
  }
}

/// Settings controller that returns a ready config without touching storage.
class FakeSettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: KnownModels.chat,
      reasonerModel: KnownModels.reasoner,
      models: const [KnownModels.chat, KnownModels.reasoner],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
      searchApiKey: 'search-key',
      gateway: const GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.example.com',
        uploadBaseUrl: 'https://upload.example.com',
      ),
      gatewayToken: 'gateway-token',
    );
  }
}

/// Settings with the factory chat-skill catalog so [_generate] can route.
class FakeChatSkillSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    final catalog = ChatSkillCatalog.factory();
    return base.copyWith(
      chatSkills: catalog,
      systemPrompt: catalog.fallback.prompt,
    );
  }
}

class FakeChatSkillSelectedModelSettings extends FakeChatSkillSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(selectedModel: KnownModels.reasoner);
  }
}

class FakeSmallContextSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      context: const ContextPrefs(
        contextWindowTokens: 4096,
        reservedOutputTokens: 3072,
        maxHistoryMessages: 6,
      ),
    );
  }
}

/// Settings with a configured vision API AND a small context window, so an
/// image attachment overflows the per-turn budget (images cannot be clipped
/// down by the context manager and must be rejected up front).
class FakeSmallContextVisionSettings extends FakeVisionSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      context: const ContextPrefs(
        contextWindowTokens: 4096,
        reservedOutputTokens: 3072,
        maxHistoryMessages: 6,
      ),
    );
  }
}

/// Settings with a single tool round, so a two-script stream hits the final
/// (tool-withheld) round on its second call.
class FakeOneSearchRoundSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(searchMaxRounds: 1);
  }
}

/// Settings whose build parks on an external gate, holding a send's preflight
/// window open so tests can act while the turn still awaits settings.
class GatedSettings extends FakeSettings {
  GatedSettings(this.gate);

  final Completer<void> gate;

  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    await gate.future;
    return base;
  }
}

/// LLM provider that errors on its first call, then answers normally.
class _FailOnceLlm implements LlmProvider {
  int callCount = 0;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    if (callCount++ == 0) throw Exception('simulated failure');
    yield const ChatChunk(contentDelta: '第一节正文');
  }
}

/// LLM provider that yields scripted chunks with a real per-chunk delay, so
/// the multi-round thinking stopwatch measures distinguishable intervals.
class _DelayedChunkProvider implements LlmProvider {
  _DelayedChunkProvider(this.scripts);

  final List<List<ChatChunk>> scripts;
  int callCount = 0;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    final index = callCount++;
    final script = scripts[index < scripts.length ? index : scripts.length - 1];
    for (final chunk in script) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      yield chunk;
    }
  }
}

/// LLM provider that delivers one text chunk then holds the stream open, so a
/// test can dispose the container while a UI flush is still pending.
class _DisposeMidStreamLlm implements LlmProvider {
  final delivered = Completer<void>();

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    yield const ChatChunk(contentDelta: 'partial');
    if (!delivered.isCompleted) delivered.complete();
    await Completer<void>().future; // hold the stream open
  }
}

/// Settings with a configured MiMo ASR endpoint (cloud speech input).
class FakeMimoSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      asrApi: const MediaApiConfig(
        baseUrl: MediaApiConfig.mimoBaseUrl,
        model: MediaApiConfig.mimoAsrModel,
      ),
      asrApiKey: 'sk-asr-test',
    );
  }
}

/// Settings with no API key — `config.isReady` is false.
class FakeUnconfiguredSettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: KnownModels.chat,
      reasonerModel: KnownModels.reasoner,
      models: const [KnownModels.chat, KnownModels.reasoner],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: '',
    );
  }
}

/// Settings whose active model is a vision-capable model (gpt-4o).
class FakeVisionSettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      chatModel: 'gpt-4o',
      reasonerModel: 'o3-mini',
      models: const ['gpt-4o', 'o3-mini'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
      visionApi: const MediaApiConfig(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o',
      ),
      visionApiKey: 'sk-vision-test',
    );
  }
}

/// Settings with the optional image-generation endpoint configured.
class FakeImageGenSettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: KnownModels.chat,
      reasonerModel: KnownModels.reasoner,
      models: const [KnownModels.chat, KnownModels.reasoner],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
      imageGenerationApi: const MediaApiConfig(
        baseUrl: 'https://media.example/v1',
        model: 'img-model',
      ),
      imageGenerationApiKey: 'sk-img-test',
    );
  }
}

/// Settings for an arbitrary OpenAI-compatible model whose tool support is
/// unknown. It should remain usable when a message contains a URL.
class FakeUnknownModelSettings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'Custom',
      baseUrl: 'https://llm.example/v1',
      chatModel: 'plain-chat-model',
      reasonerModel: 'plain-chat-model',
      models: const ['plain-chat-model'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
  }
}

/// Settings that stall on first read so tests can cancel during the start window.
class DelayedReadySettings extends SettingsController {
  final gate = Completer<void>();
  final entered = Completer<void>();

  @override
  Future<SettingsState> build() async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    final profile = ProviderProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: KnownModels.chat,
      reasonerModel: KnownModels.reasoner,
      models: const [KnownModels.chat, KnownModels.reasoner],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
  }
}

/// Settings that stall on first read AND carry an image-generation endpoint,
/// for preflight-window image-turn tests.
class DelayedImageSettings extends DelayedReadySettings {
  @override
  Future<SettingsState> build() async {
    final base = await super.build();
    return base.copyWith(
      imageGenerationApi: const MediaApiConfig(
        baseUrl: 'https://media.example/v1',
        model: 'img-model',
      ),
      imageGenerationApiKey: 'sk-img-test',
    );
  }
}

class FakeSpeechInputService implements SpeechInputService {
  FakeSpeechInputService({
    this.availability = SpeechInputAvailability.ready,
    this.initializeGate,
  });

  final SpeechInputAvailability availability;
  final Future<SpeechInputAvailability>? initializeGate;
  SpeechInputStatusCallback? _statusCallback;
  SpeechInputErrorCallback? _errorCallback;
  SpeechInputResultCallback? _resultCallback;
  int initializeCount = 0;
  int startCount = 0;
  int cancelCount = 0;

  @override
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    initializeCount++;
    _statusCallback = onStatus;
    _errorCallback = onError;
    return initializeGate ?? availability;
  }

  @override
  Future<bool> start({
    required SpeechInputResultCallback onResult,
    String preferredLanguageCode = 'zh',
  }) async {
    startCount++;
    _resultCallback = onResult;
    _statusCallback?.call(SpeechInputStatus.listening);
    return true;
  }

  void emit(String text, {bool isFinal = false}) {
    _resultCallback?.call(SpeechInputResult(text: text, isFinal: isFinal));
  }

  void fail(String code) {
    _errorCallback?.call(SpeechInputFailure(code: code, permanent: false));
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  void detach() {
    _statusCallback = null;
    _errorCallback = null;
    _resultCallback = null;
  }
}

/// In-memory MiMo ASR service: the upload is gated by [finishGate] so tests
/// can type into the composer while recognition is in flight.
class FakeMimoSpeechInputService implements MimoSpeechInputService {
  final Completer<void> finishGate = Completer<void>();
  SpeechInputResultCallback? _resultCallback;
  SpeechInputStatusCallback? _statusCallback;
  var initializeCount = 0;
  var startCount = 0;
  var cancelCount = 0;

  @override
  OpenAiCompatibleMediaProvider get mediaProvider =>
      OpenAiCompatibleMediaProvider();

  @override
  bool get isActive => false;

  @override
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    initializeCount++;
    _statusCallback = onStatus;
    return SpeechInputAvailability.ready;
  }

  @override
  Future<bool> start({
    required MediaApiConfig config,
    required String apiKey,
    required SpeechInputResultCallback onResult,
  }) async {
    startCount++;
    _resultCallback = onResult;
    _statusCallback?.call(SpeechInputStatus.listening);
    return true;
  }

  @override
  Future<void> finish({
    required MediaApiConfig config,
    required String apiKey,
    String language = 'auto',
  }) async {
    await finishGate.future;
    _resultCallback?.call(const SpeechInputResult(text: '识别结果', isFinal: true));
    _statusCallback?.call(SpeechInputStatus.stopped);
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  void detach() {}

  @override
  Future<void> dispose() async {}
}

class FakeTextToSpeechService implements TextToSpeechService {
  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );
  final List<TextToSpeechRequest> requests = [];
  var stopCount = 0;
  var _requestId = 0;

  @override
  ValueListenable<TextToSpeechPlayback> get playback => _playback;

  @override
  Future<void> speak(TextToSpeechRequest request) async {
    requests.add(request);
    _playback.value = TextToSpeechPlayback(
      phase: TextToSpeechPhase.speaking,
      messageId: request.messageId,
      requestId: ++_requestId,
    );
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _playback.value = TextToSpeechPlayback(requestId: ++_requestId);
  }

  @override
  Future<void> dispose() async {
    _playback.dispose();
  }
}

/// In-memory Drift DB for story repos in unit tests (no path_provider).
ProviderContainer _container(
  LlmProvider llm,
  InMemoryRepo repo, {
  ToolEngineFactory? toolEngineFactory,
  SettingsController Function() settingsBuilder = FakeSettings.new,
  OpenAiCompatibleMediaProvider? mediaProvider,
  SpeechInputService? speechInputService,
  MimoSpeechInputService? mimoSpeechInputService,
  TextToSpeechService? textToSpeechService,
  LongTaskGatewayClient? longTaskGatewayClient,
}) {
  final db = AppDatabase(NativeDatabase.memory());
  final characters = CharacterRepository(db);
  final worldInfo = WorldInfoRepository(db);
  final container = ProviderContainer(
    overrides: [
      llmProvider.overrideWithValue(llm),
      conversationRepositoryProvider.overrideWithValue(repo),
      settingsControllerProvider.overrideWith(settingsBuilder),
      appDatabaseProvider.overrideWithValue(db),
      characterRepositoryProvider.overrideWithValue(characters),
      worldInfoRepositoryProvider.overrideWithValue(worldInfo),
      if (toolEngineFactory != null)
        toolEngineFactoryProvider.overrideWithValue(toolEngineFactory),
      if (mediaProvider != null)
        mediaApiProvider.overrideWithValue(mediaProvider),
      if (speechInputService != null)
        speechInputServiceProvider.overrideWithValue(speechInputService),
      if (mimoSpeechInputService != null)
        mimoSpeechInputServiceProvider.overrideWithValue(
          mimoSpeechInputService,
        ),
      if (textToSpeechService != null)
        textToSpeechServiceProvider.overrideWithValue(textToSpeechService),
      if (longTaskGatewayClient != null)
        longTaskGatewayClientProvider.overrideWithValue(longTaskGatewayClient),
    ],
  );
  // Memory DB is not opened via path_provider; close it when the test ends.
  // Callers still dispose the container (which does not own this override's DB).
  addTearDown(db.close);
  return container;
}

void main() {
  test('ChatMessage round-trips through JSON with new fields', () {
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: 'hello',
      reasoning: 'thinking',
      model: 'deepseek-reasoner',
      thinkingMillis: 4200,
      kind: MessageKind.generatedImage,
      attachments: [
        Attachment(
          name: 'generated.png',
          mimeType: 'image/png',
          remoteUrl: 'https://cdn.example.com/generated.png',
        ),
      ],
      citations: const [Citation(index: 1, title: 'T', url: 'https://x')],
    );
    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.content, 'hello');
    expect(restored.reasoning, 'thinking');
    expect(restored.model, 'deepseek-reasoner');
    expect(restored.thinkingMillis, 4200);
    expect(restored.kind, MessageKind.generatedImage);
    expect(
      restored.attachments.single.remoteUrl,
      'https://cdn.example.com/generated.png',
    );
    expect(restored.citations.single.url, 'https://x');
  });

  test('deepThink toggle routes the request to the reasoner model', () async {
    final llm = FakeLlmProvider([
      const ChatChunk(reasoningDelta: 'pondering'),
      const ChatChunk(contentDelta: 'answer'),
    ]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    ctrl.toggleDeepThink();
    await ctrl.sendMessage('hi');

    expect(llm.lastConfig?.model, KnownModels.reasoner);
    expect(llm.lastThinking, isTrue); // thinking mode enabled for deep-think
    final convo = c.read(chatControllerProvider).value!.current!;
    final assistant = convo.activePath.last;
    expect(assistant.model, KnownModels.reasoner);
    expect(assistant.content, 'answer');
    expect(assistant.reasoning, 'pondering');
  });

  test('reasoning-only completion is promoted to the visible answer', () async {
    final llm = FakeLlmProvider([
      const ChatChunk(reasoningDelta: '这是被服务商放错字段的完整答复', finishReason: 'stop'),
    ]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('请回答');

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.content, '这是被服务商放错字段的完整答复');
    expect(assistant.reasoning, isEmpty);
  });

  test('reasoning-only completion keeps thought before final marker', () async {
    final llm = FakeLlmProvider([
      const ChatChunk(
        reasoningDelta: '先分析一下。\n\n最终答案：这是可见正文。',
        finishReason: 'stop',
      ),
    ]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('请回答');

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.content, '这是可见正文。');
    expect(assistant.reasoning, '先分析一下。');
  });

  test('output-limit reasoning is not promoted as a final answer', () async {
    final llm = FakeLlmProvider([
      const ChatChunk(reasoningDelta: '还在分析中……', finishReason: 'length'),
    ]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('请回答');

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.content, contains('输出额度'));
    expect(assistant.reasoning, '还在分析中……');
  });

  test(
    'deleting a conversation during send preflight does not resurrect it',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'answer')]);
      final repo = InMemoryRepo();
      final gate = Completer<void>();
      final c = _container(
        llm,
        repo,
        settingsBuilder: () => GatedSettings(gate),
      );
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      final id = c.read(chatControllerProvider).value!.current!.id;

      // Enter the _starting preflight window: sendMessage has been accepted
      // but is still awaiting settings, so streamingConvoId is not set yet.
      final sending = ctrl.sendMessage('hi');
      await Future<void>.delayed(Duration.zero);

      await ctrl.deleteConversation(id);

      gate.complete();
      await sending;

      final state = c.read(chatControllerProvider).value!;
      expect(state.conversations.any((convo) => convo.id == id), isFalse);
      expect(state.streamingConvoId, isNull);
      // The abandoned turn never reached the LLM and never wrote the deleted
      // row back: before the tombstone, _generate re-inserted its stale
      // snapshot and _persistById resurrected the conversation.
      expect(llm.callCount, 0);
      expect(repo.store.any((convo) => convo.id == id), isFalse);
    },
  );

  test(
    'without deepThink the chat model is used with thinking disabled',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'hello')]);
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage('hi');
      expect(llm.lastConfig?.model, KnownModels.chat);
      expect(llm.lastThinking, isFalse); // normal mode disables thinking
    },
  );

  test(
    'chat send routes via the classifier and marks the assistant skill',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [ChatChunk(contentDelta: '{"skill":"writing","confidence":0.9}')],
          [ChatChunk(contentDelta: '改好了')],
        ],
      );
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeChatSkillSettings.new,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage('把这段改得更顺');

      expect(llm.callCount, 2);
      expect(llm.calls.first.first.content, contains('你是任务分类器'));
      expect(llm.calls.first.last.content, contains('把这段改得更顺'));
      expect(
        llm.calls.last.any(
          (m) =>
              m.role == MessageRole.system && m.content.contains('严格按用户指定的文体'),
        ),
        isTrue,
      );
      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(assistant.content, '改好了');
      expect(assistant.turnSkill?.id, 'writing');
      expect(assistant.turnSkill?.name, '写作');
      expect(assistant.turnSkill?.source, ChatSkillSource.model);
    },
  );

  test(
    'classifier uses the profile chat model, not selectedModel or reasoner',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [ChatChunk(contentDelta: '{"skill":"writing","confidence":0.9}')],
          [ChatChunk(contentDelta: '改好了')],
        ],
      );
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeChatSkillSelectedModelSettings.new,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      ctrl.toggleDeepThink();

      await ctrl.sendMessage('把这段改得更顺');

      expect(llm.configs, hasLength(2));
      expect(llm.configs.first.model, KnownModels.chat);
      expect(llm.lastConfig?.model, KnownModels.reasoner);
    },
  );

  test(
    'long document task bypasses ordinary streaming and fills its card',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '不应调用')]);
      final gateway = FakeLongTaskGatewayClient();
      final repo = InMemoryRepo();
      final c = _container(
        llm,
        repo,
        settingsBuilder: FakeSettings.new,
        longTaskGatewayClient: gateway,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      final raw = utf8.encode('完整文件内容');
      final attachment = Attachment(
        name: 'report.txt',
        mimeType: 'text/plain',
        sizeBytes: raw.length,
        text: '完整文件内容',
        imageBase64: base64Encode(raw),
      );

      final accepted = await ctrl.sendLongDocumentTask(
        '深入分析这份报告',
        attachments: [attachment],
      );
      expect(accepted, isTrue);
      for (var i = 0; i < 20; i++) {
        final task = c
            .read(chatControllerProvider)
            .value
            ?.current
            ?.activePath
            .last
            .longTask;
        if (task?.status == LongTaskStatus.completed) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(llm.callCount, 0);
      expect(gateway.uploadedNames, ['report.txt']);
      expect(gateway.uploadBaseUrls, ['https://upload.example.com']);
      expect(gateway.createCount, 1);
      expect(assistant.longTask?.status, LongTaskStatus.completed);
      expect(assistant.content, '长任务最终结果');
      expect(repo.store.single.messages.last.longTask?.taskId, 'task_test');
      expect(
        repo.store.single.messages.last.longTask?.uploadBaseUrl,
        'https://upload.example.com',
      );
    },
  );

  test('context management compacts only the transient request', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
    final repo = InMemoryRepo();
    final c = _container(
      llm,
      repo,
      settingsBuilder: FakeSmallContextSettings.new,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    for (var i = 0; i < 10; i++) {
      await ctrl.sendMessage('turn-$i ${'x' * 600}');
    }

    final state = c.read(chatControllerProvider).value!;
    final report = state.contextReports[state.current!.id]!;
    expect(report.managed, isTrue);
    expect(report.sentTokens, lessThanOrEqualTo(report.inputBudgetTokens));
    expect(llm.calls.last.last.content, contains('turn-9'));
    // The database still has every original user/assistant node.
    expect(repo.store.single.messages, hasLength(20));
  });

  test('web_search tool runs only when the model requests it', () async {
    final llm = FakeLlmProvider(
      const [],
      scriptedChunks: const [
        [
          ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'call_1',
                name: 'web_search',
                argumentsJson: '{"query":"dart',
              ),
            ],
          ),
          ChatChunk(
            toolCalls: [ToolCall(index: 0, argumentsJson: ' flutter"}')],
            finishReason: 'tool_calls',
          ),
        ],
        [ChatChunk(contentDelta: 'Use Flutter with Dart [1].')],
      ],
    );
    final search = _CountingSearch(const [
      SearchResult(
        title: 'Flutter',
        url: 'https://flutter.dev',
        snippet:
            'Flutter is a cross-platform UI toolkit powered by the Dart '
            'programming language.',
      ),
    ]);
    final c = _container(
      llm,
      InMemoryRepo(),
      toolEngineFactory: ({required backend, required apiKey}) =>
          ToolEngine(search),
    );
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    ctrl.toggleSearch();
    await ctrl.sendMessage('What should I use?');

    expect(search.calls, 1);
    expect(search.lastQuery, 'dart flutter');
    expect(llm.callCount, 2);
    expect(llm.toolCalls.first?.single.name, 'web_search');
    expect(
      llm.calls[1].any(
        (m) =>
            m.role == MessageRole.tool &&
            m.toolCallId == 'call_1' &&
            m.content.contains('https://flutter.dev'),
      ),
      isTrue,
    );

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.content, 'Use Flutter with Dart [1].');
    expect(assistant.citations.single.url, 'https://flutter.dev');
  });

  test('fetch_url is not exposed without a URL in the current turn', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'hello')]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);
    await ctrl.sendMessage('普通离线问题');

    expect(llm.callCount, 1);
    expect(llm.toolCalls.single, isNull);
  });

  test(
    'fetch_url rejects model-invented URLs outside the turn allow-list',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [
            ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'fetch_1',
                  name: 'fetch_url',
                  argumentsJson: '{"url":"https://other.example/private"}',
                ),
              ],
              finishReason: 'tool_calls',
            ),
          ],
          [ChatChunk(contentDelta: '无法读取未授权网址。')],
        ],
      );
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      await ctrl.sendMessage('请读取 https://allowed.example/page');

      expect(llm.toolCalls.first?.single.name, 'fetch_url');
      expect(
        llm.calls[1].any(
          (m) =>
              m.role == MessageRole.tool &&
              m.toolCallId == 'fetch_1' &&
              m.content.contains('只能访问用户在本轮消息中明确提供的网址'),
        ),
        isTrue,
      );
    },
  );

  test(
    'fetch_url reads an allowed pasted URL and preserves its citation',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [
            ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'fetch_2',
                  name: 'fetch_url',
                  argumentsJson: '{"url":"https://allowed.example/page"}',
                ),
              ],
              finishReason: 'tool_calls',
            ),
          ],
          [ChatChunk(contentDelta: '页面内容见 [1]。')],
        ],
      );
      final pages = _StubPageSearch();
      final c = _container(
        llm,
        InMemoryRepo(),
        toolEngineFactory: ({required backend, required apiKey}) =>
            ToolEngine(pages),
      );
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      await ctrl.sendMessage('请读取 https://allowed.example/page');

      expect(pages.fetchCalls, 1);
      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(assistant.content, '页面内容见 [1]。');
      expect(assistant.citations.single.index, 1);
      expect(assistant.citations.single.url, 'https://allowed.example/page');
    },
  );

  test(
    'unknown models pre-fetch pasted URLs without receiving tool definitions',
    () async {
      final llm = FakeLlmProvider([
        const ChatChunk(contentDelta: '页面摘要见 [1]。'),
      ]);
      final pages = _StubPageSearch();
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeUnknownModelSettings.new,
        toolEngineFactory: ({required backend, required apiKey}) =>
            ToolEngine(pages),
      );
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      await ctrl.sendMessage('请读取 https://allowed.example/page');

      expect(pages.fetchCalls, 1);
      expect(llm.toolCalls.single, isNull);
      expect(
        llm.calls.single.any(
          (m) =>
              m.role == MessageRole.system &&
              m.content.contains('This is readable page content'),
        ),
        isTrue,
      );
    },
  );

  test('caps network work while replying to every model tool call', () async {
    final llm = FakeLlmProvider(
      const [],
      scriptedChunks: const [
        [
          ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'call_0',
                name: 'web_search',
                argumentsJson: '{"query":"q0"}',
              ),
              ToolCall(
                index: 1,
                id: 'call_1',
                name: 'web_search',
                argumentsJson: '{"query":"q1"}',
              ),
              ToolCall(
                index: 2,
                id: 'call_2',
                name: 'web_search',
                argumentsJson: '{"query":"q2"}',
              ),
              ToolCall(
                index: 3,
                id: 'call_3',
                name: 'web_search',
                argumentsJson: '{"query":"q3"}',
              ),
            ],
            finishReason: 'tool_calls',
          ),
        ],
        [ChatChunk(contentDelta: 'bounded answer')],
      ],
    );
    final search = _CountingSearch(const [
      SearchResult(title: 'Result', url: 'https://example.com'),
    ]);
    final c = _container(
      llm,
      InMemoryRepo(),
      toolEngineFactory: ({required backend, required apiKey}) =>
          ToolEngine(search),
    );
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);
    ctrl.toggleSearch();
    await ctrl.sendMessage('search safely');

    expect(search.calls, 3);
    final toolMessages = llm.calls[1]
        .where((m) => m.role == MessageRole.tool)
        .toList();
    expect(toolMessages, hasLength(4));
    expect(toolMessages.last.content, contains('最多执行 3 次'));
  });

  test(
    'a stubborn final round emitting only tool calls gets a fallback reply',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [
            ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'call_1',
                  name: 'web_search',
                  argumentsJson: '{"query":"q1"}',
                ),
              ],
              finishReason: 'tool_calls',
            ),
          ],
          [
            ChatChunk(
              reasoningDelta: '我还想调用工具',
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'call_2',
                  name: 'web_search',
                  argumentsJson: '{"query":"q2"}',
                ),
              ],
              finishReason: 'tool_calls',
            ),
          ],
        ],
      );
      final search = _CountingSearch(const [
        SearchResult(title: 'Result', url: 'https://example.com'),
      ]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeOneSearchRoundSettings.new,
        toolEngineFactory: ({required backend, required apiKey}) =>
            ToolEngine(search),
      );
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      ctrl.toggleSearch();
      await ctrl.sendMessage('stubborn model');

      final state = c.read(chatControllerProvider).value!;
      expect(llm.callCount, 2);
      expect(state.error, isNull);
      final assistant = state.current!.activePath.last;
      expect(assistant.content, isNotEmpty);
      expect(assistant.content, '模型未能输出有效回复，请重试。');
    },
  );

  test('thinking time accumulates across multiple tool rounds', () async {
    final llm = _DelayedChunkProvider([
      const [
        ChatChunk(reasoningDelta: 'r1'),
        ChatChunk(
          contentDelta: 'need to search',
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'call_1',
              name: 'web_search',
              argumentsJson: '{"query":"q1"}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      ],
      const [
        ChatChunk(reasoningDelta: 'r2'),
        ChatChunk(contentDelta: 'final answer'),
      ],
    ]);
    final search = _CountingSearch(const [
      SearchResult(title: 'Result', url: 'https://example.com'),
    ]);
    final c = _container(
      llm,
      InMemoryRepo(),
      settingsBuilder: FakeOneSearchRoundSettings.new,
      toolEngineFactory: ({required backend, required apiKey}) =>
          ToolEngine(search),
    );
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);
    ctrl.toggleSearch();
    await ctrl.sendMessage('two rounds of thinking');

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.content, 'final answer');
    // Both rounds' reasoning spans (~120ms each) must be counted, not just
    // the first round's.
    expect(assistant.thinkingMillis, greaterThanOrEqualTo(200));
  });

  test('ProviderProfile round-trips through JSON', () {
    final p = ProviderProfile(
      name: 'Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      chatModel: 'moonshot-v1-8k',
      reasonerModel: 'kimi-thinking-preview',
      models: const ['moonshot-v1-8k', 'kimi-thinking-preview'],
    );
    final restored = ProviderProfile.fromJson(p.toJson());
    expect(restored.id, p.id);
    expect(restored.name, 'Kimi');
    expect(restored.reasonerModel, 'kimi-thinking-preview');
    expect(restored.models.length, 2);
  });

  test(
    'DriftConversationRepository persists, reloads, deletes and searches',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftConversationRepository(db);

      final convo = Conversation(
        title: 'Flutter help',
        messages: [
          ChatMessage(role: MessageRole.user, content: 'how do I use drift?'),
          ChatMessage(
            role: MessageRole.assistant,
            content: 'call build_runner',
            reasoning: 'think',
            model: 'deepseek-reasoner',
            thinkingMillis: 1500,
            citations: const [
              Citation(
                index: 1,
                title: 'drift docs',
                url: 'https://drift.simonbinder.eu',
              ),
            ],
          ),
        ],
      );
      await repo.saveAll([convo]);

      final loaded = await repo.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.messages, hasLength(2));
      final assistant = loaded.single.messages[1];
      expect(assistant.thinkingMillis, 1500);
      expect(assistant.model, 'deepseek-reasoner');
      expect(assistant.citations.single.url, 'https://drift.simonbinder.eu');

      // Search matches title and message content.
      expect(await repo.search('flutter'), hasLength(1));
      expect(await repo.search('drift'), hasLength(1));
      expect(await repo.search('nonexistent'), isEmpty);

      // Removing from the saved set deletes (cascade) on next save.
      await repo.saveAll(const []);
      expect(await repo.loadAll(), isEmpty);
    },
  );

  group('FileParser', () {
    final parser = FileParser();

    test('parses plain text', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final a = parser.parse(
        name: 'note.txt',
        mimeType: 'text/plain',
        sizeBytes: 11,
        bytes: bytes,
      );
      expect(a.parseError, isNull);
      expect(a.text, 'hello world');
      expect(a.truncated, isFalse);
      expect(a.hasDownloadableBytes, isTrue);
    });

    test('truncates text past maxChars', () {
      final big = 'a' * (FileParser.maxChars + 100);
      final bytes = Uint8List.fromList(utf8.encode(big));
      final a = parser.parse(
        name: 'big.md',
        mimeType: 'text/markdown',
        sizeBytes: bytes.length,
        bytes: bytes,
      );
      expect(a.truncated, isTrue);
      expect(a.text.length, FileParser.maxChars);
      // Long-task upload uses the original bytes, not the truncated prefix.
      expect(a.hasDownloadableBytes, isTrue);
    });

    test('retains small images as base64 for vision models', () {
      final a = parser.parse(
        name: 'pic.png',
        mimeType: 'image/png',
        sizeBytes: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(a.isImage, isTrue);
      expect(a.parseError, isNull);
      expect(a.hasImageData, isTrue);
      expect(a.imageDataUrl, startsWith('data:image/png;base64,'));
    });

    test('rejects oversized images with a note', () {
      final big = Uint8List(FileParser.maxImageBytes + 1);
      final a = parser.parse(
        name: 'big.png',
        mimeType: 'image/png',
        sizeBytes: big.length,
        bytes: big,
      );
      expect(a.hasImageData, isFalse);
      expect(a.parseError, contains('过大'));
    });

    test('rejects an oversized document before attempting extraction', () {
      final a = parser.parse(
        name: 'large.txt',
        mimeType: 'text/plain',
        // Keeping bytes tiny proves the pre-flight metadata guard runs before
        // a potentially expensive parser is selected.
        sizeBytes: FileParser.maxFileBytes + 1,
        bytes: Uint8List.fromList([0x61]),
      );
      expect(a.parseError, contains('文件过大'));
    });

    test('rejects an OOXML archive with an abnormal compression ratio', () {
      // Keep the expanded part below the absolute 20 MiB entry cap so this
      // specifically exercises the independent compression-ratio guard.
      final payload = Uint8List.fromList(utf8.encode('a' * (4 * 1024 * 1024)));
      final archive = Archive()
        ..addFile(
          ArchiveFile('word/document.xml', payload.lengthInBytes, payload),
        );
      final compressed = Uint8List.fromList(
        ZipEncoder().encode(archive, level: 9)!,
      );

      final a = parser.parse(
        name: 'suspicious.docx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        sizeBytes: compressed.lengthInBytes,
        bytes: compressed,
      );
      expect(a.parseError, contains('压缩比异常'));
    });

    test('reports a clear error for unsupported types', () {
      final a = parser.parse(
        name: 'app.exe',
        mimeType: 'application/octet-stream',
        sizeBytes: 2,
        bytes: Uint8List(2),
      );
      expect(a.parseError, contains('不支持'));
    });
  });

  group('ToolEngine', () {
    // Bodies must clear ToolEngine.minSourceChars so thin-result filtering
    // does not drop fixtures that are only testing URL / citation wiring.
    const richDart =
        'Dart is a client-optimized language for fast apps on any platform. '
        'It powers Flutter and ships with a strong type system.';
    const richFlutter =
        'Flutter is Google UI toolkit for building natively compiled '
        'applications for mobile, web, and desktop from a single codebase.';
    const richExample =
        'Example Domain is commonly used in documentation and test fixtures '
        'as a reserved public hostname with a stable landing page.';

    test('builds context + numbered citations from results', () async {
      final engine = ToolEngine(
        _FakeSearch([
          const SearchResult(
            title: 'Dart',
            url: 'https://dart.dev',
            content: richDart,
          ),
          const SearchResult(
            title: 'Flutter',
            url: 'https://flutter.dev',
            snippet: richFlutter,
          ),
        ]),
      );
      final ctx = await engine.runSearch('dart flutter');
      expect(ctx.citations, hasLength(2));
      expect(ctx.citations.first.index, 1);
      expect(ctx.citations[1].url, 'https://flutter.dev');
      expect(ctx.contextText, contains('[1]'));
      expect(ctx.contextText, contains('https://dart.dev'));
      expect(ctx.contextText, contains('查询：dart flutter'));
    });

    test('returns empty context when there are no results', () async {
      final engine = ToolEngine(_FakeSearch([]));
      final ctx = await engine.runSearch('nothing');
      expect(ctx.isEmpty, isTrue);
    });

    test('propagates SearchUnavailableException so the UI can surface it', () {
      final engine = ToolEngine(_ThrowingSearch());
      expect(
        () => engine.runSearch('q'),
        throwsA(isA<SearchUnavailableException>()),
      );
    });

    test('skips results without a URL', () async {
      final engine = ToolEngine(
        _FakeSearch([
          const SearchResult(title: 'No url', url: '', content: richDart),
          const SearchResult(
            title: 'Has url',
            url: 'https://a.com',
            content: richExample,
          ),
        ]),
      );
      final ctx = await engine.runSearch('q');
      expect(ctx.citations, hasLength(1));
      expect(ctx.citations.single.url, 'https://a.com');
    });

    test('skips thin bodies and private URLs', () async {
      final engine = ToolEngine(
        _FakeSearch([
          const SearchResult(title: 'Loopback', url: 'http://127.0.0.1/x'),
          const SearchResult(title: 'Router', url: 'http://192.168.1.1/'),
          const SearchResult(title: 'Local name', url: 'http://host.local/'),
          const SearchResult(title: 'IPv6 loopback', url: 'http://[::1]/'),
          const SearchResult(
            title: 'Empty body',
            url: 'https://thin.example/',
            content: 'ok',
          ),
          const SearchResult(
            title: 'Public',
            url: 'https://example.com/',
            content: richExample,
          ),
        ]),
      );

      final ctx = await engine.runSearch('q');
      expect(ctx.citations, hasLength(1));
      expect(ctx.citations.single.url, 'https://example.com/');
      expect(HttpSearchProvider.isSafeHttpUrl('https://dart.dev'), isTrue);
      expect(HttpSearchProvider.isSafeHttpUrl('file:///tmp/x'), isFalse);
    });

    test(
      'normalizes chatty pre-search queries before calling the provider',
      () async {
        final search = _CountingSearch([
          const SearchResult(
            title: 'Public',
            url: 'https://example.com/',
            content: richExample,
          ),
        ]);
        final engine = ToolEngine(search);
        await engine.runSearch('请问  DeepSeek V3 定价是多少？   ');
        expect(search.lastQuery, 'DeepSeek V3 定价是多少？');
      },
    );
  });

  test('failed async delete restores only the deleted conversation', () async {
    final original = Conversation(title: 'Original');
    final repo = DelayedFailDeleteRepo()..store = [original];
    final container = _container(FakeLlmProvider(const []), repo);
    addTearDown(container.dispose);
    await container.read(chatControllerProvider.future);
    final controller = container.read(chatControllerProvider.notifier);

    final deletion = controller.deleteConversation(original.id);
    await repo.deleteStarted.future;
    controller.newConversation();
    final newId = container.read(chatControllerProvider).value!.currentId;
    repo.failDelete.complete();
    await deletion;

    final state = container.read(chatControllerProvider).value!;
    expect(state.conversations.map((c) => c.id), contains(original.id));
    expect(state.conversations.map((c) => c.id), contains(newId));
    expect(state.currentId, newId);
    expect(state.error, contains('本地删除失败'));
  });

  test('newStoryConversation inserts firstMes and story metadata', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final card = CharacterCard(
      name: '阿宁',
      firstMes: '你好，旅人。',
      personality: '温柔',
    );
    // Without a real world-info repo override, default ids come from DB —
    // ProviderContainer uses real appDatabase only if not overridden.
    // ChatController loads WI via worldInfoRepositoryProvider; for this test
    // we only assert card binding + firstMes, so override repos to empty.
    await ctrl.newStoryConversation(card, worldInfoIds: const []);

    final convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.isStory, isTrue);
    expect(convo.characterId, card.id);
    expect(convo.title, '阿宁');
    expect(convo.activePath, hasLength(1));
    expect(convo.activePath.first.role, MessageRole.assistant);
    expect(convo.activePath.first.content, '你好，旅人。');
    expect(convo.worldInfoIds, isEmpty);
  });

  test(
    'director story keeps a local cast and AI performs every role',
    () async {
      final llm = FakeLlmProvider([
        const ChatChunk(contentDelta: '沈砚推开休眠舱，零号正在舷窗前等他。'),
      ]);
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      final cast = [
        CharacterCard(name: '沈砚', description: '失忆的调查记者', personality: '谨慎而执着'),
        CharacterCard(name: '零号', description: '掌握真相的克隆人', personality: '冷静克制'),
      ];
      await ctrl.newDirectorStoryConversation(
        title: '失控航线',
        premise: '记者从陌生飞船醒来，发现其他乘员都是自己的克隆体。',
        cast: cast,
        outline: '- 从休眠舱醒来\n- 与零号第一次对峙',
        authorNote: '使用第三人称有限视角。',
        worldInfoIds: const [],
      );

      var convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.isStory, isTrue);
      expect(convo.characterId, isNull);
      expect(convo.localCast.map((card) => card.name), ['沈砚', '零号']);
      expect(convo.authorNote, contains('故事基准'));
      expect(convo.authorNote, contains('第三人称有限视角'));

      await ctrl.advancePlot();

      convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.plotCursor, 1);
      expect(convo.activePath.first.content, startsWith('（导演：开始第一场）'));
      expect(convo.activePath.last.content, contains('零号'));
      final request = llm.calls.single
          .map((message) => message.content)
          .join('\n');
      expect(request, contains('用户是导演'));
      expect(request, contains('冲突优先级'));
      expect(request, contains('仅本轮：写下一场'));
      expect(request, contains('沈砚'));
      expect(request, contains('零号'));
      expect(request, contains('第三人称有限视角'));
    },
  );

  test(
    'reusing unused director session applies the new plan instead of keeping stale cast',
    () async {
      final c = _container(FakeLlmProvider(const []), InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.newDirectorStoryConversation(
        title: '旧故事',
        premise: '旧前提',
        cast: [CharacterCard(name: '旧角色')],
        outline: '- 旧节拍',
        worldInfoIds: const [],
      );
      final firstId = c.read(chatControllerProvider).value!.current!.id;

      // Still unused (no user turns). Starting another plan must overwrite.
      await ctrl.newDirectorStoryConversation(
        title: '新故事',
        premise: '新前提必须保留',
        cast: [
          CharacterCard(name: '新角色甲'),
          CharacterCard(name: '新角色乙'),
        ],
        outline: '- 新开场\n- 新高潮',
        authorNote: '服从导演',
        requirements: '禁止穿越',
        worldInfoIds: const [],
      );

      final convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.id, firstId, reason: '应复用当前空导演会话壳');
      expect(convo.title, '新故事');
      expect(convo.localCast.map((e) => e.name), ['新角色甲', '新角色乙']);
      expect(convo.outline, contains('新开场'));
      expect(convo.authorNote, contains('新前提必须保留'));
      expect(convo.authorNote, contains('禁止穿越'));
      expect(convo.authorNote, isNot(contains('旧前提')));
    },
  );

  test(
    'director story is not published before its first save succeeds',
    () async {
      final repo = FailingSaveRepo()..failNextSave = true;
      final c = _container(FakeLlmProvider(const []), repo);
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      final originalId = c.read(chatControllerProvider).value!.currentId;

      await expectLater(
        ctrl.newDirectorStoryConversation(
          title: '不能丢的故事',
          premise: '测试持久化失败。',
          cast: [CharacterCard(name: '角色甲')],
          outline: '- 第一节',
          worldInfoIds: const [],
        ),
        throwsA(isA<Exception>()),
      );

      final state = c.read(chatControllerProvider).value!;
      expect(state.currentId, originalId);
      expect(state.current?.isStory, isFalse);
      expect(repo.store, isEmpty);
    },
  );

  test('advancePlot increments plotCursor after a successful reply', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: '第二节正文')]);
    final card = CharacterCard(name: '作者', firstMes: '开场');
    final c = _container(llm, InMemoryRepo());
    await c.read(characterRepositoryProvider).save(card);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.newStoryConversation(card, worldInfoIds: const []);
    ctrl.updateStoryMeta(outline: '- 相遇\n- 冲突\n- 和解', plotCursor: 0);
    expect(c.read(chatControllerProvider).value!.current!.plotCursor, 0);

    await ctrl.advancePlot();

    final convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.plotCursor, 1);
    expect(convo.activePath.last.content, '第二节正文');
    expect(convo.activePath.any((m) => m.content.startsWith('（推进情节）')), isTrue);
  });

  test(
    'a failed first director scene still cues 开始第一场 on the next advance',
    () async {
      final llm = _FailOnceLlm();
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.newDirectorStoryConversation(
        title: '开场',
        premise: '测试前提。',
        cast: [CharacterCard(name: '角色甲')],
        outline: '- 第一节',
        worldInfoIds: const [],
      );

      // First attempt fails mid-stream, leaving an empty assistant reply.
      await ctrl.advancePlot();
      var convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.plotCursor, 0);
      expect(convo.activePath.last.content, isEmpty);
      expect(
        c.read(chatControllerProvider).value!.error,
        contains('simulated failure'),
      );

      // Retrying the same first scene must not turn the cue into 写下一场.
      await ctrl.advancePlot();
      convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.activePath[2].content, startsWith('（导演：开始第一场）'));
      expect(convo.activePath.last.content, '第一节正文');
      expect(convo.plotCursor, 1);
    },
  );

  test(
    'length target does not keep a completed scene on the same beat',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: [
          [ChatChunk(contentDelta: '甲' * 20)],
          [ChatChunk(contentDelta: '乙' * 30)],
        ],
      );
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.newStoryConversation(
        CharacterCard(name: '作者'),
        worldInfoIds: const [],
      );
      ctrl.updateStoryMeta(
        outline: '- 第一拍\n- 第二拍',
        plotCursor: 0,
        targetTotalChars: 100,
      );

      await ctrl.advancePlot();
      expect(c.read(chatControllerProvider).value!.current!.plotCursor, 1);

      await ctrl.advancePlot();
      final convo = c.read(chatControllerProvider).value!.current!;
      expect(StoryLengthBudget.countWrittenChars(convo), 50);
      expect(convo.plotCursor, 2);
    },
  );

  test(
    'continueCurrentScene keeps the cursor and previous scene objective',
    () async {
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [ChatChunk(contentDelta: '第一场正文。')],
          [ChatChunk(contentDelta: '第一场续写。')],
        ],
      );
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      await ctrl.newDirectorStoryConversation(
        title: '场景测试',
        premise: '两人在雨夜重逢。',
        cast: [CharacterCard(name: '甲')],
        outline: '- 第一场：雨夜重逢\n- 第二场：共同追查',
        worldInfoIds: const [],
      );

      await ctrl.advancePlot();
      expect(c.read(chatControllerProvider).value!.current!.plotCursor, 1);

      await ctrl.continueCurrentScene();
      final convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.plotCursor, 1);
      expect(convo.activePath.last.content, '第一场续写。');
      expect(
        convo.activePath[convo.activePath.length - 2].content,
        startsWith('（导演：续写当前场）'),
      );
      final secondRequest = llm.calls.last
          .map((message) => message.content)
          .join('\n');
      expect(secondRequest, contains('第一场：雨夜重逢'));
      expect(secondRequest, isNot(contains('第二场：共同追查')));
    },
  );

  test('regenerating an advanced beat keeps committed plot progress', () async {
    final llm = FakeLlmProvider(
      const [],
      scriptedChunks: const [
        [ChatChunk(contentDelta: '第一拍正文')],
        [ChatChunk(contentDelta: '第一拍改写')],
        [ChatChunk(contentDelta: '第二拍正文')],
      ],
    );
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);
    await ctrl.newStoryConversation(
      CharacterCard(name: '作者'),
      worldInfoIds: const [],
    );
    ctrl.updateStoryMeta(outline: '- 相遇\n- 冲突\n- 和解', plotCursor: 0);

    await ctrl.advancePlot();
    expect(c.read(chatControllerProvider).value!.current!.plotCursor, 1);

    await ctrl.regenerate();
    var convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.plotCursor, 1);
    expect(convo.activePath.last.content, '第一拍改写');

    await ctrl.advancePlot();
    convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.plotCursor, 2);
    expect(convo.activePath.last.content, '第二拍正文');
  });

  test(
    'newEnsembleConversation requires two characters and sets cast',
    () async {
      final c = _container(FakeLlmProvider(const []), InMemoryRepo());
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      final a = CharacterCard(name: '甲', firstMes: '甲到场');
      final b = CharacterCard(name: '乙', firstMes: '乙到场');
      await ctrl.newEnsembleConversation(
        cast: [a, b],
        venue: '擂台中央',
        authorNote: '火药味',
        worldInfoIds: const [],
      );

      final convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.isEnsemble, isTrue);
      expect(convo.castIds, [a.id, b.id]);
      expect(convo.venue, '擂台中央');
      expect(convo.authorNote, '火药味');
      expect(convo.activePath.first.content, contains('擂台中央'));
    },
  );

  test('ensembleNextTurn labels speaker and advances index', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: '看招！')]);
    final a = CharacterCard(name: '甲');
    final b = CharacterCard(name: '乙');
    final c = _container(llm, InMemoryRepo());
    await c.read(characterRepositoryProvider).save(a);
    await c.read(characterRepositoryProvider).save(b);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.newEnsembleConversation(
      cast: [a, b],
      venue: '巷口',
      worldInfoIds: const [],
    );
    expect(c.read(chatControllerProvider).value!.current!.nextSpeakerIndex, 0);

    await ctrl.ensembleNextTurn();

    final convo = c.read(chatControllerProvider).value!.current!;
    final last = convo.activePath.last;
    expect(last.role, MessageRole.assistant);
    expect(last.speakerId, a.id);
    expect(last.speakerName, '甲');
    expect(last.content, '看招！');
    expect(convo.nextSpeakerIndex, 1);
  });

  test('adjustPlotCursor can move progress without generating', () async {
    final c = _container(FakeLlmProvider(const []), InMemoryRepo());
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.newStoryConversation(
      CharacterCard(name: 'A', firstMes: 'hi'),
      worldInfoIds: const [],
    );
    ctrl.updateStoryMeta(outline: '- 一\n- 二\n- 三', plotCursor: 1);
    ctrl.adjustPlotCursor(-1);
    expect(c.read(chatControllerProvider).value!.current!.plotCursor, 0);
    ctrl.adjustPlotCursor(2);
    expect(c.read(chatControllerProvider).value!.current!.plotCursor, 2);
  });

  test('stop aborts a send that is still waiting for settings', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'late')]);
    final delayed = DelayedReadySettings();
    final c = _container(llm, InMemoryRepo(), settingsBuilder: () => delayed);
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final send = ctrl.sendMessage('should be cancelled');
    await delayed.entered.future;
    ctrl.stop();
    delayed.gate.complete();
    final accepted = await send;

    expect(accepted, isFalse);
    expect(llm.callCount, 0);
    expect(c.read(chatControllerProvider).value!.isStreaming, isFalse);
    expect(
      c.read(chatControllerProvider).value!.current?.messages ?? const [],
      isEmpty,
    );
  });

  test('stopAndWait releases preflight before accepting replacement', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'replacement')]);
    final delayed = DelayedReadySettings();
    final c = _container(llm, InMemoryRepo(), settingsBuilder: () => delayed);
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final firstSend = ctrl.sendMessage('should be cancelled');
    await delayed.entered.future;
    var stopped = false;
    final stopping = ctrl.stopAndWait().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse, reason: '等待中的设置预检尚未退出');

    delayed.gate.complete();
    await stopping;
    expect(await firstSend, isFalse);

    expect(await ctrl.sendMessage('replacement turn'), isTrue);
    expect(llm.callCount, 1);
    expect(
      c.read(chatControllerProvider).value!.current!.activePath.last.content,
      'replacement',
    );
  });

  test('a send preflighted on one conversation does not yank focus when the '
      'user switches during preflight', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'answer')]);
    final delayed = DelayedReadySettings();
    final c = _container(llm, InMemoryRepo(), settingsBuilder: () => delayed);
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final originId = c.read(chatControllerProvider).value!.currentId!;
    final send = ctrl.sendMessage('stream into the background');
    await delayed.entered.future;
    // The user switches away while the turn is still preflighting.
    ctrl.newConversation();
    final otherId = c.read(chatControllerProvider).value!.currentId!;
    expect(otherId, isNot(originId));

    delayed.gate.complete();
    expect(await send, isTrue);

    final state = c.read(chatControllerProvider).value!;
    // Focus stays on the conversation the user chose...
    expect(state.currentId, otherId);
    expect(state.isStreaming, isFalse);
    // ...while the stream still wrote into the origin conversation.
    final origin = state.conversations.firstWhere((c) => c.id == originId);
    expect(origin.activePath.last.content, 'answer');
    expect(state.current!.messages, isEmpty);
    expect(state.error, isNull);
  });

  test('an image turn preflighted on one conversation does not yank focus when '
      'the user switches during preflight', () async {
    final delayed = DelayedImageSettings();
    final c = _container(
      FakeLlmProvider(const []),
      InMemoryRepo(),
      settingsBuilder: () => delayed,
      mediaProvider: FakeMediaProvider(),
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final originId = c.read(chatControllerProvider).value!.currentId!;
    final send = ctrl.generateImage('draw a cat');
    await delayed.entered.future;
    // The user switches away while the turn is still preflighting.
    ctrl.newConversation();
    final otherId = c.read(chatControllerProvider).value!.currentId!;
    expect(otherId, isNot(originId));

    delayed.gate.complete();
    expect(await send, isTrue);

    final state = c.read(chatControllerProvider).value!;
    // Focus stays on the conversation the user chose...
    expect(state.currentId, otherId);
    expect(state.isStreaming, isFalse);
    // ...while the image turn still wrote into the origin conversation.
    final origin = state.conversations.firstWhere((c) => c.id == originId);
    expect(
      origin.messages.where((m) => m.kind == MessageKind.generatedImage),
      isNotEmpty,
    );
    expect(
      state.current!.messages.where(
        (m) => m.kind == MessageKind.generatedImage,
      ),
      isEmpty,
    );
    expect(state.error, isNull);
  });

  test('disposing the container mid-stream completes teardown without a '
      'dispose-time state write', () async {
    final llm = _DisposeMidStreamLlm();
    final c = _container(llm, InMemoryRepo());
    // No addTearDown(c.dispose): dispose is exercised explicitly.
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    unawaited(ctrl.sendMessage('dispose me'));
    await llm.delivered.future; // chunk queued by the provider
    // Let the stream listener process the chunk (so a UI flush is pending),
    // but stay well inside the 50ms coalescing window.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    // Must not throw / report an uncaught state-write error on dispose.
    c.dispose();
    expect(llm.delivered.isCompleted, isTrue);
  });

  test(
    'a background conversation keeps its scoped error when revisited',
    () async {
      final llm = DelayedFailingLlmProvider();
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      final failedId = c.read(chatControllerProvider).value!.currentId!;

      final send = ctrl.sendMessage('this turn will fail');
      await llm.entered.future;
      ctrl.newConversation();
      final otherId = c.read(chatControllerProvider).value!.currentId!;
      expect(otherId, isNot(failedId));

      llm.gate.complete();
      await send;
      var state = c.read(chatControllerProvider).value!;
      expect(state.currentId, otherId);
      expect(state.errorConvoId, failedId);
      expect(state.errorVisibleFor(otherId), isFalse);

      ctrl.selectConversation(failedId);
      state = c.read(chatControllerProvider).value!;
      expect(state.currentId, failedId);
      expect(state.error, contains('simulated stream failure'));
      expect(state.errorVisibleFor(failedId), isTrue);
      expect(state.retryOperation?.conversationId, failedId);
    },
  );

  test(
    'deleting a conversation preserves another conversation scoped error',
    () async {
      final llm = DelayedFailingLlmProvider();
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);
      final failedId = c.read(chatControllerProvider).value!.currentId!;

      final send = ctrl.sendMessage('will fail');
      await llm.entered.future;
      ctrl.newConversation();
      final otherId = c.read(chatControllerProvider).value!.currentId!;
      expect(otherId, isNot(failedId));
      llm.gate.complete();
      await send;

      var state = c.read(chatControllerProvider).value!;
      expect(state.errorConvoId, failedId);
      expect(state.errorVisibleFor(otherId), isFalse);

      // Deleting the OTHER conversation must not erase the parked banner.
      await ctrl.deleteConversation(otherId);
      state = c.read(chatControllerProvider).value!;
      expect(state.error, contains('simulated stream failure'));
      expect(state.errorConvoId, failedId);

      // Deleting the failed conversation itself still clears it.
      await ctrl.deleteConversation(failedId);
      state = c.read(chatControllerProvider).value!;
      expect(state.error, isNull);
      expect(state.errorConvoId, isNull);
    },
  );

  test(
    'a failed pre-search does not leave its error banner after the model answers',
    () async {
      final llm = FakeLlmProvider([
        const ChatChunk(contentDelta: 'still answers'),
      ]);
      final c = _container(
        llm,
        InMemoryRepo(),
        toolEngineFactory: ({required backend, required apiKey}) =>
            ToolEngine(_ThrowingSearch()),
      );
      addTearDown(c.dispose);

      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      ctrl.toggleSearch(); // auto
      ctrl.toggleSearch(); // always: forced pre-search runs before the answer
      await ctrl.sendMessage('what is the weather?');

      final state = c.read(chatControllerProvider).value!;
      expect(state.error, isNull);
      expect(state.retryOperation, isNull);
      expect(state.current!.activePath.last.content, 'still answers');
    },
  );

  test('a failed web_search tool call does not leave its error banner after '
      'the model answers', () async {
    final llm = FakeLlmProvider(
      const [],
      scriptedChunks: const [
        [
          ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'call_1',
                name: 'web_search',
                argumentsJson: '{"query":"weather"}',
              ),
            ],
            finishReason: 'tool_calls',
          ),
        ],
        [ChatChunk(contentDelta: 'final answer')],
      ],
    );
    final c = _container(
      llm,
      InMemoryRepo(),
      toolEngineFactory: ({required backend, required apiKey}) =>
          ToolEngine(_ThrowingSearch()),
    );
    addTearDown(c.dispose);

    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    ctrl.toggleSearch(); // auto: the model decides whether to search
    await ctrl.sendMessage('what is the weather?');

    final state = c.read(chatControllerProvider).value!;
    expect(state.error, isNull);
    expect(state.retryOperation, isNull);
    expect(state.current!.activePath.last.content, 'final answer');
  });

  test(
    'a failed final persist surfaces 本地保存失败 instead of escaping the stream',
    () async {
      final repo = FailingSaveEveryTimeRepo();
      final c = _container(
        FakeLlmProvider([const ChatChunk(contentDelta: 'done')]),
        repo,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage('save me');

      final state = c.read(chatControllerProvider).value!;
      expect(state.error, contains('本地保存失败'));
      expect(state.errorConvoId, state.currentId);
    },
  );

  test('context-budget overflow ends the turn without reaching the model and '
      'the next generation flows cleanly', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'never')]);
    final c = _container(
      llm,
      InMemoryRepo(),
      settingsBuilder: FakeSmallContextVisionSettings.new,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final accepted = await ctrl.sendMessage(
      '看图',
      attachments: [
        Attachment(name: 'pic.png', mimeType: 'image/png', imageBase64: 'AAAA'),
      ],
    );
    expect(accepted, isTrue);
    expect(llm.callCount, 0); // the model was never reached

    var state = c.read(chatControllerProvider).value!;
    expect(state.isStreaming, isFalse);
    expect(state.error, contains('上下文预算'));
    expect(state.retryOperation, isNotNull);

    // A later generation through the same pipeline works normally.
    llm.chunks
      ..clear()
      ..add(const ChatChunk(contentDelta: 'ok'));
    final userMsg = state.current!.activePath.first;
    await ctrl.editMessage(userMsg.id, '简短的问题', attachments: const []);
    state = c.read(chatControllerProvider).value!;
    expect(state.error, isNull);
    expect(state.isStreaming, isFalse);
    expect(state.current!.activePath.last.content, 'ok');
    expect(llm.callCount, 1);
  });

  test(
    'deleteProfile keeps search and system prompt when last profile is removed',
    () async {
      SharedPreferences.setMockInitialValues({});
      final secureData = <String, String>{};
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        secureData,
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);

      final settings = container.read(settingsControllerProvider.notifier);
      await container.read(settingsControllerProvider.future);

      await settings.setSearchBackend(SearchBackend.tavily);
      await settings.setSearchApiKey('search-secret');
      await settings.setSystemPrompt('你是专业助手');

      final onlyId = container
          .read(settingsControllerProvider)
          .value!
          .activeProfileId!;
      await settings.deleteProfile(onlyId);

      final next = container.read(settingsControllerProvider).value!;
      expect(next.profiles, hasLength(1));
      expect(next.profiles.single.id, isNot(onlyId));
      expect(next.searchBackend, SearchBackend.tavily);
      expect(next.searchApiKey, 'search-secret');
      expect(next.systemPrompt, '你是专业助手');
      expect(next.apiKey, isEmpty);
    },
  );

  group('ModelCapabilities.resolve', () {
    test('DeepSeek V4 flash: tools + thinking field, not reasoner', () {
      final c = ModelCapabilities.resolve('deepseek-v4-flash');
      expect(c.isReasoner, isFalse);
      expect(c.supportsTools, isTrue);
      expect(c.sendThinkingField, isTrue);
    });

    test('DeepSeek V4 pro: reasoner AND tool-capable (V4 hybrid)', () {
      final c = ModelCapabilities.resolve('deepseek-v4-pro');
      expect(c.isReasoner, isTrue);
      expect(c.supportsTools, isTrue);
      expect(c.sendThinkingField, isTrue);
    });

    test('legacy deepseek-reasoner: reasoner, no tools, no thinking field', () {
      final c = ModelCapabilities.resolve('deepseek-reasoner');
      expect(c.isReasoner, isTrue);
      expect(c.supportsTools, isFalse);
      expect(c.sendThinkingField, isFalse);
    });

    test('o1: reasoner, no tools, no DeepSeek thinking field', () {
      final c = ModelCapabilities.resolve('o1');
      expect(c.isReasoner, isTrue);
      expect(c.supportsTools, isFalse);
      expect(c.sendThinkingField, isFalse);
    });

    test('o3-mini: reasoner but still tool-capable (unchanged behavior)', () {
      final c = ModelCapabilities.resolve('o3-mini');
      expect(c.isReasoner, isTrue);
      expect(c.supportsTools, isTrue);
      expect(c.sendThinkingField, isFalse);
    });

    test('gpt-4o: plain chat — tools, not reasoner, no thinking field', () {
      final c = ModelCapabilities.resolve('gpt-4o');
      expect(c.isReasoner, isFalse);
      expect(c.supportsTools, isTrue);
      expect(c.sendThinkingField, isFalse);
    });

    test('kimi-thinking-preview: now detected as reasoner', () {
      final c = ModelCapabilities.resolve('kimi-thinking-preview');
      expect(c.isReasoner, isTrue);
      expect(c.sendThinkingField, isFalse); // not a DeepSeek model
    });

    test('current Grok models expose the correct capabilities', () {
      final chat = ModelCapabilities.resolve('grok-4.3');
      expect(chat.isReasoner, isFalse);
      expect(chat.supportsTools, isTrue);
      expect(chat.supportsVision, isTrue);
      expect(chat.supportsReasoningEffort, isTrue);
      expect(chat.reasoningCanBeDisabled, isTrue);

      final reasoner = ModelCapabilities.resolve('grok-4.5');
      expect(reasoner.isReasoner, isTrue);
      expect(reasoner.supportsTools, isTrue);
      expect(reasoner.supportsVision, isTrue);
      expect(reasoner.supportsReasoningEffort, isTrue);
      expect(reasoner.reasoningCanBeDisabled, isFalse);

      final fixedReasoner = ModelCapabilities.resolve(
        'grok-4.20-0309-reasoning',
      );
      expect(fixedReasoner.isReasoner, isTrue);

      final nonReasoner = ModelCapabilities.resolve(
        'grok-4.20-0309-non-reasoning',
      );
      expect(nonReasoner.isReasoner, isFalse);
      expect(nonReasoner.supportsTools, isTrue);

      final multiAgent = ModelCapabilities.resolve(
        'grok-4.20-multi-agent-0309',
      );
      expect(multiAgent.isReasoner, isTrue);
      expect(multiAgent.supportsTools, isTrue);
    });

    test('unknown models fail closed for tool support', () {
      final c = ModelCapabilities.resolve('plain-chat-model');
      expect(c.supportsTools, isFalse);
    });

    test('tool support covers aggregator-prefixed and newer model ids', () {
      expect(ModelCapabilities.resolve('qwen3-max').supportsTools, isTrue);
      expect(ModelCapabilities.resolve('qwen/qwen3-max').supportsTools, isTrue);
      expect(
        ModelCapabilities.resolve('deepseek-ai/DeepSeek-V4').supportsTools,
        isTrue,
      );
      expect(
        ModelCapabilities.resolve('deepseek-ai/DeepSeek-V4').sendThinkingField,
        isTrue,
      );
      expect(ModelCapabilities.resolve('o4-mini').supportsTools, isTrue);
      expect(ModelCapabilities.resolve('o4-mini').isReasoner, isTrue);
      expect(ModelCapabilities.resolve('minimax-m2.1').supportsTools, isTrue);
      expect(
        ModelCapabilities.resolve('doubao-seed-2.0').supportsTools,
        isTrue,
      );
      expect(ModelCapabilities.resolve('hunyuan-turbos').supportsTools, isTrue);
    });

    test('vision detection: gpt-4o yes, deepseek-v4 no, qwen-vl yes', () {
      expect(ModelCapabilities.resolve('gpt-4o').supportsVision, isTrue);
      expect(ModelCapabilities.resolve('gpt-4o-mini').supportsVision, isTrue);
      expect(ModelCapabilities.resolve('qwen-vl-max').supportsVision, isTrue);
      expect(ModelCapabilities.resolve('glm-4v').supportsVision, isTrue);
      expect(
        ModelCapabilities.resolve('deepseek-v4-flash').supportsVision,
        isFalse,
      );
    });

    test('LlmConfig derives capabilities from its model by default', () {
      const cfg = LlmConfig(
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'deepseek-v4-flash',
      );
      expect(cfg.capabilities.sendThinkingField, isTrue);
      // copyWith to a new model re-derives (no stale override leaks through).
      final reasoner = cfg.copyWith(model: 'deepseek-reasoner');
      expect(reasoner.capabilities.supportsTools, isFalse);
    });
  });

  test('SearchBackend wire round-trips', () {
    for (final b in SearchBackend.values) {
      expect(SearchBackendInfo.fromWire(b.wire), b);
    }
    expect(SearchBackendInfo.fromWire('garbage'), SearchBackend.duckduckgo);
    expect(SearchBackend.provider.requiresApiKey, isFalse);
    expect(SearchBackend.provider.isProviderHosted, isTrue);
    expect(SearchBackend.duckduckgo.requiresApiKey, isFalse);
    expect(SearchBackend.tavily.requiresApiKey, isTrue);
  });

  test('SearchMode cycles through all three states', () {
    expect(SearchMode.off.next, SearchMode.auto);
    expect(SearchMode.auto.next, SearchMode.always);
    expect(SearchMode.always.next, SearchMode.off);
    expect(SearchMode.off.composerLabel, '联网');
    expect(SearchMode.auto.composerLabel, '联网·自动');
    expect(SearchMode.always.composerLabel, '联网·强制');
  });

  test('ToolEngine.dateLine produces the expected format', () {
    final line = ToolEngine.dateLine(DateTime(2026, 7, 26));
    expect(line, '今天是 2026-07-26（周日）');
    final monday = ToolEngine.dateLine(DateTime(2026, 7, 27));
    expect(monday, '今天是 2026-07-27（周一）');
  });

  test('SearchActivity JSON round-trips all statuses', () {
    final running = SearchActivity(
      kind: SearchActivityKind.search,
      query: 'flutter news',
    );
    final done = running.copyWith(
      status: SearchActivityStatus.done,
      resultCount: 5,
    );
    final failed = running.copyWith(
      status: SearchActivityStatus.failed,
      error: 'timeout',
    );
    for (final a in [done, failed]) {
      final json = a.toJson();
      final restored = SearchActivity.fromJson(json);
      expect(restored.id, a.id);
      expect(restored.kind, a.kind);
      expect(restored.query, a.query);
      expect(restored.status, a.status);
      expect(restored.resultCount, a.resultCount);
      expect(restored.error, a.error);
    }
    // Running → failed on reload (the process that tracked it is gone).
    final json = running.toJson();
    final reloaded = SearchActivity.fromJson(json);
    expect(reloaded.status, SearchActivityStatus.failed);
  });

  test('ChatMessage preserves searchActivities through JSON round-trip', () {
    final activities = [
      SearchActivity(
        kind: SearchActivityKind.search,
        query: 'dart 3.12',
        status: SearchActivityStatus.done,
        resultCount: 3,
      ),
      SearchActivity(
        kind: SearchActivityKind.fetch,
        query: 'https://dart.dev',
        status: SearchActivityStatus.failed,
        error: '404',
      ),
    ];
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: 'answer',
      searchActivities: activities,
    );
    final json = msg.toJson();
    final restored = ChatMessage.fromJson(json);
    expect(restored.searchActivities, hasLength(2));
    expect(restored.searchActivities[0].query, 'dart 3.12');
    expect(restored.searchActivities[0].resultCount, 3);
    expect(restored.searchActivities[1].query, 'https://dart.dev');
    expect(restored.searchActivities[1].status, SearchActivityStatus.failed);
  });

  test('ChatMessage fromJson promotes running searchActivities to failed', () {
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: 'interrupted',
      searchActivities: [
        SearchActivity(
          kind: SearchActivityKind.search,
          query: 'in-flight',
          status: SearchActivityStatus.running,
        ),
      ],
    );
    final json = msg.toJson();
    final restored = ChatMessage.fromJson(json);
    expect(
      restored.searchActivities.single.status,
      SearchActivityStatus.failed,
    );
  });

  test('ChatMessage copyWith merges searchActivities', () {
    final a1 = SearchActivity(kind: SearchActivityKind.search, query: 'q1');
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: '',
      searchActivities: [a1],
    );
    final a2 = a1.copyWith(status: SearchActivityStatus.done, resultCount: 2);
    final updated = msg.copyWith(searchActivities: [a2]);
    expect(updated.searchActivities, hasLength(1));
    expect(updated.searchActivities[0].status, SearchActivityStatus.done);
    expect(updated.searchActivities[0].resultCount, 2);
  });

  test('ChatMessage preserves appliedWorldInfo through JSON round-trip', () {
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: '夜雨中的剑光',
      appliedWorldInfo: const [
        WorldInfoHit(id: 'w1', title: '青锋剑法', alwaysOn: false),
        WorldInfoHit(id: 'w2', title: '王城律法', alwaysOn: true),
      ],
    );
    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.appliedWorldInfo, hasLength(2));
    expect(restored.appliedWorldInfo[0].title, '青锋剑法');
    expect(restored.appliedWorldInfo[1].alwaysOn, isTrue);
    expect(restored.appliedWorldInfo[1].displayTitle, '王城律法');
  });

  test(
    'ConversationExport.toMarkdown renders roles, reasoning and sources',
    () {
      final user = ChatMessage(role: MessageRole.user, content: 'hi');
      final convo = Conversation(
        title: 'My chat',
        messages: [
          user,
          ChatMessage(
            role: MessageRole.assistant,
            content: 'hello [1]',
            reasoning: 'pondered',
            model: 'deepseek-reasoner',
            parentId: user.id,
            citations: const [
              Citation(index: 1, title: 'Src', url: 'https://src.com'),
            ],
          ),
        ],
      );
      final md = ConversationExport.toMarkdown(convo);
      expect(md, contains('# My chat'));
      expect(md, contains('🧑 用户'));
      expect(md, contains('🤖 助手'));
      expect(md, contains('deepseek-reasoner'));
      expect(md, contains('深度思考'));
      expect(md, contains('[Src](https://src.com)'));
    },
  );

  test('ConversationExport.toMarkdown exports only the active branch', () {
    final user = ChatMessage(role: MessageRole.user, content: 'q');
    final oldReply = ChatMessage(
      role: MessageRole.assistant,
      content: 'DISCARDED answer',
      parentId: user.id,
    );
    final newReply = ChatMessage(
      role: MessageRole.assistant,
      content: 'ACTIVE answer',
      parentId: user.id,
    );
    // Two assistant siblings (a regenerate); the active path points to the new
    // one. The discarded branch must not appear in the export.
    final convo = Conversation(
      title: 'Branched',
      messages: [user, oldReply, newReply],
      activeChildren: {kRootKey: user.id, user.id: newReply.id},
    );
    final md = ConversationExport.toMarkdown(convo);
    expect(md, contains('ACTIVE answer'));
    expect(md, isNot(contains('DISCARDED answer')));
  });

  test('ConversationExport.toMarkdown labels story character and outline', () {
    final user = ChatMessage(role: MessageRole.user, content: '（推进情节）');
    final bot = ChatMessage(
      role: MessageRole.assistant,
      content: '月光下…',
      parentId: user.id,
    );
    final convo = Conversation(
      title: '夜谈',
      mode: ConversationMode.story,
      outline: '- 开端\n- 转折',
      authorNote: '偏诗意',
      plotCursor: 1,
      messages: [user, bot],
      activeChildren: {kRootKey: user.id, user.id: bot.id},
    );
    final md = ConversationExport.toMarkdown(convo, characterName: '林晚');
    expect(md, contains('模式：故事'));
    expect(md, contains('角色：林晚'));
    expect(md, contains('## 大纲'));
    expect(md, contains('导演指令'));
    expect(md, contains('偏诗意'));
    expect(md, contains('## 🤖 林晚'));
    expect(md, contains('月光下'));
  });

  test('ConversationExport.toMarkdown labels director and local AI cast', () {
    final director = ChatMessage(
      role: MessageRole.user,
      content: '让两人在这里发生第一次冲突。',
    );
    final story = ChatMessage(
      role: MessageRole.assistant,
      content: '舱门合拢，争执随之爆发。',
      parentId: director.id,
    );
    final convo = Conversation(
      title: '失控航线',
      mode: ConversationMode.story,
      localCast: [
        CharacterCard(name: '沈砚'),
        CharacterCard(name: '零号'),
      ],
      messages: [director, story],
      activeChildren: {kRootKey: director.id, director.id: story.id},
    );

    final md = ConversationExport.toMarkdown(convo);
    expect(md, contains('模式：导演故事'));
    expect(md, contains('AI 角色：沈砚、零号'));
    expect(md, contains('## 🎬 导演'));
    expect(md, contains('## 🤖 旁白与角色'));
  });

  test('ConversationExport.toMarkdown escapes hostile character names', () {
    final director = ChatMessage(role: MessageRole.user, content: '开始。');
    final convo = Conversation(
      title: '转义测试',
      mode: ConversationMode.story,
      localCast: [
        CharacterCard(name: 'K_9'),
        CharacterCard(name: '艾拉\n# 系统公告'),
      ],
      messages: [director],
      activeChildren: {kRootKey: director.id},
    );

    final md = ConversationExport.toMarkdown(convo);
    expect(md, contains(r'K\_9'));
    expect(md, isNot(contains('\n# 系统公告')));
  });

  test('LlmRequestMessage serializes images as multimodal content parts', () {
    const msg = LlmRequestMessage(
      role: MessageRole.user,
      content: 'what is this?',
      imageDataUrls: ['data:image/png;base64,AAAA'],
    );
    final json = msg.toOpenAiJson();
    final parts = json['content'] as List;
    expect(parts.first, {'type': 'text', 'text': 'what is this?'});
    expect(parts.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,AAAA'},
    });
  });

  test('vision model receives image attachments as image parts', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'a cat')]);
    final c = _container(
      llm,
      InMemoryRepo(),
      settingsBuilder: FakeVisionSettings.new,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage(
      'what is this?',
      attachments: [
        Attachment(name: 'pic.png', mimeType: 'image/png', imageBase64: 'AAAA'),
      ],
    );

    final user = llm.calls.last.firstWhere((m) => m.role == MessageRole.user);
    expect(user.imageDataUrls, ['data:image/png;base64,AAAA']);
  });

  test(
    'image send is rejected when the optional vision API is not configured',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
      final c = _container(llm, InMemoryRepo()); // default DeepSeek (no vision)
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      final accepted = await ctrl.sendMessage(
        'what is this?',
        attachments: [
          Attachment(
            name: 'pic.png',
            mimeType: 'image/png',
            imageBase64: 'AAAA',
          ),
        ],
      );

      expect(accepted, isFalse);
      expect(llm.calls, isEmpty);
      expect(c.read(chatControllerProvider).value!.error, contains('视觉 API'));
    },
  );

  test(
    'editMessage of a plain turn does not route to the vision model',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeVisionSettings.new,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage('第一句纯文本');
      await ctrl.sendMessage(
        '看看这张图',
        attachments: [
          Attachment(
            name: 'pic.png',
            mimeType: 'image/png',
            imageBase64: 'AAAA',
          ),
        ],
      );
      expect(llm.lastConfig!.apiKey, 'sk-vision-test');

      // Editing the first (plain) turn discards the image turn; the regenerated
      // branch contains no images, so it must use the plain chat credentials.
      final convo = c.read(chatControllerProvider).value!.current!;
      final firstUser = convo.activePath.firstWhere(
        (m) => m.role == MessageRole.user,
      );
      await ctrl.editMessage(firstUser.id, '改写第一句');

      expect(llm.lastConfig!.apiKey, 'sk-test');
    },
  );

  test(
    'editMessage of an inactive-branch turn ignores active-path images',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeVisionSettings.new,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      // A plain two-turn conversation.
      await ctrl.sendMessage('第一句');
      await ctrl.sendMessage('第二句');

      // Edit the first turn: a sibling branch becomes active.
      var convo = c.read(chatControllerProvider).value!.current!;
      final firstUser = convo.activePath.first;
      final secondUser = convo.activePath[2];
      await ctrl.editMessage(firstUser.id, '改写第一句');
      expect(llm.lastConfig!.apiKey, 'sk-test');

      // The active branch now carries an image turn...
      await ctrl.sendMessage(
        '看图',
        attachments: [
          Attachment(
            name: 'pic.png',
            mimeType: 'image/png',
            imageBase64: 'AAAA',
          ),
        ],
      );
      expect(llm.lastConfig!.apiKey, 'sk-vision-test');

      // ...but editing the SECOND turn on the INACTIVE branch regenerates a
      // text-only branch whose own ancestors carry no images.
      convo = c.read(chatControllerProvider).value!.current!;
      final secondUserOnInactive = convo.messages.firstWhere(
        (m) => m.id == secondUser.id,
      );
      await ctrl.editMessage(secondUserOnInactive.id, '改写第二句');
      expect(llm.lastConfig!.apiKey, 'sk-test');
    },
  );

  test('deleteConversation drops its context report', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('hello');
    final state = c.read(chatControllerProvider).value!;
    final id = state.currentId!;
    expect(state.contextReports, contains(id));

    await ctrl.deleteConversation(id);
    expect(
      c.read(chatControllerProvider).value!.contextReports.containsKey(id),
      isFalse,
    );
  });

  test('generateImage recovers when the placeholder persist fails', () async {
    final repo = FailingSaveRepo();
    final c = _container(
      FakeLlmProvider(const []),
      repo,
      settingsBuilder: FakeImageGenSettings.new,
      mediaProvider: FakeMediaProvider(),
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    repo.failNextSave = true;
    final ok = await ctrl.generateImage('画一只猫');

    expect(ok, isTrue);
    final state = c.read(chatControllerProvider).value!;
    expect(state.isStreaming, isFalse);
    final path = state.current!.activePath;
    expect(path.last.kind, MessageKind.generatedImage);
    expect(path.last.attachments, isNotEmpty);
    // Later checkpoint writes still reach storage once it recovers.
    expect(repo.store, isNotEmpty);
  });

  test('failed pure image generation retries the image operation', () async {
    final media = FakeMediaProvider(failuresRemaining: 1);
    final c = _container(
      FakeLlmProvider(const []),
      InMemoryRepo(),
      settingsBuilder: FakeImageGenSettings.new,
      mediaProvider: media,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.generateImage('画一只猫');
    var state = c.read(chatControllerProvider).value!;
    expect(state.error, contains('simulated image failure'));
    expect(state.retryOperation?.kind, ChatRetryKind.image);
    expect(state.current!.activePath.last.attachments, isEmpty);

    await ctrl.retryLast();
    state = c.read(chatControllerProvider).value!;
    expect(media.prompts, hasLength(2));
    expect(state.error, isNull);
    expect(state.retryOperation, isNull);
    expect(state.current!.activePath.last.kind, MessageKind.generatedImage);
    expect(state.current!.activePath.last.attachments, isNotEmpty);
    expect(
      state.current!.messages.where(
        (message) => message.kind == MessageKind.generatedImage,
      ),
      hasLength(2),
    );
  });

  test(
    'generateImage with deepThink optimizes prompt before media call',
    () async {
      final media = FakeMediaProvider();
      final llm = FakeLlmProvider([
        const ChatChunk(reasoningDelta: '先补光影…'),
        const ChatChunk(
          contentDelta:
              'a fluffy orange cat sitting on a windowsill, soft morning light, '
              'photorealistic, shallow depth of field',
        ),
      ]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeImageGenSettings.new,
        mediaProvider: media,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      ctrl.toggleDeepThink();
      expect(c.read(chatControllerProvider).value!.deepThink, isTrue);

      final ok = await ctrl.generateImage('画一只猫');
      expect(ok, isTrue);
      expect(media.lastPrompt, contains('fluffy orange cat'));
      expect(media.lastPrompt, isNot(equals('画一只猫')));
      expect(llm.callCount, 1);
      expect(llm.lastThinking, isTrue);
      expect(llm.lastConfig?.model, KnownModels.reasoner);

      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(assistant.kind, MessageKind.generatedImage);
      expect(assistant.attachments, isNotEmpty);
      expect(assistant.reasoning, contains('先补光影'));
      expect(assistant.content, contains('深度思考优化后的提示词'));
    },
  );

  test('generateImage without deepThink sends the raw prompt', () async {
    final media = FakeMediaProvider();
    final llm = FakeLlmProvider(const []);
    final c = _container(
      llm,
      InMemoryRepo(),
      settingsBuilder: FakeImageGenSettings.new,
      mediaProvider: media,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final ok = await ctrl.generateImage('画一只猫');
    expect(ok, isTrue);
    // Pure 生图 is scrubbed + SFW-suffixed like dialogue illustration.
    expect(media.lastPrompt, contains('画一只猫'));
    expect(media.lastPrompt, contains('safe for work'));
    expect(media.lastReferenceBytes, isNull);
    expect(llm.callCount, 0);
  });

  test('generateImage with reference image uses img2img path', () async {
    final media = FakeMediaProvider();
    final c = _container(
      FakeLlmProvider(const []),
      InMemoryRepo(),
      settingsBuilder: FakeImageGenSettings.new,
      mediaProvider: media,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    final refBytes = List<int>.generate(16, (i) => i + 1);
    final ref = Attachment(
      name: 'ref.png',
      mimeType: 'image/png',
      sizeBytes: refBytes.length,
      imageBase64: base64Encode(refBytes),
    );
    final ok = await ctrl.generateImage('改成赛博朋克风格', referenceImages: [ref]);
    expect(ok, isTrue);
    expect(media.lastPrompt, contains('改成赛博朋克风格'));
    expect(media.lastPrompt, contains('safe for work'));
    expect(media.lastReferenceBytes, refBytes);

    final path = c.read(chatControllerProvider).value!.current!.activePath;
    expect(path.first.attachments, hasLength(1)); // user kept reference
    expect(path.last.content, contains('图生图'));
    expect(path.last.attachments, isNotEmpty);
  });

  test('toggleImageGenMode cycles off → auto → always → off', () async {
    final c = _container(FakeLlmProvider(const []), InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    expect(
      c.read(chatControllerProvider).value!.imageGenMode,
      ImageGenMode.off,
    );
    ctrl.toggleImageGenMode();
    expect(
      c.read(chatControllerProvider).value!.imageGenMode,
      ImageGenMode.auto,
    );
    ctrl.toggleImageGenMode();
    expect(
      c.read(chatControllerProvider).value!.imageGenMode,
      ImageGenMode.always,
    );
    ctrl.toggleImageGenMode();
    expect(
      c.read(chatControllerProvider).value!.imageGenMode,
      ImageGenMode.off,
    );
  });

  test('配图·强制 pre-generates one SFW image on the assistant turn', () async {
    final media = FakeMediaProvider();
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: '这是文字回复')]);
    final c = _container(
      llm,
      InMemoryRepo(),
      settingsBuilder: FakeImageGenSettings.new,
      mediaProvider: media,
    );
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    ctrl.toggleImageGenMode(); // auto
    ctrl.toggleImageGenMode(); // always
    expect(
      c.read(chatControllerProvider).value!.imageGenMode,
      ImageGenMode.always,
    );

    final ok = await ctrl.sendMessage('请介绍一下量子计算');
    expect(ok, isTrue);
    expect(media.prompts, hasLength(1));
    expect(media.lastPrompt, contains('safe for work'));

    final assistant = c
        .read(chatControllerProvider)
        .value!
        .current!
        .activePath
        .last;
    expect(assistant.role, MessageRole.assistant);
    expect(assistant.attachments, hasLength(1));
    expect(assistant.content, contains('这是文字回复'));
  });

  test(
    '配图·强制 on character chat builds portrait without R18 user text',
    () async {
      final media = FakeMediaProvider();
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '……')]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeImageGenSettings.new,
        mediaProvider: media,
      );
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      final card = CharacterCard(
        name: '苏晚',
        description: '青衣长发，手持折扇',
        firstMes: '你好',
      );
      // Portrait resolution loads the card from the character library.
      await c.read(characterRepositoryProvider).save(card);
      await ctrl.newStoryConversation(card, worldInfoIds: const []);
      ctrl.toggleImageGenMode();
      ctrl.toggleImageGenMode(); // always

      await ctrl.sendMessage('他们激烈做爱，场面不堪入目，继续写');
      expect(media.prompts, hasLength(1));
      final prompt = media.lastPrompt!;
      expect(prompt, contains('苏晚'));
      expect(prompt, contains('青衣长发'));
      expect(prompt, isNot(contains('做爱')));
      expect(prompt, isNot(contains('不堪入目')));
      expect(prompt, contains('safe for work'));

      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(assistant.attachments, hasLength(1));
    },
  );

  test(
    'regenerate creates a new assistant branch and switches between them',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'first')]);
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage('question');
      var convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.activePath, hasLength(2)); // user + assistant
      expect(convo.activePath.last.content, 'first');

      llm.chunks
        ..clear()
        ..add(const ChatChunk(contentDelta: 'second'));
      await ctrl.regenerate();

      convo = c.read(chatControllerProvider).value!.current!;
      // Active path still 2, but the assistant now has a sibling branch.
      expect(convo.activePath, hasLength(2));
      expect(convo.activePath.last.content, 'second');
      final assistant = convo.activePath.last;
      final (idx, count) = convo.branchInfo(assistant.id);
      expect(count, 2);
      expect(idx, 1);
      // All assistant nodes are retained in the tree (no data lost).
      expect(
        convo.messages.where((m) => m.role == MessageRole.assistant).length,
        2,
      );

      // Switch back to the first branch.
      ctrl.switchBranch(assistant.id, -1);
      convo = c.read(chatControllerProvider).value!.current!;
      expect(convo.activePath.last.content, 'first');
    },
  );

  test('editMessage branches the user turn and keeps the original', () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ans-a')]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('hello');
    var convo = c.read(chatControllerProvider).value!.current!;
    final firstUser = convo.activePath.first;
    expect(firstUser.content, 'hello');

    llm.chunks
      ..clear()
      ..add(const ChatChunk(contentDelta: 'ans-b'));
    await ctrl.editMessage(firstUser.id, 'hello edited');

    convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.activePath.first.content, 'hello edited');
    expect(convo.activePath.last.content, 'ans-b');
    // The original user turn is preserved as a sibling branch.
    final (idx, count) = convo.branchInfo(convo.activePath.first.id);
    expect(count, 2);
    expect(idx, 1);
  });

  test(
    'Conversation.activePath follows activeChildren and JSON round-trips',
    () {
      final u1 = ChatMessage(role: MessageRole.user, content: 'q');
      final a1 = ChatMessage(
        role: MessageRole.assistant,
        content: 'a1',
        parentId: u1.id,
      );
      final a2 = ChatMessage(
        role: MessageRole.assistant,
        content: 'a2',
        parentId: u1.id,
      );
      final convo = Conversation(
        title: 't',
        messages: [u1, a1, a2],
        activeChildren: {kRootKey: u1.id, u1.id: a1.id},
      );
      expect(convo.activePath.map((m) => m.content), ['q', 'a1']);
      expect(convo.branchInfo(a1.id), (0, 2));

      final restored = Conversation.fromJson(convo.toJson());
      expect(restored.activePath.map((m) => m.content), ['q', 'a1']);
      expect(restored.activeChildren[u1.id], a1.id);
      expect(restored.messages[1].parentId, u1.id);
    },
  );

  group('ChatPage widget interactions', () {
    testWidgets('permission sheet inactivity does not cancel first voice use', (
      tester,
    ) async {
      final gate = Completer<SpeechInputAvailability>();
      final speech = FakeSpeechInputService(initializeGate: gate.future);
      final c = _container(
        FakeLlmProvider(const []),
        InMemoryRepo(),
        speechInputService: speech,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.tap(find.byTooltip('语音输入'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      gate.complete(SpeechInputAvailability.ready);
      await tester.pump();
      await tester.pump();

      expect(speech.startCount, 1);
      expect(speech.cancelCount, 0);
      expect(find.byTooltip('停止语音输入'), findsOneWidget);
    });

    testWidgets('voice input is cancelled when the app goes to background', (
      tester,
    ) async {
      final speech = FakeSpeechInputService();
      final c = _container(
        FakeLlmProvider(const []),
        InMemoryRepo(),
        speechInputService: speech,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.tap(find.byTooltip('语音输入'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      expect(speech.cancelCount, 1);
      expect(find.byTooltip('语音输入'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('speech-listening-indicator')),
        findsNothing,
      );
    });

    testWidgets('voice input fills the composer without auto-sending', (
      tester,
    ) async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '收到')]);
      final speech = FakeSpeechInputService();
      final c = _container(llm, InMemoryRepo(), speechInputService: speech);
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.tap(find.byTooltip('语音输入'));
      await tester.pump();
      speech.emit('帮我写一封邮件');
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('composer-text-field')),
      );
      expect(field.controller?.text, '帮我写一封邮件');
      expect(find.text('正在听… 识别文字不会自动发送'), findsOneWidget);
      expect(llm.callCount, 0);

      await tester.tap(find.byTooltip('发送'));
      await _drain(tester);

      expect(speech.initializeCount, 1);
      expect(speech.startCount, 1);
      expect(speech.cancelCount, 1);
      expect(llm.callCount, 1);
      final path = c
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath;
      expect(path.first.content, '帮我写一封邮件');
    });

    testWidgets('speech errors cancel the native recognizer', (tester) async {
      final speech = FakeSpeechInputService();
      final c = _container(
        FakeLlmProvider(const []),
        InMemoryRepo(),
        speechInputService: speech,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.tap(find.byTooltip('语音输入'));
      await tester.pump();
      speech.fail('error_audio');
      await tester.pump();

      expect(speech.cancelCount, 1);
      expect(find.byTooltip('语音输入'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('speech-listening-indicator')),
        findsNothing,
      );
    });

    testWidgets('assistant replies can be read aloud and stopped', (
      tester,
    ) async {
      final tts = FakeTextToSpeechService();
      final c = _container(
        FakeLlmProvider([const ChatChunk(contentDelta: 'hello there')]),
        InMemoryRepo(),
        textToSpeechService: tts,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.enterText(find.byType(TextField).first, 'hi');
      await tester.tap(find.byTooltip('发送'));
      await _drain(tester);

      expect(find.byTooltip('朗读'), findsOneWidget);
      await tester.tap(find.byTooltip('朗读'));
      await tester.pump();

      expect(tts.requests, hasLength(1));
      expect(tts.requests.single.text, 'hello there');
      expect(find.byTooltip('停止朗读'), findsOneWidget);

      await tester.tap(find.byTooltip('停止朗读'));
      await tester.pump();
      expect(tts.stopCount, 1);
      expect(find.byTooltip('朗读'), findsOneWidget);
    });

    testWidgets('denied voice permission is explained without starting', (
      tester,
    ) async {
      final speech = FakeSpeechInputService(
        availability: SpeechInputAvailability.permissionDenied,
      );
      final c = _container(
        FakeLlmProvider(const []),
        InMemoryRepo(),
        speechInputService: speech,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.tap(find.byTooltip('语音输入'));
      await tester.pump();

      expect(find.text('未获得麦克风或语音识别权限，请在系统设置中允许后重试。'), findsOneWidget);
      expect(speech.initializeCount, 1);
      expect(speech.startCount, 0);
    });

    testWidgets(
      'MiMo upload keeps edits made to the composer while recognizing',
      (tester) async {
        final mimo = FakeMimoSpeechInputService();
        final c = _container(
          FakeLlmProvider(const []),
          InMemoryRepo(),
          settingsBuilder: FakeMimoSettings.new,
          mimoSpeechInputService: mimo,
        );
        addTearDown(c.dispose);
        await _pumpChat(tester, c);

        await tester.tap(find.byTooltip('语音输入'));
        await tester.pump();
        expect(find.byTooltip('结束录音并识别'), findsOneWidget);

        // Finish the recording; the upload is now gated.
        await tester.tap(find.byTooltip('结束录音并识别'));
        await tester.pump();
        expect(find.byTooltip('正在上传语音；点按取消'), findsOneWidget);

        // The composer stays editable while the upload runs.
        await tester.enterText(
          find.byKey(const ValueKey('composer-text-field')),
          '上传期间打的字',
        );
        await tester.pump();

        mimo.finishGate.complete();
        await _drain(tester);

        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('composer-text-field')),
        );
        expect(field.controller?.text, contains('上传期间打的字'));
        expect(field.controller?.text, contains('识别结果'));
      },
    );

    testWidgets('tapping send dispatches the message and renders the reply', (
      tester,
    ) async {
      final llm = FakeLlmProvider([
        const ChatChunk(contentDelta: 'hello there'),
      ]);
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      // Fresh conversation → empty state visible.
      expect(find.text('开始一段对话'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'hi');
      await tester.tap(find.byTooltip('发送'));
      await _drain(tester);

      expect(llm.callCount, 1);
      final assistant = c
          .read(chatControllerProvider)
          .value!
          .current!
          .activePath
          .last;
      expect(assistant.content, 'hello there');
      // The message list replaced the empty state.
      expect(find.text('开始一段对话'), findsNothing);
    });

    testWidgets('深度思考 chip toggles deep-think state', (tester) async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'x')]);
      final c = _container(llm, InMemoryRepo());
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      expect(c.read(chatControllerProvider).value!.deepThink, isFalse);
      await tester.tap(find.text('深度思考'));
      await tester.pump();
      expect(c.read(chatControllerProvider).value!.deepThink, isTrue);
    });

    testWidgets('preflight API-key error does not offer an invalid retry', (
      tester,
    ) async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'x')]);
      final c = _container(
        llm,
        InMemoryRepo(),
        settingsBuilder: FakeUnconfiguredSettings.new,
      );
      addTearDown(c.dispose);
      await _pumpChat(tester, c);

      await tester.enterText(find.byType(TextField).first, 'hi');
      await tester.tap(find.byTooltip('发送'));
      await _drain(tester);

      expect(llm.callCount, 0); // never reached the LLM
      expect(find.text('请先在设置中填写 API Key。'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });
  });
}

/// Pump [ChatPage] against a prebuilt container so tests can read state back.
Future<void> _pumpChat(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ChatPage()),
    ),
  );
  await _drain(tester);
}

/// Bounded pumping — the async-loading branch shows a spinner, so pumpAndSettle
/// would hang; a few fixed frames let the AsyncNotifier + fake stream resolve.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _FakeSearch implements SearchProvider {
  _FakeSearch(this.results);
  final List<SearchResult> results;
  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async => results;
}

class _ThrowingSearch implements SearchProvider {
  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async => throw const SearchUnavailableException('unavailable');
}

class _CountingSearch implements SearchProvider {
  _CountingSearch(this.results);

  final List<SearchResult> results;
  int calls = 0;
  String? lastQuery;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async {
    calls++;
    lastQuery = query;
    return results.take(maxResults).toList();
  }
}

class _StubPageSearch extends HttpSearchProvider {
  _StubPageSearch() : super(backend: SearchBackend.duckduckgo, apiKey: '');

  int fetchCalls = 0;

  @override
  Future<SearchResult> fetchPage(String url, {CancelToken? cancelToken}) async {
    fetchCalls++;
    return SearchResult(
      title: 'Allowed page',
      url: url,
      content:
          'This is readable page content long enough to pass the minimum '
          'source threshold used by the tool engine.',
    );
  }
}
