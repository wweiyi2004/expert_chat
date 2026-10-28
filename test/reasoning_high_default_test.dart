import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/settings_storage_keys.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/models.dart'
    show MessageRole, Conversation, ChatMessage;
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/work_agent_runtime.dart';
import 'package:expert_chat/features/chat/widgets/reasoning_effort_control.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart'
    show FakeChatSkillSettings, FakeLlmProvider, InMemoryRepo;

class _ChildCapture implements LlmProvider {
  bool? thinking;
  ReasoningEffort? effort;
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
    this.thinking = thinking;
    effort = reasoningEffort;
    yield const ChatChunk(contentDelta: '已完成');
  }
}

class _SavedLowSettings extends FakeChatSkillSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    reasoningEffort: ReasoningEffort.low,
    hasReasoningEffortOverride: true,
  );
}

class _PlainSettings extends FakeChatSkillSettings {
  _PlainSettings({this.dedicated = false});
  final bool dedicated;
  @override
  Future<SettingsState> build() async {
    final p = ProviderProfile(
      id: 'plain',
      name: 'Plain',
      baseUrl: 'https://plain.invalid/v1',
      chatModel: 'gpt-4o',
      reasonerModel: dedicated ? 'o3-mini' : 'gpt-4o',
      models: dedicated ? ['gpt-4o', 'o3-mini'] : ['gpt-4o'],
      authMode: 'none',
    );
    return (await super.build()).copyWith(
      profiles: [p],
      activeProfileId: p.id,
      selectedModel: null,
      apiKey: '',
    );
  }
}

class _BodyCapture implements HttpClientAdapter {
  Map<String, dynamic> body = {};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    body = jsonDecode(options.data as String) as Map<String, dynamic>;
    return ResponseBody.fromString(
      'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'new state starts thinking High while explicit effort decode stays compatible',
    () {
      for (final value in [null, 'unknown', 'high']) {
        expect(ReasoningEffort.fromWire(value), ReasoningEffort.high);
      }
      expect(const ChatState().reasoningEffort, ReasoningEffort.high);
      expect(const ChatState().deepThink, isTrue);
      expect(ReasoningEffort.fromWire('medium'), ReasoningEffort.medium);
      expect(ReasoningEffort.fromWire('xhigh'), ReasoningEffort.xhigh);
      expect(ReasoningEffort.fromWire('low'), ReasoningEffort.low);
      expect(ReasoningEffort.fromWire('max'), ReasoningEffort.max);
    },
  );

  for (final saved in <ReasoningEffort?>[
    null,
    ReasoningEffort.low,
    ReasoningEffort.max,
  ]) {
    test(
      'settings preserve ${saved?.wire ?? 'missing High default'} and persist later choices',
      () async {
        SharedPreferences.setMockInitialValues({
          if (saved != null) kSettingsReasoningEffort: saved.wire,
        });
        FlutterSecureStorage.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        ProviderContainer create() => ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            secureStorageProvider.overrideWithValue(
              const FlutterSecureStorage(),
            ),
          ],
        );
        final first = create();
        addTearDown(first.dispose);
        final initial = await first.read(settingsControllerProvider.future);
        expect(initial.reasoningEffort, saved ?? ReasoningEffort.high);
        expect(initial.hasReasoningEffortOverride, saved != null);
        final choice = saved == ReasoningEffort.low
            ? ReasoningEffort.max
            : ReasoningEffort.low;
        await first
            .read(settingsControllerProvider.notifier)
            .setReasoningEffort(choice);
        expect(prefs.getString(kSettingsReasoningEffort), choice.wire);
        final second = create();
        addTearDown(second.dispose);
        final restored = await second.read(settingsControllerProvider.future);
        expect(restored.reasoningEffort, choice);
        expect(restored.hasReasoningEffortOverride, isTrue);
      },
    );
  }

  testWidgets(
    'High remains adjustable through the real controller and following requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '完成答复')]);
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(FakeChatSkillSettings.new),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          llmProvider.overrideWithValue(llm),
        ],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) c.dispose();
      });
      await c.read(settingsControllerProvider.future);
      await c.read(chatControllerProvider.future);
      final controller = c.read(chatControllerProvider.notifier);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.high,
      );
      expect(c.read(chatControllerProvider).requireValue.deepThink, isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final chat = ref.watch(chatControllerProvider).requireValue;
                  return ReasoningEffortSlider(
                    thinking: chat.deepThink,
                    effort: chat.reasoningEffort,
                    supportsEffort: true,
                    onToggle: controller.toggleDeepThink,
                    onChanged: controller.setReasoningEffort,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('reasoning-effort-slider')),
            )
            .value,
        2,
      );
      for (final selected in [ReasoningEffort.low, ReasoningEffort.max]) {
        final rect = tester.getRect(
          find.byKey(const ValueKey('reasoning-effort-slider')),
        );
        final value = selected.index + 1;
        await tester.tapAt(
          Offset(
            rect.left + 24 + (rect.width - 48) * value / 3,
            rect.center.dy,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          c.read(chatControllerProvider).requireValue.reasoningEffort,
          selected,
        );
        expect(prefs.getString(kSettingsReasoningEffort), selected.wire);
        await controller.sendMessage('/翻译 hello');
        await tester.pumpAndSettle();
        expect(llm.lastThinking, isTrue);
        expect(llm.lastReasoningEffort, selected);
      }
      controller.toggleDeepThink();
      await controller.sendMessage('/翻译 hello');
      await tester.pumpAndSettle();
      expect(llm.lastThinking, isFalse);
      expect(llm.lastReasoningEffort, isNull);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.max,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      disposed = true;
    },
  );

  testWidgets('models without effort support expose only the thinking switch', (
    tester,
  ) async {
    var enabled = false;
    var effortChanges = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => ReasoningEffortSlider(
              thinking: enabled,
              effort: ReasoningEffort.high,
              supportsEffort: false,
              onToggle: () => update(() => enabled = !enabled),
              onChanged: (_) => effortChanges++,
            ),
          ),
        ),
      ),
    );
    final slider = find.byKey(const ValueKey('reasoning-effort-slider'));
    expect(tester.widget<Slider>(slider).max, 1);
    expect(find.text('高'), findsNothing);
    expect(find.text('最大'), findsNothing);
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.right - 24, rect.center.dy));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(effortChanges, 0);
    expect(find.text('深度思考'), findsOneWidget);
  });

  test(
    'fresh chat and work use enabled High while older off/Low choices stay per session',
    () async {
      SharedPreferences.setMockInitialValues({kSettingsReasoningEffort: 'low'});
      final prefs = await SharedPreferences.getInstance();
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '完整答复')]);
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(_SavedLowSettings.new),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          llmProvider.overrideWithValue(llm),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(settingsControllerProvider.future);
      await c.read(chatControllerProvider.future);
      final ctrl = c.read(chatControllerProvider.notifier);
      final first = c.read(chatControllerProvider).requireValue.currentId!;
      expect(c.read(chatControllerProvider).requireValue.deepThink, isTrue);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.high,
      );
      expect(prefs.getString(kSettingsReasoningEffort), 'low');
      await ctrl.sendMessage('/翻译 hello');
      expect(llm.lastThinking, isTrue);
      expect(llm.lastReasoningEffort, ReasoningEffort.high);
      ctrl.setReasoningEffort(ReasoningEffort.low);
      ctrl.toggleDeepThink();
      for (var i = 0; i < 2; i++) {
        await ctrl.sendMessage('/翻译 hello');
        expect(llm.lastThinking, isFalse);
        expect(llm.lastReasoningEffort, isNull);
      }
      ctrl.newConversation(forceNew: true, workMode: true);
      expect(c.read(chatControllerProvider).requireValue.deepThink, isTrue);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.high,
      );
      await ctrl.sendMessage('只简短说明结果');
      expect(llm.lastThinking, isTrue);
      expect(llm.lastReasoningEffort, ReasoningEffort.high);
      await ctrl.selectConversation(first);
      expect(c.read(chatControllerProvider).requireValue.deepThink, isFalse);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.low,
      );
      ctrl.toggleDeepThink();
      await ctrl.sendMessage('/翻译 hello');
      expect(llm.lastThinking, isTrue);
      expect(llm.lastReasoningEffort, ReasoningEffort.low);
      ctrl.setReasoningEffort(ReasoningEffort.max);
      await ctrl.sendMessage('/翻译 hello');
      expect(llm.lastReasoningEffort, ReasoningEffort.max);
    },
  );

  test(
    'returning to an existing historical session preserves its manual off and Max',
    () async {
      SharedPreferences.setMockInitialValues({kSettingsReasoningEffort: 'low'});
      final prefs = await SharedPreferences.getInstance();
      final repo = InMemoryRepo()
        ..store = [
          Conversation(
            id: 'historical',
            messages: [ChatMessage(role: MessageRole.user, content: '历史消息')],
          ),
        ];
      final llm = FakeLlmProvider([const ChatChunk(contentDelta: '完整答复')]);
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(_SavedLowSettings.new),
          conversationRepositoryProvider.overrideWithValue(repo),
          llmProvider.overrideWithValue(llm),
        ],
      );
      addTearDown(c.dispose);
      await c.read(settingsControllerProvider.future);
      await c.read(chatControllerProvider.future);
      final ctrl = c.read(chatControllerProvider.notifier);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.low,
      );
      ctrl.setReasoningEffort(ReasoningEffort.max);
      ctrl.toggleDeepThink();
      ctrl.newConversation(forceNew: true);
      expect(c.read(chatControllerProvider).requireValue.deepThink, isTrue);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.high,
      );
      await ctrl.selectConversation('historical');
      expect(c.read(chatControllerProvider).requireValue.deepThink, isFalse);
      expect(
        c.read(chatControllerProvider).requireValue.reasoningEffort,
        ReasoningEffort.max,
      );
      await ctrl.sendMessage('/翻译 hello');
      expect(llm.lastThinking, isFalse);
      expect(llm.lastReasoningEffort, isNull);
      ctrl.toggleDeepThink();
      await ctrl.sendMessage('/翻译 hello');
      expect(llm.lastReasoningEffort, ReasoningEffort.max);
    },
  );

  for (final work in [false, true]) {
    for (final auto in [false, true]) {
      test(
        'enabled default keeps ${auto ? 'Auto plain candidate' : 'explicit plain model'} for work=$work',
        () async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final llm = FakeLlmProvider([const ChatChunk(contentDelta: 'ok')]);
          final c = ProviderContainer(
            overrides: [
              sharedPrefsProvider.overrideWithValue(prefs),
              secureStorageProvider.overrideWithValue(
                const FlutterSecureStorage(),
              ),
              settingsControllerProvider.overrideWith(
                () => _PlainSettings(dedicated: !auto),
              ),
              conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
              llmProvider.overrideWithValue(llm),
              desktopWorkspaceHostProvider.overrideWithValue(
                stub.createDesktopWorkspaceHost(),
              ),
            ],
          );
          addTearDown(c.dispose);
          await c.read(settingsControllerProvider.future);
          await c.read(chatControllerProvider.future);
          final ctrl = c.read(chatControllerProvider.notifier);
          ctrl.newConversation(forceNew: true, workMode: work);
          final id = c.read(chatControllerProvider).requireValue.currentId!;
          await c
              .read(conversationModelChoiceProvider.notifier)
              .select(id, auto ? autoModelChoice : 'gpt-4o');
          await ctrl.sendMessage('你好');
          expect(llm.lastConfig?.model, 'gpt-4o');
          expect(llm.lastConfig?.baseUrl, 'https://plain.invalid/v1');
          expect(c.read(chatControllerProvider).requireValue.deepThink, isTrue);
        },
      );
    }
  }

  for (final model in ['deepseek-v4-flash', 'gpt-4o']) {
    test(
      'default enabled High serializes only fields supported by $model',
      () async {
        final adapter = _BodyCapture();
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        await OpenAiCompatibleProvider(dio: dio)
            .streamChat(
              config: LlmConfig(
                baseUrl: 'https://test.invalid/v1',
                apiKey: 'test-only',
                model: model,
              ),
              messages: const [
                LlmRequestMessage(role: MessageRole.user, content: 'hello'),
              ],
              thinking: const ChatState().deepThink,
              reasoningEffort: const ChatState().reasoningEffort,
            )
            .toList();
        if (model.startsWith('deepseek')) {
          expect(adapter.body['thinking'], {'type': 'enabled'});
          expect(adapter.body['reasoning_effort'], 'high');
        } else {
          expect(adapter.body.containsKey('thinking'), isFalse);
          expect(adapter.body.containsKey('reasoning_effort'), isFalse);
        }
      },
    );
  }

  for (final selected in ReasoningEffort.values) {
    test('child requests inherit the parent $selected choice', () async {
      final provider = _ChildCapture();
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final root = runtime.registerRoot(
        conversationId: 'work',
        taskId: 'task',
        task: 'main',
        environment: WorkAgentEnvironment(
          provider: provider,
          config: const LlmConfig(
            baseUrl: 'https://test.invalid',
            apiKey: 'test-only',
            model: 'configured-model',
          ),
          tools: const [],
          executeTool: (_, _, _, _) async => 'ok',
          resolveModel: (requested, parent) async =>
              parent.copyWith(model: requested ?? parent.model),
          thinking: true,
          reasoningEffort: selected,
        ),
      );
      final child = runtime.spawn(parentId: root, task: 'child');
      for (var i = 0; i < 150 && runtime.record(child)?.terminal != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(runtime.record(child)?.terminal, isTrue);
      expect(provider.thinking, isTrue);
      expect(provider.effort, selected);
    });
  }
}
