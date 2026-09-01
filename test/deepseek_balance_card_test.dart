import 'package:dio/dio.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/deepseek_balance_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_usage_store.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('official DeepSeek settings show queried balance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final client = _FakeBalanceClient(
      const DeepSeekBalance(
        isAvailable: true,
        infos: [
          DeepSeekBalanceInfo(
            currency: 'CNY',
            totalBalance: '110.00',
            grantedBalance: '10.00',
            toppedUpBalance: '100.00',
          ),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        settingsControllerProvider.overrideWith(
          _DeepSeekSettingsController.new,
        ),
        modelUsageStoreProvider.overrideWith((ref) => ModelUsageStore(prefs)),
        deepSeekBalanceClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(480, 900);
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

    expect(find.text('DeepSeek 余额'), findsOneWidget);
    expect(find.text('¥110.00'), findsOneWidget);
    expect(find.text('¥100.00'), findsOneWidget);
    expect(find.text('¥10.00'), findsOneWidget);
    expect(client.fetchCount, 1);
  });

  testWidgets('non-DeepSeek settings hide the balance card', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        settingsControllerProvider.overrideWith(_OtherSettingsController.new),
        modelUsageStoreProvider.overrideWith((ref) => ModelUsageStore(prefs)),
        deepSeekBalanceClientProvider.overrideWithValue(
          _FakeBalanceClient(
            const DeepSeekBalance(isAvailable: true, infos: []),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage(asRootTab: true)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek 余额'), findsNothing);
  });
}

class _FakeBalanceClient extends DeepSeekBalanceClient {
  _FakeBalanceClient(this.balance);

  final DeepSeekBalance balance;
  var fetchCount = 0;

  @override
  Future<DeepSeekBalance> fetch({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async {
    fetchCount += 1;
    return balance;
  }
}

class _DeepSeekSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      chatModel: 'deepseek-v4-flash',
      reasonerModel: 'deepseek-v4-pro',
      models: const ['deepseek-v4-flash', 'deepseek-v4-pro'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
      chatSkills: ChatSkillCatalog.factory(),
    );
  }
}

class _OtherSettingsController extends SettingsController {
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
      chatSkills: ChatSkillCatalog.factory(),
    );
  }
}
