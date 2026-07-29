import 'dart:async';

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
import 'package:expert_chat/domain/story/story_ai_assist.dart';
import 'package:expert_chat/features/story/director_story_setup_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Widget buildSubject() {
    return ProviderScope(
      overrides: [
        llmProvider.overrideWithValue(llm),
        conversationRepositoryProvider.overrideWithValue(conversations),
        worldInfoRepositoryProvider.overrideWithValue(
          WorldInfoRepository(database),
        ),
        sharedPrefsProvider.overrideWithValue(prefs),
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
    expect(find.text('AI 选角并生成大纲'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '导演故事创建页在 320px 宽窗口不应出现布局溢出',
    );
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

    await tester.enterText(
      fieldWithLabel('故事情节 *'),
      '一列夜车驶入被雾封锁的港口，乘客发现车票写着自己的死亡日期。',
    );
    await tester.tap(find.text('AI 选角并生成大纲'));
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
    expect(llm.calls, hasLength(2));
    expect(llm.calls.first.last.content, contains('一列夜车驶入被雾封锁的港口'));
    expect(llm.calls.last.first.content, contains('严格审稿人'));
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

    await tester.enterText(fieldWithLabel('故事情节 *'), '海边小城每到午夜就会倒退一天。');
    await tester.tap(find.byKey(const ValueKey('director-style-jp_ln')));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('director-len-120000')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('director-len-120000')));
    await tester.pump(const Duration(milliseconds: 600));

    final saved = DirectorStorySetupDraftStore(prefs).read();
    expect(saved, isNotNull);
    expect(saved!.premise, '海边小城每到午夜就会倒退一天。');
    expect(saved.styleIds, contains('jp_ln'));
    expect(saved.targetTotalChars, 120000);
    expect(saved.strictReview, isTrue);
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
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('director-style-mystery_cool')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('开始演绎第一节'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('director-strict-review')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('director-strict-review')),
          )
          .value,
      isFalse,
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

    expect(
      tester.widget<TextField>(fieldWithLabel('故事情节 *')).controller?.text,
      isEmpty,
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

    const premise = '一列夜车驶入被雾封锁的港口，乘客发现车票写着自己的死亡日期。';
    await tester.enterText(fieldWithLabel('故事情节 *'), premise);
    await tester.tap(find.text('AI 选角并生成大纲'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      DirectorStorySetupDraftStore(prefs).read(),
      isNotNull,
      reason: '开始故事前，AI 方案应已进入本地草稿',
    );

    await tester.tap(find.text('开始演绎第一节'));
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
    expect(conversation.authorNote, contains('【故事原始情节】'));
    expect(conversation.authorNote, contains(premise));
    expect(conversation.plotCursor, anyOf(0, 1));
    expect(llm.calls, hasLength(3));
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

    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('AI 选角并生成大纲'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    final saved = DirectorStorySetupDraftStore(prefs).read();
    expect(saved?.generationFingerprint, isNotEmpty);

    await tester.enterText(fieldWithLabel('故事情节 *'), '改成一座时间会倒流的海边小城。');
    final startButton = find.widgetWithText(FilledButton, '开始演绎第一节');
    await tester.ensureVisible(startButton);
    await tester.tap(startButton);
    await tester.pumpAndSettle();

    expect(llm.calls, hasLength(2), reason: '旧方案不应触发第一节生成');
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

    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('AI 选角并生成大纲'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    conversations.saveError = StateError('disk full');

    await tester.tap(find.text('开始演绎第一节'));
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

    await tester.enterText(fieldWithLabel('故事情节 *'), '雾港夜车的故事。');
    await tester.tap(find.text('AI 选角并生成大纲'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始演绎第一节'));
    await tester.pump();
    await tester.pumpAndSettle();

    final story = container.read(chatControllerProvider).requireValue.current!;
    expect(story.isStory, isTrue);
    expect(llm.calls, hasLength(4), reason: '旧流应被停止，严格审稿与首节生成照常发起');
    expect(story.activePath, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
