import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_endpoint.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_discovery.dart';
import 'package:expert_chat/features/tui_bridge/settings_bridge.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:expert_chat/state/settings_controller.dart';

class _Settings extends SettingsController {
  _Settings(this.profile);
  final ProviderProfile profile;
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [profile],
    activeProfileId: profile.id,
    apiKey: 'synthetic-secret',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'official OpenRouter shorthand gains v1 without changing relay prefixes or queries',
    () {
      expect(
        LlmEndpoint.base('https://openrouter.ai/api'),
        'https://openrouter.ai/api/v1',
      );
      expect(
        LlmEndpoint.base('https://openrouter.ai'),
        'https://openrouter.ai/api/v1',
      );
      expect(
        LlmEndpoint.action('https://openrouter.ai/api', 'models'),
        'https://openrouter.ai/api/v1/models',
      );
      expect(
        LlmEndpoint.base('https://relay.invalid/api'),
        'https://relay.invalid/api',
      );
      expect(
        LlmEndpoint.base('https://openrouter.ai/api?tag=test'),
        'https://openrouter.ai/api/v1?tag=test',
      );
      expect(
        LlmEndpoint.base('https://openrouter.ai/custom/v1'),
        'https://openrouter.ai/custom/v1',
      );
    },
  );
  test(
    'model discovery error messages retain HTTP category but never echo body or keys',
    () {
      for (final status in [401, 403, 404, 429, 503]) {
        final request = RequestOptions(
          path: 'https://synthetic.invalid/models',
          headers: {'Authorization': 'Bearer synthetic-secret'},
        );
        final error = DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: request,
            statusCode: status,
            data: 'synthetic-secret',
          ),
        );
        final message = describeModelDiscoveryError(error);
        expect(message, contains('$status'));
        expect(message, isNot(contains('synthetic-secret')));
      }
    },
  );
  test(
    'provider.scan returns an actionable failure and preserves saved models',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previous);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 404;
        request.response.write('synthetic-secret');
        await request.response.close();
      });
      final profile = ProviderProfile(
        id: 'p',
        name: 'Synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/api',
        models: ['original-model'],
        chatModel: 'original-model',
        reasonerModel: 'original-model',
        apiFormat: LlmApiFormat.openAiCompatible,
      );
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        providerApiKeyStorageKey('p'): 'synthetic-secret',
      });
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          settingsControllerProvider.overrideWith(() => _Settings(profile)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      final bridge = TuiSettingsBridge(container, rememberSecrets: (_) {});
      await expectLater(
        bridge.invoke('provider.scan', {'id': 'p'}),
        throwsA(
          isA<BridgeFailure>()
              .having((e) => e.code, 'code', 'provider_scan_failed')
              .having((e) => e.message, 'message', contains('404')),
        ),
      );
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .profiles
            .single
            .models,
        ['original-model'],
      );
    },
  );
}
