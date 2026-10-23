import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../data/settings_storage_keys.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/auth/chatgpt_auth.dart';
import 'settings_controller.dart';
import 'model_service_routing.dart';
import 'model_context.dart';

final chatGptAuthProvider = Provider<ChatGptAuth>(
  (ref) => ChatGptAuth(
    ref.read(secureStorageProvider),
    ref.read(sharedPrefsProvider),
  ),
);
Future<LlmConfig> resolveModelCredentials(Ref ref, LlmConfig config) async {
  if (config.authMode == 'chatgpt') {
    if (config.baseUrl.replaceFirst(RegExp(r'/+$'), '') !=
            'https://api.openai.com/v1' ||
        config.profileId == null)
      throw StateError('ChatGPT 登录凭据只能用于官方服务');
    return config.copyWith(
      apiKey: await ref
          .read(chatGptAuthProvider)
          .accessToken(config.profileId!),
      apiFormat: LlmApiFormat.openAiResponses,
    );
  }
  return config;
}

Future<List<LlmConfig>> modelServiceCandidates(
  Ref ref,
  LlmConfig config,
) async {
  if (config.profileId == null) return [config];
  final settings = ref.read(settingsControllerProvider).value;
  if (settings == null) return [config];
  final profiles = servicesForModel(
    config.model,
    settings.profiles,
    ref.read(modelServiceRoutingProvider),
  );
  if (profiles.isEmpty) return [config];
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
    final candidate = config.copyWith(
      profileId: profile.id,
      baseUrl: profile.baseUrl,
      apiFormat: profile.apiFormat,
      authMode: profile.authMode,
      apiKey:
          profile.id == config.profileId && profile.baseUrl == config.baseUrl
          ? config.apiKey
          : await ref
                    .read(secureStorageProvider)
                    .read(key: providerApiKeyStorageKey(profile.id)) ??
                '',
    );
    var bounded = applyContextConfig(
      candidate,
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
