import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/director_story_setup_draft.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/story/director_prose_styles.dart';
import 'package:expert_chat/domain/story/story_ai_assist.dart';
import 'package:expert_chat/features/story/director_story_setup_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only transitive dependency: used to simulate a failing prefs backend.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Prefs backend whose writes always fail, like a full disk.
class _FailingPrefsStore extends InMemorySharedPreferencesStore {
  _FailingPrefsStore() : super.withData(const {});

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    throw StateError('disk full');
  }
}

class _ReadySettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: '测试模型',
      baseUrl: 'https://example.com/v1',
      chatModel: 'story-model',
      reasonerModel: 'story-model',
      models: const ['story-model'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
  }
}

class _ScriptedLlmProvider implements LlmProvider {
  _ScriptedLlmProvider(this.responses, {this.hangOn});

  final List<String> responses;

  /// Call index whose stream emits once and then stays open until cancelled.
  final int? hangOn;
  final List<List<LlmRequestMessage>> calls = [];

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls.add(List<LlmRequestMessage>.of(messages));
    final index = calls.length - 1;
    final response = responses[index.clamp(0, responses.length - 1)];
    yield ChatChunk(contentDelta: response);
    if (index == hangOn) {
      await Completer<void>().future; // held open until the stream is cancelled
    }
  }
}

class _MemoryConversationRepository implements ConversationRepository {
  final List<Conversation> conversations = [];
  Object? saveError;
  int saveCalls = 0;

  @override
  Future<List<Conversation>> loadAll() async =>
      List<Conversation>.of(conversations);

  @override
  Future<void> saveAll(List<Conversation> next) async {
    conversations
      ..clear()
      ..addAll(next);
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    saveCalls++;
    final error = saveError;
    if (error != null) throw error;
    final index = conversations.indexWhere(
      (candidate) => candidate.id == conversation.id,
    );
    if (index < 0) {
      conversations.insert(0, conversation);
    } else {
      conversations[index] = conversation;
    }
  }

  @override
  Future<void> deleteConversation(String id) async {
    conversations.removeWhere((conversation) => conversation.id == id);
  }
}

const _directorDraftJson = '''
{
  "title": "雾港夜车",
  "outline": "- 夜车驶入被雾封锁的港口\\n- 林澈发现车票上写着自己的死亡日期\\n- 顾舟警告众人雾散前不得下车\\n- 车厢广播念出第一位乘客的秘密\\n- 林澈追查夜车与旧失踪案的关系\\n- 众人在港口遗址找到被隐瞒的名单\\n- 顾舟承认自己曾参与最后一次夜车事故\\n- 林澈迫使夜车在黎明前返回原站",
  "authorNote": "AI 扮演旁白和全部角色，用户只负责导演。",
  "characters": [
    {
      "name": "林澈",
      "description": "正在追查失踪案的记者。",
      "personality": "谨慎、敏锐，不轻易信任陌生人。",
      "scenario": "在夜车上醒来，手中握着一张陌生车票。",
      "firstMes": "这张车票不是我的。",
      "systemPrompt": "保持克制，优先观察细节。"
    },
    {
      "name": "顾舟",
      "description": "知道港口秘密的老船长。",
      "personality": "沉默寡言，背负愧疚。",
      "scenario": "等待夜车带来新的乘客。",
      "firstMes": "雾散之前，没有人能离开。",
      "systemPrompt": "隐瞒港口的核心真相。"
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late _MemoryConversationRepository conversations;
  late _ScriptedLlmProvider llm;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    database = AppDatabase(NativeDatabase.memory());
    conversations = _MemoryConversationRepository();
    llm = _ScriptedLlmProvider(const [
      _directorDraftJson,
      _directorDraftJson,
      '雾气贴着车窗缓慢流动。林澈醒来时，顾舟已经站在车厢尽头。',
    ]);
  });

  tearDown(() async {
    await database.close();
  });

  Widget buildSubject({SharedPreferences? prefsOverride}) {
    return ProviderScope(
      overrides: [
        llmProvider.overrideWithValue(llm),
        conversationRepositoryProvider.overrideWithValue(conversations),
        worldInfoRepositoryProvider.overrideWithValue(
          WorldInfoRepository(database),
        ),
        sharedPrefsProvider.overrideWithValue(prefsOverride ?? prefs),
        settingsControllerProvider.overrideWith(_ReadySettingsController.new),
      ],
      child: const MaterialApp(home: DirectorStorySetupPage()),
    );
  }

  Finder fieldWithLabel(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  testWidgets('director setup stays overflow-free on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('导演故事'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('director-plot-interview')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull, reason: '访谈首屏在 320px 宽窗口不应出现布局溢出');
    await tester.tap(find.byKey(const ValueKey('director-skip-interview')));
    await tester.pumpAndSettle();
    expect(find.text('仅生成方案（先预览再开写）'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '跳过访谈后在 320px 宽窗口不应出现布局溢出');
  });

  Future<void> skipInterview(WidgetTester tester) async {
    final skip = find.byKey(const ValueKey('director-skip-interview'));
    if (skip.evaluate().isNotEmpty) {
      await tester.ensureVisible(skip);
      await tester.pumpAndSettle();
      await tester.tap(skip);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('plot interview composes premise and can open editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('director-plot-interview')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('interview-genre-mystery')),
    );
    await tester.tap(find.byKey(const ValueKey('interview-genre-mystery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('interview-next')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('interview-hook-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('interview-hook-field')),
      '夜车永远到不了站，车票上写着乘客的忌日。',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('interview-next')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('interview-constraint-field')),
      '慢热；禁止提前揭晓真相',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('interview-next')));
    await tester.pumpAndSettle();

    expect(find.textContaining('【主线剧情】'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('interview-confirm-edit')));
    await tester.pumpAndSettle();

    expect(find.text('故事种子'), findsOneWidget);
    final seed = tester
        .widget<TextField>(fieldWithLabel('故事情节 *'))
        .controller
        ?.text;
    expect(seed, contains('夜车永远到不了站'));
    expect(seed, contains('悬疑推理'));
    expect(seed, isNot(contains('慢热')));
    // The selected genre contributes its own style without silently adding
    // the Japanese-light-novel preset.
    await tester.ensureVisible(
      find.byKey(const ValueKey('director-advanced-settings')),
    );
    await tester.tap(find.byKey(const ValueKey('director-advanced-settings')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('director-style-jp_ln')),
          )
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('director-style-mystery_cool')),
          )
          .selected,
      isTrue,
    );
    final requirements = tester
        .widget<TextField>(fieldWithLabel('其它创作要求 / 硬性约束（可选）'))
        .controller
        ?.text;
    expect(requirements, contains('慢热；禁止提前揭晓真相'));
  });

  testWidgets('AI creates local cast and editable outline from a premise', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
    await skipInterview(tester);

    await tester.enterText(
      fieldWithLabel('故事情节 *'),
      '一列夜车驶入被雾封锁的港口，乘客发现车票写着自己的死亡日期。',
    );
    await tester.tap(find.text('仅生成方案（先预览再开写）'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('演绎方案'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('演绎方案'), findsOneWidget);
    expect(find.text('2 位角色'), findsOneWidget);
    expect(find.text('林澈'), findsOneWidget);
    expect(find.text('顾舟'), findsOneWidget);
    expect(find.text('8 个节拍'), findsOneWidget);

    final titleField = fieldWithLabel('故事标题');
    expect(tester.widget<TextField>(titleField).controller?.text, '雾港夜车');

    final outlineField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.helperText == '每个非空行视为一个节拍，演绎时会按顺序推进。',
    );
    expect(outlineField, findsOneWidget);
    expect(
      tester.widget<TextField>(outlineField).controller?.text,
      contains('发现车票上写着自己的死亡日期'),
    );

    await tester.enterText(
      outlineField,
      '- 夜车抵达雾港\n- 林澈与顾舟第一次对峙\n- 导演决定是否相信船长',
    );
    expect(
      tester.widget<TextField>(outlineField).controller?.text,
      contains('导演决定是否相信船长'),
    );
    // Default is fast draft (no strict review); only one LLM call.
    expect(llm.calls, hasLength(1));
    expect(llm.calls.first.last.content, contains('一列夜车驶入被雾封锁的港口'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('setup fields are auto-saved after a short debounce', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
    await skipInterview(tester);

    await tester.enterText(fieldWithLabel('故事情节 *'), '海边小城每到午夜就会倒退一天。');
    await tester.pump(const Duration(milliseconds: 600));

    final saved = DirectorStorySetupDraftStore(prefs).read();
    expect(saved, isNotNull);
    expect(saved!.premise, '海边小城每到午夜就会倒退一天。');
    expect(saved.strictReview, isFalse);
  });

  testWidgets('saved generated plan and manual edits are restored', (
    tester,
  ) async {
    await DirectorStorySetupDraftStore(prefs).save(
      DirectorStorySetupDraft(
        premise: '一列夜车驶入雾港。',
        requirements: '不要提前揭晓真相。',
        styleIds: const ['mystery_cool'],
        beatCount: 6,
        targetTotalChars: 120000,
        strictReview: false,
        generatedDraft: DirectorStoryDraft(
          title: '雾港夜车·修订版',
          outline: '- 抵达雾港\n- 发现死亡车票\n- 追查旧案',
          authorNote: '保持悬念，由导演决定何时揭晓真相。',
          characters: [
            CharacterCardDraft(name: '林澈', description: '记者'),
            CharacterCardDraft(name: '顾舟', description: '船长'),
          ],
        ),
      ),
    );

    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('已恢复上次未完成的故事草稿。'), findsOneWidget);
    expect(
      tester.widget<TextField>(fieldWithLabel('故事情节 *')).controller?.text,
      '一列夜车驶入雾港。',
    );
    expect(find.text('进入聊天 · 写第一场'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('director-advanced-settings')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('director-style-mystery_cool')),
          )
          .selected,
      isTrue,
    );
    await tester.scrollUntilVisible(
      find.text('演绎方案'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fieldWithLabel('故事标题')).controller?.text,
      '雾港夜车·修订版',
    );
    expect(find.text('林澈'), findsOneWidget);
    expect(find.text('顾舟'), findsOneWidget);
    expect(find.text('3 个节拍'), findsOneWidget);
  });

  testWidgets('clear draft resets the editor and removes persisted data', (
    tester,
  ) async {
    await DirectorStorySetupDraftStore(prefs).save(
      const DirectorStorySetupDraft(
        premise: '需要被清空的故事。',
        styleIds: ['web_novel'],
      ),
    );

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('清空草稿'));
    await tester.pumpAndSettle();
    expect(find.text('清空当前草稿？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();

    // Clear returns to the plot interview.
    expect(
      find.byKey(const ValueKey('director-plot-interview')),
      findsOneWidget,
    );
    expect(DirectorStorySetupDraftStore(prefs).read(), isNull);
    expect(find.text('草稿已清空，可以重新开始。'), findsOneWidget);
  });

  testWidgets('starting the first section persists director story metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
    await skipInterview(tester);

    const premise = '一列夜车驶入被雾封锁的港口，乘客发现车票写着自己的死亡日期。';
    await tester.enterText(fieldWithLabel('故事情节 *'), premise);
    await tester.tap(find.text('仅生成方案（先预览再开写）'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      DirectorStorySetupDraftStore(prefs).read(),
      isNotNull,
      reason: '开始故事前，AI 方案应已进入本地草稿',
    );

    await tester.tap(find.text('进入聊天 · 写第一场'));
    await tester.pump();
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectorStorySetupPage)),
    );
    final conversation = container
        .read(chatControllerProvider)
        .requireValue
        .current!;

    expect(conversation.isStory, isTrue);
    expect(conversation.characterId, isNull, reason: '导演不应被绑定为故事中的任何一个角色');
    expect(conversation.localCast.map((card) => card.name), ['林澈', '顾舟']);
    expect(conversation.outline, contains('夜车驶入被雾封锁的港口'));
    expect(conversation.authorNote, contains('用户只负责导演'));
    expect(conversation.authorNote, contains('【故事基准】'));
    expect(conversation.authorNote, contains(premise));
    expect(conversation.plotCursor, anyOf(0, 1));
    // Generate (1) + first section stream (1); strict review off by default.
    expect(llm.calls, hasLength(2));
    expect(
      DirectorStorySetupDraftStore(prefs).read(),
      isNull,
      reason: '故事已经进入会话历史，不应继续恢复创建页草稿',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed generation inputs cannot start an outdated plan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
    await skipInterview(tester);

    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('仅生成方案（先预览再开写）'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    final saved = DirectorStorySetupDraftStore(prefs).read();
    expect(saved?.generationFingerprint, isNotEmpty);

    await tester.enterText(fieldWithLabel('故事情节 *'), '改成一座时间会倒流的海边小城。');
    final startButton = find.widgetWithText(FilledButton, '进入聊天 · 写第一场');
    await tester.ensureVisible(startButton);
    await tester.tap(startButton);
    await tester.pumpAndSettle();

    expect(llm.calls, hasLength(1), reason: '旧方案不应触发第一节生成');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectorStorySetupPage)),
    );
    await container.read(chatControllerProvider.future);
    expect(
      container.read(chatControllerProvider).requireValue.current?.isStory,
      isFalse,
    );
    expect(DirectorStorySetupDraftStore(prefs).read(), isNotNull);
  });

  testWidgets('failed conversation save keeps setup draft recoverable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
    await skipInterview(tester);

    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('仅生成方案（先预览再开写）'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    conversations.saveError = StateError('disk full');

    await tester.tap(find.text('进入聊天 · 写第一场'));
    await tester.pumpAndSettle();

    expect(conversations.saveCalls, greaterThan(0));
    expect(DirectorStorySetupDraftStore(prefs).read(), isNotNull);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectorStorySetupPage)),
    );
    expect(
      container.read(chatControllerProvider).requireValue.current?.isStory,
      isFalse,
      reason: '未持久化的故事不应先发布到内存状态',
    );
  });

  testWidgets('starting the story stops a stream running in another chat', (
    tester,
  ) async {
    llm = _ScriptedLlmProvider(const [
      '这条回复永远写不完……',
      _directorDraftJson,
      _directorDraftJson,
      '雾中传来第一声汽笛。',
    ], hangOn: 0);

    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(DirectorStorySetupPage)),
    );
    final ctrl = container.read(chatControllerProvider.notifier);
    await container.read(chatControllerProvider.future);
    unawaited(ctrl.sendMessage('随便聊聊'));
    await tester.pump();
    expect(
      container.read(chatControllerProvider).requireValue.isStreaming,
      isTrue,
    );

    await skipInterview(tester);
    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('仅生成方案（先预览再开写）'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('进入聊天 · 写第一场'));
    await tester.pump();
    await tester.pumpAndSettle();

    final story = container.read(chatControllerProvider).requireValue.current!;
    expect(story.isStory, isTrue);
    // hang chat (1) + generate draft (1) + first section (1); no strict review.
    expect(llm.calls, hasLength(3), reason: '旧流应被停止，首节生成照常发起');
    expect(story.activePath, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'non-preset beat count and length restore without tripping the input guard',
    (tester) async {
      llm = _ScriptedLlmProvider(const ['雾气贴着车窗缓慢流动。林澈醒来时，顾舟已经站在车厢尽头。']);
      // 节拍数 7 与总字数 9万 都不在页面预设选项中；生成指纹按这两个值计算。
      // Explicitly selected style remains part of the generation fingerprint.
      final jpLnRequirements = DirectorProseStyle.mergeRequirements(
        styleIds: const ['jp_ln'],
      );
      await DirectorStorySetupDraftStore(prefs).save(
        DirectorStorySetupDraft(
          premise: '一列夜车驶入雾港。',
          styleIds: const ['jp_ln'],
          beatCount: 7,
          targetTotalChars: 90000,
          generatedDraft: DirectorStoryDraft(
            title: '雾港夜车',
            outline: '- 夜车抵达雾港\n- 林澈发现死亡车票',
            authorNote: '保持悬念。',
            characters: [CharacterCardDraft(name: '林澈', description: '记者')],
          ),
          generationFingerprint: jsonEncode({
            'premise': '一列夜车驶入雾港。',
            'requirements': jpLnRequirements,
            'beatCount': 7,
            'targetTotalChars': 90000,
            'strictReview': true,
          }),
        ),
      );

      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      // Expand advanced settings so non-preset controls are on-screen.
      await tester.tap(
        find.byKey(const ValueKey('director-advanced-settings')),
      );
      await tester.pumpAndSettle();
      // 非预设的节拍数/字数也必须被恢复，而不是静默回落到默认 8 / 80000。
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<int>),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        7,
      );
      expect(find.text('7 个节拍'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('director-len-120000')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(find.textContaining('目标约 9万'), findsOneWidget);

      // 恢复后的值与生成时一致：开始演绎不应误报「输入已变化」。
      await tester.tap(find.widgetWithText(FilledButton, '进入聊天 · 写第一场'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('已变化'), findsNothing);
      expect(llm.calls, isNotEmpty, reason: '指纹与恢复后的实际值一致时，不应被「输入已变化」拦截');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('draft save failure surfaces a one-time notice', (tester) async {
    // 用写入必失败的 prefs 后端模拟磁盘已满。
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _FailingPrefsStore();
    final failingPrefs = await SharedPreferences.getInstance();

    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject(prefsOverride: failingPrefs));
    await tester.pumpAndSettle();
    await skipInterview(tester);

    await tester.enterText(fieldWithLabel('故事情节 *'), '一段需要被自动保存的故事。');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('草稿保存失败，请检查存储空间。'), findsOneWidget);

    // 提示只弹一次：同一失败周期内继续输入不再重复打扰。
    // SnackBar 需要逐帧驱动：入场动画完成后才开始 4s 展示计时，随后还有退场动画。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('草稿保存失败，请检查存储空间。'), findsNothing);

    await tester.enterText(fieldWithLabel('故事情节 *'), '再改一句。');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('草稿保存失败，请检查存储空间。'), findsNothing);
  });
}
