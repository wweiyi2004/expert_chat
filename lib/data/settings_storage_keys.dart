import 'media_api_config.dart';

const kSettingsProfiles = 'providerProfiles';
const kSettingsActiveProfile = 'activeProfileId';
const kSettingsSelectedModel = 'selectedModel';
const kSettingsThemeMode = 'themeMode';
const kSettingsSearchBackend = 'searchBackend';
const kSettingsDeepSeekSearchDefaultMigrated = 'deepseekSearchDefaultV1';
const kSettingsSearchApiKeySecure = 'search_api_key';
const kSettingsDeepSeekSearchApiKeySecure = 'deepseek_search_api_key';
const kSettingsSearchBrainModel = 'searchBrainModel';
const kSettingsSearchMaxRounds = 'searchMaxRounds';
const kSettingsSearchMaxResults = 'searchMaxResults';
const kSettingsComposerSearchMode = 'composerSearchMode';
const kSettingsComposerImageGenMode = 'composerImageGenMode';
const kSettingsReasoningEffort = 'reasoningEffort';
const kSettingsSystemPrompt = 'systemPrompt';
const kSettingsWorkAgentInstructions = 'workAgentInstructions';
const kSettingsSubagentInstructions = 'subagentInstructions';
const kSettingsSubagentRoles = 'subagentRoles.v1';
const kSettingsSubagentRouterModel = 'subagentRouterModel';
const kSettingsChatSkills = 'chatSkills';
const kSettingsJevConfig = 'jevConfig';
const kSettingsJevApiKeySecure = 'jev_api_key';
const kSettingsUiPrefs = 'uiPrefs';
const kSettingsVisionApi = 'visionApi';
const kSettingsVisionApiKeySecure = 'vision_api_key';
const kSettingsImageGenerationApi = 'imageGenerationApi';
const kSettingsImageGenerationApiKeySecure = 'image_generation_api_key';
const kSettingsTtsApi = 'ttsApi';
const kSettingsTtsApiKeySecure = 'tts_api_key';
const kSettingsAsrApi = 'asrApi';
const kSettingsAsrApiKeySecure = 'asr_api_key';
const kSettingsContextPrefs = 'contextPrefs';
const kSettingsModelContexts = 'modelContextPrefs';
const kSettingsGateway = 'expertChatGateway';
const kSettingsGatewayTokenSecure = 'expert_chat_gateway_token';
String customMcpTokenStorageKey(String id) => 'custom_mcp_token_$id';
const kSettingsGatewayOidcAccessTokenSecure =
    'expert_chat_gateway_oidc_access_token';
const kSettingsGatewayOidcRefreshTokenSecure =
    'expert_chat_gateway_oidc_refresh_token';
const kSettingsGatewayOidcExpiresAtSecure =
    'expert_chat_gateway_oidc_expires_at';
const kSettingsGatewayOidcSubjectSecure = 'expert_chat_gateway_oidc_subject';
const kSettingsGatewayOidcDisplayNameSecure =
    'expert_chat_gateway_oidc_display_name';
// Legacy split-service keys retained for a lossless one-time migration.
const kSettingsLegacyDocumentService = 'documentService';
const kSettingsLegacyDocumentServiceTokenSecure = 'document_service_token';
const kSettingsLegacyLongTaskGateway = 'longTaskGateway';
const kSettingsLegacyLongTaskGatewayTokenSecure = 'long_task_gateway_token';
const kSettingsMemoryEnabled = 'memoryEnabled';
const kSettingsResearchModeEnabled = 'researchModeEnabled';
const kSettingsStudyModeEnabled = 'studyModeEnabled';
const kSettingsCreationModeEnabled = 'creationModeEnabled';

// Legacy M1 keys (single-config) — read once for migration.
const kSettingsLegacyBaseUrl = 'baseUrl';
const kSettingsLegacyModel = 'model';
const kSettingsLegacyApiKeySecure = 'llm_api_key';
const kSettingsProfilesCorruptBackup = 'providerProfiles.corrupt';

/// Stable secure-storage key used by provider-scoped background jobs as well as
/// the settings controller. A job may outlive a change of active provider.
String providerApiKeyStorageKey(String profileId) => 'apikey_$profileId';

/// TTS providers keep independent endpoint/model/voice profiles. The legacy
/// keys above continue to mirror whichever profile is active so old releases
/// and existing installs remain compatible.
String ttsApiProfilePrefsKey(SpeechApiProtocol protocol) =>
    'ttsApi.${protocol.name}';

String ttsApiProfileSecureKey(SpeechApiProtocol protocol) =>
    'tts_api_key.${protocol.name}';

/// Loads settings (profiles + active key) and persists changes. Migrates the
/// M1 single-config layout to a profile on first run.

String customMcpSecretsStorageKey(String id) => 'customMcpSecrets.$id';
