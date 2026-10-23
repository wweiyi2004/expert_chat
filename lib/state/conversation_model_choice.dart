import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../data/settings_storage_keys.dart';
import '../domain/llm/llm_provider.dart';
import 'settings_controller.dart';
import 'model_service_routing.dart';

const autoModelChoice = '__auto__';
final conversationModelChoiceProvider =
    NotifierProvider<ConversationModelChoice, Map<String, String>>(
      ConversationModelChoice.new,
    );

class ConversationModelChoice extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    final raw = ref
        .read(sharedPrefsProvider)
        .getString('conversationModelChoices');
    return raw == null ? {} : Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> select(String conversation, String model) async {
    final next = {...state, conversation: model};
    if (!await ref
        .read(sharedPrefsProvider)
        .setString('conversationModelChoices', jsonEncode(next)))
      throw StateError('模型选择保存失败');
    if (ref.mounted) state = next;
  }
}

Future<LlmConfig> resolveConversationModel(
  Ref ref,
  String conversation,
  LlmConfig fallback, {
  required bool work,
  required bool images,
  required bool thinking,
  String? choiceOverride,
  bool useChoiceOverride = false,
  SettingsState? settingsOverride,
  Map<String, List<String>>? servicePrioritiesOverride,
}) async {
  final settings =
      settingsOverride ?? ref.read(settingsControllerProvider).value;
  final choice = useChoiceOverride
      ? choiceOverride
      : ref.read(conversationModelChoiceProvider)[conversation];
  if (settings == null || choice == null) return fallback;
  final keys = <String, String>{};
  for (final profile in settings.profiles) {
    keys[profile.id] =
        await ref
            .read(secureStorageProvider)
            .read(key: providerApiKeyStorageKey(profile.id)) ??
        '';
  }
  final availableProfiles = settings.profiles
      .where(
        (profile) =>
            profile.authMode != 'apiKey' || keys[profile.id]!.isNotEmpty,
      )
      .toList();
  var model = choice;
  if (choice == autoModelChoice) {
    // Capability routing avoids another paid model call just to select a model.
    final candidates = serviceModelCatalog(availableProfiles).where((id) {
      final c = ModelCapabilities.resolve(id);
      return (!work || c.supportsTools) && (!images || c.supportsVision);
    }).toList();
    if (candidates.isEmpty) return fallback;
    model = candidates.contains(fallback.model)
        ? fallback.model
        : candidates.first;
    if (thinking &&
        !ModelCapabilities.resolve(model).supportsReasoningEffort &&
        !ModelCapabilities.resolve(model).isReasoner &&
        !ModelCapabilities.resolve(model).sendThinkingField) {
      model =
          candidates
              .where(
                (id) => ModelCapabilities.resolve(id).supportsReasoningEffort,
              )
              .firstOrNull ??
          model;
    }
  }
  final services = servicesForModel(
    model,
    choice == autoModelChoice ? availableProfiles : settings.profiles,
    servicePrioritiesOverride ?? ref.read(modelServiceRoutingProvider),
  );
  if (services.isEmpty) return fallback;
  final provider = services.first;
  final key = keys[provider.id] ?? '';
  return fallback.copyWith(
    model: model,
    profileId: provider.id,
    baseUrl: provider.baseUrl,
    apiFormat: provider.apiFormat,
    authMode: provider.authMode,
    apiKey: key,
  );
}
