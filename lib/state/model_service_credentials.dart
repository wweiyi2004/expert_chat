import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/model_credentials_unavailable.dart';
import '../domain/llm/auth/chatgpt_auth.dart';
import '../domain/llm/auth/kimi_code_auth.dart';
import 'settings_controller.dart';
import 'model_service_routing.dart';
import 'model_context.dart';
import '../data/model_service_credential_snapshot.dart';
export '../data/model_service_credential_snapshot.dart';

Future<ModelServiceCredentialSnapshot> readCoherentModelService(
  Ref ref,
  String profileId,
) => ref
    .read(settingsControllerProvider.notifier)
    .readCurrentProfileCredentials(profileId);

bool modelServiceDescriptorMatches(
  LlmConfig config,
  ModelServiceCredentialSnapshot current,
) {
  final profile = current.profile;
  if (!profile.enabled) return false;
  return profile.baseUrl.replaceFirst(RegExp(r'/+$'), '') ==
          config.baseUrl.replaceFirst(RegExp(r'/+$'), '') &&
      profile.authMode == config.authMode &&
      (profile.models.contains(config.model) ||
          profile.chatModel == config.model ||
          profile.reasonerModel == config.model) &&
      (profile.apiFormat == config.apiFormat ||
          profile.apiFormat == LlmApiFormat.auto ||
          profile.authMode == 'chatgpt' &&
              config.apiFormat == LlmApiFormat.openAiResponses);
}

/// Explicit user key edits only. Ephemeral counters contain no credentials and
/// must not enter settings/backup or change on ordinary OAuth token refresh.
final explicitCredentialEpochProvider =
    NotifierProvider<ExplicitCredentialEpochs, Map<String, int>>(
      ExplicitCredentialEpochs.new,
    );

class ExplicitCredentialEpochs extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => {};
  void bump(String profileId) =>
      state = {...state, profileId: (state[profileId] ?? 0) + 1};
}

final chatGptAuthProvider = Provider<ChatGptAuth>(
  (ref) => ChatGptAuth(
    ref.read(secureStorageProvider),
    ref.read(sharedPrefsProvider),
  ),
);
final kimiCodeAuthProvider=Provider<KimiCodeAuth>((ref)=>KimiCodeAuth(ref.read(secureStorageProvider),ref.read(sharedPrefsProvider)));
Future<LlmConfig> resolveModelCredentials(Ref ref, LlmConfig config) async {
  if (config.profileId != null) {
    final current = await readCoherentModelService(ref, config.profileId!);
    if (!modelServiceDescriptorMatches(config, current)) {
      throw const ModelCredentialsUnavailable('channel_descriptor_changed');
    }
    if (config.authMode == 'apiKey' && current.apiKey != config.apiKey) {
      throw const ModelCredentialsUnavailable(
        'explicit_key_changed_wait_boundary',
      );
    }
  }
  if (config.authMode == 'apiKey' && config.apiKey.trim().isEmpty) {
    throw const ModelCredentialsUnavailable('api_key_missing');
  }
  if (config.authMode == 'chatgpt') {
    if (config.baseUrl.replaceFirst(RegExp(r'/+$'), '') !=
            'https://api.openai.com/v1' ||
        config.profileId == null) {
      throw StateError('ChatGPT 登录凭据只能用于官方服务');
    }
    return config.copyWith(
      apiKey: await ref
          .read(chatGptAuthProvider)
          .accessToken(config.profileId!),
      apiFormat: LlmApiFormat.openAiResponses,
    );
  }
  if(config.authMode=='kimiCode'){
    if(config.profileId==null||!KimiCodeAuth.accepts(config.baseUrl))throw StateError('Kimi 登录凭据仅用于 Kimi Code 官方服务');
    return config.copyWith(apiKey:await ref.read(kimiCodeAuthProvider).accessToken(config.profileId!));
  }
  return config.authMode == 'none' ? config.copyWith(apiKey: '') : config;
}

Future<List<LlmConfig>> modelServiceCandidates(
  Ref ref,
  LlmConfig config,
) async {
  if (config.profileId == null) return [config];
  await ref.read(settingsControllerProvider.notifier).waitForProfileMutations();
  final settings = ref.read(settingsControllerProvider).value;
  if (settings == null) return [config];
  final profiles = servicesForModel(
    config.model,
    config.lockProfile
        ? settings.profiles.where((p) => p.id == config.profileId).toList()
        : settings.profiles,
    ref.read(modelServiceRoutingProvider),
  );
  if (profiles.isEmpty) {
    throw const ModelCredentialsUnavailable('model_channels_removed');
  }
  if (!ref.read(modelServiceRoutingProvider).containsKey(config.model)) {
    final original = profiles
        .where((profile) => profile.id == config.profileId)
        .firstOrNull;
    if (original != null) {
      profiles.remove(original);
      profiles.insert(0, original);
    }
  }
  final result = <LlmConfig>[];
  for (final profile in profiles) {
    final current = await readCoherentModelService(ref, profile.id);
    if (current.profile.toJson().toString() != profile.toJson().toString()) {
      throw const ModelCredentialsUnavailable('channel_descriptor_changed');
    }
    final candidate = config.copyWith(
      profileId: profile.id,
      baseUrl: profile.baseUrl,
      apiFormat: profile.apiFormat,
      authMode: profile.authMode,
      apiKey: current.apiKey,
    );
    var bounded = applyContextConfig(
      applyReportedModelCapabilities(settings, candidate),
      effectiveContextPrefs(settings, candidate),
    );
    final requested = config.maxOutputTokens;
    if (requested != null &&
        requested > 0 &&
        (bounded.maxOutputTokens == null ||
            requested < bounded.maxOutputTokens!)) {
      bounded = bounded.copyWith(maxOutputTokens: requested);
    }
    result.add(bounded);
  }
  return result;
}
