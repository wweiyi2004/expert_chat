import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers.dart';
import '../data/context_prefs.dart';
import '../data/gateway_config.dart';
import '../data/media_api_config.dart';
import '../data/provider_profile.dart';
import '../data/ui_prefs.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/gateway/gateway_auth_service.dart';
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
    this.themeMode = ThemeMode.system,
    this.searchBackend = SearchBackend.duckduckgo,
    this.searchApiKey = '',
    this.searchBrainModel,
    this.searchMaxRounds = kDefaultSearchMaxRounds,
    this.searchMaxResults = kDefaultSearchMaxResults,
    this.systemPrompt = '',
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
    this.gateway = const GatewayConfig(),
    this.gatewayToken = '',
    this.gatewayLegacyToken = '',
    this.gatewayAuthSession,
    this.gatewayTokenProvider,
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
  final ThemeMode themeMode;

  /// Web-search backend + its key (for the "联网搜索" feature, M5).
  final SearchBackend searchBackend;
  final String searchApiKey;

  /// Model that plans multi-round retrieval for models without function
  /// calling ("搜索大脑"). Null/empty = follow the active profile's chat model.
  final String? searchBrainModel;

  /// Max search rounds per answer (brain orchestration AND the tool loop).
  final int searchMaxRounds;

  /// Results requested per search call.
  final int searchMaxResults;

  /// Optional global preset/persona prompt, prepended as a `system` message on
  /// every request. Empty = no preset (model uses its own default behavior).
  final String systemPrompt;

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

  /// One connection for every server-side Expert Chat capability.
  final GatewayConfig gateway;
  final String gatewayToken;
  final String gatewayLegacyToken;
  final GatewayAuthSession? gatewayAuthSession;
  final Future<String> Function()? gatewayTokenProvider;

  /// Local Markdown long-term memory. Off by default until the user opts in.
  final bool memoryEnabled;

  /// M7: hidden research mode (SSH / tmux / AI command approval). Default off.
  final bool researchModeEnabled;

  /// Study hub tab (导师 / 课程 / 刷题 / 复习). Default on.
  final bool studyModeEnabled;

  /// Creation hub tab (角色 / 世界书 / 导演故事). Default on; can hide for a cleaner nav.
  final bool creationModeEnabled;

  bool get searchConfigured => searchApiKey.trim().isNotEmpty;
  bool get gatewayConfigured => gateway.isConfigured;
  bool get gatewaySignedIn => gatewayAuthSession != null;
  bool get supportsLongTasks =>
      gateway.supports(GatewayCapabilityIds.longTasks);
  bool get supportsDocumentEdit =>
      gateway.supports(GatewayCapabilityIds.documentEdit);
  bool get supportsDocumentConvert =>
      gateway.supports(GatewayCapabilityIds.documentConvert);
  GatewayConnection get gatewayConnection => GatewayConnection(
    config: gateway,
    apiToken: gatewayToken,
    tokenProvider: gatewayTokenProvider,
  );
  bool get visionConfigured => visionApi.isConfiguredWith(visionApiKey);
  bool get imageGenerationConfigured =>
      imageGenerationApi.isConfiguredWith(imageGenerationApiKey);
  bool get ttsConfigured => ttsApi.isConfiguredWith(ttsApiKey);
  bool get asrConfigured => asrApi.isConfiguredWith(asrApiKey);

  ProviderProfile? get active {
    if (profiles.isEmpty) return null;
    return profiles.firstWhere(
      (p) => p.id == activeProfileId,
      orElse: () => profiles.first,
    );
  }

  String get baseUrl => active?.baseUrl ?? '';
  String get model => selectedModel ?? active?.chatModel ?? KnownModels.chat;

  /// Model used when "深度思考" is on — the active profile's reasoner.
  String get reasonerModel => active?.reasonerModel ?? model;

  /// Resolved "搜索大脑" model: the explicit choice, else the active profile's
  /// chat model (NOT the possibly-reasoner override, which can't call tools).
  String get effectiveSearchBrainModel {
    final chosen = searchBrainModel?.trim() ?? '';
    if (chosen.isNotEmpty) return chosen;
    return active?.chatModel ?? model;
  }

  /// Models offered in the picker for the active profile.
  List<String> get availableModels =>
      active?.models ?? const [KnownModels.chat, KnownModels.reasoner];

  LlmConfig get config =>
      LlmConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);

  LlmConfig get visionConfig => LlmConfig(
    baseUrl: visionApi.baseUrl,
    apiKey: visionApiKey,
    model: visionApi.model,
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
    Object? selectedModel = _sentinel,
    ThemeMode? themeMode,
    SearchBackend? searchBackend,
    String? searchApiKey,
    Object? searchBrainModel = _sentinel,
    int? searchMaxRounds,
    int? searchMaxResults,
    String? systemPrompt,
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
    GatewayConfig? gateway,
    String? gatewayToken,
    String? gatewayLegacyToken,
    Object? gatewayAuthSession = _sentinel,
    Future<String> Function()? gatewayTokenProvider,
    bool? memoryEnabled,
    bool? researchModeEnabled,
    bool? studyModeEnabled,
    bool? creationModeEnabled,
  }) => SettingsState(
    profiles: profiles ?? this.profiles,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    apiKey: apiKey ?? this.apiKey,
    selectedModel: identical(selectedModel, _sentinel)
        ? this.selectedModel
        : selectedModel as String?,
    themeMode: themeMode ?? this.themeMode,
    searchBackend: searchBackend ?? this.searchBackend,
    searchApiKey: searchApiKey ?? this.searchApiKey,
    searchBrainModel: identical(searchBrainModel, _sentinel)
        ? this.searchBrainModel
        : searchBrainModel as String?,
    searchMaxRounds: searchMaxRounds ?? this.searchMaxRounds,
    searchMaxResults: searchMaxResults ?? this.searchMaxResults,
    systemPrompt: systemPrompt ?? this.systemPrompt,
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
    gateway: gateway ?? this.gateway,
    gatewayToken: gatewayToken ?? this.gatewayToken,
    gatewayLegacyToken: gatewayLegacyToken ?? this.gatewayLegacyToken,
    gatewayAuthSession: identical(gatewayAuthSession, _sentinel)
        ? this.gatewayAuthSession
        : gatewayAuthSession as GatewayAuthSession?,
    gatewayTokenProvider: gatewayTokenProvider ?? this.gatewayTokenProvider,
    memoryEnabled: memoryEnabled ?? this.memoryEnabled,
    researchModeEnabled: researchModeEnabled ?? this.researchModeEnabled,
    studyModeEnabled: studyModeEnabled ?? this.studyModeEnabled,
    creationModeEnabled: creationModeEnabled ?? this.creationModeEnabled,
  );

  static const _sentinel = Object();
}

const _kProfiles = 'providerProfiles';
const _kActiveProfile = 'activeProfileId';
const _kSelectedModel = 'selectedModel';
const _kThemeMode = 'themeMode';
const _kSearchBackend = 'searchBackend';
const _kSearchApiKeySecure = 'search_api_key';
const _kSearchBrainModel = 'searchBrainModel';
const _kSearchMaxRounds = 'searchMaxRounds';
const _kSearchMaxResults = 'searchMaxResults';
const _kSystemPrompt = 'systemPrompt';
const _kUiPrefs = 'uiPrefs';
const _kVisionApi = 'visionApi';
const _kVisionApiKeySecure = 'vision_api_key';
const _kImageGenerationApi = 'imageGenerationApi';
const _kImageGenerationApiKeySecure = 'image_generation_api_key';
const _kTtsApi = 'ttsApi';
const _kTtsApiKeySecure = 'tts_api_key';
const _kAsrApi = 'asrApi';
const _kAsrApiKeySecure = 'asr_api_key';
const _kContextPrefs = 'contextPrefs';
const _kGateway = 'expertChatGateway';
const _kGatewayTokenSecure = 'expert_chat_gateway_token';
const _kGatewayOidcAccessTokenSecure = 'expert_chat_gateway_oidc_access_token';
const _kGatewayOidcRefreshTokenSecure =
    'expert_chat_gateway_oidc_refresh_token';
const _kGatewayOidcExpiresAtSecure = 'expert_chat_gateway_oidc_expires_at';
const _kGatewayOidcSubjectSecure = 'expert_chat_gateway_oidc_subject';
const _kGatewayOidcDisplayNameSecure = 'expert_chat_gateway_oidc_display_name';
// Legacy split-service keys retained for a lossless one-time migration.
const _kLegacyDocumentService = 'documentService';
const _kLegacyDocumentServiceTokenSecure = 'document_service_token';
const _kLegacyLongTaskGateway = 'longTaskGateway';
const _kLegacyLongTaskGatewayTokenSecure = 'long_task_gateway_token';
const _kMemoryEnabled = 'memoryEnabled';
const _kResearchModeEnabled = 'researchModeEnabled';
const _kStudyModeEnabled = 'studyModeEnabled';
const _kCreationModeEnabled = 'creationModeEnabled';

// Legacy M1 keys (single-config) — read once for migration.
const _kLegacyBaseUrl = 'baseUrl';
const _kLegacyModel = 'model';
const _kLegacyApiKeySecure = 'llm_api_key';
const _kProfilesCorruptBackup = 'providerProfiles.corrupt';

/// Stable secure-storage key used by provider-scoped background jobs as well as
/// the settings controller. A job may outlive a change of active provider.
String providerApiKeyStorageKey(String profileId) => 'apikey_$profileId';

/// TTS providers keep independent endpoint/model/voice profiles. The legacy
/// keys above continue to mirror whichever profile is active so old releases
/// and existing installs remain compatible.
String _ttsApiProfilePrefsKey(SpeechApiProtocol protocol) =>
    'ttsApi.${protocol.name}';

String _ttsApiProfileSecureKey(SpeechApiProtocol protocol) =>
    'tts_api_key.${protocol.name}';

/// Loads settings (profiles + active key) and persists changes. Migrates the
/// M1 single-config layout to a profile on first run.
class SettingsController extends AsyncNotifier<SettingsState> {
  Future<GatewayAuthSession>? _gatewayRefreshInFlight;

  @override
  Future<SettingsState> build() async {
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);

    final profileRead = _readProfiles(prefs);
    List<ProviderProfile> profiles = profileRead.profiles;
    String? activeId = prefs.getString(_kActiveProfile);
    final legacyKey = await secure.read(key: _kLegacyApiKeySecure);

    // First run / migration from the M1 single-config layout.
    // Never treat a *corrupt* profiles blob as first-run empty — that would
    // overwrite the user's JSON with a default preset.
    if (profiles.isEmpty && !profileRead.corrupt) {
      final legacyBaseUrl = prefs.getString(_kLegacyBaseUrl);
      if (legacyBaseUrl != null || legacyKey != null) {
        final migrated = ProviderProfile(
          name: 'DeepSeek',
          baseUrl: legacyBaseUrl ?? 'https://api.deepseek.com',
          chatModel: prefs.getString(_kLegacyModel) ?? KnownModels.chat,
          reasonerModel: KnownModels.reasoner,
          models: const [KnownModels.chat, KnownModels.reasoner],
        );
        profiles = [migrated];
        if (legacyKey != null && legacyKey.isNotEmpty) {
          await secure.write(
            key: providerApiKeyStorageKey(migrated.id),
            value: legacyKey,
          );
        }
      } else {
        profiles = [ProviderPreset.presets.first.toProfile()];
      }
      activeId = profiles.first.id;
      await _writeProfiles(prefs, profiles);
      await prefs.setString(_kActiveProfile, activeId);
    } else if (profiles.isEmpty && profileRead.corrupt) {
      // Keep UI usable without clobbering the corrupt store.
      profiles = [ProviderPreset.presets.first.toProfile()];
      activeId = profiles.first.id;
    }

    // One-time upgrade: bump unmodified DeepSeek profiles to the v4 models.
    if (profiles.any(_isLegacyDeepSeek)) {
      profiles = [
        for (final p in profiles)
          if (_isLegacyDeepSeek(p))
            p.copyWith(
              chatModel: 'deepseek-v4-flash',
              reasonerModel: 'deepseek-v4-pro',
              models: const ['deepseek-v4-flash', 'deepseek-v4-pro'],
            )
          else
            p,
      ];
      await _writeProfiles(prefs, profiles);
    }

    // Old releases copied the M1 secret into a profile but left `llm_api_key`
    // behind. Run cleanup for already-migrated installations too, not only
    // inside the first-run branch above. Delete only after finding a verified
    // profile copy, and preserve it when profile JSON itself is corrupt.
    if (!profileRead.corrupt && legacyKey != null && legacyKey.isNotEmpty) {
      var copied = false;
      for (final profile in profiles) {
        final profileKey = await secure.read(
          key: providerApiKeyStorageKey(profile.id),
        );
        if (profileKey == legacyKey) {
          copied = true;
          break;
        }
      }
      if (copied) {
        await secure.delete(key: _kLegacyApiKeySecure);
      }
    }

    activeId ??= profiles.first.id;
    final apiKey =
        await secure.read(key: providerApiKeyStorageKey(activeId)) ?? '';
    final searchApiKey = await secure.read(key: _kSearchApiKeySecure) ?? '';
    final visionApiKey = await secure.read(key: _kVisionApiKeySecure) ?? '';
    final imageGenerationApiKey =
        await secure.read(key: _kImageGenerationApiKeySecure) ?? '';
    final ttsApi = _readMediaApi(prefs, _kTtsApi);
    var ttsApiKey = await secure.read(key: _kTtsApiKeySecure) ?? '';
    final activeTtsProtocol = ttsApi.effectiveSpeechProtocol;
    final activeTtsProfilePrefsKey = _ttsApiProfilePrefsKey(activeTtsProtocol);
    final activeTtsProfileSecureKey = _ttsApiProfileSecureKey(
      activeTtsProtocol,
    );

    // One-time, lossless migration from the old single TTS slot. Keep the old
    // slot as the active-profile mirror, and seed the matching provider slot
    // only when it does not already exist.
    if (!prefs.containsKey(activeTtsProfilePrefsKey)) {
      await prefs.setString(
        activeTtsProfilePrefsKey,
        jsonEncode(ttsApi.toJson()),
      );
    }
    final providerTtsApiKey = await secure.read(key: activeTtsProfileSecureKey);
    if (providerTtsApiKey != null) {
      ttsApiKey = providerTtsApiKey;
    } else if (ttsApiKey.isNotEmpty) {
      await secure.write(key: activeTtsProfileSecureKey, value: ttsApiKey);
    }
    final asrApiKey = await secure.read(key: _kAsrApiKeySecure) ?? '';
    var gateway = _readGateway(prefs);
    if (gateway == null) {
      gateway = _migrateLegacyGateway(prefs);
      await prefs.setString(_kGateway, jsonEncode(gateway.toJson()));
    }
    var gatewayLegacyToken = await secure.read(key: _kGatewayTokenSecure) ?? '';
    if (gatewayLegacyToken.isEmpty) {
      gatewayLegacyToken =
          await secure.read(key: _kLegacyLongTaskGatewayTokenSecure) ?? '';
      if (gatewayLegacyToken.isEmpty) {
        gatewayLegacyToken =
            await secure.read(key: _kLegacyDocumentServiceTokenSecure) ?? '';
      }
      if (gatewayLegacyToken.isNotEmpty) {
        await secure.write(
          key: _kGatewayTokenSecure,
          value: gatewayLegacyToken,
        );
      }
    }
    var gatewayAuthSession = await _readGatewayAuthSession();
    if (gateway.authServiceConfigured &&
        gatewayAuthSession != null &&
        gatewayAuthSession.needsRefresh) {
      try {
        gatewayAuthSession = await ref
            .read(gatewayAuthServiceProvider)
            .refresh(gateway, gatewayAuthSession);
        await _persistGatewayAuthSession(gatewayAuthSession);
      } catch (_) {
        // Preserve the refresh token for a later online retry. Gateway clients
        // call _freshGatewayToken before every request.
      }
    }
    final gatewayToken =
        gateway.authServiceConfigured && gatewayAuthSession != null
        ? gatewayAuthSession.accessToken
        : gatewayLegacyToken;

    // Drop a stored model override that no longer exists in the active
    // profile's model list (e.g. the profile was edited since), so requests
    // can't silently go out with a stale model id.
    final id = activeId;
    final activeProfile = profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => profiles.first,
    );
    var selectedModel = prefs.getString(_kSelectedModel);
    if (selectedModel != null &&
        !activeProfile.models.contains(selectedModel)) {
      selectedModel = null;
      await prefs.remove(_kSelectedModel);
    }

    return SettingsState(
      profiles: profiles,
      activeProfileId: activeId,
      apiKey: apiKey,
      selectedModel: selectedModel,
      themeMode: _readThemeMode(prefs),
      searchBackend: SearchBackendInfo.fromWire(
        prefs.getString(_kSearchBackend),
      ),
      searchApiKey: searchApiKey,
      searchBrainModel: prefs.getString(_kSearchBrainModel),
      searchMaxRounds:
          (prefs.getInt(_kSearchMaxRounds) ?? kDefaultSearchMaxRounds).clamp(
            kMinSearchMaxRounds,
            kMaxSearchMaxRounds,
          ),
      searchMaxResults:
          (prefs.getInt(_kSearchMaxResults) ?? kDefaultSearchMaxResults).clamp(
            kMinSearchMaxResults,
            kMaxSearchMaxResults,
          ),
      systemPrompt: prefs.getString(_kSystemPrompt) ?? '',
      ui: _readUiPrefs(prefs),
      visionApi: _readMediaApi(prefs, _kVisionApi),
      visionApiKey: visionApiKey,
      imageGenerationApi: _readMediaApi(prefs, _kImageGenerationApi),
      imageGenerationApiKey: imageGenerationApiKey,
      ttsApi: ttsApi,
      ttsApiKey: ttsApiKey,
      asrApi: _readMediaApi(prefs, _kAsrApi),
      asrApiKey: asrApiKey,
      context: _readContextPrefs(prefs),
      gateway: gateway,
      gatewayToken: gatewayToken,
      gatewayLegacyToken: gatewayLegacyToken,
      gatewayAuthSession: gatewayAuthSession,
      gatewayTokenProvider: _freshGatewayToken,
      memoryEnabled: prefs.getBool(_kMemoryEnabled) ?? false,
      researchModeEnabled: prefs.getBool(_kResearchModeEnabled) ?? false,
      // Default on: learning hub is part of the main product surface.
      studyModeEnabled: prefs.getBool(_kStudyModeEnabled) ?? true,
      // Default on: existing installs keep the 创作 tab unless user hides it.
      creationModeEnabled: prefs.getBool(_kCreationModeEnabled) ?? true,
    );
  }

  Future<void> setMemoryEnabled(bool enabled) async {
    final next = _current.copyWith(memoryEnabled: enabled);
    state = AsyncData(next);
    await ref.read(sharedPrefsProvider).setBool(_kMemoryEnabled, enabled);
  }

  /// M7: toggle hidden research mode (SSH terminal). Does not connect.
  Future<void> setResearchModeEnabled(bool enabled) async {
    final next = _current.copyWith(researchModeEnabled: enabled);
    state = AsyncData(next);
    await ref.read(sharedPrefsProvider).setBool(_kResearchModeEnabled, enabled);
  }

  /// Show/hide the 学习 hub tab. Does not delete courses or cards.
  Future<void> setStudyModeEnabled(bool enabled) async {
    final next = _current.copyWith(studyModeEnabled: enabled);
    state = AsyncData(next);
    await ref.read(sharedPrefsProvider).setBool(_kStudyModeEnabled, enabled);
  }

  /// Show/hide the 创作 hub tab. Does not delete characters or drafts.
  Future<void> setCreationModeEnabled(bool enabled) async {
    final next = _current.copyWith(creationModeEnabled: enabled);
    state = AsyncData(next);
    await ref.read(sharedPrefsProvider).setBool(_kCreationModeEnabled, enabled);
  }

  /// A stored theme index from a corrupt/older store may fall outside the
  /// enum range; fall back to the default instead of crashing the whole build.
  static ThemeMode _readThemeMode(SharedPreferences prefs) {
    final stored = prefs.getInt(_kThemeMode);
    if (stored == null || stored < 0 || stored >= ThemeMode.values.length) {
      return ThemeMode.system;
    }
    return ThemeMode.values[stored];
  }

  static UiPrefs _readUiPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_kUiPrefs);
    if (raw == null || raw.isEmpty) return const UiPrefs();
    try {
      return UiPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const UiPrefs();
    }
  }

  static MediaApiConfig _readMediaApi(SharedPreferences prefs, String key) {
    return _readMediaApiOrNull(prefs, key) ?? const MediaApiConfig();
  }

  static MediaApiConfig? _readMediaApiOrNull(
    SharedPreferences prefs,
    String key,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return MediaApiConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static GatewayConfig? _readGateway(SharedPreferences prefs) {
    final raw = prefs.getString(_kGateway);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return GatewayConfig.fromJson(decoded);
      }
      if (decoded is Map) {
        return GatewayConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  static GatewayConfig _migrateLegacyGateway(SharedPreferences prefs) {
    Map<String, dynamic> readLegacy(String key) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return const {};
    }

    final longTask = readLegacy(_kLegacyLongTaskGateway);
    final document = readLegacy(_kLegacyDocumentService);
    final longUrl = longTask['baseUrl']?.toString().trim() ?? '';
    final documentUrl = document['baseUrl']?.toString().trim() ?? '';
    final longEnabled = longTask['enabled'] == true && longUrl.isNotEmpty;
    final documentEnabled =
        document['enabled'] == true && documentUrl.isNotEmpty;
    final baseUrl = longEnabled
        ? longUrl
        : documentEnabled
        ? documentUrl
        : longUrl.isNotEmpty
        ? longUrl
        : documentUrl.isNotEmpty
        ? documentUrl
        : 'http://127.0.0.1:8790';
    return GatewayConfig(
      enabled: longEnabled || documentEnabled,
      baseUrl: baseUrl,
      taskModel: longTask['model']?.toString() ?? '',
      taskPollSeconds: (longTask['pollSeconds'] as num?)?.toInt() ?? 2,
      requestTimeoutSeconds:
          (document['timeoutSeconds'] as num?)?.toInt() ?? 120,
      // The legacy servers did not expose a common manifest. Stay optimistic
      // until the user runs capability discovery against the unified server.
      capabilitiesDiscovered: false,
    );
  }

  static ContextPrefs _readContextPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_kContextPrefs);
    if (raw == null || raw.isEmpty) return const ContextPrefs();
    try {
      return ContextPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ContextPrefs();
    }
  }

  /// A DeepSeek profile still carrying the old default model list (so we can
  /// safely upgrade it without clobbering a user's custom edits).
  static bool _isLegacyDeepSeek(ProviderProfile p) =>
      p.baseUrl.contains('api.deepseek.com') &&
      p.models.contains('deepseek-chat') &&
      p.models.contains('deepseek-reasoner');

  SettingsState get _current => state.value ?? const SettingsState();

  ({List<ProviderProfile> profiles, bool corrupt}) _readProfiles(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) {
      return (profiles: const [], corrupt: false);
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final profiles = list
          .map((e) => ProviderProfile.fromJson(e as Map<String, dynamic>))
          .toList();
      return (profiles: profiles, corrupt: false);
    } catch (_) {
      // Preserve the broken payload for manual recovery; never silent-overwrite.
      unawaited(prefs.setString(_kProfilesCorruptBackup, raw));
      return (profiles: const [], corrupt: true);
    }
  }

  Future<void> _writeProfiles(
    SharedPreferences prefs,
    List<ProviderProfile> profiles,
  ) => prefs.setString(
    _kProfiles,
    jsonEncode(profiles.map((p) => p.toJson()).toList()),
  );

  /// Update theme and/or model selection (lightweight, frequently called).
  ///
  /// [selectedModel] uses the same sentinel convention as [SettingsState.copyWith]:
  /// omitting it leaves the current model untouched (so e.g. switching theme
  /// alone doesn't wipe the picked model), passing `null` clears it back to the
  /// profile default, and passing a value sets it.
  Future<void> apply({
    Object? selectedModel = SettingsState._sentinel,
    ThemeMode? themeMode,
  }) async {
    final next = _current.copyWith(
      selectedModel: selectedModel,
      themeMode: themeMode,
    );
    state = AsyncData(next);
    final prefs = ref.read(sharedPrefsProvider);
    if (!identical(selectedModel, SettingsState._sentinel)) {
      final model = selectedModel as String?;
      if (model != null) {
        await prefs.setString(_kSelectedModel, model);
      } else {
        await prefs.remove(_kSelectedModel);
      }
    }
    if (themeMode != null) await prefs.setInt(_kThemeMode, themeMode.index);
  }

  /// Patch appearance prefs and persist as JSON.
  Future<void> setUiPrefs(UiPrefs ui) async {
    state = AsyncData(_current.copyWith(ui: ui));
    await ref
        .read(sharedPrefsProvider)
        .setString(_kUiPrefs, jsonEncode(ui.toJson()));
  }

  /// Set the API key for the active profile.
  Future<void> setApiKey(String apiKey) async {
    final active = _current.active;
    if (active == null) return;
    state = AsyncData(_current.copyWith(apiKey: apiKey));
    await ref
        .read(secureStorageProvider)
        .write(key: providerApiKeyStorageKey(active.id), value: apiKey);
  }

  /// Set the web-search backend.
  Future<void> setSearchBackend(SearchBackend backend) async {
    state = AsyncData(_current.copyWith(searchBackend: backend));
    await ref
        .read(sharedPrefsProvider)
        .setString(_kSearchBackend, backend.wire);
  }

  /// Set the web-search API key (stored in secure storage).
  Future<void> setSearchApiKey(String key) async {
    state = AsyncData(_current.copyWith(searchApiKey: key));
    await ref
        .read(secureStorageProvider)
        .write(key: _kSearchApiKeySecure, value: key);
  }

  /// Pick the "搜索大脑" model; null/empty follows the profile's chat model.
  Future<void> setSearchBrainModel(String? model) async {
    final normalized = (model?.trim().isEmpty ?? true) ? null : model!.trim();
    state = AsyncData(_current.copyWith(searchBrainModel: normalized));
    final prefs = ref.read(sharedPrefsProvider);
    if (normalized == null) {
      await prefs.remove(_kSearchBrainModel);
    } else {
      await prefs.setString(_kSearchBrainModel, normalized);
    }
  }

  Future<void> setSearchMaxRounds(int rounds) async {
    final bounded = rounds.clamp(kMinSearchMaxRounds, kMaxSearchMaxRounds);
    state = AsyncData(_current.copyWith(searchMaxRounds: bounded));
    await ref.read(sharedPrefsProvider).setInt(_kSearchMaxRounds, bounded);
  }

  Future<void> setSearchMaxResults(int results) async {
    final bounded = results.clamp(kMinSearchMaxResults, kMaxSearchMaxResults);
    state = AsyncData(_current.copyWith(searchMaxResults: bounded));
    await ref.read(sharedPrefsProvider).setInt(_kSearchMaxResults, bounded);
  }

  Future<void> setGatewayConfig(GatewayConfig config) async {
    final current = _current.gateway;
    final authChanged =
        config.normalizedAuthServiceUrl != current.normalizedAuthServiceUrl ||
        config.oidcClientId.trim() != current.oidcClientId.trim() ||
        config.oidcRedirectUri.trim() != current.oidcRedirectUri.trim();
    final next = config.normalizedBaseUrl != current.normalizedBaseUrl
        ? config.clearDiscovery()
        : config;
    if (authChanged && _current.gatewayAuthSession != null) {
      await _clearGatewayAuthSession();
      state = AsyncData(
        _current.copyWith(
          gateway: next,
          gatewayToken: _current.gatewayLegacyToken,
          gatewayAuthSession: null,
        ),
      );
    } else {
      state = AsyncData(_current.copyWith(gateway: next));
    }
    await ref
        .read(sharedPrefsProvider)
        .setString(_kGateway, jsonEncode(next.toJson()));
  }

  Future<void> setGatewayToken(String token) async {
    state = AsyncData(
      _current.copyWith(
        gatewayLegacyToken: token,
        gatewayToken: _current.gatewayAuthSession == null
            ? token
            : _current.gatewayToken,
      ),
    );
    await ref
        .read(secureStorageProvider)
        .write(key: _kGatewayTokenSecure, value: token);
  }

  Future<void> signInGateway() async {
    final config = _current.gateway;
    final session = await ref.read(gatewayAuthServiceProvider).signIn(config);
    await _persistGatewayAuthSession(session);
    state = AsyncData(
      _current.copyWith(
        gatewayToken: session.accessToken,
        gatewayAuthSession: session,
        gatewayTokenProvider: _freshGatewayToken,
      ),
    );
  }

  Future<void> signOutGateway() async {
    await _clearGatewayAuthSession();
    state = AsyncData(
      _current.copyWith(
        gatewayToken: _current.gatewayLegacyToken,
        gatewayAuthSession: null,
      ),
    );
  }

  Future<String> _freshGatewayToken() async {
    final current = _current;
    final session = current.gatewayAuthSession;
    if (!current.gateway.authServiceConfigured || session == null) {
      return current.gatewayLegacyToken;
    }
    if (!session.needsRefresh) return session.accessToken;
    var pending = _gatewayRefreshInFlight;
    if (pending == null) {
      pending = ref
          .read(gatewayAuthServiceProvider)
          .refresh(current.gateway, session);
      _gatewayRefreshInFlight = pending;
    }
    try {
      final refreshed = await pending;
      await _persistGatewayAuthSession(refreshed);
      state = AsyncData(
        _current.copyWith(
          gatewayToken: refreshed.accessToken,
          gatewayAuthSession: refreshed,
        ),
      );
      return refreshed.accessToken;
    } catch (_) {
      if (DateTime.now().toUtc().isBefore(session.expiresAt)) {
        return session.accessToken;
      }
      rethrow;
    } finally {
      if (identical(_gatewayRefreshInFlight, pending)) {
        _gatewayRefreshInFlight = null;
      }
    }
  }

  Future<GatewayAuthSession?> _readGatewayAuthSession() async {
    final secure = ref.read(secureStorageProvider);
    final access = await secure.read(key: _kGatewayOidcAccessTokenSecure) ?? '';
    final refresh =
        await secure.read(key: _kGatewayOidcRefreshTokenSecure) ?? '';
    final expiresRaw =
        await secure.read(key: _kGatewayOidcExpiresAtSecure) ?? '';
    final subject = await secure.read(key: _kGatewayOidcSubjectSecure) ?? '';
    final displayName =
        await secure.read(key: _kGatewayOidcDisplayNameSecure) ?? subject;
    final expiresAt = DateTime.tryParse(expiresRaw)?.toUtc();
    if (access.isEmpty || expiresAt == null) return null;
    return GatewayAuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      subject: subject,
      displayName: displayName,
    );
  }

  Future<void> _persistGatewayAuthSession(GatewayAuthSession session) async {
    final secure = ref.read(secureStorageProvider);
    await Future.wait([
      secure.write(
        key: _kGatewayOidcAccessTokenSecure,
        value: session.accessToken,
      ),
      secure.write(
        key: _kGatewayOidcRefreshTokenSecure,
        value: session.refreshToken,
      ),
      secure.write(
        key: _kGatewayOidcExpiresAtSecure,
        value: session.expiresAt.toUtc().toIso8601String(),
      ),
      secure.write(key: _kGatewayOidcSubjectSecure, value: session.subject),
      secure.write(
        key: _kGatewayOidcDisplayNameSecure,
        value: session.displayName,
      ),
    ]);
  }

  Future<void> _clearGatewayAuthSession() async {
    final secure = ref.read(secureStorageProvider);
    await Future.wait([
      secure.delete(key: _kGatewayOidcAccessTokenSecure),
      secure.delete(key: _kGatewayOidcRefreshTokenSecure),
      secure.delete(key: _kGatewayOidcExpiresAtSecure),
      secure.delete(key: _kGatewayOidcSubjectSecure),
      secure.delete(key: _kGatewayOidcDisplayNameSecure),
    ]);
  }

  Future<void> setGatewayCapabilities({
    required List<String> capabilities,
    required String serverVersion,
  }) => setGatewayConfig(
    _current.gateway.copyWith(
      capabilitiesDiscovered: true,
      capabilities: capabilities.toSet().toList()..sort(),
      serverVersion: serverVersion,
    ),
  );

  /// Set the global preset/system prompt (persisted in shared preferences).
  Future<void> setSystemPrompt(String prompt) async {
    state = AsyncData(_current.copyWith(systemPrompt: prompt));
    await ref.read(sharedPrefsProvider).setString(_kSystemPrompt, prompt);
  }

  Future<void> setContextPrefs(ContextPrefs context) async {
    state = AsyncData(_current.copyWith(context: context));
    await ref
        .read(sharedPrefsProvider)
        .setString(_kContextPrefs, jsonEncode(context.toJson()));
  }

  Future<void> setMediaApiConfig(
    MediaApiKind kind,
    MediaApiConfig config,
  ) async {
    final prefs = ref.read(sharedPrefsProvider);
    final encoded = jsonEncode(config.toJson());
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(_current.copyWith(visionApi: config));
        await prefs.setString(_kVisionApi, encoded);
      case MediaApiKind.imageGeneration:
        state = AsyncData(_current.copyWith(imageGenerationApi: config));
        await prefs.setString(_kImageGenerationApi, encoded);
      case MediaApiKind.tts:
        state = AsyncData(_current.copyWith(ttsApi: config));
        await prefs.setString(_kTtsApi, encoded);
        await prefs.setString(
          _ttsApiProfilePrefsKey(config.effectiveSpeechProtocol),
          encoded,
        );
      case MediaApiKind.asr:
        state = AsyncData(_current.copyWith(asrApi: config));
        await prefs.setString(_kAsrApi, encoded);
    }
  }

  Future<void> setMediaApiKey(MediaApiKind kind, String key) async {
    // Media cards may flush a debounced key from dispose via microtask; by
    // then the settings provider can already be gone (route pop / test
    // teardown). Skip rather than throwing UnmountedRefException.
    if (!ref.mounted) return;
    final secure = ref.read(secureStorageProvider);
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(_current.copyWith(visionApiKey: key));
        await secure.write(key: _kVisionApiKeySecure, value: key);
      case MediaApiKind.imageGeneration:
        state = AsyncData(_current.copyWith(imageGenerationApiKey: key));
        await secure.write(key: _kImageGenerationApiKeySecure, value: key);
      case MediaApiKind.tts:
        final protocol = _current.ttsApi.effectiveSpeechProtocol;
        state = AsyncData(_current.copyWith(ttsApiKey: key));
        await secure.write(key: _kTtsApiKeySecure, value: key);
        await secure.write(key: _ttsApiProfileSecureKey(protocol), value: key);
      case MediaApiKind.asr:
        state = AsyncData(_current.copyWith(asrApiKey: key));
        await secure.write(key: _kAsrApiKeySecure, value: key);
    }
  }

  /// Switches the active TTS provider without overwriting another provider's
  /// endpoint, model, voice, or API key. [fallback] is used only the first
  /// time that provider is selected.
  Future<void> selectTtsProvider(
    SpeechApiProtocol protocol,
    MediaApiConfig fallback,
  ) async {
    if (!ref.mounted) return;
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);
    final current = _current;
    final currentProtocol = current.ttsApi.effectiveSpeechProtocol;

    // Capture the active provider before loading the target. This also covers
    // a legacy install that has not switched providers since migration.
    await prefs.setString(
      _ttsApiProfilePrefsKey(currentProtocol),
      jsonEncode(current.ttsApi.toJson()),
    );
    await secure.write(
      key: _ttsApiProfileSecureKey(currentProtocol),
      value: current.ttsApiKey,
    );

    final targetConfig =
        _readMediaApiOrNull(prefs, _ttsApiProfilePrefsKey(protocol)) ??
        fallback.copyWith(speechProtocol: protocol);
    final targetApiKey =
        await secure.read(key: _ttsApiProfileSecureKey(protocol)) ?? '';
    if (!ref.mounted) return;

    state = AsyncData(
      _current.copyWith(ttsApi: targetConfig, ttsApiKey: targetApiKey),
    );

    // Mirror the selected profile to the original active TTS keys.
    await prefs.setString(_kTtsApi, jsonEncode(targetConfig.toJson()));
    await secure.write(key: _kTtsApiKeySecure, value: targetApiKey);
  }

  /// Switch the active profile, loading its stored key.
  Future<void> selectProfile(String id) async {
    if (!_current.profiles.any((p) => p.id == id)) return;
    final key =
        await ref
            .read(secureStorageProvider)
            .read(key: providerApiKeyStorageKey(id)) ??
        '';
    state = AsyncData(
      _current.copyWith(activeProfileId: id, apiKey: key, selectedModel: null),
    );
    final prefs = ref.read(sharedPrefsProvider);
    await prefs.setString(_kActiveProfile, id);
    await prefs.remove(_kSelectedModel);
  }

  /// Add a profile (e.g. from a preset). Becomes active.
  Future<void> addProfile(ProviderProfile profile) async {
    final profiles = [..._current.profiles, profile];
    state = AsyncData(
      _current.copyWith(
        profiles: profiles,
        activeProfileId: profile.id,
        apiKey: '',
        selectedModel: null,
      ),
    );
    final prefs = ref.read(sharedPrefsProvider);
    await _writeProfiles(prefs, profiles);
    await prefs.setString(_kActiveProfile, profile.id);
    await prefs.remove(_kSelectedModel);
  }

  /// Edit an existing profile in place. Clears the model override when the
  /// edit removed that model from the active profile's list.
  Future<void> updateProfile(ProviderProfile updated) async {
    final profiles = [
      for (final p in _current.profiles) p.id == updated.id ? updated : p,
    ];
    final overrideStale =
        updated.id == _current.activeProfileId &&
        _current.selectedModel != null &&
        !updated.models.contains(_current.selectedModel);
    state = AsyncData(
      _current.copyWith(
        profiles: profiles,
        selectedModel: overrideStale ? null : _current.selectedModel,
      ),
    );
    final prefs = ref.read(sharedPrefsProvider);
    if (overrideStale) await prefs.remove(_kSelectedModel);
    await _writeProfiles(prefs, profiles);
  }

  /// Delete a profile and its stored key. Falls back to another profile, or a
  /// fresh DeepSeek preset if none remain.
  Future<void> deleteProfile(String id) async {
    final remaining = _current.profiles.where((p) => p.id != id).toList();
    final secure = ref.read(secureStorageProvider);
    await secure.delete(key: providerApiKeyStorageKey(id));

    final prefs = ref.read(sharedPrefsProvider);
    if (remaining.isEmpty) {
      final fresh = ProviderPreset.presets.first.toProfile();
      // Keep search + system-prompt settings: only the LLM profile is being
      // replaced. Dropping them here would clear the in-memory form while the
      // secure-storage / prefs values still exist, so a restart "revives" them.
      state = AsyncData(
        SettingsState(
          profiles: [fresh],
          activeProfileId: fresh.id,
          apiKey: '',
          themeMode: _current.themeMode,
          searchBackend: _current.searchBackend,
          searchApiKey: _current.searchApiKey,
          searchBrainModel: _current.searchBrainModel,
          searchMaxRounds: _current.searchMaxRounds,
          searchMaxResults: _current.searchMaxResults,
          systemPrompt: _current.systemPrompt,
          ui: _current.ui,
          visionApi: _current.visionApi,
          visionApiKey: _current.visionApiKey,
          imageGenerationApi: _current.imageGenerationApi,
          imageGenerationApiKey: _current.imageGenerationApiKey,
          ttsApi: _current.ttsApi,
          ttsApiKey: _current.ttsApiKey,
          asrApi: _current.asrApi,
          asrApiKey: _current.asrApiKey,
          context: _current.context,
          gateway: _current.gateway,
          gatewayToken: _current.gatewayToken,
          memoryEnabled: _current.memoryEnabled,
          researchModeEnabled: _current.researchModeEnabled,
          studyModeEnabled: _current.studyModeEnabled,
          creationModeEnabled: _current.creationModeEnabled,
        ),
      );
      await _writeProfiles(prefs, [fresh]);
      await prefs.setString(_kActiveProfile, fresh.id);
      await prefs.remove(_kSelectedModel);
      return;
    }

    var activeId = _current.activeProfileId;
    var apiKey = _current.apiKey;
    if (activeId == id) {
      activeId = remaining.first.id;
      apiKey = await secure.read(key: providerApiKeyStorageKey(activeId)) ?? '';
    }
    state = AsyncData(
      _current.copyWith(
        profiles: remaining,
        activeProfileId: activeId,
        apiKey: apiKey,
        selectedModel: null,
      ),
    );
    await _writeProfiles(prefs, remaining);
    await prefs.setString(_kActiveProfile, activeId!);
  }
}

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, SettingsState>(
      SettingsController.new,
    );
