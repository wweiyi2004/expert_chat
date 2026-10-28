import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/settings/model_setup_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

class _ProbeProvider implements LlmProvider {
  final configs = <LlmConfig>[];
  final requests = <List<LlmRequestMessage>>[];

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
    configs.add(config);
    requests.add(messages);
    yield const ChatChunk(contentDelta: 'OK');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, SharedPreferences)> store({
    _ProbeProvider? probe,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        if (probe != null) llmProvider.overrideWithValue(probe),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);
    return (container, prefs);
  }

  test('Gemini normalization retains relay mount names containing models', () {
    const relay = 'https://relay.example/proxy/models-router/v1beta';
    expect(GeminiEndpoint.normalizeGeminiVersionBaseUrl(relay), relay);
    expect(GeminiEndpoint.normalizeOpenAiBaseUrl(relay), '$relay/openai');
    expect(
      GeminiEndpoint.cleanUserInputBaseUrl(
        '$relay/models/gemini-2.5-flash:streamGenerateContent',
      ),
      relay,
    );
    expect(
      GeminiEndpoint.modelEndpoint(
        relay,
        'models/gemini-2.5-flash',
        'streamGenerateContent',
        sse: true,
      ),
      '$relay/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
    );
    expect(
      GeminiEndpoint.normalizeOpenAiBaseUrl(
        'https://relay.example/models-router/v1',
      ),
      'https://relay.example/models-router/v1',
    );
  });

  test(
    'only the Gemini API host selects its native protocol and key authentication',
    () {
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://generativelanguage.googleapis.com',
        ),
        LlmApiFormat.geminiNative,
      );
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://aiplatform.googleapis.com/v1',
        ),
        LlmApiFormat.openAiCompatible,
      );
      expect(
        GeminiEndpoint.normalizeOpenAiBaseUrl(
          'https://storage.googleapis.com/v1',
        ),
        'https://storage.googleapis.com/v1',
      );
      expect(
        GeminiEndpoint.headers(
          'https://generativelanguage.googleapis.com/v1beta',
          ' synthetic-key ',
        ),
        containsPair('x-goog-api-key', 'synthetic-key'),
      );
      expect(
        GeminiEndpoint.headers(
          'https://generativelanguage.googleapis.com/v1beta',
          'synthetic-key',
        ),
        isNot(contains('Authorization')),
      );
      expect(
        GeminiEndpoint.headers('https://relay.example/v1beta', 'relay-token'),
        containsPair('Authorization', 'Bearer relay-token'),
      );
    },
  );

  test(
    'explicit Gemini format survives copy, edits, model switching, export and fresh import',
    () async {
      final (container, prefs) = await store();
      final controller = container.read(settingsControllerProvider.notifier);
      final original = ProviderProfile(
        id: 'native-relay',
        name: 'Gemini relay',
        baseUrl: 'https://relay.example/v1',
        chatModel: 'gemini-2.5-flash',
        reasonerModel: 'gemini-2.5-pro',
        models: ['gemini-2.5-flash', 'gemini-2.5-pro'],
        apiFormat: LlmApiFormat.geminiNative,
      );
      final edited = original.copyWith(name: 'Edited relay');
      expect(edited.apiFormat, LlmApiFormat.geminiNative);
      await controller.saveVerifiedConnection(original, 'synthetic-native-key');
      await controller.updateProfile(edited);
      await controller.apply(selectedModel: 'gemini-2.5-pro');
      await controller.setMediaApiConfig(
        MediaApiKind.vision,
        const MediaApiConfig(
          baseUrl: 'https://vision.example/v1',
          model: 'gemini-2.5-flash',
          apiFormat: LlmApiFormat.geminiNative,
        ),
      );
      final current = container.read(settingsControllerProvider).requireValue;
      expect(current.config.apiFormat, LlmApiFormat.geminiNative);
      expect(current.config.model, 'gemini-2.5-pro');
      expect(current.visionConfig.apiFormat, LlmApiFormat.geminiNative);
      final exported = await controller.exportSettingsJson();
      expect(
        (jsonDecode(exported)['profiles'] as List).singleWhere(
          (p) => p['id'] == original.id,
        )['apiFormat'],
        'geminiNative',
      );
      expect(
        prefs.getKeys().map(prefs.get).join(),
        isNot(contains('synthetic-native-key')),
      );

      final (other, otherPrefs) = await store();
      final importedController = other.read(
        settingsControllerProvider.notifier,
      );
      await importedController.importSettingsJson(exported);
      final imported = other.read(settingsControllerProvider).requireValue;
      expect(imported.active!.id, original.id);
      expect(imported.active!.name, 'Edited relay');
      expect(imported.config.apiFormat, LlmApiFormat.geminiNative);
      expect(imported.config.model, 'gemini-2.5-pro');
      expect(imported.apiKey, 'synthetic-native-key');
      expect(imported.visionConfig.apiFormat, LlmApiFormat.geminiNative);

      final compatible = original.copyWith(
        apiFormat: LlmApiFormat.openAiCompatible,
      );
      await importedController.updateProfile(compatible);
      expect(
        other
            .read(settingsControllerProvider)
            .requireValue
            .config
            .isGeminiNative,
        isFalse,
      );
      await importedController.updateProfile(edited);
      final reloaded = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(otherPrefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(reloaded.dispose);
      expect(
        (await reloaded.read(
          settingsControllerProvider.future,
        )).config.apiFormat,
        LlmApiFormat.geminiNative,
      );
    },
  );

  for (final selectedFormat in [
    LlmApiFormat.geminiNative,
    LlmApiFormat.openAiResponses,
    LlmApiFormat.anthropicMessages,
  ]) {
    testWidgets('setup probes and saves ${selectedFormat.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final probe = _ProbeProvider();
      final (container, prefs) = (await tester.runAsync(
        () => store(probe: probe),
      ))!;
      await tester.runAsync(
        () => container
            .read(settingsControllerProvider.notifier)
            .addProfile(
              ProviderProfile(
                id: 'setup-relay',
                name: 'Relay',
                baseUrl: 'https://relay.example/v1',
                chatModel: 'gemini-2.5-flash',
                reasonerModel: 'gemini-2.5-pro',
                models: ['gemini-2.5-flash', 'gemini-2.5-pro'],
              ),
            ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showModelSetup(context),
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      final format = find.byType(DropdownButtonFormField<LlmApiFormat>);
      await tester.ensureVisible(format);
      await tester.pumpAndSettle();
      await tester.tap(format);
      await tester.pumpAndSettle();
      await tester.tap(find.text(selectedFormat.label).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('setup-key')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('setup-key')),
        'synthetic-setup-key',
      );
      await tester.ensureVisible(find.text('测试连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(probe.configs, hasLength(1));
      expect(probe.configs.single.apiFormat, selectedFormat);
      expect(probe.configs.single.baseUrl, 'https://relay.example/v1');
      expect(probe.requests.single.single.role, MessageRole.user);
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        isEmpty,
      );
      await tester.ensureVisible(find.text('保存并开始对话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并开始对话'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelSetupPage), findsNothing);
      final saved = container.read(settingsControllerProvider).requireValue;
      expect(saved.active!.apiFormat, selectedFormat);
      expect(saved.apiKey, 'synthetic-setup-key');
      expect(
        (jsonDecode(prefs.getString('providerProfiles')!) as List).singleWhere(
          (p) => p['id'] == 'setup-relay',
        )['apiFormat'],
        selectedFormat.wire,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
