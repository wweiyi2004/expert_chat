import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/export/conversation_export.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// LLM provider that replays a scripted list of chunks and records the config
/// it was called with (so tests can assert model routing).
class FakeLlmProvider implements LlmProvider {
  FakeLlmProvider(this.chunks);
  final List<ChatChunk> chunks;
  LlmConfig? lastConfig;
  List<ToolSpec>? lastTools;
  bool? lastThinking;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<ChatMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
  }) async* {
    lastConfig = config;
    lastTools = tools;
    lastThinking = thinking;
    for (final c in chunks) {
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
    );
  }
}

ProviderContainer _container(FakeLlmProvider llm, InMemoryRepo repo) {
  return ProviderContainer(overrides: [
    llmProvider.overrideWithValue(llm),
    conversationRepositoryProvider.overrideWithValue(repo),
    settingsControllerProvider.overrideWith(FakeSettings.new),
  ]);
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

  test('without deepThink the chat model is used with thinking disabled',
      () async {
    final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'hello')]);
    final c = _container(llm, InMemoryRepo());
    addTearDown(c.dispose);
    final ctrl = c.read(chatControllerProvider.notifier);
    await c.read(chatControllerProvider.future);

    await ctrl.sendMessage('hi');
    expect(llm.lastConfig?.model, KnownModels.chat);
    expect(llm.lastThinking, isFalse); // normal mode disables thinking
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

  test('DriftConversationRepository persists, reloads, deletes and searches',
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
            Citation(index: 1, title: 'drift docs', url: 'https://drift.simonbinder.eu'),
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
  });

  group('FileParser', () {
    final parser = FileParser();

    test('parses plain text', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final a = parser.parse(
          name: 'note.txt', mimeType: 'text/plain', sizeBytes: 11, bytes: bytes);
      expect(a.parseError, isNull);
      expect(a.text, 'hello world');
      expect(a.truncated, isFalse);
    });

    test('truncates text past maxChars', () {
      final big = 'a' * (FileParser.maxChars + 100);
      final bytes = Uint8List.fromList(utf8.encode(big));
      final a = parser.parse(
          name: 'big.md', mimeType: 'text/markdown', sizeBytes: bytes.length, bytes: bytes);
      expect(a.truncated, isTrue);
      expect(a.text.length, FileParser.maxChars);
    });

    test('flags images as unsupported for text', () {
      final a = parser.parse(
          name: 'pic.png', mimeType: 'image/png', sizeBytes: 4, bytes: Uint8List(4));
      expect(a.isImage, isTrue);
      expect(a.parseError, isNotNull);
    });

    test('reports a clear error for unsupported types', () {
      final a = parser.parse(
          name: 'app.exe',
          mimeType: 'application/octet-stream',
          sizeBytes: 2,
          bytes: Uint8List(2));
      expect(a.parseError, contains('不支持'));
    });
  });

  group('ToolEngine', () {
    test('builds context + numbered citations from results', () async {
      final engine = ToolEngine(_FakeSearch([
        const SearchResult(
            title: 'Dart', url: 'https://dart.dev', content: 'Dart lang'),
        const SearchResult(
            title: 'Flutter', url: 'https://flutter.dev', snippet: 'UI kit'),
      ]));
      final ctx = await engine.runSearch('dart flutter');
      expect(ctx.citations, hasLength(2));
      expect(ctx.citations.first.index, 1);
      expect(ctx.citations[1].url, 'https://flutter.dev');
      expect(ctx.contextText, contains('[1]'));
      expect(ctx.contextText, contains('https://dart.dev'));
    });

    test('returns empty context when there are no results', () async {
      final engine = ToolEngine(_FakeSearch([]));
      final ctx = await engine.runSearch('nothing');
      expect(ctx.isEmpty, isTrue);
    });

    test('skips results without a URL', () async {
      final engine = ToolEngine(_FakeSearch([
        const SearchResult(title: 'No url', url: '', content: 'x'),
        const SearchResult(title: 'Has url', url: 'https://a.com', content: 'y'),
      ]));
      final ctx = await engine.runSearch('q');
      expect(ctx.citations, hasLength(1));
      expect(ctx.citations.single.url, 'https://a.com');
    });
  });

  test('SearchBackend wire round-trips', () {
    for (final b in SearchBackend.values) {
      expect(SearchBackendInfo.fromWire(b.wire), b);
    }
    expect(SearchBackendInfo.fromWire('garbage'), SearchBackend.tavily);
  });

  test('ConversationExport.toMarkdown renders roles, reasoning and sources', () {
    final convo = Conversation(
      title: 'My chat',
      messages: [
        ChatMessage(role: MessageRole.user, content: 'hi'),
        ChatMessage(
          role: MessageRole.assistant,
          content: 'hello [1]',
          reasoning: 'pondered',
          model: 'deepseek-reasoner',
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
  });

  test('regenerate creates a new assistant branch and switches between them',
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
        convo.messages
            .where((m) => m.role == MessageRole.assistant)
            .length,
        2);

    // Switch back to the first branch.
    ctrl.switchBranch(assistant.id, -1);
    convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.activePath.last.content, 'first');
  });

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

  test('Conversation.activePath follows activeChildren and JSON round-trips',
      () {
    final u1 = ChatMessage(role: MessageRole.user, content: 'q');
    final a1 = ChatMessage(
        role: MessageRole.assistant, content: 'a1', parentId: u1.id);
    final a2 = ChatMessage(
        role: MessageRole.assistant, content: 'a2', parentId: u1.id);
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
  });
}

class _FakeSearch implements SearchProvider {
  _FakeSearch(this.results);
  final List<SearchResult> results;
  @override
  Future<List<SearchResult>> search(String query, {int maxResults = 5}) async =>
      results;
}
