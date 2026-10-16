import 'dart:io';
import 'dart:ui' as ui;

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryConversationRepository
    with ConversationRepositoryViaLoadAll
    implements ConversationRepository {
  @override
  Future<void> deleteConversation(String id) async {}

  @override
  Future<List<Conversation>> loadAll() async => [];

  @override
  Future<void> saveAll(List<Conversation> conversations) async {}

  @override
  Future<void> saveConversation(Conversation conversation) async {}
}

class _LayoutSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    context: ContextPrefs(),
    visionApi: MediaApiConfig(
      baseUrl: 'https://media.example/v1',
      model: 'vision-test',
    ),
    visionApiKey: 'vision-key',
    imageGenerationApi: MediaApiConfig(
      baseUrl: 'https://media.example/v1',
      model: 'image-test',
    ),
    imageGenerationApiKey: 'image-key',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC');
    loader.addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    if (const bool.fromEnvironment('RENDER_MOBILE')) {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  for (final width in [320.0, 360.0, 390.0]) {
    for (final scale in [1.0, 1.24]) {
      testWidgets(
        'managed context keeps work-mode labels visible at $width / $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsControllerProvider.overrideWith(
                  _LayoutSettingsController.new,
                ),
                chatControllerProvider.overrideWith(
                  _ManagedLayoutChatController.new,
                ),
              ],
              child: MaterialApp(
                theme: AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(
                    key: const ValueKey('mobile-render'),
                    child: child!,
                  ),
                ),
                home: const ChatPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final switchFinder = find.byKey(
            const ValueKey('chat-work-mode-switch'),
          );
          final paragraphs = find.descendant(
            of: switchFinder,
            matching: find.byType(RichText),
          );
          expect(paragraphs, findsNWidgets(2));
          for (final element in paragraphs.evaluate()) {
            final paragraph = element.renderObject! as RenderParagraph;
            expect(
              paragraph.size.width,
              greaterThanOrEqualTo(
                paragraph.getMaxIntrinsicWidth(double.infinity) - 0.1,
              ),
            );
          }
          expect(find.text('任务').hitTestable(), findsOneWidget);
          // Mobile chrome reserves the center for the chat/work switch.
          expect(
            find.byKey(const ValueKey('chat-context-usage')),
            findsNothing,
          );
          expect(find.byTooltip('切换提示词预设'), findsOneWidget);
          final input = tester.getRect(
            find.byKey(const ValueKey('composer-text-field')),
          );
          expect(input.width, greaterThan(width - 65));
          if (const bool.fromEnvironment('RENDER_MOBILE')) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('mobile-render')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'output/mobile-chat-${width.toInt()}-$scale.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }
  testWidgets('desktop sidebar unifies workspaces and conversation history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository(),
          ),
          settingsControllerProvider.overrideWith(
            _LayoutSettingsController.new,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 288,
              child: Consumer(
                builder: (context, ref, _) => const ChatWorkspaceSidebar(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Expert Chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-new-chat')), findsOneWidget);
    expect(find.text('资料库'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('学习'), findsOneWidget);
    expect(find.text('创作'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversation-mode-filter')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-mode-filter-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-mode-filter-chat')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short window keeps the empty state scroll-safe and composer low',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1000, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            conversationRepositoryProvider.overrideWithValue(
              _MemoryConversationRepository(),
            ),
            settingsControllerProvider.overrideWith(
              _LayoutSettingsController.new,
            ),
          ],
          child: const MaterialApp(home: ChatPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('chat-empty-state-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-context-usage')), findsOneWidget);
      expect(find.byTooltip('上下文预算 251.9K（发送后显示本轮用量）'), findsOneWidget);

      final composerHeight = tester
          .getSize(find.byKey(const ValueKey('chat-composer')))
          .height;
      expect(composerHeight, lessThan(125));

      // Context usage lives in the AppBar, not the composer tool strip.
      final appBarTop = tester.getTopLeft(find.byType(AppBar)).dy;
      final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
      final contextCenter = tester
          .getCenter(find.byKey(const ValueKey('chat-context-usage')))
          .dy;
      expect(contextCenter, greaterThan(appBarTop));
      expect(contextCenter, lessThan(appBarBottom));

      // Mode chips stay on the strip; tools/MCP live in the “+” tray.
      expect(find.text('深度思考'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-work-mode-switch')),
        findsOneWidget,
      );
      final workSwitchCenter = tester
          .getCenter(find.byKey(const ValueKey('chat-work-mode-switch')))
          .dy;
      expect(workSwitchCenter, greaterThan(appBarTop));
      expect(workSwitchCenter, lessThan(appBarBottom));
      expect(find.text('联网'), findsNothing);
      expect(find.text('配图'), findsNothing);
      expect(find.text('MCP'), findsNothing);
      expect(
        find.byKey(const ValueKey('composer-plus-button')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('composer-plus-tray')), findsNothing);
      expect(find.byTooltip('语音输入'), findsOneWidget);
      expect(find.byTooltip('发送'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-plus-tray')), findsOneWidget);
      expect(find.text('上传文件'), findsOneWidget);
      expect(find.text('上传图片'), findsOneWidget);
      expect(find.text('图片'), findsOneWidget);
      expect(find.text('联网·自动'), findsOneWidget);
      expect(find.text('配图·自动'), findsNothing);
      await tester.tap(find.text('图片'));
      await tester.pumpAndSettle();
      expect(find.text('图片生成'), findsOneWidget);
      expect(find.text('回答配图'), findsOneWidget);
      expect(find.text('自动配图'), findsOneWidget);
      await tester.ensureVisible(find.text('关闭配图'));
      await tester.tap(find.text('关闭配图'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatPage)),
      );
      expect(
        container.read(chatControllerProvider).requireValue.imageGenMode,
        ImageGenMode.off,
      );
      expect(
        container.read(settingsControllerProvider).requireValue.imageGenMode,
        ImageGenMode.off,
      );

      const filterKeys = [
        ValueKey('conversation-mode-filter-all'),
        ValueKey('conversation-mode-filter-chat'),
      ];
      expect(
        find.byKey(const ValueKey('conversation-mode-filter')),
        findsOneWidget,
      );
      final filterRects = [
        for (final key in filterKeys) tester.getRect(find.byKey(key)),
      ];
      expect(
        filterRects.map((rect) => rect.top).toSet(),
        hasLength(1),
        reason: '两个会话筛选项应保持在同一行',
      );
      for (final rect in filterRects.skip(1)) {
        expect(
          rect.width,
          closeTo(filterRects.first.width, 0.01),
          reason: '两个会话筛选项应等宽',
        );
      }
      expect(
        find.byKey(const ValueKey('conversation-mode-filter-story')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('conversation-mode-filter-ensemble')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('conversation-mode-filter-study')),
        findsNothing,
      );
    },
  );

  testWidgets('narrow phone layout does not overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(
            _MemoryConversationRepository(),
          ),
          settingsControllerProvider.overrideWith(
            _LayoutSettingsController.new,
          ),
        ],
        child: const MaterialApp(home: ChatPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('开始一段对话'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-work-mode-switch')), findsOneWidget);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final switchRect = tester.getRect(
      find.byKey(const ValueKey('chat-work-mode-switch')),
    );
    final appBarRect = tester.getRect(find.byType(AppBar));
    expect(appBarRect.overlaps(switchRect), isTrue);

    final titleInAppBar = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('新对话'),
    );
    if (titleInAppBar.evaluate().isNotEmpty) {
      expect(
        tester.getRect(titleInAppBar).overlaps(switchRect),
        isFalse,
        reason: '手机顶栏标题不能和「对话|任务」叠在一起',
      );
    }
  });
}

class _ManagedLayoutChatController extends ChatController {
  @override
  Future<ChatState> build() async {
    final conversation = Conversation(title: '长对话');
    return ChatState(
      conversations: [conversation],
      currentId: conversation.id,
      contextReports: {
        conversation.id: const ContextWindowReport(
          originalTokens: 280000,
          sentTokens: 220000,
          inputBudgetTokens: 251904,
          droppedMessages: 12,
          summaryInjected: true,
        ),
      },
    );
  }
}
