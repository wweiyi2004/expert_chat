import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_credentials_unavailable.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/model_route_groups.dart';

class _LocalModels extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'local',
        name: 'Local fixture',
        baseUrl: 'http://127.0.0.1:1/v1',
        chatModel: 'gpt-text-only',
        reasonerModel: 'gpt-text-only',
        models: ['gpt-text-only', 'gpt-4o'],
        authMode: 'none',
      ),
    ],
    activeProfileId: 'local',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'explicit deleted model or group fails instead of switching to global model; Auto/default stay documented',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          settingsControllerProvider.overrideWith(_LocalModels.new),
        ],
      );
      addTearDown(container.dispose);
      final settings = SettingsState(
        profiles: [
          ProviderProfile(
            id: 'remaining',
            name: 'Remaining service',
            baseUrl: 'http://127.0.0.1:1/v1',
            chatModel: 'gpt-4o',
            reasonerModel: 'gpt-4o',
            models: ['gpt-4o'],
            authMode: 'none',
          ),
        ],
        activeProfileId: 'remaining',
      );
      await container.read(settingsControllerProvider.future);
      final controller = container.read(settingsControllerProvider.notifier);
      // Positive controls must be registered in the CURRENT credential catalog,
      // rather than inventing an override-only profile the coherency gate rejects.
      await controller.saveModelService(settings.profiles.single, '');
      const fallback = LlmConfig(
        baseUrl: 'http://127.0.0.1:1/v1',
        apiKey: '',
        authMode: 'none',
        model: 'gpt-4o',
      );
      Future<LlmConfig> resolve(String? choice) => resolveConversationModel(
        container.read(Provider((ref) => ref)),
        'deleted-selection',
        fallback,
        work: true,
        images: false,
        thinking: false,
        choiceOverride: choice,
        useChoiceOverride: true,
        settingsOverride: settings,
      );
      await expectLater(resolve('gpt-deleted-model'), throwsStateError);
      await expectLater(
        resolve('${modelGroupPrefix}deleted-group'),
        throwsStateError,
      );
      expect((await resolve(autoModelChoice)).model, 'gpt-4o');
      expect((await resolve(null)).model, 'gpt-4o');
      await container.read(modelRouteGroupsProvider.notifier).save([
        const ModelRouteGroup(
          id: 'unavailable',
          name: 'Unavailable',
          models: ['gpt-deleted-model'],
          failover: true,
        ),
      ]);
      await expectLater(
        resolve('${modelGroupPrefix}unavailable'),
        throwsStateError,
      );
      final removed = settings.profiles.single.copyWith(
        name: 'Removed channel',
      );
      final removedProfile = ProviderProfile(
        id: 'removed-channel',
        name: removed.name,
        baseUrl: removed.baseUrl,
        chatModel: removed.chatModel,
        reasonerModel: removed.reasonerModel,
        models: removed.models,
        authMode: 'none',
      );
      await controller.saveModelService(removedProfile, '');
      final stale = SettingsState(
        profiles: [removedProfile],
        activeProfileId: removedProfile.id,
      );
      await controller.deleteProfile(removedProfile.id);
      await expectLater(
        resolveConversationModel(
          container.read(Provider((ref) => ref)),
          'removed-channel-selection',
          fallback,
          work: true,
          images: false,
          thinking: false,
          choiceOverride: 'gpt-4o',
          useChoiceOverride: true,
          settingsOverride: stale,
        ),
        throwsA(
          isA<ModelCredentialsUnavailable>().having(
            (error) => error.reason,
            'reason',
            'channel_removed',
          ),
        ),
      );
    },
  );
  test(
    'Auto image need filters configured models/groups, explicit text choice preserved without image ability',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          settingsControllerProvider.overrideWith(_LocalModels.new),
        ],
      );
      addTearDown(container.dispose);
      final settings = await container.read(settingsControllerProvider.future);
      const fallback = LlmConfig(
        baseUrl: 'http://127.0.0.1:1/v1',
        apiKey: '',
        authMode: 'none',
        model: 'gpt-text-only',
      );
      Future<LlmConfig> resolve(
        String choice, {
        bool images = true,
        LlmConfig base = fallback,
      }) => resolveConversationModel(
        container.read(Provider((ref) => ref)),
        'c',
        base,
        work: true,
        images: images,
        thinking: false,
        choiceOverride: choice,
        useChoiceOverride: true,
        settingsOverride: settings,
      );
      final auto = await resolve(autoModelChoice);
      expect(auto.model, 'gpt-4o');
      expect(auto.capabilities.supportsVision, true);
      await container.read(modelRouteGroupsProvider.notifier).save([
        const ModelRouteGroup(
          id: 'group',
          name: 'Group',
          models: ['gpt-text-only', 'gpt-4o'],
          failover: true,
        ),
      ], autoGroup: 'group');
      final grouped = await resolve(autoModelChoice);
      expect(grouped.model, 'gpt-4o');
      expect(grouped.modelFallbacks, isEmpty);
      final explicit = await resolve(
        'gpt-text-only',
        base: fallback.copyWith(modelFallbacks: [auto]),
      );
      expect(explicit.model, 'gpt-text-only');
      expect(explicit.capabilities.supportsVision, false);
      expect(explicit.modelFallbacks, isEmpty);
    },
  );
}
