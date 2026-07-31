import 'dart:convert';

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
    expect(state.themeMode, ThemeMode.system);
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
    expect(state.themeMode, ThemeMode.system);
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
    expect(state.themeMode, ThemeMode.dark);
  });
}
