import 'dart:convert';

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/composer_modes.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_storage_keys.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/platform/theme_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
// ignore: depend_on_referenced_packages - test-only transitive platform dep
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingWriteStore extends SharedPreferencesStorePlatform {
  _FailingWriteStore({this.returnFalse = false});
  final bool returnFalse;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (returnFalse) return false;
    throw StateError('synthetic write failure');
  }

  @override
  Future<bool> remove(String key) async => true;
  @override
  Future<bool> clear() async => true;
  @override
  Future<Map<String, Object>> getAll() async => {};
}

void main() {
  for (final backend in <String?>[
    null,
    'duckduckgo',
    'provider',
    'deepseek',
    'tavily',
  ]) {
    test(
      'DeepSeek becomes the persisted default from $backend exactly once',
      () async {
        SharedPreferences.setMockInitialValues({
          kSettingsSearchBackend: ?backend,
        });
        final priorSecure = FlutterSecureStoragePlatform.instance;
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
        addTearDown(() => FlutterSecureStoragePlatform.instance = priorSecure);
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            secureStorageProvider.overrideWithValue(
              const FlutterSecureStorage(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final loaded = await container.read(settingsControllerProvider.future);
        expect(loaded.searchBackend, SearchBackend.deepseek);
        // Retain a legacy vendor label as credential provenance; runtime/UI is
        // DeepSeek-only and must not relabel its old key as a DeepSeek key.
        expect(
          prefs.getString(kSettingsSearchBackend),
          backend == 'tavily' ? 'tavily' : 'deepseek',
        );
        expect(prefs.getBool(kSettingsDeepSeekSearchDefaultMigrated), isTrue);
        // Legacy callers cannot reactivate a removed alternate search backend.
        await container
            .read(settingsControllerProvider.notifier)
            .setSearchBackend(SearchBackend.duckduckgo);
        container.invalidate(settingsControllerProvider);
        expect(
          (await container.read(
            settingsControllerProvider.future,
          )).searchBackend,
          SearchBackend.deepseek,
        );
      },
    );
  }

  test('composer preference persistence failures reach the caller', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);
    final settings = await container.read(settingsControllerProvider.future);
    final store = SharedPreferencesStorePlatform.instance;
    addTearDown(() => SharedPreferencesStorePlatform.instance = store);
    SharedPreferencesStorePlatform.instance = _FailingWriteStore();
    final controller = container.read(settingsControllerProvider.notifier);
    await expectLater(
      controller.setSearchMode(settings.searchMode.next),
      throwsStateError,
    );
    await expectLater(
      controller.setImageGenMode(settings.imageGenMode.next),
      throwsStateError,
    );
    SharedPreferencesStorePlatform.instance = _FailingWriteStore(
      returnFalse: true,
    );
    await expectLater(
      controller.setSearchMode(settings.searchMode),
      throwsStateError,
    );
    await expectLater(
      controller.setImageGenMode(settings.imageGenMode),
      throwsStateError,
    );
  });
  for (final entry in {
    'chatSkills': jsonEncode([
      {'id': 'custom', 'prompt': 'preserve me'},
      {'id': 'broken', 'enabled': 'not-a-bool'},
    ]),
    'expertChatGateway': jsonEncode({
      'baseUrl': 'https://example.invalid',
      'enabled': 'not-a-bool',
    }),
  }.entries) {
    test('load keeps malformed ${entry.key} and surfaces the error', () async {
      SharedPreferences.setMockInitialValues({entry.key: entry.value});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(settingsControllerProvider.future),
        throwsFormatException,
      );
      expect(prefs.getString(entry.key), entry.value);
      expect(prefs.getKeys(), {entry.key});
    });
  }
  test(
    'selecting the default effort explicitly persists the override',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });
      final prefs = await SharedPreferences.getInstance();
      ProviderContainer create() => ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      final first = create();
      addTearDown(first.dispose);
      final initial = await first.read(settingsControllerProvider.future);
      expect(initial.hasReasoningEffortOverride, isFalse);
      await first
          .read(settingsControllerProvider.notifier)
          .setReasoningEffort(ReasoningEffort.high);
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .hasReasoningEffortOverride,
        isTrue,
      );
      final second = create();
      addTearDown(second.dispose);
      final restored = await second.read(settingsControllerProvider.future);
      expect(restored.reasoningEffort, ReasoningEffort.high);
      expect(restored.hasReasoningEffortOverride, isTrue);
    },
  );

  test(
    'task budget defaults persist and legacy installs remain custom',
    () async {
      for (final legacy in [false, true]) {
        SharedPreferences.setMockInitialValues(
          legacy ? {'baseUrl': 'https://example.com'} : {},
        );
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
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
        final initial = await first.read(settingsControllerProvider.future);
        expect(
          initial.taskBudget.preset,
          legacy ? TaskBudgetPreset.custom : TaskBudgetPreset.standard,
        );
        first.dispose();
        final second = create();
        final restored = await second.read(settingsControllerProvider.future);
        expect(restored.taskBudget.toJson(), initial.taskBudget.toJson());
        await second
            .read(settingsControllerProvider.notifier)
            .setTaskBudget(TaskBudgetPrefs.forPreset(TaskBudgetPreset.quick));
        expect(
          TaskBudgetPrefs.decode(prefs.getString('taskBudget')).preset,
          TaskBudgetPreset.quick,
        );
        second.dispose();
      }
    },
  );
  test('composer search and image modes default to auto and persist', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.searchMode, SearchMode.auto);
    expect(state.imageGenMode, ImageGenMode.auto);

    await container
        .read(settingsControllerProvider.notifier)
        .setSearchMode(SearchMode.off);
    await container
        .read(settingsControllerProvider.notifier)
        .setImageGenMode(ImageGenMode.always);
    expect(prefs.getString('composerSearchMode'), 'off');
    expect(prefs.getString('composerImageGenMode'), 'always');
    expect(
      container.read(settingsControllerProvider).value!.searchMode,
      SearchMode.off,
    );
    expect(
      container.read(settingsControllerProvider).value!.imageGenMode,
      ImageGenMode.always,
    );
  });

  test(
    'split document and long-task settings migrate into one Gateway',
    () async {
      SharedPreferences.setMockInitialValues({
        'longTaskGateway': jsonEncode({
          'enabled': true,
          'baseUrl': 'https://gateway.example.com',
          'model': 'server-model',
          'pollSeconds': 4,
        }),
        'documentService': jsonEncode({
          'enabled': true,
          'baseUrl': 'https://gateway.example.com',
          'timeoutSeconds': 240,
        }),
      });
      final secureData = <String, String>{
        'long_task_gateway_token': 'unified-token',
        'document_service_token': 'legacy-document-token',
      };
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        secureData,
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(settingsControllerProvider.future);
      expect(state.gateway.baseUrl, 'https://gateway.example.com');
      expect(state.gateway.taskModel, 'server-model');
      expect(state.gateway.taskPollSeconds, 4);
      expect(state.gateway.requestTimeoutSeconds, 240);
      expect(state.gatewayToken, 'unified-token');
      expect(state.gateway.capabilitiesDiscovered, isFalse);
      expect(state.gateway.supports(GatewayCapabilityIds.longTasks), isFalse);
      expect(
        state.gateway.supports(GatewayCapabilityIds.documentEdit),
        isFalse,
      );
      expect(prefs.getString('expertChatGateway'), isNotNull);
      expect(secureData['expert_chat_gateway_token'], 'unified-token');
    },
  );

  test('TTS provider profiles keep independent configs and keys', () async {
    const mimoConfig = MediaApiConfig(
      baseUrl: MediaApiConfig.mimoBaseUrl,
      model: MediaApiConfig.mimoTtsModel,
      voice: '冰糖',
      speechProtocol: SpeechApiProtocol.mimoChatCompletions,
    );
    const aliyunFallback = MediaApiConfig(
      baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
      model: MediaApiConfig.aliyunQwen3TtsModel,
      voice: MediaApiConfig.aliyunQwen3DefaultVoice,
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );
    const customizedAliyun = MediaApiConfig(
      baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
      model: MediaApiConfig.aliyunQwen3TtsModel,
      voice: 'Serena',
      voiceDesignPrompt: '温柔自然',
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );

    SharedPreferences.setMockInitialValues({
      'ttsApi': jsonEncode(mimoConfig.toJson()),
    });
    final secureData = <String, String>{'tts_api_key': 'mimo-secret'};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      secureData,
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final firstContainer = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    var state = await firstContainer.read(settingsControllerProvider.future);
    expect(state.ttsApi.voice, '冰糖');
    expect(state.ttsApiKey, 'mimo-secret');

    final firstController = firstContainer.read(
      settingsControllerProvider.notifier,
    );
    await firstController.selectTtsProvider(
      SpeechApiProtocol.aliyunModelStudio,
      aliyunFallback,
    );
    state = firstContainer.read(settingsControllerProvider).requireValue;
    expect(state.ttsApi, isNot(same(mimoConfig)));
    expect(state.ttsApi.model, MediaApiConfig.aliyunQwen3TtsModel);
    expect(state.ttsApiKey, isEmpty);

    await firstController.setMediaApiConfig(MediaApiKind.tts, customizedAliyun);
    await firstController.setMediaApiKey(MediaApiKind.tts, 'aliyun-secret');

    await firstController.selectTtsProvider(
      SpeechApiProtocol.mimoChatCompletions,
      mimoConfig,
    );
    state = firstContainer.read(settingsControllerProvider).requireValue;
    expect(state.ttsApi.voice, '冰糖');
    expect(state.ttsApiKey, 'mimo-secret');

    await firstController.selectTtsProvider(
      SpeechApiProtocol.aliyunModelStudio,
      aliyunFallback,
    );
    state = firstContainer.read(settingsControllerProvider).requireValue;
    expect(state.ttsApi.voice, 'Serena');
    expect(state.ttsApi.voiceDesignPrompt, '温柔自然');
    expect(state.ttsApiKey, 'aliyun-secret');
    firstContainer.dispose();

    // Recreate the controller to prove this is persistent profile storage,
    // not only an in-memory UI cache.
    final secondContainer = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(secondContainer.dispose);
    state = await secondContainer.read(settingsControllerProvider.future);
    expect(state.ttsApi.voice, 'Serena');
    expect(state.ttsApiKey, 'aliyun-secret');

    await secondContainer
        .read(settingsControllerProvider.notifier)
        .selectTtsProvider(SpeechApiProtocol.mimoChatCompletions, mimoConfig);
    state = secondContainer.read(settingsControllerProvider).requireValue;
    expect(state.ttsApi.voice, '冰糖');
    expect(state.ttsApiKey, 'mimo-secret');
  });

  test(
    'DeepSeek Flash is added once to official profiles without changing selections',
    () async {
      final profiles = [
        for (final url in [
          'https://api.deepseek.com/v1',
          'https://gateway.example/v1',
          'https://api.deepseek.com.example/v1',
        ])
          ProviderProfile(
            id: url,
            name: 'Custom DeepSeek',
            baseUrl: url,
            chatModel: 'deepseek-v4-pro',
            reasonerModel: 'deepseek-v4-pro',
            models: const ['deepseek-v4-pro', 'custom-model'],
          ),
      ];
      SharedPreferences.setMockInitialValues({
        'providerProfiles': jsonEncode(
          profiles.map((p) => p.toJson()).toList(),
        ),
        'activeProfileId': profiles.first.id,
        'selectedModel': 'custom-model',
      });
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });
      final prefs = await SharedPreferences.getInstance();
      for (var load = 0; load < 2; load++) {
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            secureStorageProvider.overrideWithValue(
              const FlutterSecureStorage(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final state = await container.read(settingsControllerProvider.future);
        expect(state.selectedModel, 'custom-model');
        expect(state.profiles.first.chatModel, 'deepseek-v4-pro');
        expect(state.profiles.first.reasonerModel, 'deepseek-v4-pro');
        expect(state.profiles.first.models, [
          'deepseek-v4-pro',
          'custom-model',
          'deepseek-flash',
        ]);
        for (final profile in state.profiles.skip(1)) {
          expect(profile.models, ['deepseek-v4-pro', 'custom-model']);
        }
        final stored = jsonDecode(prefs.getString('providerProfiles')!) as List;
        expect((stored.first as Map)['models'], state.profiles.first.models);
      }
    },
  );

  test(
    'official DeepSeek Flash aliases migrate to the current vision model',
    () async {
      final profile = ProviderProfile(
        id: 'v4-profile',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        chatModel: 'deepseek-v4-flash',
        reasonerModel: 'deepseek-v4-pro',
        models: const ['deepseek-v4-flash', 'deepseek-v4-pro'],
      );
      SharedPreferences.setMockInitialValues({
        'providerProfiles': jsonEncode([profile.toJson()]),
        'activeProfileId': profile.id,
      });
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(settingsControllerProvider.future);
      expect(state.profiles.single.chatModel, 'deepseek-flash');
      expect(state.profiles.single.reasonerModel, 'deepseek-v4-pro');
      expect(state.profiles.single.models, contains('deepseek-flash'));
      expect(
        state.profiles.single.models,
        isNot(contains('deepseek-v4-flash-vision-exp')),
      );
    },
  );

  test(
    'already-migrated profiles delete the verified legacy API key',
    () async {
      final profile = ProviderProfile(
        id: 'migrated-profile',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        chatModel: 'deepseek-v4-flash',
        reasonerModel: 'deepseek-v4-pro',
        models: const ['deepseek-v4-flash', 'deepseek-v4-pro'],
      );
      SharedPreferences.setMockInitialValues({
        'providerProfiles': jsonEncode([profile.toJson()]),
        'activeProfileId': profile.id,
      });
      final secureData = <String, String>{
        'llm_api_key': 'legacy-secret',
        'apikey_${profile.id}': 'legacy-secret',
      };
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        secureData,
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(settingsControllerProvider.future);

      expect(state.apiKey, 'legacy-secret');
      expect(secureData, isNot(contains('llm_api_key')));
      expect(secureData['apikey_${profile.id}'], 'legacy-secret');
    },
  );

  test('out-of-range themeMode value falls back to system, no crash', () async {
    SharedPreferences.setMockInitialValues({'themeMode': 99});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.themeMode, ThemePreference.system);
  });

  test('negative themeMode value falls back to system', () async {
    SharedPreferences.setMockInitialValues({'themeMode': -1});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.themeMode, ThemePreference.system);
  });

  test('wrong-typed uiPrefs field does not wipe the other UI prefs', () async {
    SharedPreferences.setMockInitialValues({
      'uiPrefs': jsonEncode({'textScale': 42, 'density': 'compact'}),
    });
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    // 损坏的 textScale 单独回退默认,健康的 density 保留。
    expect(state.ui.textScale, TextScalePref.medium);
    expect(state.ui.density, DensityPref.compact);
  });

  test('in-range themeMode value is honored', () async {
    SharedPreferences.setMockInitialValues({'themeMode': 2});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.themeMode, ThemePreference.dark);
  });

  test('legacy systemPrompt migrates into the general chat skill', () async {
    SharedPreferences.setMockInitialValues({'systemPrompt': '你是专业助手'});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.chatSkills.skillById('general')?.prompt, '你是专业助手');
    expect(state.chatSkills.skillById('writing'), isNotNull);
    expect(state.systemPrompt, '你是专业助手');
    expect(prefs.getString('chatSkills'), isNotNull);
  });

  test('load persists a newly shipped built-in skill', () async {
    final previous = ChatSkillCatalog([
      for (final skill in ChatSkillCatalog.factory().skills)
        if (skill.id != 'image-prompt') skill,
    ]);
    SharedPreferences.setMockInitialValues({'chatSkills': previous.encode()});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(settingsControllerProvider.future);
    expect(state.chatSkills.skillById('image-prompt')?.prefix, '/生图提示');
    final stored = ChatSkillCatalog.decode(prefs.getString('chatSkills'));
    expect(stored.skillById('image-prompt')?.prefix, '/生图提示');
  });

  test(
    'first load with empty systemPrompt keeps factory out of storage',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(settingsControllerProvider.future);
      final factoryGeneral = ChatSkillCatalog.factory().fallback.prompt;
      expect(state.chatSkills.fallback.prompt, factoryGeneral);
      expect(state.systemPrompt, isEmpty);
      expect(prefs.getString('systemPrompt'), isNull);
      expect(prefs.getString('chatSkills'), isNotNull);
    },
  );

  test(
    'setChatSkills rejects a catalog with no fallback by sanitizing',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      addTearDown(() {
        FlutterSecureStoragePlatform.instance =
            TestFlutterSecureStoragePlatform({});
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      final controller = container.read(settingsControllerProvider.notifier);
      await controller.setChatSkills(
        const ChatSkillCatalog([
          ChatSkill(id: 'only', name: '仅此', when: 'x', prompt: 'y'),
        ]),
      );
      final next = container.read(settingsControllerProvider).requireValue;
      expect(next.chatSkills.fallback.enabled, isTrue);
    },
  );
}
