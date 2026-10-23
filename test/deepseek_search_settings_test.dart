import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/state/deepseek_search.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<SettingsState> resolve(
    SettingsState settings,
    Map<String, String> keys,
  ) async {
    final previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      keys,
    );
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    try {
      return await container.read(
        Provider((ref) => resolveDeepSeekSearchSettings(ref, settings)),
      );
    } finally {
      container.dispose();
      FlutterSecureStoragePlatform.instance = previous;
    }
  }

  final gateway = ProviderProfile(
    id: 'gateway',
    name: 'Gateway',
    baseUrl: 'https://gateway.test',
    chatModel: 'deepseek-v4.1-flash',
    reasonerModel: 'deepseek-v4.1-flash',
  );
  final official = ProviderProfile(
    id: 'official',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    chatModel: 'deepseek-flash',
    reasonerModel: 'deepseek-v4-pro',
  );
  test(
    'search can use an inactive official service while the task uses a gateway',
    () async {
      final result = await resolve(
        SettingsState(
          profiles: [gateway, official],
          activeProfileId: gateway.id,
          apiKey: 'gateway-only',
        ),
        {
          'apikey_official': 'official-search-key',
          'apikey_gateway': 'gateway-only',
        },
      );
      expect(result.effectiveSearchBackend, SearchBackend.deepseek);
      expect(result.effectiveSearchApiKey, 'official-search-key');
      expect(result.apiKey, 'gateway-only');
      expect(result.searchConfigured, true);
    },
  );
  test(
    'gateway keys and legacy non-DeepSeek search keys are never sent to official search',
    () async {
      final result = await resolve(
        SettingsState(
          profiles: [gateway],
          activeProfileId: gateway.id,
          apiKey: 'gateway-only',
          searchBackend: SearchBackend.tavily,
          searchApiKey: 'tavily-only',
        ),
        {},
      );
      expect(result.effectiveSearchApiKey, isEmpty);
      expect(result.searchConfigured, false);
    },
  );
  test('explicit official search key takes precedence', () async {
    final result = await resolve(
      SettingsState(
        profiles: [official],
        activeProfileId: official.id,
        apiKey: 'official-model',
        searchApiKey: 'dedicated-search',
      ),
      {'apikey_official': 'official-model'},
    );
    expect(result.effectiveSearchApiKey, 'dedicated-search');
  });
}
