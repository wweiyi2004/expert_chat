import '../../data/chat_state.dart';
import '../../data/composer_modes.dart';
import '../../data/models.dart';
import '../../data/settings_state.dart';
import '../../data/provider_profile.dart';
import '../../data/subagent_role.dart';
import '../../data/prompt_presets.dart';
import '../../data/chat_skill.dart';
import '../../data/jev_config.dart';
import '../../data/ui_prefs.dart';
import '../../data/media_api_config.dart';
import '../../data/context_prefs.dart';
import '../../data/gateway_config.dart';
import '../../data/task_budget_prefs.dart';
import '../../platform/theme_mode.dart';
import '../llm/llm_provider.dart';
import '../tools/search_provider.dart';
import '../gateway/gateway_auth_service.dart';
import '../context/context_window_manager.dart';
import '../story/story_generation_intent.dart';

Map<String, dynamic> wireMap(Object? value) =>
    Map<String, dynamic>.from(value as Map? ?? {});
List<Map<String, dynamic>> wireRows(Object? value) => [
  for (final row in value as List? ?? []) wireMap(row),
];
T wireEnum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

Object? encodeHostValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Enum) return value.name;
  if (value is DateTime) return value.toIso8601String();
  if (value is ChatSkillCatalog) {
    return value.skills.map((s) => s.toJson()).toList();
  }
  if (value is ChatRetryOperation) return encodeRetry(value);
  if (value is Iterable) return value.map(encodeHostValue).toList();
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), encodeHostValue(v)));
  }
  return (value as dynamic).toJson();
}

/// Privileged GUI state only. Never include this payload in public TUI snapshots,
/// diagnostics, request journals, task context or model tools.
Map<String, Object?> encodeSettingsState(SettingsState s) => {
  'profiles': s.profiles.map((p) => p.toJson()).toList(),
  'activeProfileId': s.activeProfileId,
  'apiKey': s.apiKey,
  'selectedModel': s.selectedModel,
  'themeMode': s.themeMode.name,
  'searchBackend': s.searchBackend.name,
  'searchApiKey': s.searchApiKey,
  'searchBrainModel': s.searchBrainModel,
  'searchMaxRounds': s.searchMaxRounds,
  'searchMaxResults': s.searchMaxResults,
  'taskBudget': s.taskBudget.toJson(),
  'searchMode': s.searchMode.name,
  'imageGenMode': s.imageGenMode.name,
  'reasoningEffort': s.reasoningEffort.name,
  'hasReasoningEffortOverride': s.hasReasoningEffortOverride,
  'systemPrompt': s.systemPrompt,
  'workAgentInstructions': s.workAgentInstructions,
  'subagentInstructions': s.subagentInstructions,
  'subagentRoles': s.subagentRoles?.map((r) => r.toJson()).toList(),
  'subagentRouterModel': s.subagentRouterModel,
  'promptPresets': s.promptPresets.toJson(),
  'chatSkills': s.chatSkills.skills.map((s) => s.toJson()).toList(),
  'jevConfig': s.jevConfig.toJson(),
  'jevApiKey': s.jevApiKey,
  'ui': s.ui.toJson(),
  'visionApi': s.visionApi.toJson(),
  'visionApiKey': s.visionApiKey,
  'imageGenerationApi': s.imageGenerationApi.toJson(),
  'imageGenerationApiKey': s.imageGenerationApiKey,
  'ttsApi': s.ttsApi.toJson(),
  'ttsApiKey': s.ttsApiKey,
  'asrApi': s.asrApi.toJson(),
  'asrApiKey': s.asrApiKey,
  'context': s.context.toJson(),
  'modelContexts': s.modelContexts.map((k, v) => MapEntry(k, v.toJson())),
  'gateway': s.gateway.toJson(),
  'gatewayToken': s.gatewayToken,
  'gatewayLegacyToken': s.gatewayLegacyToken,
  'gatewayAuthSession': s.gatewayAuthSession == null
      ? null
      : {
          'accessToken': s.gatewayAuthSession!.accessToken,
          'refreshToken': s.gatewayAuthSession!.refreshToken,
          'expiresAt': s.gatewayAuthSession!.expiresAt.toIso8601String(),
          'subject': s.gatewayAuthSession!.subject,
          'displayName': s.gatewayAuthSession!.displayName,
        },
  'asrEnabled': s.asrEnabled,
  'customMcpTokens': s.customMcpTokens,
  'customMcpEnvironments': s.customMcpEnvironments,
  'customMcpHeaders': s.customMcpHeaders,
  'memoryEnabled': s.memoryEnabled,
  'researchModeEnabled': s.researchModeEnabled,
  'studyModeEnabled': s.studyModeEnabled,
  'creationModeEnabled': s.creationModeEnabled,
};

SettingsState decodeSettingsState(
  Map<String, dynamic> j, {
  Future<String> Function()? gatewayTokenProvider,
}) {
  final presets = wireMap(j['promptPresets']),
      auth = wireMap(j['gatewayAuthSession']);
  Map<String, Map<String, String>> secretMaps(String key) => wireMap(
    j[key],
  ).map((k, v) => MapEntry(k, Map<String, String>.from(v as Map)));
  return SettingsState(
    profiles: wireRows(j['profiles']).map(ProviderProfile.fromJson).toList(),
    activeProfileId: j['activeProfileId'] as String?,
    apiKey: j['apiKey'] as String? ?? '',
    selectedModel: j['selectedModel'] as String?,
    themeMode: wireEnum(
      ThemePreference.values,
      j['themeMode'],
      ThemePreference.system,
    ),
    searchBackend: wireEnum(
      SearchBackend.values,
      j['searchBackend'],
      SearchBackend.deepseek,
    ),
    searchApiKey: j['searchApiKey'] as String? ?? '',
    searchBrainModel: j['searchBrainModel'] as String?,
    searchMaxRounds: j['searchMaxRounds'] as int? ?? 3,
    searchMaxResults: j['searchMaxResults'] as int? ?? 5,
    taskBudget: TaskBudgetPrefs.fromJson(j['taskBudget']),
    searchMode: wireEnum(SearchMode.values, j['searchMode'], SearchMode.auto),
    imageGenMode: wireEnum(
      ImageGenMode.values,
      j['imageGenMode'],
      ImageGenMode.auto,
    ),
    reasoningEffort: wireEnum(
      ReasoningEffort.values,
      j['reasoningEffort'],
      ReasoningEffort.high,
    ),
    hasReasoningEffortOverride: j['hasReasoningEffortOverride'] == true,
    systemPrompt: j['systemPrompt'] as String? ?? '',
    workAgentInstructions: j['workAgentInstructions'] as String? ?? '',
    subagentInstructions: j['subagentInstructions'] as String? ?? '',
    subagentRoles: j['subagentRoles'] == null
        ? null
        : wireRows(j['subagentRoles']).map(SubagentRole.fromJson).toList(),
    subagentRouterModel: j['subagentRouterModel'] as String? ?? '',
    promptPresets: PromptPresets(
      items: wireRows(presets['items']).map(PromptPreset.fromJson).toList(),
      activeId: presets['activeId'] as String?,
    ),
    chatSkills: ChatSkillCatalog(
      wireRows(j['chatSkills']).map(ChatSkill.fromJson).toList(),
    ),
    jevConfig: JevConfig.fromJson(wireMap(j['jevConfig'])),
    jevApiKey: j['jevApiKey'] as String? ?? '',
    ui: UiPrefs.fromJson(wireMap(j['ui'])),
    visionApi: MediaApiConfig.fromJson(wireMap(j['visionApi'])),
    visionApiKey: j['visionApiKey'] as String? ?? '',
    imageGenerationApi: MediaApiConfig.fromJson(
      wireMap(j['imageGenerationApi']),
    ),
    imageGenerationApiKey: j['imageGenerationApiKey'] as String? ?? '',
    ttsApi: MediaApiConfig.fromJson(wireMap(j['ttsApi'])),
    ttsApiKey: j['ttsApiKey'] as String? ?? '',
    asrApi: MediaApiConfig.fromJson(wireMap(j['asrApi'])),
    asrApiKey: j['asrApiKey'] as String? ?? '',
    context: ContextPrefs.fromJson(wireMap(j['context'])),
    modelContexts: wireMap(
      j['modelContexts'],
    ).map((k, v) => MapEntry(k, ContextPrefs.fromJson(wireMap(v)))),
    gateway: GatewayConfig.fromJson(wireMap(j['gateway'])),
    gatewayToken: j['gatewayToken'] as String? ?? '',
    gatewayLegacyToken: j['gatewayLegacyToken'] as String? ?? '',
    gatewayAuthSession: auth.isEmpty
        ? null
        : GatewayAuthSession(
            accessToken: auth['accessToken'] as String,
            refreshToken: auth['refreshToken'] as String,
            expiresAt: DateTime.parse(auth['expiresAt'] as String),
            subject: auth['subject'] as String,
            displayName: auth['displayName'] as String,
          ),
    gatewayTokenProvider: gatewayTokenProvider,
    asrEnabled: j['asrEnabled'] != false,
    customMcpTokens: Map<String, String>.from(
      j['customMcpTokens'] as Map? ?? {},
    ),
    customMcpEnvironments: secretMaps('customMcpEnvironments'),
    customMcpHeaders: secretMaps('customMcpHeaders'),
    memoryEnabled: j['memoryEnabled'] == true,
    researchModeEnabled: j['researchModeEnabled'] == true,
    studyModeEnabled: j['studyModeEnabled'] != false,
    creationModeEnabled: j['creationModeEnabled'] != false,
  );
}

Map<String, Object?>? encodeRetry(ChatRetryOperation? r) => r == null
    ? null
    : {
        'kind': r.kind.name,
        'conversationId': r.conversationId,
        'assistantMessageId': r.assistantMessageId,
        'promptPlotCursor': r.promptPlotCursor,
        'commitPlotAdvance': r.commitPlotAdvance,
        'storyIntent': r.storyIntent?.name,
        'ensembleSpeakerId': r.ensembleSpeakerId,
      };
ChatRetryOperation? decodeRetry(Object? raw) {
  if (raw == null) return null;
  final j = wireMap(raw);
  return ChatRetryOperation(
    kind: wireEnum(ChatRetryKind.values, j['kind'], ChatRetryKind.regenerate),
    conversationId: j['conversationId'] as String,
    assistantMessageId: j['assistantMessageId'] as String,
    promptPlotCursor: j['promptPlotCursor'] as int?,
    commitPlotAdvance: j['commitPlotAdvance'] == true,
    storyIntent: StoryGenerationIntent.values
        .where((v) => v.name == j['storyIntent'])
        .firstOrNull,
    ensembleSpeakerId: j['ensembleSpeakerId'] as String?,
  );
}

Map<String, Object?> encodeChatState(ChatState s) => {
  'conversations': s.conversations
      .map((c) => {...c.toJson(), 'messagesLoaded': c.messagesLoaded})
      .toList(),
  'currentId': s.currentId,
  'streamingConvoId': s.streamingConvoId,
  'runningConversationIds': s.runningConversationIds.toList(),
  'pendingSessionConfigurations': s.pendingSessionConfigurations.map(
    (k, v) => MapEntry(k, v.labels),
  ),
  'sessionCheckpoints': s.sessionCheckpoints.map(
    (k, v) => MapEntry(k, v.toJson()),
  ),
  'deepThink': s.deepThink,
  'reasoningEffort': s.reasoningEffort.name,
  'searchMode': s.searchMode.name,
  'imageGenMode': s.imageGenMode.name,
  'isSearching': s.isSearching,
  'isGeneratingImage': s.isGeneratingImage,
  'isProcessingDocument': s.isProcessingDocument,
  'error': s.error,
  'errorConvoId': s.errorConvoId,
  'retryOperation': encodeRetry(s.retryOperation),
  'contextReports': s.contextReports.map(
    (k, v) => MapEntry(k, {
      'originalTokens': v.originalTokens,
      'sentTokens': v.sentTokens,
      'inputBudgetTokens': v.inputBudgetTokens,
      'droppedMessages': v.droppedMessages,
      'truncated': v.truncated,
      'summaryInjected': v.summaryInjected,
    }),
  ),
};
ChatState decodeChatState(
  Map<String, dynamic> j, {
  String? selectedId,
}) => ChatState(
  conversations: wireRows(j['conversations'])
      .map(
        (v) => Conversation.fromJson(
          v,
        ).copyWith(messagesLoaded: v['messagesLoaded'] != false),
      )
      .toList(),
  currentId: selectedId ?? j['currentId'] as String?,
  streamingConvoId: j['streamingConvoId'] as String?,
  runningConversationIds: (j['runningConversationIds'] as List? ?? [])
      .cast<String>()
      .toSet(),
  pendingSessionConfigurations: wireMap(j['pendingSessionConfigurations']).map(
    (k, v) =>
        MapEntry(k, SessionPendingConfiguration((v as List).cast<String>())),
  ),
  sessionCheckpoints: wireMap(j['sessionCheckpoints']).map(
    (k, v) => MapEntry(
      k,
      SessionExecutionCheckpoint.fromJson(wireMap(v), liveProjection: true),
    ),
  ),
  deepThink: j['deepThink'] != false,
  reasoningEffort: wireEnum(
    ReasoningEffort.values,
    j['reasoningEffort'],
    ReasoningEffort.high,
  ),
  searchMode: wireEnum(SearchMode.values, j['searchMode'], SearchMode.auto),
  imageGenMode: wireEnum(
    ImageGenMode.values,
    j['imageGenMode'],
    ImageGenMode.auto,
  ),
  isSearching: j['isSearching'] == true,
  isGeneratingImage: j['isGeneratingImage'] == true,
  isProcessingDocument: j['isProcessingDocument'] == true,
  error: j['error'] as String?,
  errorConvoId: j['errorConvoId'] as String?,
  retryOperation: decodeRetry(j['retryOperation']),
  contextReports: wireMap(j['contextReports']).map((k, v) {
    final r = wireMap(v);
    return MapEntry(
      k,
      ContextWindowReport(
        originalTokens: r['originalTokens'] as int,
        sentTokens: r['sentTokens'] as int,
        inputBudgetTokens: r['inputBudgetTokens'] as int,
        droppedMessages: r['droppedMessages'] as int? ?? 0,
        truncated: r['truncated'] == true,
        summaryInjected: r['summaryInjected'] == true,
      ),
    );
  }),
);
