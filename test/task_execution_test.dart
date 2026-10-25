import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Reuse the in-memory fixtures; importing this file does not run its main().
import 'widget_test.dart'
    show
        FakeSettings,
        FakeLlmProvider,
        InMemoryRepo,
        FakeImageGenSettings,
        FakeMediaProvider;
import 'widget_test.dart' show InMemoryLibraryFileStore;

class _Settings extends FakeSettings {
  _Settings(this.budget, {this.images = false});
  final TaskBudgetPrefs budget;
  final bool images;
  @override
  Future<SettingsState> build() async =>
      (await (images ? FakeImageGenSettings().build() : super.build()))
          .copyWith(taskBudget: budget);
}

class _Search implements SearchProvider {
  int calls = 0;
  bool fail = false;
  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async {
    calls++;
    if (fail) throw StateError('offline');
    return [
      SearchResult(
        title: '已保存资料',
        url: 'https://example.com/$calls',
        content: '这是足够长的搜索正文，包含用于验证恢复流程的独特标记：SAVED_EVIDENCE。重复这段文字以确保超过最短正文限制。',
      ),
    ];
  }
}

class _LiveLlm extends FakeLlmProvider {
  _LiveLlm() : super(const []);
  final entered = Completer<void>();
  bool hangFinal = false;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls.add(List.of(messages));
    configs.add(config);
    toolCalls.add(tools);
    if (calls.length == 1) {
      yield const ChatChunk(reasoningDelta: '继续规划');
      entered.complete();
      await cancelToken!.whenCancel;
      return;
    }
    if (hangFinal) {
      await cancelToken!.whenCancel;
      return;
    }
    yield const ChatChunk(contentDelta: '依据已有资料回答');
  }
}

const _searchCall = ChatChunk(
  toolCalls: [
    ToolCall(
      index: 0,
      id: 's1',
      name: 'web_search',
      argumentsJson: '{"query":"test"}',
    ),
  ],
  finishReason: 'tool_calls',
);

class _DelayedStreamCleanupLlm extends FakeLlmProvider {
  _DelayedStreamCleanupLlm() : super(const [ChatChunk(contentDelta: '新答复')]);
  final entered = Completer<void>();
  final cleanupStarted = Completer<void>();
  final cleanupReleased = Completer<void>();
  late final source = StreamController<ChatChunk>(
    onListen: entered.complete,
    onCancel: () {
      cleanupStarted.complete();
      return cleanupReleased.future;
    },
  );

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    if (!entered.isCompleted) return source.stream;
    return super.streamChat(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      forceToolName: forceToolName,
      cancelToken: cancelToken,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> setup(
    LlmProvider llm,
    _Search search, {
    TaskBudgetPrefs budget = const TaskBudgetPrefs(),
    InMemoryRepo? repo,
    FakeMediaProvider? media,
  }) async {
    final engine = ToolEngine(search);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
        sharedPrefsProvider.overrideWithValue(prefs),
        llmProvider.overrideWithValue(llm),
        conversationRepositoryProvider.overrideWithValue(
          repo ?? InMemoryRepo(),
        ),
        settingsControllerProvider.overrideWith(
          () => _Settings(budget, images: media != null),
        ),
        if (media != null) mediaApiProvider.overrideWithValue(media),
        toolEngineFactoryProvider.overrideWithValue(
          ({required backend, apiKey = ''}) => engine,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(chatControllerProvider.future);
    container.read(chatControllerProvider.notifier).setWorkMode(false);
    return container;
  }

  test(
    'stopping the origin waits for cleanup while a new conversation can run',
    () async {
      final llm = _DelayedStreamCleanupLlm();
      final c = await setup(llm, _Search());
      final ctrl = c.read(chatControllerProvider.notifier);
      final first = ctrl.sendMessage('旧问题');
      await llm.entered.future;
      final originId = c.read(chatControllerProvider).requireValue.currentId;
      llm.source.add(const ChatChunk(contentDelta: '已收到的正文'));
      await Future<void>.delayed(Duration.zero);
      ctrl.newConversation();
      final nextId = c.read(chatControllerProvider).requireValue.currentId;
      expect(nextId, isNot(originId));
      var stopped = false;
      final stopping = ctrl
          .stopAndWait(conversationId: originId)
          .then((_) => stopped = true);
      await llm.cleanupStarted.future;
      llm.source.add(const ChatChunk(contentDelta: '迟到的数据'));
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      expect(await ctrl.sendMessage('独立新会话的问题'), isTrue);
      expect(stopped, isFalse);
      llm.cleanupReleased.complete();
      await stopping;
      await first;
      expect(await ctrl.sendMessage('新问题'), isTrue);
      final state = c.read(chatControllerProvider).requireValue;
      expect(state.currentId, nextId);
      expect(state.current!.activePath.last.content, '新答复');
      expect(
        state.conversations
            .firstWhere((c) => c.id == originId)
            .activePath
            .last
            .content,
        '已收到的正文',
      );
      expect(state.error, isNull);
      await llm.source.close();
    },
  );

  test(
    'zero search budget prevents the request and wraps up without tools',
    () async {
      final search = _Search();
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [_searchCall],
          [ChatChunk(contentDelta: '资料不足')],
        ],
      );
      final c = await setup(
        llm,
        search,
        budget: const TaskBudgetPrefs(maxSearches: 0),
      );
      await c.read(chatControllerProvider.notifier).sendMessage('查询资料');
      expect(search.calls, 0);
      expect(llm.calls, hasLength(2));
      expect(llm.toolCalls.last, isNull);
      expect(llm.configs.last.allowReasoningRetry, isFalse);
      expect(c.read(chatControllerProvider).requireValue.isStreaming, isFalse);
    },
  );

  test(
    'saved search results survive JSON and answering does not search again',
    () async {
      final search = _Search();
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [_searchCall],
          [ChatChunk(contentDelta: '原答复')],
          [ChatChunk(contentDelta: '重新整理答复')],
        ],
      );
      final c = await setup(llm, search);
      final ctrl = c.read(chatControllerProvider.notifier);
      await ctrl.sendMessage('查询资料');
      final convo = c.read(chatControllerProvider).requireValue.current!;
      final source = convo.activePath.last;
      final decoded = ChatMessage.fromJson(
        jsonDecode(jsonEncode(source.toJson())),
      );
      expect(
        decoded.searchActivities.single.resultText,
        contains('SAVED_EVIDENCE'),
      );
      expect(decoded.searchActivities.single.startedAt, isNotNull);
      await ctrl.answerFromResults(convo.id, source.id);
      expect(search.calls, 1);
      expect(llm.calls, hasLength(3));
      expect(
        llm.calls.last.map((m) => m.content).join('\n'),
        contains('SAVED_EVIDENCE'),
      );
      expect(llm.toolCalls.last, isNull);
      expect(
        c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .content,
        '重新整理答复',
      );
      expect(
        c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .messages
            .any((m) => m.id == source.id),
        isTrue,
      );
    },
  );

  test(
    'step retry performs only the failed search and prevents duplicate taps',
    () async {
      final search = _Search()..fail = true;
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [_searchCall],
          [ChatChunk(contentDelta: '搜索失败')],
        ],
      );
      final c = await setup(llm, search);
      final ctrl = c.read(chatControllerProvider.notifier);
      await ctrl.sendMessage('查询资料');
      final convo = c.read(chatControllerProvider).requireValue.current!;
      final source = convo.activePath.last;
      final step = source.searchActivities.single;
      expect(step.canRetry, isTrue);
      search.fail = false;
      await Future.wait([
        ctrl.retryTaskStep(convo.id, source.id, step.id),
        ctrl.retryTaskStep(convo.id, source.id, step.id),
      ]);
      expect(search.calls, 2);
      expect(llm.calls, hasLength(2));
      final latest = c
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath
          .last;
      expect(latest.searchActivities.last.retryOfId, step.id);
      expect(latest.searchActivities.last.status, SearchActivityStatus.done);
    },
  );

  test(
    'live finish cancels planning and starts exactly one tool-free answer',
    () async {
      final llm = _LiveLlm();
      final c = await setup(llm, _Search());
      final ctrl = c.read(chatControllerProvider.notifier);
      final sent = ctrl.sendMessage('帮我整理');
      await llm.entered.future;
      final convo = c.read(chatControllerProvider).requireValue.current!;
      ctrl.requestTaskAnswer(convo.id, convo.activePath.last.id);
      await sent;
      expect(llm.calls, hasLength(2));
      expect(llm.toolCalls.last, isNull);
      expect(
        c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .content,
        '依据已有资料回答',
      );
    },
  );

  test('user stop does not turn into a wrap-up request', () async {
    final llm = _LiveLlm();
    final c = await setup(llm, _Search());
    final ctrl = c.read(chatControllerProvider.notifier);
    final sent = ctrl.sendMessage('帮我整理');
    await llm.entered.future;
    await ctrl.stopAndWait();
    await sent;
    expect(llm.calls, hasLength(1));
  });

  testWidgets(
    'whole-turn deadline reaches one final answer even without new chunks',
    (tester) async {
      final llm = _LiveLlm();
      final c = await setup(
        llm,
        _Search(),
        budget: const TaskBudgetPrefs(workSeconds: 30),
      );
      final ctrl = c.read(chatControllerProvider.notifier);
      final sent = ctrl.sendMessage('整理资料');
      await llm.entered.future;
      await tester
          .pump(); // Deliver the queued reasoning chunk before advancing its timer.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      await sent;
      expect(llm.calls, hasLength(2));
      expect(
        c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .content,
        '依据已有资料回答',
      );
    },
  );

  testWidgets('wrap-up without a first answer terminates after 20 seconds', (
    tester,
  ) async {
    final llm = _LiveLlm()..hangFinal = true;
    final c = await setup(
      llm,
      _Search(),
      budget: const TaskBudgetPrefs(workSeconds: 30),
    );
    final ctrl = c.read(chatControllerProvider.notifier);
    final sent = ctrl.sendMessage('整理资料');
    await llm.entered.future;
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(llm.calls, hasLength(2));
    await tester.pump(const Duration(seconds: 21));
    await sent;
    final state = c.read(chatControllerProvider).requireValue;
    expect(state.isStreaming, isFalse);
    expect(state.error, contains('整理答复未及时返回正文'));
    expect(llm.calls, hasLength(2));
  });

  test(
    'image step retry requires confirmation and reuses the optimized prompt',
    () async {
      final media = FakeMediaProvider(failuresRemaining: 1);
      final llm = FakeLlmProvider(const [ChatChunk(contentDelta: '优化后的森林插画')]);
      final c = await setup(llm, _Search(), media: media);
      final ctrl = c.read(chatControllerProvider.notifier);
      if (!c.read(chatControllerProvider).requireValue.deepThink) {
        ctrl.toggleDeepThink();
      }
      await ctrl.generateImage('森林');
      final convo = c.read(chatControllerProvider).requireValue.current!;
      final source = convo.activePath.last;
      final step = source.searchActivities.last;
      expect(step.canRetry, isTrue);
      expect(llm.calls, hasLength(1));
      await ctrl.retryTaskStep(convo.id, source.id, step.id);
      expect(media.prompts, hasLength(1));
      await ctrl.retryTaskStep(
        convo.id,
        source.id,
        step.id,
        confirmedPaidRequest: true,
      );
      expect(media.prompts, hasLength(2));
      expect(llm.calls, hasLength(1));
      expect(media.prompts.last, contains('优化后的森林插画'));
      expect(
        c
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .attachments,
        hasLength(1),
      );
    },
  );

  test(
    'disabled search cannot be re-enabled by replaying a failed step',
    () async {
      final search = _Search()..fail = true;
      final llm = FakeLlmProvider(
        const [],
        scriptedChunks: const [
          [_searchCall],
          [ChatChunk(contentDelta: '失败')],
        ],
      );
      final c = await setup(llm, search);
      final ctrl = c.read(chatControllerProvider.notifier);
      await ctrl.sendMessage('查询');
      final convo = c.read(chatControllerProvider).requireValue.current!;
      final source = convo.activePath.last;
      ctrl.applyComposerPrefs(
        searchMode: SearchMode.off,
        imageGenMode: ImageGenMode.off,
        reasoningEffort: ReasoningEffort.high,
      );
      await ctrl.retryTaskStep(
        convo.id,
        source.id,
        source.searchActivities.single.id,
      );
      expect(search.calls, 1);
      expect(
        c.read(chatControllerProvider).requireValue.error,
        contains('已关闭'),
      );
    },
  );
}
