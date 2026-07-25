import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/character_repository.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/domain/export/conversation_export.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
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
    CancelToken? cancelToken,
  }) async* {
    final callIndex = callCount++;
    calls.add(List<LlmRequestMessage>.of(messages));
    toolCalls.add(tools == null ? null : List<ToolSpec>.of(tools));
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

/// In-memory Drift DB for story repos in unit tests (no path_provider).
ProviderContainer _container(
  FakeLlmProvider llm,
  InMemoryRepo repo, {
  ToolEngineFactory? toolEngineFactory,
  SettingsController Function() settingsBuilder = FakeSettings.new,
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
      citations: const [Citation(index: 1, title: 'T', url: 'https://x')],
    );
    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.content, 'hello');
    expect(restored.reasoning, 'thinking');
    expect(restored.model, 'deepseek-reasoner');
    expect(restored.thinkingMillis, 4200);
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
      final payload = Uint8List.fromList(utf8.encode('a' * (256 * 1024)));
      final archive = Archive()
        ..addFile(
          ArchiveFile('word/document.xml', payload.lengthInBytes, payload),
        );
      final compressed = Uint8List.fromList(ZipEncoder().encode(archive)!);

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
    expect(convo.activePath.any((m) => m.content == '（推进情节）'), isTrue);
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
    expect(SearchBackend.duckduckgo.requiresApiKey, isFalse);
    expect(SearchBackend.tavily.requiresApiKey, isTrue);
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
    'non-vision model describes images in text, not as image parts',
    () async {
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
      final c = _container(llm, InMemoryRepo()); // default DeepSeek (no vision)
      addTearDown(c.dispose);
      final ctrl = c.read(chatControllerProvider.notifier);
      await c.read(chatControllerProvider.future);

      await ctrl.sendMessage(
        'what is this?',
        attachments: [
          Attachment(
            name: 'pic.png',
            mimeType: 'image/png',
            imageBase64: 'AAAA',
          ),
        ],
      );

      final user = llm.calls.last.firstWhere((m) => m.role == MessageRole.user);
      expect(user.imageDataUrls, isEmpty);
      expect(user.content, contains('不支持图片'));
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

    testWidgets('error banner with 重试 appears when the API key is missing', (
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
      expect(find.text('重试'), findsOneWidget);
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
