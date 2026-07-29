import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryConversationRepository implements ConversationRepository {
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
  testWidgets(
    'short window keeps the empty state scroll-safe and composer low',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 320);
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
      expect(
        find.byKey(const ValueKey('chat-empty-state-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-context-usage')),
        findsOneWidget,
      );
      expect(find.byTooltip('上下文预算 251.9K'), findsOneWidget);

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

      // Model chips stay visible; media actions hide behind the “+” tray.
      expect(find.text('深度思考'), findsOneWidget);
      expect(find.text('联网'), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-plus-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-plus-tray')), findsNothing);
      expect(find.byTooltip('语音输入'), findsOneWidget);
      expect(find.byTooltip('发送'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-plus-tray')), findsOneWidget);
      expect(find.text('上传文件'), findsOneWidget);
      expect(find.text('上传图片'), findsOneWidget);
      expect(find.text('图片生成'), findsOneWidget);

      const filterKeys = [
        ValueKey('conversation-mode-filter-all'),
        ValueKey('conversation-mode-filter-chat'),
        ValueKey('conversation-mode-filter-story'),
        ValueKey('conversation-mode-filter-ensemble'),
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
        reason: '四个会话筛选项应保持在同一行',
      );
      for (final rect in filterRects.skip(1)) {
        expect(
          rect.width,
          closeTo(filterRects.first.width, 0.01),
          reason: '四个会话筛选项应等宽',
        );
      }
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
  });
}
