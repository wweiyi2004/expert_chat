import 'dart:async';
import '../state/model_context.dart';

import '../platform/theme_mode.dart';

import 'chat_skill.dart';
import 'subagent_role.dart';
import 'prompt_presets.dart';
import 'jev_config.dart';
import 'composer_modes.dart';
import 'context_prefs.dart';
import 'gateway_config.dart';
import 'media_api_config.dart';
import 'provider_profile.dart';
import 'task_budget_prefs.dart';
import 'ui_prefs.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/gateway/gateway_auth_service.dart';
import '../domain/mcp/mcp_host_tools.dart';
import '../domain/tools/search_provider.dart';

/// Bounds / defaults for the web-search knobs surfaced in settings.
const int kDefaultSearchMaxRounds = 3;
const int kMinSearchMaxRounds = 1;
const int kMaxSearchMaxRounds = 5;
const int kDefaultSearchMaxResults = 8;
const int kMinSearchMaxResults = 4;
const int kMaxSearchMaxResults = 12;

/// App settings: a list of named provider profiles (one active at a time),
/// the per-profile API key (kept in secure storage), an optional model
/// override within the active profile, and the theme mode.
class SettingsState {
  const SettingsState({
    this.profiles = const [],
    this.activeProfileId,
    this.apiKey = '',
    this.selectedModel,
    this.themeMode = ThemePreference.system,
    this.searchBackend = SearchBackend.deepseek,
    this.searchApiKey = '',
    this.searchBrainModel,
    this.searchMaxRounds = kDefaultSearchMaxRounds,
    this.searchMaxResults = kDefaultSearchMaxResults,
    this.taskBudget = const TaskBudgetPrefs(),
    this.searchMode = SearchMode.auto,
    this.imageGenMode = ImageGenMode.auto,
    this.reasoningEffort = ReasoningEffort.high,
    this.hasReasoningEffortOverride = false,
    this.systemPrompt = '',
    this.workAgentInstructions = '',
    this.subagentInstructions = '',
    this.subagentRoles,
    this.subagentRouterModel = '',
    this.promptPresets = const PromptPresets(),
    this.chatSkills = const ChatSkillCatalog([]),
    this.jevConfig = const JevConfig(),
    this.jevApiKey = '',
    this.ui = const UiPrefs(),
    this.visionApi = const MediaApiConfig(),
    this.visionApiKey = '',
    this.imageGenerationApi = const MediaApiConfig(),
    this.imageGenerationApiKey = '',
    this.ttsApi = const MediaApiConfig(),
    this.ttsApiKey = '',
    this.asrApi = const MediaApiConfig(),
    this.asrApiKey = '',
    this.context = const ContextPrefs(),
    this.modelContexts = const {},
    this.gateway = const GatewayConfig(),
    this.gatewayToken = '',
    this.gatewayLegacyToken = '',
    this.gatewayAuthSession,
    this.gatewayTokenProvider,
    this.asrEnabled = true,
    this.customMcpTokens = const {},
    this.customMcpEnvironments = const {},
    this.customMcpHeaders = const {},
    this.memoryEnabled = false,
    this.researchModeEnabled = false,
    this.studyModeEnabled = true,
    this.creationModeEnabled = true,
  });

  final List<ProviderProfile> profiles;
  final String? activeProfileId;

  /// API key of the active profile (loaded from secure storage).
  final String apiKey;

  /// Model override within the active profile; null = use profile.chatModel.
  final String? selectedModel;
  final ThemePreference themeMode;

  /// Web-search backend + its key (for the "联网搜索" feature, M5).
  final SearchBackend searchBackend;
  final String searchApiKey;

  /// Official DeepSeek search is a standalone API, available to both models.
  SearchBackend get effectiveSearchBackend => SearchBackend.deepseek;

  String get effectiveSearchApiKey =>
      searchBackend == SearchBackend.deepseek && searchApiKey.trim().isNotEmpty
      ? searchApiKey
      : config.isOfficialDeepSeek
      ? apiKey
      : '';

  /// Model that plans multi-round retrieval for models without function
  /// calling ("搜索大脑"). Null/empty = follow the active profile's chat model.
  final String? searchBrainModel;

  /// Max search rounds per answer (brain orchestration AND the tool loop).
  final int searchMaxRounds;

  /// Results requested per search call.
  final int searchMaxResults;

  /// Composer 联网 default (off / auto / always). Missing prefs → auto.
  final SearchMode searchMode;

  /// Composer 配图 default (off / auto / always). Missing prefs → auto.
  final ImageGenMode imageGenMode;

  /// DeepSeek/Grok thinking intensity while composer 深度思考 is on.
  final ReasoningEffort reasoningEffort;

  /// A saved user choice takes precedence over task-specific defaults.
  final bool hasReasoningEffortOverride;

  /// User-authored general prompt. Empty on first install even though the
  /// chat catalog fallback has factory text. Synced with
  /// [chatSkills].fallback.prompt when the user edits general.
  final String systemPrompt;
  final String workAgentInstructions;
  final String subagentInstructions;
  final List<SubagentRole>? subagentRoles;
  final String subagentRouterModel;
  List<SubagentRole> get effectiveSubagentRoles =>
      subagentRoles ?? SubagentRole.defaults(subagentInstructions);
  final PromptPresets promptPresets;

  /// Per-turn skill catalog. Empty lists are sanitized on read/save.
  final ChatSkillCatalog chatSkills;
  final JevConfig jevConfig;
  final String jevApiKey;

  /// Appearance / reading preferences (text scale, density, message style…).
  final UiPrefs ui;

  /// Optional, independently configured multimedia endpoints.
  final MediaApiConfig visionApi;
  final String visionApiKey;
  final MediaApiConfig imageGenerationApi;
  final String imageGenerationApiKey;
  final MediaApiConfig ttsApi;
  final String ttsApiKey;
  final MediaApiConfig asrApi;
  final String asrApiKey;
  final ContextPrefs context;
  final Map<String, ContextPrefs> modelContexts;

  /// One connection for every server-side Expert Chat capability.
  final GatewayConfig gateway;
  final String gatewayToken;
  final String gatewayLegacyToken;
  final GatewayAuthSession? gatewayAuthSession;
  final Future<String> Function()? gatewayTokenProvider;

  /// Bearer tokens for [GatewayConfig.customMcpServers], keyed by server id.
  final bool asrEnabled;
  final Map<String, String> customMcpTokens;
  final Map<String, Map<String, String>> customMcpEnvironments,
      customMcpHeaders;

  /// Local Markdown long-term memory. Off by default until the user opts in.
  final bool memoryEnabled;
  final TaskBudgetPrefs taskBudget;

  /// M7: hidden research mode (SSH / tmux / AI command approval). Default off.
  final bool researchModeEnabled;

  /// Study hub tab (导师 / 课程 / 刷题 / 复习). Default on.
  final bool studyModeEnabled;

  /// Creation hub tab (角色 / 世界书 / 导演故事). Default on; can hide for a cleaner nav.
  final bool creationModeEnabled;

  bool get searchConfigured => effectiveSearchApiKey.trim().isNotEmpty;
  bool get gatewayConfigured => gateway.isConfigured;
  bool get gatewaySignedIn => gatewayAuthSession != null;
  bool get supportsLongTasks =>
      gateway.supports(GatewayCapabilityIds.longTasks);
  bool get supportsDocumentEdit =>
      gateway.supports(GatewayCapabilityIds.documentEdit);
  bool get supportsDocumentConvert =>
      gateway.supports(GatewayCapabilityIds.documentConvert);
  List<DiscoveredMcpTool> get modelDocumentMcpTools =>
      gateway.capabilitiesDiscovered
      ? McpHostTools.modelFacing(gateway.mcpTools)
      : const [];
  List<RoutedMcpTool> get routedMcpTools => McpHostTools.mergeForModel(
    documentTools: modelDocumentMcpTools,
    customServers: gateway.customMcpServers,
  );
  List<DiscoveredMcpTool> get modelMcpTools => [
    for (final routed in routedMcpTools)
      DiscoveredMcpTool(
        name: routed.exposedName,
        description: routed.tool.description,
        inputSchema: routed.tool.inputSchema,
      ),
  ];

  List<McpServerChoice> get availableMcpServers => [
    if (gateway.isConfigured)
      McpServerChoice(
        id: McpHostTools.expertChatServerId,
        name: '文档 MCP',
        toolsDiscovered: gateway.capabilitiesDiscovered,
      ),
    for (final server in gateway.customMcpServers)
      if (server.enabled)
        McpServerChoice(
          id: server.id,
          name: server.name,
          toolsDiscovered: server.toolsDiscovered,
        ),
  ];

  List<DiscoveredMcpTool> modelMcpToolsFor(Iterable<String> selectedIds) {
    final selected = selectedIds.toSet();
    // Keep names identical to execution routing even when an earlier server
    // with the same tool name is not selected for this conversation.
    final routed = routedMcpTools.where(
      (tool) =>
          selected.contains(tool.serverId ?? McpHostTools.expertChatServerId),
    );
    return [
      for (final tool in routed)
        DiscoveredMcpTool(
          name: tool.exposedName,
          description: tool.tool.description,
          inputSchema: tool.tool.inputSchema,
        ),
    ];
  }

  RoutedMcpTool? routedMcpTool(String name) {
    for (final tool in routedMcpTools) {
      if (tool.exposedName == name) return tool;
    }
    return null;
  }

  GatewayConnection connectionForRouted(RoutedMcpTool tool) {
    final serverId = tool.serverId;
    if (serverId == null) return gatewayConnection;
    for (final server in gateway.customMcpServers) {
      if (server.id == serverId) {
        return connectionForCustom(server);
      }
    }
    return gatewayConnection;
  }

  GatewayConnection connectionForCustom(CustomMcpServer server) =>
      gateway.connectionForCustom(
        server,
        customMcpTokens[server.id] ?? '',
        headers: customMcpHeaders[server.id] ?? const {},
        environment: customMcpEnvironments[server.id] ?? const {},
      );

  GatewayConnection get gatewayConnection => GatewayConnection(
    config: gateway,
    apiToken: gatewayToken,
    tokenProvider: gatewayTokenProvider,
  );
  bool get visionConfigured => visionApi.isConfiguredWith(visionApiKey);

  /// True when the user can upload pictures for this turn: either the optional
  /// vision API is set, or the active chat/reasoner model accepts images.
  bool canAttachImages({required bool deepThink}) =>
      visionConfigured ||
      ModelCapabilities.resolve(model).supportsVision ||
      (deepThink && ModelCapabilities.resolve(reasonerModel).supportsVision);
  bool get imageGenerationConfigured =>
      imageGenerationApi.isConfiguredWith(imageGenerationApiKey);
  bool get ttsConfigured => ttsApi.isConfiguredWith(ttsApiKey);
  bool get asrConfigured => asrEnabled && asrApi.isConfiguredWith(asrApiKey);

  ProviderProfile? get active {
    if (profiles.isEmpty) return null;
    return profiles.firstWhere(
      (p) => p.id == activeProfileId,
      orElse: () => profiles.first,
    );
  }

  String get baseUrl => active?.baseUrl ?? '';
  String get model => selectedModel ?? active?.chatModel ?? KnownModels.flash;

  /// Dedicated reasoner model for providers that cannot toggle thinking on
  /// the chat model. DeepSeek V4 ignores this and stays on [model].
  String get reasonerModel => selectedModel ?? active?.reasonerModel ?? model;

  /// Resolved "搜索大脑" model: the explicit choice, else the active profile's
  /// chat model (NOT the possibly-reasoner override, which can't call tools).
  String get effectiveSearchBrainModel {
    final chosen = searchBrainModel?.trim() ?? '';
    if (chosen.isNotEmpty) return chosen;
    return active?.chatModel ?? model;
  }

  /// Models offered in the picker for the active profile.
  List<String> get availableModels => active?.models ?? KnownModels.all;

  LlmApiFormat get apiFormat => active?.apiFormat ?? LlmApiFormat.auto;

  LlmConfig get config {
    final base = LlmConfig(
      profileId: active?.id,
      authMode: active?.authMode ?? 'apiKey',
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      apiFormat: apiFormat,
    );
    return applyReportedModelCapabilities(
      this,
      applyContextConfig(base, effectiveContextPrefs(this, base)),
    );
  }

  LlmConfig get visionConfig => LlmConfig(
    baseUrl: visionApi.baseUrl,
    apiKey: visionApiKey,
    model: visionApi.model,
    apiFormat: visionApi.apiFormat,
    capabilities: const ModelCapabilities(
      isReasoner: false,
      supportsTools: false,
      sendThinkingField: false,
      supportsVision: true,
    ),
  );

  SettingsState copyWith({
    List<ProviderProfile>? profiles,
    String? activeProfileId,
    String? apiKey,
    Object? selectedModel = unchanged,
    ThemePreference? themeMode,
    SearchBackend? searchBackend,
    String? searchApiKey,
    Object? searchBrainModel = unchanged,
    int? searchMaxRounds,
    int? searchMaxResults,
    SearchMode? searchMode,
    ImageGenMode? imageGenMode,
    ReasoningEffort? reasoningEffort,
    bool? hasReasoningEffortOverride,
    String? systemPrompt,
    String? workAgentInstructions,
    String? subagentInstructions,
    List<SubagentRole>? subagentRoles,
    String? subagentRouterModel,
    PromptPresets? promptPresets,
    ChatSkillCatalog? chatSkills,
    JevConfig? jevConfig,
    String? jevApiKey,
    UiPrefs? ui,
    MediaApiConfig? visionApi,
    String? visionApiKey,
    MediaApiConfig? imageGenerationApi,
    String? imageGenerationApiKey,
    MediaApiConfig? ttsApi,
    String? ttsApiKey,
    MediaApiConfig? asrApi,
    String? asrApiKey,
    ContextPrefs? context,
    Map<String, ContextPrefs>? modelContexts,
    GatewayConfig? gateway,
    String? gatewayToken,
    String? gatewayLegacyToken,
    Object? gatewayAuthSession = unchanged,
    Future<String> Function()? gatewayTokenProvider,
    bool? asrEnabled,
    Map<String, String>? customMcpTokens,
    Map<String, Map<String, String>>? customMcpEnvironments,
    Map<String, Map<String, String>>? customMcpHeaders,
    bool? memoryEnabled,
    TaskBudgetPrefs? taskBudget,
    bool? researchModeEnabled,
    bool? studyModeEnabled,
    bool? creationModeEnabled,
  }) => SettingsState(
    profiles: profiles ?? this.profiles,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    apiKey: apiKey ?? this.apiKey,
    selectedModel: identical(selectedModel, unchanged)
        ? this.selectedModel
        : selectedModel as String?,
    themeMode: themeMode ?? this.themeMode,
    searchBackend: searchBackend ?? this.searchBackend,
    searchApiKey: searchApiKey ?? this.searchApiKey,
    searchBrainModel: identical(searchBrainModel, unchanged)
        ? this.searchBrainModel
        : searchBrainModel as String?,
    searchMaxRounds: searchMaxRounds ?? this.searchMaxRounds,
    searchMaxResults: searchMaxResults ?? this.searchMaxResults,
    searchMode: searchMode ?? this.searchMode,
    imageGenMode: imageGenMode ?? this.imageGenMode,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    hasReasoningEffortOverride:
        hasReasoningEffortOverride ?? this.hasReasoningEffortOverride,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    workAgentInstructions: workAgentInstructions ?? this.workAgentInstructions,
    subagentInstructions: subagentInstructions ?? this.subagentInstructions,
    subagentRoles: subagentRoles ?? this.subagentRoles,
    subagentRouterModel: subagentRouterModel ?? this.subagentRouterModel,
    promptPresets: promptPresets ?? this.promptPresets,
    chatSkills: chatSkills ?? this.chatSkills,
    jevConfig: jevConfig ?? this.jevConfig,
    jevApiKey: jevApiKey ?? this.jevApiKey,
    ui: ui ?? this.ui,
    visionApi: visionApi ?? this.visionApi,
    visionApiKey: visionApiKey ?? this.visionApiKey,
    imageGenerationApi: imageGenerationApi ?? this.imageGenerationApi,
    imageGenerationApiKey: imageGenerationApiKey ?? this.imageGenerationApiKey,
    ttsApi: ttsApi ?? this.ttsApi,
    ttsApiKey: ttsApiKey ?? this.ttsApiKey,
    asrApi: asrApi ?? this.asrApi,
    asrApiKey: asrApiKey ?? this.asrApiKey,
    context: context ?? this.context,
    modelContexts: modelContexts ?? this.modelContexts,
    gateway: gateway ?? this.gateway,
    gatewayToken: gatewayToken ?? this.gatewayToken,
    gatewayLegacyToken: gatewayLegacyToken ?? this.gatewayLegacyToken,
    gatewayAuthSession: identical(gatewayAuthSession, unchanged)
        ? this.gatewayAuthSession
        : gatewayAuthSession as GatewayAuthSession?,
    gatewayTokenProvider: gatewayTokenProvider ?? this.gatewayTokenProvider,
    asrEnabled: asrEnabled ?? this.asrEnabled,
    customMcpTokens: customMcpTokens ?? this.customMcpTokens,
    customMcpEnvironments: customMcpEnvironments ?? this.customMcpEnvironments,
    customMcpHeaders: customMcpHeaders ?? this.customMcpHeaders,
    memoryEnabled: memoryEnabled ?? this.memoryEnabled,
    taskBudget: taskBudget ?? this.taskBudget,
    researchModeEnabled: researchModeEnabled ?? this.researchModeEnabled,
    studyModeEnabled: studyModeEnabled ?? this.studyModeEnabled,
    creationModeEnabled: creationModeEnabled ?? this.creationModeEnabled,
  );

  static const unchanged = Object();
}
