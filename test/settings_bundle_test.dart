import 'dart:convert';
import 'package:expert_chat/data/ui_prefs.dart';

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/model_token_limits.dart';
import 'package:expert_chat/data/settings_bundle.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

void main() {
  test(
    'legacy Tavily import is retained separately and never reused as unified DeepSeek credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      final secure = TestFlutterSecureStoragePlatform({});
      FlutterSecureStoragePlatform.instance = secure;
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      await container
          .read(settingsControllerProvider.notifier)
          .importSettingsJson(
            SettingsBundle.encode({
              'search': {'backend': 'tavily', 'apiKey': 'tvly-legacy-fixture'},
            }),
          );
      for (var boot = 0; boot < 2; boot++) {
        final loaded = await container.read(settingsControllerProvider.future);
        expect(loaded.searchBackend, SearchBackend.deepseek);
        expect(loaded.searchApiKey, isEmpty);
        expect(secure.data['search_api_key'], 'tvly-legacy-fixture');
        expect(secure.data['deepseek_search_api_key'], isNull);
        container.invalidate(settingsControllerProvider);
      }
    },
  );
  test('decodeUtf8 strips a UTF-8 BOM', () {
    final bom = [0xEF, 0xBB, 0xBF, ...utf8.encode('{"format":"x"}')];
    expect(SettingsBundle.decodeUtf8(bom), '{"format":"x"}');
  });

  test('decode rejects a non-bundle JSON object', () {
    expect(
      () => SettingsBundle.decode('{"hello":1}'),
      throwsA(isA<SettingsBundleException>()),
    );
  });

  test('example template is a valid bundle', () {
    const raw = '''
{
  "format": "expert-chat-settings",
  "version": 1,
  "profiles": [
    {
      "name": "DeepSeek",
      "baseUrl": "https://api.deepseek.com",
      "chatModel": "deepseek-v4-flash",
      "reasonerModel": "deepseek-v4-pro",
      "models": ["deepseek-v4-flash", "deepseek-v4-pro"],
      "apiKey": "sk-filled"
    }
  ]
}
''';
    final decoded = SettingsBundle.decode(raw);
    expect(decoded['format'], SettingsBundle.formatId);
    expect(decoded['profiles'], isA<List>());
  });

  test('media slot strips the local voice-clone path', () {
    const config = MediaApiConfig(
      baseUrl: 'https://api.example.com/v1',
      model: 'tts-1',
      voiceClonePath: r'C:\secret\clone.wav',
    );
    final json = SettingsBundle.mediaToJson(config, 'sk-tts');
    expect(json.containsKey('voiceClonePath'), isFalse);
    expect(json['apiKey'], 'sk-tts');
    final parsed = SettingsBundle.mediaFromJson(json)!;
    expect(parsed.config.voiceClonePath, isEmpty);
    expect(parsed.apiKey, 'sk-tts');
  });

  test('export then import restores API keys on a fresh store', () async {
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

    final controller = container.read(settingsControllerProvider.notifier);
    await container.read(settingsControllerProvider.future);

    final profile = ProviderProfile(
      id: 'profile-a',
      name: '搬家服务商',
      modelLimits: const {
        KnownModels.chat: ModelTokenLimits(
          reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
          reasoningCanBeDisabled: true,
        ),
      },
      baseUrl: 'https://api.moved.example/v1',
      chatModel: KnownModels.chat,
      reasonerModel: KnownModels.reasoner,
      models: KnownModels.all,
    );
    await controller.addProfile(profile);
    await controller.setApiKey('sk-moved');
    await controller.setSearchBackend(SearchBackend.deepseek);
    await controller.setSearchApiKey('sk-deepseek-search-fixture');
    await controller.setGatewayConfig(
      const GatewayConfig(
        enabled: true,
        baseUrl: 'https://gateway.moved.example',
      ),
    );
    await controller.setGatewayToken('gw-moved');
    await controller.setMediaApiConfig(
      MediaApiKind.imageGeneration,
      const MediaApiConfig(
        baseUrl: 'https://image.moved.example/v1',
        model: 'gpt-image-2',
      ),
    );
    await controller.setMediaApiKey(MediaApiKind.imageGeneration, 'sk-image');

    await controller.setUiPrefs(
      const UiPrefs(
        colorTheme: ColorThemePref.dailan,
        workbenchWidth: 704,
        sidebarCollapsedGroups: ['work:local', 'chat:docs'],
      ),
    );
    final exported = await controller.exportSettingsJson();
    final snapshot = jsonDecode(exported) as Map<String, dynamic>;
    expect(snapshot['format'], SettingsBundle.formatId);
    expect(snapshot['gateway']['token'], 'gw-moved');
    expect(snapshot['search']['backend'], SearchBackend.deepseek.wire);
    expect(snapshot['search']['apiKey'], 'sk-deepseek-search-fixture');

    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final otherPrefs = await SharedPreferences.getInstance();
    final other = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(otherPrefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(other.dispose);

    final otherController = other.read(settingsControllerProvider.notifier);
    await other.read(settingsControllerProvider.future);
    await otherController.importSettingsJson(exported);

    final imported = other.read(settingsControllerProvider).value!;
    expect(imported.active?.name, '搬家服务商');
    expect(imported.active!.modelLimits[KnownModels.chat]!.reasoningEfforts, [
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    expect(
      imported.active!.modelLimits[KnownModels.chat]!.reasoningCanBeDisabled,
      true,
    );
    other.invalidate(settingsControllerProvider);
    final rebooted = await other.read(settingsControllerProvider.future);
    expect(
      rebooted.active!.modelLimits[KnownModels.chat]!.toJson(),
      imported.active!.modelLimits[KnownModels.chat]!.toJson(),
    );
    expect(imported.ui.colorTheme, ColorThemePref.dailan);
    expect(imported.ui.workbenchWidth, 704);
    expect(imported.ui.sidebarCollapsedGroups, ['work:local', 'chat:docs']);
    expect(imported.apiKey, 'sk-moved');
    expect(imported.searchBackend, SearchBackend.deepseek);
    expect(imported.searchApiKey, 'sk-deepseek-search-fixture');
    expect(imported.gateway.baseUrl, 'https://gateway.moved.example');
    expect(imported.gatewayLegacyToken, 'gw-moved');
    expect(
      imported.imageGenerationApi.baseUrl,
      'https://image.moved.example/v1',
    );
    expect(imported.imageGenerationApiKey, 'sk-image');
  });

  test(
    'importing a different gateway URL drops leftover OIDC tokens',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
        'expert_chat_gateway_oidc_access_token': 'old-access',
        'expert_chat_gateway_oidc_refresh_token': 'old-refresh',
        'expert_chat_gateway_oidc_expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
        'expert_chat_gateway_oidc_subject': 'sub',
        'expert_chat_gateway_oidc_display_name': 'me',
      });
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

      final controller = container.read(settingsControllerProvider.notifier);
      await container.read(settingsControllerProvider.future);
      expect(
        container.read(settingsControllerProvider).value!.gatewayAuthSession,
        isNotNull,
      );

      await controller.importSettingsJson(
        SettingsBundle.encode({
          'gateway': {
            'enabled': true,
            'baseUrl': 'https://other-gateway.example',
            'token': 'new-token',
          },
        }),
      );

      final imported = container.read(settingsControllerProvider).value!;
      expect(imported.gatewayAuthSession, isNull);
      expect(imported.gateway.baseUrl, 'https://other-gateway.example');
      expect(imported.gateway.capabilitiesDiscovered, isFalse);
      expect(imported.gatewayLegacyToken, 'new-token');
      final secure = container.read(secureStorageProvider);
      expect(
        await secure.read(key: 'expert_chat_gateway_oidc_access_token'),
        isNull,
      );
    },
  );
}
