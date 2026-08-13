import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSettingsController extends SettingsController {
  final Map<SpeechApiProtocol, MediaApiConfig> _ttsConfigs = {};
  final Map<SpeechApiProtocol, String> _ttsKeys = {};

  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: '测试服务',
      baseUrl: 'https://example.com/v1',
      chatModel: 'test-chat',
      reasonerModel: 'test-chat',
      models: const ['test-chat'],
    );
    final initial = SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
    _ttsConfigs[initial.ttsApi.effectiveSpeechProtocol] = initial.ttsApi;
    return initial;
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
        _ttsConfigs[config.effectiveSpeechProtocol] = config;
        state = AsyncData(current.copyWith(ttsApi: config));
      case MediaApiKind.asr:
        state = AsyncData(current.copyWith(asrApi: config));
    }
  }

  @override
  Future<void> setMediaApiKey(MediaApiKind kind, String key) async {
    if (!ref.mounted) return;
    final current = state.requireValue;
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(current.copyWith(visionApiKey: key));
      case MediaApiKind.imageGeneration:
        state = AsyncData(current.copyWith(imageGenerationApiKey: key));
      case MediaApiKind.tts:
        _ttsKeys[current.ttsApi.effectiveSpeechProtocol] = key;
        state = AsyncData(current.copyWith(ttsApiKey: key));
      case MediaApiKind.asr:
        state = AsyncData(current.copyWith(asrApiKey: key));
    }
  }

  @override
  Future<void> setGatewayConfig(GatewayConfig config) async {
    state = AsyncData(state.requireValue.copyWith(gateway: config));
  }

  @override
  Future<void> selectTtsProvider(
    SpeechApiProtocol protocol,
    MediaApiConfig fallback,
  ) async {
    final current = state.requireValue;
    _ttsConfigs[current.ttsApi.effectiveSpeechProtocol] = current.ttsApi;
    _ttsKeys[current.ttsApi.effectiveSpeechProtocol] = current.ttsApiKey;
    state = AsyncData(
      current.copyWith(
        ttsApi: _ttsConfigs[protocol] ?? fallback,
        ttsApiKey: _ttsKeys[protocol] ?? '',
      ),
    );
  }
}

/// Opens the settings page with a controlled container so tests can read the
/// controller state directly.
///
/// [tall] gives the TTS card room for the expanded voice picker (chips +
/// modes) so taps are not clipped by a phone-sized viewport.
Future<ProviderContainer> pumpSettingsPage(
  WidgetTester tester, {
  bool tall = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      settingsControllerProvider.overrideWith(_FakeSettingsController.new),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = tall
      ? const Size(480, 1600)
      : const Size(360, 720);
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
  await tester.scrollUntilVisible(
    find.text('云端语音合成'),
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('云端语音合成'));
  await tester.pumpAndSettle();
  // Expand the card body far enough that voice chips / modes are hittable.
  await tester.scrollUntilVisible(
    find.text('API Key'),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.tap(finder);
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
    expect(find.text('明暗模式'), findsOneWidget);

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

  testWidgets('Gateway exposes a separately persisted file upload URL', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await tester.tap(find.text('能力'));
    tester.view.physicalSize = const Size(480, 4000);
    await tester.pumpAndSettle();

    final uploadUrl = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == '文件上传地址（可选）',
      skipOffstage: false,
    );
    expect(uploadUrl, findsOneWidget);
    await tester.enterText(uploadUrl, 'https://upload.example.com/');
    await tester.pump();

    final gateway = container
        .read(settingsControllerProvider)
        .requireValue
        .gateway;
    expect(gateway.uploadBaseUrl, 'https://upload.example.com/');
    expect(gateway.effectiveUploadBaseUrl, 'https://upload.example.com');
  });

  testWidgets('cloud TTS configuration includes a persisted voice field', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    final baseUrl = fieldWithLabel('Base URL');
    final model = fieldWithLabel('模型');
    final apiKey = fieldWithLabel('API Key');
    expect(baseUrl, findsOneWidget);
    expect(model, findsOneWidget);
    expect(apiKey, findsOneWidget);
    // Built-in OpenAI-compatible chips replace the free-form-only field.
    expect(find.text('Nova'), findsOneWidget);
    expect(find.text('自定义 ID'), findsOneWidget);

    Future<void> setText(Finder field, String value) async {
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.enterText(field, value);
      await tester.pump();
    }

    await setText(baseUrl, 'https://tts.example.com/v1');
    await setText(model, 'tts-model');
    await tapVisible(tester, find.text('Nova'));
    await setText(apiKey, 'sk-tts-test');
    // The key is persisted only once the debounce pause elapses.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('已启用'), findsOneWidget);
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'nova',
    );
  });

  testWidgets('Alibaba TTS preset exposes Qwen and CosyVoice choices', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    await tapVisible(tester, find.text('切换到百炼 TTS'));
    var tts = container.read(settingsControllerProvider).requireValue.ttsApi;
    expect(tts.baseUrl, MediaApiConfig.aliyunModelStudioBaseUrl);
    expect(tts.model, MediaApiConfig.aliyunQwen3TtsModel);
    expect(tts.voice, MediaApiConfig.aliyunQwen3DefaultVoice);
    expect(tts.speechProtocol, SpeechApiProtocol.aliyunModelStudio);
    expect(find.text('Qwen3 性价比'), findsOneWidget);
    expect(find.text('芊悦'), findsOneWidget);
    expect(fieldWithLabel('风格 / 情绪指令（可选）'), findsOneWidget);
    expect(find.textContaining('会分别保存'), findsOneWidget);

    await tapVisible(tester, find.text('Qwen-Audio 低延迟'));
    tts = container.read(settingsControllerProvider).requireValue.ttsApi;
    expect(tts.model, MediaApiConfig.aliyunQwenAudioTtsModel);
    expect(tts.voice, MediaApiConfig.aliyunQwenAudioDefaultVoice);
    expect(find.text('龙安欢'), findsOneWidget);
    expect(find.textContaining('WorkspaceId'), findsOneWidget);

    await tapVisible(tester, find.text('CosyVoice 自定义'));
    tts = container.read(settingsControllerProvider).requireValue.ttsApi;
    expect(tts.model, MediaApiConfig.aliyunCosyVoiceTtsModel);
    expect(tts.voice, isEmpty);
    expect(fieldWithLabel('自定义 Voice ID'), findsOneWidget);
    expect(find.text('当前模型必须填写 Voice ID'), findsOneWidget);
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

  testWidgets('leaving the capabilities page flushes a pending media API key', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester);
    await openTtsCard(tester);

    final baseUrl = fieldWithLabel('Base URL');
    final model = fieldWithLabel('模型');
    await tester.ensureVisible(baseUrl);
    await tester.enterText(baseUrl, 'https://tts.example.com/v1');
    await tester.ensureVisible(model);
    await tester.enterText(model, 'tts-model');
    await tester.pumpAndSettle();

    final apiKeyField = fieldWithLabel('API Key');
    await tester.ensureVisible(apiKeyField);
    await tester.enterText(apiKeyField, 'sk-flush-on-leave');
    // Still inside the debounce window — key is only in the text field.
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      '',
    );

    // "模型" also appears as a field label inside the card, so use a
    // category name that only exists on the segmented control.
    await tester.tap(find.text('外观'));
    // Flush is scheduled on a microtask after dispose.
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      'sk-flush-on-leave',
    );
  });

  testWidgets(
    'pasting a MiMo TTS base URL auto-selects the MiMo speech protocol',
    (tester) async {
      final container = await pumpSettingsPage(tester);
      await openTtsCard(tester);

      final baseUrl = fieldWithLabel('Base URL');
      final model = fieldWithLabel('模型');
      await tester.ensureVisible(baseUrl);
      await tester.enterText(baseUrl, MediaApiConfig.mimoBaseUrl);
      await tester.pumpAndSettle();
      await tester.ensureVisible(model);
      await tester.enterText(model, MediaApiConfig.mimoTtsModel);
      await tester.pumpAndSettle();

      final tts = container
          .read(settingsControllerProvider)
          .requireValue
          .ttsApi;
      expect(tts.speechProtocol, SpeechApiProtocol.mimoChatCompletions);
      expect(tts.voice, MediaApiConfig.mimoDefaultVoice);
      expect(find.textContaining('自动选用'), findsOneWidget);
    },
  );

  testWidgets('switching TTS protocol restores the independent OpenAI voice', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    await tapVisible(tester, find.text('切换到 MiMo TTS'));

    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'mimo_default',
    );
    expect(find.text('MiMo 默认'), findsOneWidget);
    expect(find.text('内置音色'), findsOneWidget);

    // Drive the dropdown through its own onChanged callback (tapping the
    // off-screen dropdown is flaky inside a scrolled ListView).
    final protocolDropdown = tester
        .widget<DropdownButtonFormField<SpeechApiProtocol>>(
          find.byType(DropdownButtonFormField<SpeechApiProtocol>),
        );

    // Switch back to OpenAI: restore that provider's own Alloy profile rather
    // than leaking the MiMo-default voice into /audio/speech requests.
    protocolDropdown.onChanged!(SpeechApiProtocol.openAiAudio);
    await tester.pumpAndSettle();

    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      MediaApiConfig.openAiDefaultVoice,
    );
    expect(find.text('Alloy'), findsOneWidget);

    // Switching back to MiMo fills the default voice while empty.
    protocolDropdown.onChanged!(SpeechApiProtocol.mimoChatCompletions);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'mimo_default',
    );
  });

  testWidgets('TTS providers remember independent voices and keys', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    await tapVisible(tester, find.text('Nova'));
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'nova',
    );

    // Drive the dropdown through its own onChanged callback (tapping the
    // off-screen dropdown is flaky inside a scrolled ListView).
    final protocolDropdown = tester
        .widget<DropdownButtonFormField<SpeechApiProtocol>>(
          find.byType(DropdownButtonFormField<SpeechApiProtocol>),
        );

    final apiKey = fieldWithLabel('API Key');
    await tester.enterText(apiKey, 'openai-key');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // MiMo starts from its own default profile instead of inheriting OpenAI's
    // voice or key.
    protocolDropdown.onChanged!(SpeechApiProtocol.mimoChatCompletions);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      MediaApiConfig.mimoDefaultVoice,
    );
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      '',
    );

    // Pick a custom free-form id that should survive round-trips.
    await tapVisible(tester, find.text('自定义 ID'));
    final customVoice = fieldWithLabel('自定义 Voice ID');
    await tester.enterText(customVoice, 'my-custom-voice');
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithLabel('API Key'), 'mimo-key');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    protocolDropdown.onChanged!(SpeechApiProtocol.openAiAudio);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'nova',
    );
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      'openai-key',
    );

    protocolDropdown.onChanged!(SpeechApiProtocol.mimoChatCompletions);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.voice,
      'my-custom-voice',
    );
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApiKey,
      'mimo-key',
    );
  });

  testWidgets(
    'same-frame TTS field edits both persist instead of overwriting',
    (tester) async {
      final container = await pumpSettingsPage(tester, tall: true);
      await openTtsCard(tester);

      // Leave free-form mode so the custom Voice ID field is mounted.
      await tapVisible(tester, find.text('自定义 ID'));

      final baseUrl = fieldWithLabel('Base URL');
      final voice = fieldWithLabel('自定义 Voice ID');
      await tester.ensureVisible(baseUrl);
      await tester.ensureVisible(voice);

      // Two edits land in the same frame — the second must merge with the
      // first instead of rebuilding from the stale build snapshot. (Calling
      // the onChanged callbacks directly keeps both edits in one frame;
      // enterText would pump between them via showKeyboard.)
      final voiceField = tester.widget<TextField>(voice);
      final baseUrlField = tester.widget<TextField>(baseUrl);
      voiceField.onChanged!('my-custom-voice');
      baseUrlField.onChanged!('https://same-frame.example/v1');
      await tester.pumpAndSettle();

      final tts = container
          .read(settingsControllerProvider)
          .requireValue
          .ttsApi;
      expect(tts.baseUrl, 'https://same-frame.example/v1');
      expect(tts.voice, 'my-custom-voice');
      // The visible field must not have been reverted by the merge.
      expect(
        tester.widget<TextField>(voice).controller?.text,
        'my-custom-voice',
      );
    },
  );

  testWidgets('TTS card hints that the default voice will be used when empty', (
    tester,
  ) async {
    await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    // Fresh card defaults to the Alloy chip — no free-form empty hint yet.
    expect(find.text('将使用默认音色'), findsNothing);

    await tapVisible(tester, find.text('自定义 ID'));
    expect(find.text('将使用默认音色'), findsOneWidget);

    final voice = fieldWithLabel('自定义 Voice ID');
    await tester.enterText(voice, 'nova');
    await tester.pumpAndSettle();
    // nova is a known OpenAI chip, so free-form field (and its empty hint) hide.
    expect(find.text('将使用默认音色'), findsNothing);
    expect(find.text('Nova'), findsOneWidget);
  });

  testWidgets('MiMo TTS modes expose builtin, design and clone controls', (
    tester,
  ) async {
    final container = await pumpSettingsPage(tester, tall: true);
    await openTtsCard(tester);

    await tapVisible(tester, find.text('切换到 MiMo TTS'));

    expect(find.text('内置音色'), findsOneWidget);
    expect(find.text('文案设计'), findsOneWidget);
    expect(find.text('用户音色'), findsOneWidget);
    expect(find.text('冰糖'), findsOneWidget);
    expect(find.text('Chloe'), findsOneWidget);

    await tapVisible(tester, find.text('文案设计'));
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.model,
      MediaApiConfig.mimoTtsDesignModel,
    );
    expect(fieldWithLabel('音色描述（必填）'), findsOneWidget);

    await tapVisible(tester, find.text('用户音色'));
    expect(
      container.read(settingsControllerProvider).requireValue.ttsApi.model,
      MediaApiConfig.mimoTtsCloneModel,
    );
    expect(find.text('上传录音'), findsOneWidget);
  });
}
