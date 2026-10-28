import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/llm/llm_provider.dart';
import 'settings_controller.dart';
import 'model_service_routing.dart';
import 'model_route_groups.dart';
import 'model_context.dart';
import 'model_service_credentials.dart';
import 'session_policy.dart';
import '../domain/llm/model_credentials_unavailable.dart';

const autoModelChoice = '__auto__';
const modelSourcePrefix = '__source__:';
String modelSourceChoice(String profile, String model) =>
    '$modelSourcePrefix${Uri.encodeComponent(profile)}:${Uri.encodeComponent(model)}';
({String profile, String model})? parseModelSourceChoice(String choice) {
  if (!choice.startsWith(modelSourcePrefix)) return null;
  final parts = choice.substring(modelSourcePrefix.length).split(':');
  if (parts.length != 2) return null;
  return (
    profile: Uri.decodeComponent(parts[0]),
    model: Uri.decodeComponent(parts[1]),
  );
}

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
        .setString('conversationModelChoices', jsonEncode(next))) {
      throw StateError('模型选择保存失败');
    }
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
  final config = await _resolveConversationModel(
    ref,
    conversation,
    fallback,
    work: work,
    images: images,
    thinking: thinking,
    choiceOverride: choiceOverride,
    useChoiceOverride: useChoiceOverride,
    settingsOverride: settingsOverride,
    servicePrioritiesOverride: servicePrioritiesOverride,
  );
  return applyFastMode(ref.read(sessionPolicyProvider)[conversation], config);
}

/// Fast mode only touches configs whose provider documents priority processing.
/// Returns [config] itself when nothing changes, so callers keep its identity.
LlmConfig applyFastMode(SessionPolicy? policy, LlmConfig config) {
  final tier = policy?.fast == true && config.supportsPriorityTier
      ? 'priority'
      : null;
  if (tier == config.serviceTier) return config;
  return tier == null
      ? config.copyWith(clearServiceTier: true)
      : config.copyWith(serviceTier: tier);
}

Future<LlmConfig> _resolveConversationModel(
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
  await ref.read(settingsControllerProvider.notifier).waitForProfileMutations();
  final keys = <String, String>{};
  for (final profile in settings.profiles) {
    final coherent = await readCoherentModelService(ref, profile.id);
    if (coherent.profile.toJson().toString() != profile.toJson().toString()) {
      throw const ModelCredentialsUnavailable('channel_descriptor_changed');
    }
    keys[profile.id] = coherent.apiKey;
  }
  final availableProfiles = settings.profiles
      .where(
        (profile) =>
            profile.authMode != 'apiKey' || keys[profile.id]!.isNotEmpty,
      )
      .toList();
  final source = parseModelSourceChoice(choice);
  var model = source?.model ?? choice;
  final policy = ref.read(modelRouteGroupsProvider);
  final groupId = choice.startsWith(modelGroupPrefix)
      ? choice.substring(modelGroupPrefix.length)
      : choice == autoModelChoice
      ? policy.autoGroup
      : '';
  final group = policy.groups.where((group) => group.id == groupId).firstOrNull;
  if (choice.startsWith(modelGroupPrefix) && group == null) {
    throw StateError('所选模型路由组已删除，请重新选择');
  }
  if (group != null) {
    final options = <LlmConfig>[];
    for (final id in group.models) {
      final capabilities = ModelCapabilities.resolve(id);
      if ((work && !capabilities.supportsTools) ||
          (images && !capabilities.supportsVision)) {
        continue;
      }
      final services = servicesForModel(
        id,
        availableProfiles,
        servicePrioritiesOverride ?? ref.read(modelServiceRoutingProvider),
      );
      if (services.isEmpty) continue;
      final profile = services.first;
      final candidate = fallback.copyWith(
        lockProfile: false,
        model: id,
        profileId: profile.id,
        baseUrl: profile.baseUrl,
        apiFormat: profile.apiFormat,
        authMode: profile.authMode,
        apiKey: keys[profile.id] ?? '',
        modelFallbacks: const [],
      );
      options.add(
        applyContextConfig(
          candidate,
          effectiveContextPrefs(settings, candidate),
        ),
      );
    }
    if (options.isEmpty) throw StateError('模型路由组没有符合本任务能力且已配置的模型');
    return applyReportedModelCapabilities(
      settings,
      options.first.copyWith(
        modelFallbacks: group.failover ? options.skip(1).toList() : const [],
      ),
    );
  }
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
    source != null
        ? settings.profiles.where((p) => p.id == source.profile).toList()
        : choice == autoModelChoice
        ? availableProfiles
        : settings.profiles,
    servicePrioritiesOverride ?? ref.read(modelServiceRoutingProvider),
  );
  if (services.isEmpty) {
    if (choice != autoModelChoice) {
      throw StateError('所选模型已没有配置渠道，请重新选择模型；不会自动改用其他模型。');
    }
    return fallback;
  }
  final provider = services.first;
  final key = keys[provider.id] ?? '';
  return applyReportedModelCapabilities(
    settings,
    fallback.copyWith(
      modelFallbacks: const [],
      lockProfile: source != null,
      model: model,
      profileId: provider.id,
      baseUrl: provider.baseUrl,
      apiFormat: provider.apiFormat,
      authMode: provider.authMode,
      apiKey: key,
    ),
  );
}
