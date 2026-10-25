import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only persistence failure/ordering adapter.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/prioritized_llm_provider.dart';
import 'package:expert_chat/domain/llm/model_credentials_unavailable.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/model_service_credentials.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'capability_evolution_test.dart' show FakeLlm;

final oldProfile = ProviderProfile(
  id: 'paired',
  name: 'Old fixture',
  baseUrl: 'https://old.invalid/v1',
  chatModel: 'gpt-4o',
  reasonerModel: 'gpt-4o',
  models: ['gpt-4o'],
);

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [oldProfile],
    activeProfileId: oldProfile.id,
    apiKey: 'old-fixture-key',
  );
}

class _GatedProfilesStore extends InMemorySharedPreferencesStore {
  _GatedProfilesStore(super.values) : super.withData();
  bool pause = false, fail = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (pause && key == 'flutter.providerProfiles') {
      pause = false;
      entered.complete();
      await release.future;
      if (fail) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'queued key edit bound to old endpoint is rejected after successful endpoint migration',
    () async {
      final initial = {
        'providerProfiles': jsonEncode([oldProfile.toJson()]),
        'activeProfileId': 'paired',
      };
      SharedPreferences.setMockInitialValues(initial);
      final prefs = await SharedPreferences.getInstance();
      final originalStore = SharedPreferencesStorePlatform.instance;
      final store = _GatedProfilesStore({
        for (final entry in initial.entries)
          'flutter.${entry.key}': entry.value,
      });
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(
        () => SharedPreferencesStorePlatform.instance = originalStore,
      );
      final secure = TestFlutterSecureStoragePlatform({
        providerApiKeyStorageKey('paired'): 'old-fixture-key',
      });
      FlutterSecureStoragePlatform.instance = secure;
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      final settings = container.read(settingsControllerProvider.notifier);
      await settings.saveModelService(oldProfile, 'old-fixture-key');
      final updated = oldProfile.copyWith(baseUrl: 'https://new.invalid/v1');
      store.pause = true;
      final saving = settings.saveModelService(updated, 'new-fixture-key');
      await store.entered.future;
      final queued = settings.setProfileApiKey(
        'paired',
        'key-typed-for-old-realm',
      );
      final rejected = expectLater(
        queued,
        throwsA(
          isA<ModelCredentialsUnavailable>().having(
            (e) => e.reason,
            'reason',
            'channel_changed_before_key_save',
          ),
        ),
      );
      store.release.complete();
      await saving;
      await rejected;
      final coherent = await settings.readCurrentProfileCredentials('paired');
      expect(coherent.profile.baseUrl, updated.baseUrl);
      expect(coherent.apiKey, 'new-fixture-key');
      expect(
        secure.data[providerApiKeyStorageKey('paired')],
        'new-fixture-key',
      );
      expect(container.read(explicitCredentialEpochProvider), isEmpty);
    },
  );
  test(
    'interrupted encrypted binding fails closed on startup instead of pairing new key with old endpoint',
    () async {
      SharedPreferences.setMockInitialValues({
        'providerProfiles': jsonEncode([oldProfile.toJson()]),
        'activeProfileId': 'paired',
      });
      final changed = oldProfile.copyWith(baseUrl: 'https://new.invalid/v1');
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
        providerApiKeyStorageKey('paired'): 'new-fixture-key',
        providerCredentialBindingStorageKey('paired'): modelCredentialBinding(
          changed,
          'new-fixture-key',
        ),
      });
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final loaded = await container.read(settingsControllerProvider.future);
      expect(loaded.active!.baseUrl, oldProfile.baseUrl);
      expect(loaded.apiKey, isEmpty);
      await expectLater(
        readCoherentModelService(
          container.read(Provider((ref) => ref)),
          'paired',
        ),
        throwsA(isA<ModelCredentialsUnavailable>()),
      );
    },
  );
  for (final failure in [false, true]) {
    test(
      'paused profile-save ${failure ? 'failure restores old pair' : 'success exposes only new coherent pair'}; no new key reaches old endpoint',
      () async {
        final initial = {
          'providerProfiles': jsonEncode([oldProfile.toJson()]),
          'activeProfileId': 'paired',
        };
        SharedPreferences.setMockInitialValues(initial);
        final prefs = await SharedPreferences.getInstance();
        final originalStore = SharedPreferencesStorePlatform.instance;
        final store = _GatedProfilesStore({
          for (final entry in initial.entries)
            'flutter.${entry.key}': entry.value,
        });
        SharedPreferencesStorePlatform.instance = store;
        addTearDown(
          () => SharedPreferencesStorePlatform.instance = originalStore,
        );
        final secure = TestFlutterSecureStoragePlatform({
          providerApiKeyStorageKey('paired'): 'old-fixture-key',
        });
        FlutterSecureStoragePlatform.instance = secure;
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            settingsControllerProvider.overrideWith(_Settings.new),
          ],
        );
        addTearDown(container.dispose);
        await container.read(settingsControllerProvider.future);
        final settings = container.read(settingsControllerProvider.notifier);
        await settings.saveModelService(oldProfile, 'old-fixture-key');
        final ref = container.read(Provider((ref) => ref));
        final oldSettings = container
            .read(settingsControllerProvider)
            .requireValue;
        final calls = <LlmConfig>[];
        final provider = PrioritizedLlmProvider(
          delegate: FakeLlm((config) async* {
            calls.add(config);
            yield const ChatChunk(contentDelta: 'ok', finishReason: 'stop');
          }),
          candidates: (config) => modelServiceCandidates(ref, config),
          credentials: (config) => resolveModelCredentials(ref, config),
        );
        final original = LlmConfig(
          baseUrl: oldProfile.baseUrl,
          apiKey: 'old-fixture-key',
          model: 'gpt-4o',
          profileId: 'paired',
          routingSessionId: 'coherent-route',
        );
        await provider.streamChat(config: original, messages: []).toList();
        expect(calls, hasLength(1));
        final updated = oldProfile.copyWith(
          name: 'New fixture',
          baseUrl: 'https://new.invalid/v1',
        );
        store.pause = true;
        store.fail = failure;
        final saving = settings.saveModelService(updated, 'new-fixture-key');
        final saveCheck = failure
            ? expectLater(saving, throwsStateError)
            : saving;
        await store.entered.future;
        expect(
          secure.data[providerApiKeyStorageKey('paired')],
          'new-fixture-key',
        );
        expect(
          container
              .read(settingsControllerProvider)
              .requireValue
              .active!
              .baseUrl,
          oldProfile.baseUrl,
        );
        var readReturned = false;
        final reading = readCoherentModelService(ref, 'paired').then((value) {
          readReturned = true;
          return value;
        });
        final continuing = provider
            .streamChat(config: original, messages: [])
            .toList();
        final continueCheck = failure
            ? continuing.then((_) {})
            : expectLater(
                continuing,
                throwsA(isA<ModelCredentialsUnavailable>()),
              );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(readReturned, false);
        expect(calls, hasLength(1));
        store.release.complete();
        await saveCheck;
        await continueCheck;
        final coherent = await reading;
        expect(
          coherent.profile.baseUrl,
          failure ? oldProfile.baseUrl : updated.baseUrl,
        );
        expect(
          coherent.apiKey,
          failure ? 'old-fixture-key' : 'new-fixture-key',
        );
        expect(
          calls.any(
            (call) =>
                call.baseUrl == oldProfile.baseUrl &&
                call.apiKey == 'new-fixture-key',
          ),
          false,
        );
        if (failure) {
          expect(
            prefs.getString('providerProfiles'),
            initial['providerProfiles'],
          );
          expect(
            secure.data[providerApiKeyStorageKey('paired')],
            'old-fixture-key',
          );
          expect(
            secure.data[providerCredentialBindingStorageKey('paired')],
            modelCredentialBinding(oldProfile, 'old-fixture-key'),
          );
        } else {
          await expectLater(
            resolveConversationModel(
              ref,
              'c',
              original,
              work: true,
              images: false,
              thinking: false,
              choiceOverride: 'gpt-4o',
              useChoiceOverride: true,
              settingsOverride: oldSettings,
            ),
            throwsA(isA<ModelCredentialsUnavailable>()),
          );
          final next = original.copyWith(
            baseUrl: coherent.profile.baseUrl,
            apiKey: coherent.apiKey,
          );
          await provider.streamChat(config: next, messages: []).toList();
          expect(calls.last.baseUrl, updated.baseUrl);
          expect(calls.last.apiKey, 'new-fixture-key');
        }
      },
    );
  }
}
