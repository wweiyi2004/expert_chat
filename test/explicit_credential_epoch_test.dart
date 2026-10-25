import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/model_service_credentials.dart';
import 'package:expert_chat/domain/llm/auth/chatgpt_auth.dart';

class _EpochSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'primary',
        name: 'Primary',
        baseUrl: 'https://unused.invalid',
        chatModel: 'model',
        reasonerModel: 'model',
      ),
      ProviderProfile(
        id: 'inactive',
        name: 'Inactive',
        baseUrl: 'https://unused.invalid',
        chatModel: 'model',
        reasonerModel: 'model',
      ),
    ],
    activeProfileId: 'primary',
    apiKey: 'active-fixture-key',
  );
}

class _Storage extends TestFlutterSecureStoragePlatform {
  _Storage() : super({});
  bool fail = false;
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (fail) throw StateError('synthetic storage failure');
    await super.write(key: key, value: value, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'explicit inactive key epoch advances only after successful write and never persists or tracks token reads',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _Storage();
      FlutterSecureStoragePlatform.instance = storage;
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(_EpochSettings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      final settings = container.read(settingsControllerProvider.notifier);
      final saving = settings.setProfileApiKey(
        'inactive',
        'inactive-fixture-key',
      );
      expect(container.read(explicitCredentialEpochProvider), isEmpty);
      await saving;
      expect(container.read(explicitCredentialEpochProvider), {'inactive': 1});
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        'active-fixture-key',
      );
      expect(
        await settings.exportSettingsJson(),
        isNot(contains('explicitCredentialEpoch')),
      );
      storage.fail = true;
      await expectLater(
        settings.setProfileApiKey('inactive', 'rejected-fixture-key'),
        throwsStateError,
      );
      expect(container.read(explicitCredentialEpochProvider), {'inactive': 1});
      await expectLater(
        settings.setProfileApiKey('primary', 'rejected-active-key'),
        throwsStateError,
      );
      expect(
        container.read(settingsControllerProvider).requireValue.apiKey,
        'active-fixture-key',
      );
      expect(container.read(explicitCredentialEpochProvider), {'inactive': 1});
      storage.fail = false;
      storage.data[ChatGptAuth.key('oauth-fixture')] = jsonEncode({
        'client_id': 'fixture-client',
        'access_token': 'synthetic-access-token',
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      });
      expect(
        await container.read(chatGptAuthProvider).accessToken('oauth-fixture'),
        'synthetic-access-token',
      );
      expect(container.read(explicitCredentialEpochProvider), {'inactive': 1});
      expect(
        prefs.getKeys().any(
          (key) => key.toLowerCase().contains('credentialepoch'),
        ),
        false,
      );
    },
  );
}
