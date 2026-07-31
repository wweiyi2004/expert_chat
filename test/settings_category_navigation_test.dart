import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: '测试服务',
      baseUrl: 'https://example.com/v1',
      chatModel: 'test-chat',
      reasonerModel: 'test-chat',
      models: const ['test-chat'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
  }

  @override
  Future<void> setMediaApiConfig(
    MediaApiKind kind,
    MediaApiConfig config,
  ) async {
    final current = state.requireValue;
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(current.copyWith(visionApi: config));
      case MediaApiKind.imageGeneration:
        state = AsyncData(current.copyWith(imageGenerationApi: config));
      case MediaApiKind.tts:
        state = AsyncData(current.copyWith(ttsApi: config));
      case MediaApiKind.asr:
        state = AsyncData(current.copyWith(asrApi: config));
    }
  }

  @override
  Future<void> setMediaApiKey(MediaApiKind kind, String key) async {
    final current = state.requireValue;
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(current.copyWith(visionApiKey: key));
      case MediaApiKind.imageGeneration:
        state = AsyncData(current.copyWith(imageGenerationApiKey: key));
      case MediaApiKind.tts:
        state = AsyncData(current.copyWith(ttsApiKey: key));
      case MediaApiKind.asr:
        state = AsyncData(current.copyWith(asrApiKey: key));
    }
  }
}

/// Opens the settings page with a controlled container so tests can read the
/// controller state directly.
Future<ProviderContainer> pumpSettingsPage(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      settingsControllerProvider.overrideWith(_FakeSettingsController.new),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsPage(asRootTab: true)),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Expands the 云端语音合成 (TTS) card so its fields are available.
Future<void> openTtsCard(WidgetTester tester) async {
  await tester.tap(find.text('能力'));
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView), const Offset(0, -360));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('云端语音合成'));
  await tester.tap(find.text('云端语音合成'));
  await tester.pumpAndSettle();
}

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets('settings categories replace the long single-page list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        ],
        child: const MaterialApp(home: SettingsPage(asRootTab: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'initial model category must not overflow',
    );

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('模型服务'), findsOneWidget);
    expect(find.text('多媒体能力（可选）'), findsNothing);

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'capabilities category must not overflow',
    );

    expect(find.text('模型服务'), findsNothing);
    expect(find.text('多媒体能力（可选）'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('联网搜索'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('联网搜索'), findsOneWidget);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'appearance category must not overflow',
    );

    expect(find.text('多媒体能力（可选）'), findsNothing);
    expect(find.text('流式实时 Markdown'), findsOneWidget);

    await tester.tap(find.text('数据'));
    await tester.pumpAndSettle();
    expect(find.text('启用长期记忆'), findsOneWidget);
    expect(find.text('管理记忆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vision API fields remain stable while focused settings rebuild',
    (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsControllerProvider.overrideWith(
              _FakeSettingsController.new,
            ),
          ],
          child: const MaterialApp(home: SettingsPage(asRootTab: true)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('能力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视觉理解'));
      await tester.pumpAndSettle();

      Finder fieldWithLabel(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );

      final baseUrlField = fieldWithLabel('Base URL');
      final modelField = fieldWithLabel('模型');
      final apiKeyField = fieldWithLabel('API Key');
      expect(baseUrlField, findsOneWidget);
      expect(modelField, findsOneWidget);
      expect(apiKeyField, findsOneWidget);

      await tester.ensureVisible(baseUrlField);
      await tester.pumpAndSettle();
      await tester.tap(baseUrlField);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.enterText(baseUrlField, 'https://vision.example.com/v1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(modelField);
      await tester.pumpAndSettle();
      await tester.tap(modelField);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.enterText(modelField, 'vision-model');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(apiKeyField);
      await tester.pumpAndSettle();
      await tester.tap(apiKeyField);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.enterText(apiKeyField, 'sk-vision-test');
      await tester.pumpAndSettle();
      // The key is persisted only once the debounce pause elapses.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('已启用'), findsOneWidget);
      expect(
        tester.widget<TextField>(baseUrlField).controller?.text,
        'https://vision.example.com/v1',
      );
      expect(
        tester.widget<TextField>(modelField).controller?.text,
        'vision-model',
      );
      expect(
        tester.widget<TextField>(apiKeyField).controller?.text,
        'sk-vision-test',
      );
    },
  );

  testWidgets('cloud TTS configuration includes a persisted voice field', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        ],
        child: const MaterialApp(home: SettingsPage(asRootTab: true)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    // The added cloud-ASR card pushes TTS below the initial viewport.
    await tester.drag(find.byType(ListView), const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('云端语音合成'));
    await tester.tap(find.text('云端语音合成'));
    await tester.pumpAndSettle();

    Finder fieldWithLabel(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

    final baseUrl = fieldWithLabel('Base URL');
    final model = fieldWithLabel('模型');
    final voice = fieldWithLabel('音色 / Voice');
    final apiKey = fieldWithLabel('API Key');
    expect(baseUrl, findsOneWidget);
    expect(model, findsOneWidget);
    expect(voice, findsOneWidget);
    expect(apiKey, findsOneWidget);

    Future<void> setText(Finder field, String value) async {
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.enterText(field, value);
      await tester.pump();
    }

    await setText(baseUrl, 'https://tts.example.com/v1');
    await setText(model, 'tts-model');
    await setText(voice, 'nova');
    await setText(apiKey, 'sk-tts-test');
    // The key is persisted only once the debounce pause elapses.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('已启用'), findsOneWidget);
    expect(tester.widget<TextField>(voice).controller?.text, 'nova');
  });

  testWidgets('media API key edits persist only after a typing pause', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester);
    await openTtsCard(tester);

    // Fill the endpoint fields first so the 已启用 badge hinges on the key
    // being persisted — a live probe for the debounced save.
    final baseUrl = fieldWithLabel('Base URL');
    final model = fieldWithLabel('模型');
    await tester.ensureVisible(baseUrl);
    await tester.enterText(baseUrl, 'https://tts.example.com/v1');
    await tester.ensureVisible(model);
    await tester.enterText(model, 'tts-model');
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsWidgets);

    final apiKeyField = fieldWithLabel('API Key');
    await tester.ensureVisible(apiKeyField);
    await tester.tap(apiKeyField);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await tester.enterText(apiKeyField, 'sk-partial');
    // Only a fraction of the debounce window has elapsed: the intermediate
    // keystroke must not have reached the controller yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      '',
    );
    expect(find.text('已启用'), findsNothing);

    // The settled value lands once the pause elapses.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      'sk-partial',
    );
    expect(find.text('已启用'), findsOneWidget);
  });

  testWidgets(
    'switching TTS protocol off MiMo drops the MiMo-default voice',
    (tester) async {
      final container = await pumpSettingsPage(tester);
      await openTtsCard(tester);

      await tester.ensureVisible(find.text('填入 MiMo 默认配置'));
      await tester.tap(find.text('填入 MiMo 默认配置'));
      await tester.pumpAndSettle();

      final voice = fieldWithLabel('音色 / Voice');
      expect(tester.widget<TextField>(voice).controller?.text, 'mimo_default');

      // Drive the dropdown through its own onChanged callback (tapping the
      // off-screen dropdown is flaky inside a scrolled ListView).
      final protocolDropdown = tester
          .widget<DropdownButtonFormField<SpeechApiProtocol>>(
            find.byType(DropdownButtonFormField<SpeechApiProtocol>),
          );

      // Switch back to OpenAI: the MiMo-default voice must not leak into
      // /audio/speech requests.
      protocolDropdown.onChanged!(SpeechApiProtocol.openAiAudio);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(voice).controller?.text, '');
      expect(
        container.read(settingsControllerProvider).requireValue.ttsApi.voice,
        '',
      );
      // An empty voice means "use the endpoint default": hint the user.
      expect(find.text('将使用默认音色'), findsOneWidget);

      // Switching back to MiMo fills the default voice while empty.
      protocolDropdown.onChanged!(SpeechApiProtocol.mimoChatCompletions);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(voice).controller?.text, 'mimo_default');
    },
  );

  testWidgets('a manually chosen TTS voice survives protocol switches', (
    tester,
  ) async {
    await pumpSettingsPage(tester);
    await openTtsCard(tester);

    final voice = fieldWithLabel('音色 / Voice');
    await tester.ensureVisible(voice);
    await tester.tap(voice);
    await tester.enterText(voice, 'nova');
    await tester.pumpAndSettle();

    // Drive the dropdown through its own onChanged callback (tapping the
    // off-screen dropdown is flaky inside a scrolled ListView).
    final protocolDropdown = tester.widget<DropdownButtonFormField<SpeechApiProtocol>>(
      find.byType(DropdownButtonFormField<SpeechApiProtocol>),
    );

    // To MiMo: the voice is neither empty nor the MiMo default — untouched.
    protocolDropdown.onChanged!(SpeechApiProtocol.mimoChatCompletions);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(voice).controller?.text, 'nova');

    // And back to OpenAI: still untouched.
    protocolDropdown.onChanged!(SpeechApiProtocol.openAiAudio);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(voice).controller?.text, 'nova');
  });

  testWidgets('same-frame TTS field edits both persist instead of overwriting', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester);
    await openTtsCard(tester);

    final baseUrl = fieldWithLabel('Base URL');
    final voice = fieldWithLabel('音色 / Voice');
    await tester.ensureVisible(baseUrl);
    await tester.ensureVisible(voice);

    // Two edits land in the same frame — the second must merge with the
    // first instead of rebuilding from the stale build snapshot. (Calling
    // the onChanged callbacks directly keeps both edits in one frame;
    // enterText would pump between them via showKeyboard.)
    final voiceField = tester.widget<TextField>(voice);
    final baseUrlField = tester.widget<TextField>(baseUrl);
    voiceField.onChanged!('nova');
    baseUrlField.onChanged!('https://same-frame.example/v1');
    await tester.pumpAndSettle();

    final tts = container.read(settingsControllerProvider).requireValue.ttsApi;
    expect(tts.baseUrl, 'https://same-frame.example/v1');
    expect(tts.voice, 'nova');
    // The visible field must not have been reverted by the merge.
    expect(tester.widget<TextField>(voice).controller?.text, 'nova');
  });

  testWidgets('TTS card hints that the default voice will be used when empty', (
    tester,
  ) async {
    await pumpSettingsPage(tester);
    await openTtsCard(tester);

    // The default voice is 'alloy', so no hint shows for a fresh card.
    expect(find.text('将使用默认音色'), findsNothing);

    final voice = fieldWithLabel('音色 / Voice');
    await tester.ensureVisible(voice);
    await tester.tap(voice);
    await tester.enterText(voice, '');
    await tester.pumpAndSettle();
    expect(find.text('将使用默认音色'), findsOneWidget);

    await tester.enterText(voice, 'nova');
    await tester.pumpAndSettle();
    expect(find.text('将使用默认音色'), findsNothing);
  });
}
