import 'dart:convert';

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/jev_config.dart';
import 'package:expert_chat/data/full_backup_service.dart';
import 'package:expert_chat/data/settings_bundle.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  Future<ProviderContainer> create() async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);
    return container;
  }

  test(
    'default off; settings persist with key only in secure storage',
    () async {
      final first = await create();
      expect(
        first.read(settingsControllerProvider).requireValue.jevConfig.enabled,
        isFalse,
      );
      final controller = first.read(settingsControllerProvider.notifier);
      await controller.setJevConfig(
        const JevConfig(enabled: true, minConfidence: 0.8),
      );
      await controller.setJevApiKey('  secret-jev-test  ');
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonEncode({for (final k in prefs.getKeys()) k: prefs.get(k)}),
        isNot(contains('secret-jev-test')),
      );
      expect(
        await const FlutterSecureStorage().read(key: 'jev_api_key'),
        'secret-jev-test',
      );
      final second = await create();
      final restored = second.read(settingsControllerProvider).requireValue;
      expect(restored.jevConfig.enabled, isTrue);
      expect(restored.jevConfig.minConfidence, 0.8);
      expect(restored.jevApiKey, 'secret-jev-test');
      await controller.setJevApiKey('');
      expect(
        await const FlutterSecureStorage().read(key: 'jev_api_key'),
        isNull,
      );
      expect(FullBackupService.preferenceKeys, isNot(contains('jevConfig')));
    },
  );

  test('explicit API settings export/import round trips Jev', () async {
    final container = await create();
    final controller = container.read(settingsControllerProvider.notifier);
    await controller.setJevConfig(
      const JevConfig(enabled: true, model: 'jev-test', minConfidence: 0.7),
    );
    await controller.setJevApiKey('portable-key');
    final raw = await controller.exportSettingsJson();
    expect(SettingsBundle.decode(raw)['jev'], {
      'enabled': true,
      'model': 'jev-test',
      'minConfidence': 0.7,
      'apiKey': 'portable-key',
    });
    await controller.setJevConfig(const JevConfig());
    await controller.setJevApiKey('');
    await controller.importSettingsJson(raw);
    final restored = await container.read(settingsControllerProvider.future);
    expect(restored.jevConfig.enabled, isTrue);
    expect(restored.jevConfig.model, 'jev-test');
    expect(restored.jevApiKey, 'portable-key');
    await controller.importSettingsJson(
      SettingsBundle.encode({'systemPrompt': 'legacy'}),
    );
    expect(
      (await container.read(settingsControllerProvider.future)).jevApiKey,
      'portable-key',
    );
  });

  test('rapid key saves preserve the latest edit', () async {
    final container = await create();
    final controller = container.read(settingsControllerProvider.notifier);
    await Future.wait([
      controller.setJevApiKey('first'),
      controller.setJevApiKey('second'),
    ]);
    expect(
      await const FlutterSecureStorage().read(key: 'jev_api_key'),
      'second',
    );
    expect(
      container.read(settingsControllerProvider).requireValue.jevApiKey,
      'second',
    );
  });

  test('corrupt config disables optional routing', () {
    expect(JevConfig.decode('broken').enabled, isFalse);
    expect(
      JevConfig.decode('{"model":null,"minConfidence":"bad"}').model,
      'jev-latest',
    );
    expect(
      JevConfig.fromJson({'minConfidence': double.nan}).minConfidence,
      0.6,
    );
    expect(JevConfig.fromJson({'minConfidence': 5}).minConfidence, 1);
  });
}
