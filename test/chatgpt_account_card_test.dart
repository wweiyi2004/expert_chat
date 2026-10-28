import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/auth/chatgpt_auth.dart';
import 'package:expert_chat/features/settings/model_services_panel.dart';
import 'package:expert_chat/state/model_service_credentials.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'account',
        name: 'ChatGPT fixture',
        baseUrl: 'https://api.openai.com/v1',
        chatModel: 'gpt-6.1-sol',
        reasonerModel: 'gpt-6.1-sol',
        models: ['gpt-6.1-sol'],
        authMode: 'chatgpt',
      ),
    ],
    activeProfileId: 'account',
  );
}

class _Auth extends ChatGptAuth {
  _Auth(SharedPreferences prefs, this.record)
    : super(const FlutterSecureStorage(), prefs);
  Map<String, dynamic>? record;
  int refreshes = 0;
  @override
  Future<Map<String, dynamic>?> saved(String id) async => record;
  @override
  Future<String> accessToken(String id) async {
    refreshes++;
    return 'fixture-only';
  }
}

void main() {
  for (final signedIn in [true, false]) {
    testWidgets(
      'subscription card reflects saved account signedIn=$signedIn and refreshes explicitly',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final auth = _Auth(
          prefs,
          signedIn
              ? {
                  'access_token': 'fixture-only',
                  'email': 'fixture@example.invalid',
                  'expires_at': DateTime.now()
                      .add(const Duration(days: 1))
                      .toIso8601String(),
                }
              : null,
        );
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            settingsControllerProvider.overrideWith(_Settings.new),
            chatGptAuthProvider.overrideWithValue(auth),
          ],
        );
        addTearDown(container.dispose);
        await container.read(settingsControllerProvider.future);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const Scaffold(
                body: SingleChildScrollView(child: ModelServicesPanel()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('chatgpt-account-account')),
          findsOneWidget,
        );
        expect(auth.refreshes, 0);
        if (signedIn) {
          expect(
            find.text('ChatGPT · fixture@example.invalid'),
            findsOneWidget,
          );
          expect(find.text('已登录 · 1 个已扫描模型'), findsOneWidget);
          expect(find.text('Continue with ChatGPT'), findsNothing);
          final refresh = find.text('刷新登录状态');
          await tester.ensureVisible(refresh);
          await tester.tap(refresh);
          await tester.pumpAndSettle();
          expect(auth.refreshes, 1);
          expect(find.text('登录凭据有效'), findsOneWidget);
        } else {
          expect(find.text('未登录或登录凭据已移除'), findsOneWidget);
          expect(find.text('Continue with ChatGPT'), findsOneWidget);
          expect(find.text('刷新登录状态'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
