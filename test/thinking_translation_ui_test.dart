import 'dart:io';
import 'dart:ui' as ui;

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/features/chat/widgets/thinking_translation_host.dart';
import 'package:expert_chat/features/chat/widgets/work_round_activity.dart';
import 'package:expert_chat/state/reasoning_translation.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'Test',
      baseUrl: 'https://example.test',
      chatModel: 'model-a',
      reasonerModel: 'model-a',
      models: const ['model-a', 'model-b'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      selectedModel: 'model-a',
      apiKey: 'test',
    );
  }
}

class _Translation extends ReasoningTranslation {
  int starts = 0, stops = 0;
  bool partial = false;
  List<String> submitted = [];
  final visible = <String, bool>{};
  @override
  Map<String, ReasoningTranslationState> build() => {};
  @override
  void setVisible(String conversationId, String messageId, bool value) =>
      visible[ReasoningTranslation.key(conversationId, messageId)] = value;
  @override
  void updateSource({
    required String conversationId,
    required String messageId,
    required List<String> segments,
    required bool isStreaming,
  }) {}
  @override
  void start({
    required String conversationId,
    required String messageId,
    required List<String> segments,
    required bool isStreaming,
    String modelChoice = '',
  }) {
    starts++;
    submitted = List.of(segments);
    state = {
      ...state,
      ReasoningTranslation.key(
        conversationId,
        messageId,
      ): ReasoningTranslationState(
        enabled: true,
        modelChoice: modelChoice,
        actualModel: modelChoice.isEmpty ? 'model-a' : modelChoice,
        sources: List.of(segments),
        translatedSegments: {
          for (var i = 0; i < segments.length; i++) i: '第${i + 1}段中文译文。',
        },
        translatedSourceLengths: {
          for (var i = 0; i < segments.length; i++)
            i: partial ? 5 : segments[i].length,
        },
        requestCount: starts,
        inputTokens: 30,
        outputTokens: 15,
      ),
    };
  }

  @override
  void stop(String conversationId, String messageId) {
    stops++;
    final key = ReasoningTranslation.key(conversationId, messageId);
    final previous = state[key];
    if (previous != null) {
      state = {
        ...state,
        key: ReasoningTranslationState(
          modelChoice: previous.modelChoice,
          actualModel: previous.actualModel,
          sources: previous.sources,
          translatedSegments: previous.translatedSegments,
          translatedSourceLengths: previous.translatedSourceLengths,
          requestCount: previous.requestCount,
          inputTokens: previous.inputTokens,
          outputTokens: previous.outputTokens,
        ),
      };
    }
  }
}

Future<void> _capture(WidgetTester tester) async {
  if (!const bool.fromEnvironment('RENDER_TRANSLATION')) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('translation-render')),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/thinking-translation-narrow.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('RENDER_TRANSLATION')) return;
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'explicit translation preserves tool positions and mode switches reuse cached text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          settingsControllerProvider.overrideWith(_Settings.new),
          reasoningTranslationProvider.overrideWith(_Translation.new),
        ],
      );
      addTearDown(container.dispose);
      const source = 'First thought. Second thought.';
      final activity = SearchActivity(
        kind: SearchActivityKind.mcp,
        query: '检查',
        toolName: 'coding_read_file',
        status: SearchActivityStatus.done,
        reasoningOffset: 14,
        reasoningOffsetRecorded: true,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'NotoSansSC', useMaterial3: true),
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('translation-render'),
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: WorkRoundActivity(
                    conversationId: 'c',
                    messageId: 'm',
                    reasoning: source,
                    activities: [activity],
                    running: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final translator =
          container.read(reasoningTranslationProvider.notifier) as _Translation;
      expect(translator.starts, 0);
      expect(
        find.byKey(const ValueKey('thinking-translate-start')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('work-round-toggle')));
      await tester.pumpAndSettle();
      expect(translator.starts, 0);
      await tester.tap(find.byKey(const ValueKey('thinking-translate-start')));
      await tester.pumpAndSettle();
      expect(translator.starts, 1);
      expect(translator.submitted, ['First thought.', 'Second thought.']);
      final first = find.byKey(const ValueKey('thinking-translated-segment-0'));
      final second = find.byKey(
        const ValueKey('thinking-translated-segment-1'),
      );
      final tool = find.textContaining('已读取文件');
      expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(tool).dy));
      expect(
        tester.getTopLeft(tool).dy,
        lessThan(tester.getTopLeft(second).dy),
      );
      await tester.tap(find.byTooltip('思考显示方式'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<ReasoningTranslationView>,
          '对照',
        ),
      );
      await tester.pumpAndSettle();
      expect(translator.starts, 1);
      expect(find.text('First thought.'), findsOneWidget);
      expect(find.text('第1段中文译文。'), findsOneWidget);
      await _capture(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('work-round-collapse-bottom')),
      );
      await tester.pumpAndSettle();
      expect(translator.visible[ReasoningTranslation.key('c', 'm')], false);
      await tester.tap(find.byKey(const ValueKey('work-round-toggle')));
      await tester.pumpAndSettle();
      expect(translator.starts, 1);
      expect(find.text('第1段中文译文。'), findsOneWidget);
    },
  );

  testWidgets(
    'pending original tail is labeled and changing model hides old model translation',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsControllerProvider.overrideWith(_Settings.new),
          reasoningTranslationProvider.overrideWith(_Translation.new),
        ],
      );
      addTearDown(container.dispose);
      final translator =
          container.read(reasoningTranslationProvider.notifier) as _Translation;
      translator.partial = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ThinkingTranslationHost(
                conversationId: 'c',
                messageId: 'm',
                segments: const ['First thought.'],
                isStreaming: false,
                expanded: true,
                builder: (controls, render) => Column(
                  children: [
                    controls,
                    render(0, 'First thought.', const Text('First thought.')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thinking-translate-start')));
      await tester.pumpAndSettle();
      expect(find.text('待翻译原文'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('thinking-untranslated-tail-0')),
            )
            .data,
        ' thought.',
      );
      await tester.tap(
        find.byKey(const ValueKey('thinking-translation-model')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('model-b'));
      await tester.pumpAndSettle();
      expect(translator.starts, 1);
      expect(translator.stops, 1);
      expect(find.text('第1段中文译文。'), findsNothing);
      expect(find.text('First thought.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'waiting for another source chunk remains independently cancellable',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsControllerProvider.overrideWith(_Settings.new),
          reasoningTranslationProvider.overrideWith(_Translation.new),
        ],
      );
      addTearDown(container.dispose);
      final translator =
          container.read(reasoningTranslationProvider.notifier) as _Translation;
      translator.partial = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ThinkingTranslationHost(
                conversationId: 'c',
                messageId: 'm',
                segments: const ['First thought.'],
                isStreaming: true,
                expanded: true,
                builder: (controls, render) => Column(
                  children: [
                    controls,
                    render(0, 'First thought.', const Text('First thought.')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thinking-translate-start')));
      await tester.pumpAndSettle();
      expect(find.text('等待新片段'), findsOneWidget);
      expect(find.text('停止翻译'), findsOneWidget);
      await tester.tap(find.text('停止翻译'));
      await tester.pumpAndSettle();
      expect(translator.stops, 1);
      expect(translator.starts, 1);
      expect(find.text('第1段中文译文。'), findsOneWidget);
      expect(find.text('待翻译原文'), findsOneWidget);
      expect(find.text('等待新片段'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
