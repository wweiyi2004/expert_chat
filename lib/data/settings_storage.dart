import '../state/model_context.dart';
import 'dart:async';
import 'dart:convert';
import '../platform/theme_mode.dart';
import '../platform/credentials.dart';
import '../platform/preferences.dart';
import 'chat_skill.dart';
import 'subagent_role.dart';
import 'prompt_presets.dart';
import 'jev_config.dart';
import 'composer_modes.dart';
import 'context_prefs.dart';
import 'gateway_config.dart';
import 'media_api_config.dart';
import 'provider_profile.dart';
import 'model_service_credential_snapshot.dart';
import 'task_budget_prefs.dart';
import 'ui_prefs.dart';
import 'settings_state.dart';
import 'settings_storage_keys.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/gateway/gateway_auth_service.dart';
import '../domain/tools/search_provider.dart';

/// Startup decoding, legacy migration and credential persistence. No Riverpod
/// state is owned here; controller mutations still serialize secret writes.
class SettingsStorage {
  SettingsStorage({
    required this.prefs,
    required this.secure,
    required this.authService,
    required this.freshGatewayToken,
  });
  final SharedPreferences prefs;
  final FlutterSecureStorage secure;
  final GatewayAuthService authService;
  final Future<String> Function() freshGatewayToken;

  Future<SettingsState> load() async {
    // Decode stored configuration before any startup migration writes.
    var gateway = readGateway(prefs);
    final storedSystemPrompt = prefs.getString(kSettingsSystemPrompt) ?? '';
    final storedSkills = prefs.getString(kSettingsChatSkills);
    final catalog = ChatSkillCatalog.decode(
      storedSkills,
      legacySystemPrompt: storedSystemPrompt,
    );
    // Read before first-run profile migration writes defaults.
    final existingInstall =
        prefs.containsKey(kSettingsProfiles) ||
        prefs.containsKey(kSettingsLegacyBaseUrl);
    final taskBudget = prefs.containsKey('taskBudget')
        ? TaskBudgetPrefs.decode(prefs.getString('taskBudget'))
        : existingInstall
        ? const TaskBudgetPrefs()
        : TaskBudgetPrefs.forPreset(TaskBudgetPreset.standard);
    if (!prefs.containsKey('taskBudget')) {
      await prefs.setString('taskBudget', jsonEncode(taskBudget.toJson()));
    }

    final profileRead = readProfiles(prefs);
    List<ProviderProfile> profiles = profileRead.profiles;
    String? activeId = prefs.getString(kSettingsActiveProfile);
    final legacyKey = await secure.read(key: kSettingsLegacyApiKeySecure);

    // First run / migration from the M1 single-config layout.
    // Never treat a *corrupt* profiles blob as first-run empty — that would
    // overwrite the user's JSON with a default preset.
    if (profiles.isEmpty && !profileRead.corrupt) {
      final legacyBaseUrl = prefs.getString(kSettingsLegacyBaseUrl);
      if (legacyBaseUrl != null || legacyKey != null) {
        final migrated = ProviderProfile(
          name: 'DeepSeek',
          baseUrl: legacyBaseUrl ?? 'https://api.deepseek.com',
          chatModel: prefs.getString(kSettingsLegacyModel) ?? KnownModels.flash,
          reasonerModel: KnownModels.reasoner,
          models: KnownModels.all,
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
      await writeProfiles(prefs, profiles);
      await prefs.setString(kSettingsActiveProfile, activeId);
    } else if (profiles.isEmpty && profileRead.corrupt) {
      // Keep UI usable without clobbering the corrupt store.
      profiles = [ProviderPreset.presets.first.toProfile()];
      activeId = profiles.first.id;
    }

    // One-time upgrade: bump unmodified DeepSeek profiles to the v4 models.
    if (profiles.any(isLegacyDeepSeek)) {
      profiles = [
        for (final p in profiles)
          if (isLegacyDeepSeek(p))
            p.copyWith(
              chatModel: KnownModels.flash,
              reasonerModel: KnownModels.reasoner,
              models: KnownModels.all,
            )
          else
            p,
      ];
      await writeProfiles(prefs, profiles);
    }

    // Retired Flash aliases are now served by deepseek-flash. Only official
    // endpoints migrate; gateway model IDs and custom models stay untouched.
    if (profiles.any((p) => _needsFlashAliasUpgrade(p))) {
      profiles = [
        for (final p in profiles)
          if (_needsFlashAliasUpgrade(p))
            p.copyWith(
              chatModel: _currentDeepSeekModel(p.chatModel),
              reasonerModel: _currentDeepSeekModel(p.reasonerModel),
              models: p.models.map(_currentDeepSeekModel).toSet().toList(),
            )
          else
            p,
      ];
      await writeProfiles(prefs, profiles);
    }

    // Add V4.1 Flash without changing the user's defaults or selected model.
    if (profiles.any(isDeepSeekMissingFlash)) {
      profiles = [
        for (final p in profiles)
          if (isDeepSeekMissingFlash(p))
            p.copyWith(models: [...p.models, KnownModels.flash])
          else
            p,
      ];
      await writeProfiles(prefs, profiles);
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
        await secure.delete(key: kSettingsLegacyApiKeySecure);
      }
    }

    activeId ??= profiles.first.id;
    var apiKey =
        await secure.read(key: providerApiKeyStorageKey(activeId)) ?? '';
    final activeBinding = await secure.read(
      key: providerCredentialBindingStorageKey(activeId),
    );
    final activeDescriptor = profiles.firstWhere(
      (profile) => profile.id == activeId,
    );
    if (activeBinding != null &&
        activeBinding != modelCredentialBinding(activeDescriptor, apiKey)) {
      apiKey = '';
    }
    var searchApiKey = await secure.read(
      key: kSettingsDeepSeekSearchApiKeySecure,
    );
    // Only migrate a key already identified as DeepSeek's, never another search vendor's key.
    if (searchApiKey == null &&
        prefs.getString(kSettingsSearchBackend) ==
            SearchBackend.deepseek.wire) {
      searchApiKey = await secure.read(key: kSettingsSearchApiKeySecure);
      if (searchApiKey != null) {
        await secure.write(
          key: kSettingsDeepSeekSearchApiKeySecure,
          value: searchApiKey,
        );
      }
    }
    final visionApiKey =
        await secure.read(key: kSettingsVisionApiKeySecure) ?? '';
    final imageGenerationApiKey =
        await secure.read(key: kSettingsImageGenerationApiKeySecure) ?? '';
    final ttsApi = readMediaApi(prefs, kSettingsTtsApi);
    var ttsApiKey = await secure.read(key: kSettingsTtsApiKeySecure) ?? '';
    final activeTtsProtocol = ttsApi.effectiveSpeechProtocol;
    final activeTtsProfilePrefsKey = ttsApiProfilePrefsKey(activeTtsProtocol);
    final activeTtsProfileSecureKey = ttsApiProfileSecureKey(activeTtsProtocol);

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
    final asrApiKey = await secure.read(key: kSettingsAsrApiKeySecure) ?? '';
    if (gateway == null) {
      gateway = migrateLegacyGateway(prefs);
      await prefs.setString(kSettingsGateway, jsonEncode(gateway.toJson()));
    }
    var gatewayLegacyToken =
        await secure.read(key: kSettingsGatewayTokenSecure) ?? '';
    if (gatewayLegacyToken.isEmpty) {
      gatewayLegacyToken =
          await secure.read(key: kSettingsLegacyLongTaskGatewayTokenSecure) ??
          '';
      if (gatewayLegacyToken.isEmpty) {
        gatewayLegacyToken =
            await secure.read(key: kSettingsLegacyDocumentServiceTokenSecure) ??
            '';
      }
      if (gatewayLegacyToken.isNotEmpty) {
        await secure.write(
          key: kSettingsGatewayTokenSecure,
          value: gatewayLegacyToken,
        );
      }
    }
    var gatewayAuthSession = await readGatewayAuthSession();
    if (gateway.authServiceConfigured &&
        gatewayAuthSession != null &&
        gatewayAuthSession.needsRefresh) {
      try {
        gatewayAuthSession = await authService.refresh(
          gateway,
          gatewayAuthSession,
        );
        await persistGatewayAuthSession(gatewayAuthSession);
      } catch (_) {
        // Preserve the refresh token for a later online retry. Gateway clients
        // call freshGatewayToken before every request.
      }
    }
    final gatewayToken =
        gateway.authServiceConfigured && gatewayAuthSession != null
        ? gatewayAuthSession.accessToken
        : gatewayLegacyToken;
    final customMcpTokens = <String, String>{};
    final customMcpEnvironments = <String, Map<String, String>>{},
        customMcpHeaders = <String, Map<String, String>>{};
    for (final server in gateway.customMcpServers) {
      final token =
          await secure.read(key: customMcpTokenStorageKey(server.id)) ?? '';
      if (token.isNotEmpty) customMcpTokens[server.id] = token;
      final secretRaw = await secure.read(
        key: customMcpSecretsStorageKey(server.id),
      );
      if (secretRaw != null) {
        final secret = jsonDecode(secretRaw) as Map;
        customMcpEnvironments[server.id] = Map<String, String>.from(
          secret['env'] as Map? ?? {},
        );
        customMcpHeaders[server.id] = Map<String, String>.from(
          secret['headers'] as Map? ?? {},
        );
      }
    }

    // Drop a stored model override that no longer exists in the active
    // profile's model list (e.g. the profile was edited since), so requests
    // can't silently go out with a stale model id.
    final id = activeId;
    final activeProfile = profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => profiles.first,
    );
    var selectedModel = prefs.getString(kSettingsSelectedModel);
    if (selectedModel != null &&
        Uri.tryParse(activeProfile.baseUrl)?.host.toLowerCase() ==
            'api.deepseek.com') {
      final normalized = _currentDeepSeekModel(selectedModel);
      if (normalized != selectedModel) {
        selectedModel = normalized;
        await prefs.setString(kSettingsSelectedModel, normalized);
      }
    }
    if (selectedModel != null &&
        !activeProfile.models.contains(selectedModel)) {
      selectedModel = null;
      await prefs.remove(kSettingsSelectedModel);
    }

    final encodedSkills = catalog.encode();
    if (storedSkills != encodedSkills) {
      await prefs.setString(kSettingsChatSkills, encodedSkills);
    }

    var searchBackend = SearchBackendInfo.fromWire(
      prefs.getString(kSettingsSearchBackend),
    );
    if (!(prefs.getBool(kSettingsDeepSeekSearchDefaultMigrated) ?? false)) {
      if (searchBackend == SearchBackend.duckduckgo ||
          (searchBackend == SearchBackend.provider &&
              ModelCatalog.isOfficialDeepSeekEndpoint(activeProfile.baseUrl))) {
        searchBackend = SearchBackend.deepseek;
      }
      await prefs.setString(kSettingsSearchBackend, searchBackend.wire);
      await prefs.setBool(kSettingsDeepSeekSearchDefaultMigrated, true);
    }

    return SettingsState(
      profiles: profiles,
      activeProfileId: activeId,
      taskBudget: taskBudget,
      apiKey: apiKey,
      selectedModel: selectedModel,
      themeMode: readThemePreference(prefs),
      searchBackend: SearchBackend.deepseek,
      searchApiKey: searchApiKey ?? '',
      searchBrainModel: prefs.getString(kSettingsSearchBrainModel),
      searchMaxRounds:
          (prefs.getInt(kSettingsSearchMaxRounds) ?? kDefaultSearchMaxRounds)
              .clamp(kMinSearchMaxRounds, kMaxSearchMaxRounds),
      searchMaxResults:
          (prefs.getInt(kSettingsSearchMaxResults) ?? kDefaultSearchMaxResults)
              .clamp(kMinSearchMaxResults, kMaxSearchMaxResults),
      searchMode: SearchModeInfo.fromWire(
        prefs.getString(kSettingsComposerSearchMode),
      ),
      imageGenMode: ImageGenModeInfo.fromWire(
        prefs.getString(kSettingsComposerImageGenMode),
      ),
      reasoningEffort: ReasoningEffort.fromWire(
        prefs.getString(kSettingsReasoningEffort),
      ),
      hasReasoningEffortOverride: prefs.containsKey(kSettingsReasoningEffort),
      systemPrompt: storedSystemPrompt,
      workAgentInstructions:
          prefs.getString(kSettingsWorkAgentInstructions) ?? '',
      subagentInstructions:
          prefs.getString(kSettingsSubagentInstructions) ?? '',
      subagentRoles: SubagentRole.decode(
        prefs.getString(kSettingsSubagentRoles),
      ),
      subagentRouterModel: prefs.getString(kSettingsSubagentRouterModel) ?? '',
      chatSkills: catalog,
      promptPresets: PromptPresets.decode(
        prefs.getString(PromptPresets.storageKey),
        legacyPrompt: storedSystemPrompt,
      ),
      jevConfig: JevConfig.decode(prefs.getString(kSettingsJevConfig)),
      jevApiKey: await secure.read(key: kSettingsJevApiKeySecure) ?? '',
      ui: readUiPrefs(prefs),
      visionApi: readMediaApi(prefs, kSettingsVisionApi),
      visionApiKey: visionApiKey,
      imageGenerationApi: readMediaApi(prefs, kSettingsImageGenerationApi),
      imageGenerationApiKey: imageGenerationApiKey,
      ttsApi: ttsApi,
      ttsApiKey: ttsApiKey,
      asrApi: readMediaApi(prefs, kSettingsAsrApi),
      asrApiKey: asrApiKey,
      context: readContextPrefs(prefs),
      modelContexts: decodeModelContexts(
        prefs.getString(kSettingsModelContexts),
      ),
      gateway: gateway,
      gatewayToken: gatewayToken,
      gatewayLegacyToken: gatewayLegacyToken,
      gatewayAuthSession: gatewayAuthSession,
      gatewayTokenProvider: freshGatewayToken,
      asrEnabled: prefs.getBool('asrEnabled') ?? true,
      customMcpTokens: customMcpTokens,
      customMcpEnvironments: customMcpEnvironments,
      customMcpHeaders: customMcpHeaders,
      memoryEnabled: prefs.getBool(kSettingsMemoryEnabled) ?? false,
      researchModeEnabled: prefs.getBool(kSettingsResearchModeEnabled) ?? false,
      // Default on: learning hub is part of the main product surface.
      studyModeEnabled: prefs.getBool(kSettingsStudyModeEnabled) ?? true,
      // Default on: existing installs keep the 创作 tab unless user hides it.
      creationModeEnabled: prefs.getBool(kSettingsCreationModeEnabled) ?? true,
    );
  }

  /// A stored theme index from a corrupt/older store may fall outside the
  /// enum range; fall back to the default instead of crashing the whole build.
  static ThemePreference readThemePreference(SharedPreferences prefs) {
    final stored = prefs.getInt(kSettingsThemeMode);
    if (stored == null ||
        stored < 0 ||
        stored >= ThemePreference.values.length) {
      return ThemePreference.system;
    }
    return ThemePreference.values[stored];
  }

  static UiPrefs readUiPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(kSettingsUiPrefs);
    if (raw == null || raw.isEmpty) return const UiPrefs();
    try {
      return UiPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const UiPrefs();
    }
  }

  static MediaApiConfig readMediaApi(SharedPreferences prefs, String key) {
    return readMediaApiOrNull(prefs, key) ?? const MediaApiConfig();
  }

  static MediaApiConfig? readMediaApiOrNull(
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

  static GatewayConfig? readGateway(SharedPreferences prefs) {
    final raw = prefs.getString(kSettingsGateway);
    if (raw == null) return null;
    try {
      return GatewayConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      throw const FormatException('Gateway 配置无法解析，原始配置未被覆盖。');
    } on TypeError {
      throw const FormatException('Gateway 配置字段类型错误，原始配置未被覆盖。');
    }
  }

  static GatewayConfig migrateLegacyGateway(SharedPreferences prefs) {
    Map<String, dynamic> readLegacy(String key) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return const {};
    }

    final longTask = readLegacy(kSettingsLegacyLongTaskGateway);
    final document = readLegacy(kSettingsLegacyDocumentService);
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

  static ContextPrefs readContextPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(kSettingsContextPrefs);
    if (raw == null || raw.isEmpty) return const ContextPrefs();
    try {
      return ContextPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ContextPrefs();
    }
  }

  /// A DeepSeek profile still carrying the old default model list (so we can
  /// safely upgrade it without clobbering a user's custom edits).
  static bool isLegacyDeepSeek(ProviderProfile p) =>
      p.baseUrl.contains('api.deepseek.com') &&
      p.models.contains('deepseek-chat') &&
      p.models.contains('deepseek-reasoner');

  static String _currentDeepSeekModel(String model) => switch (model) {
    'deepseek-v4-flash' || 'deepseek-v4-flash-vision-exp' => KnownModels.flash,
    _ => model,
  };

  static bool _needsFlashAliasUpgrade(ProviderProfile p) =>
      Uri.tryParse(p.baseUrl)?.host.toLowerCase() == 'api.deepseek.com' &&
      (p.chatModel != _currentDeepSeekModel(p.chatModel) ||
          p.reasonerModel != _currentDeepSeekModel(p.reasonerModel) ||
          p.models.any((m) => m != _currentDeepSeekModel(m)));

  static bool isDeepSeekMissingFlash(ProviderProfile p) =>
      Uri.tryParse(p.baseUrl)?.host.toLowerCase() == 'api.deepseek.com' &&
      !p.models.contains(KnownModels.flash);

  static ({List<ProviderProfile> profiles, bool corrupt}) readProfiles(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(kSettingsProfiles);
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
      unawaited(prefs.setString(kSettingsProfilesCorruptBackup, raw));
      return (profiles: const [], corrupt: true);
    }
  }

  static Future<void> writeProfiles(
    SharedPreferences prefs,
    List<ProviderProfile> profiles,
  ) => prefs.setString(
    kSettingsProfiles,
    jsonEncode(profiles.map((p) => p.toJson()).toList()),
  );

  Future<GatewayAuthSession?> readGatewayAuthSession() async {
    final access =
        await secure.read(key: kSettingsGatewayOidcAccessTokenSecure) ?? '';
    final refresh =
        await secure.read(key: kSettingsGatewayOidcRefreshTokenSecure) ?? '';
    final expiresRaw =
        await secure.read(key: kSettingsGatewayOidcExpiresAtSecure) ?? '';
    final subject =
        await secure.read(key: kSettingsGatewayOidcSubjectSecure) ?? '';
    final displayName =
        await secure.read(key: kSettingsGatewayOidcDisplayNameSecure) ??
        subject;
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

  Future<void> persistGatewayAuthSession(GatewayAuthSession session) async {
    await Future.wait([
      secure.write(
        key: kSettingsGatewayOidcAccessTokenSecure,
        value: session.accessToken,
      ),
      secure.write(
        key: kSettingsGatewayOidcRefreshTokenSecure,
        value: session.refreshToken,
      ),
      secure.write(
        key: kSettingsGatewayOidcExpiresAtSecure,
        value: session.expiresAt.toUtc().toIso8601String(),
      ),
      secure.write(
        key: kSettingsGatewayOidcSubjectSecure,
        value: session.subject,
      ),
      secure.write(
        key: kSettingsGatewayOidcDisplayNameSecure,
        value: session.displayName,
      ),
    ]);
  }

  Future<void> clearGatewayAuthSession() async {
    await Future.wait([
      secure.delete(key: kSettingsGatewayOidcAccessTokenSecure),
      secure.delete(key: kSettingsGatewayOidcRefreshTokenSecure),
      secure.delete(key: kSettingsGatewayOidcExpiresAtSecure),
      secure.delete(key: kSettingsGatewayOidcSubjectSecure),
      secure.delete(key: kSettingsGatewayOidcDisplayNameSecure),
    ]);
  }
}
