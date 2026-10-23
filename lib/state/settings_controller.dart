import 'model_context.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/chat_skill.dart';
import '../data/subagent_role.dart';
import '../data/prompt_presets.dart';
import '../data/jev_config.dart';
import '../data/composer_modes.dart';
import '../data/context_prefs.dart';
import '../data/gateway_config.dart';
import '../data/media_api_config.dart';
import '../data/provider_profile.dart';
import '../data/settings_bundle.dart';
import '../data/task_budget_prefs.dart';
import '../data/ui_prefs.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/gateway/gateway_auth_service.dart';
import '../domain/tools/search_provider.dart';

import '../data/settings_state.dart';
import '../data/settings_storage.dart';
import '../data/settings_storage_keys.dart';
export '../data/settings_storage_keys.dart'
    show providerApiKeyStorageKey, customMcpTokenStorageKey;
export '../data/settings_state.dart';

class SettingsController extends AsyncNotifier<SettingsState> {
  Future<GatewayAuthSession>? _gatewayRefreshInFlight;

  SettingsStorage get _storage => SettingsStorage(
    prefs: ref.read(sharedPrefsProvider),
    secure: ref.read(secureStorageProvider),
    authService: ref.read(gatewayAuthServiceProvider),
    freshGatewayToken: _freshGatewayToken,
  );

  @override
  Future<SettingsState> build() => _storage.load();

  Future<void> setMemoryEnabled(bool enabled) async {
    final next = _current.copyWith(memoryEnabled: enabled);
    state = AsyncData(next);
    await ref
        .read(sharedPrefsProvider)
        .setBool(kSettingsMemoryEnabled, enabled);
  }

  /// M7: toggle hidden research mode (SSH terminal). Does not connect.
  Future<void> setResearchModeEnabled(bool enabled) async {
    final next = _current.copyWith(researchModeEnabled: enabled);
    state = AsyncData(next);
    await ref
        .read(sharedPrefsProvider)
        .setBool(kSettingsResearchModeEnabled, enabled);
  }

  /// Show/hide the 学习 hub tab. Does not delete courses or cards.
  Future<void> setStudyModeEnabled(bool enabled) async {
    final next = _current.copyWith(studyModeEnabled: enabled);
    state = AsyncData(next);
    await ref
        .read(sharedPrefsProvider)
        .setBool(kSettingsStudyModeEnabled, enabled);
  }

  /// Show/hide the 创作 hub tab. Does not delete characters or drafts.
  Future<void> setCreationModeEnabled(bool enabled) async {
    final next = _current.copyWith(creationModeEnabled: enabled);
    state = AsyncData(next);
    await ref
        .read(sharedPrefsProvider)
        .setBool(kSettingsCreationModeEnabled, enabled);
  }

  SettingsState get _current => state.value ?? const SettingsState();

  /// Update theme and/or model selection (lightweight, frequently called).
  ///
  /// [selectedModel] uses the same sentinel convention as [SettingsState.copyWith]:
  /// omitting it leaves the current model untouched (so e.g. switching theme
  /// alone doesn't wipe the picked model), passing `null` clears it back to the
  /// profile default, and passing a value sets it.
  Future<void> apply({
    Object? selectedModel = SettingsState.unchanged,
    ThemeMode? themeMode,
  }) async {
    final next = _current.copyWith(
      selectedModel: selectedModel,
      themeMode: themeMode,
    );
    state = AsyncData(next);
    final prefs = ref.read(sharedPrefsProvider);
    if (!identical(selectedModel, SettingsState.unchanged)) {
      final model = selectedModel as String?;
      if (model != null) {
        await prefs.setString(kSettingsSelectedModel, model);
      } else {
        await prefs.remove(kSettingsSelectedModel);
      }
    }
    if (themeMode != null) {
      await prefs.setInt(kSettingsThemeMode, themeMode.index);
    }
  }

  /// Patch appearance prefs and persist as JSON.
  Future<void> setUiPrefs(UiPrefs ui) async {
    state = AsyncData(_current.copyWith(ui: ui));
    await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsUiPrefs, jsonEncode(ui.toJson()));
  }

  /// Set the API key for the active profile.
  Future<void> setApiKey(String apiKey) async {
    final active = _current.active;
    if (active == null) return;
    await setProfileApiKey(active.id, apiKey);
  }

  Future<void> setTaskBudget(TaskBudgetPrefs value) async {
    final safe = TaskBudgetPrefs.fromJson(value.toJson());
    state = AsyncData(_current.copyWith(taskBudget: safe));
    await ref
        .read(sharedPrefsProvider)
        .setString('taskBudget', jsonEncode(safe.toJson()));
  }

  final Map<String, Future<void>> _profileKeyWrites = {};

  Future<void> setProfileApiKey(String profileId, String apiKey) async {
    if (!ref.mounted || !_current.profiles.any((p) => p.id == profileId)) {
      return;
    }
    final storage = ref.read(secureStorageProvider);
    if (_current.active?.id == profileId) {
      state = AsyncData(_current.copyWith(apiKey: apiKey));
    }
    final previous = _profileKeyWrites[profileId] ?? Future<void>.value();
    final write = previous
        .catchError((Object _) {})
        .then(
          (_) => storage.write(
            key: providerApiKeyStorageKey(profileId),
            value: apiKey,
          ),
        );
    _profileKeyWrites[profileId] = write;
    try {
      await write;
    } finally {
      if (identical(_profileKeyWrites[profileId], write)) {
        _profileKeyWrites.remove(profileId);
      }
    }
  }

  /// Set the web-search backend.
  Future<void> setSearchBackend(SearchBackend backend) async {
    state = AsyncData(_current.copyWith(searchBackend: SearchBackend.deepseek));
    await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsSearchBackend, SearchBackend.deepseek.wire);
  }

  /// Set the web-search API key (stored in secure storage).
  Future<void> setSearchApiKey(String key) async {
    state = AsyncData(
      _current.copyWith(
        searchApiKey: key,
        searchBackend: SearchBackend.deepseek,
      ),
    );
    await ref
        .read(secureStorageProvider)
        .write(key: kSettingsDeepSeekSearchApiKeySecure, value: key);
  }

  /// Pick the "搜索大脑" model; null/empty follows the profile's chat model.
  Future<void> setSearchBrainModel(String? model) async {
    final normalized = (model?.trim().isEmpty ?? true) ? null : model!.trim();
    state = AsyncData(_current.copyWith(searchBrainModel: normalized));
    final prefs = ref.read(sharedPrefsProvider);
    if (normalized == null) {
      await prefs.remove(kSettingsSearchBrainModel);
    } else {
      await prefs.setString(kSettingsSearchBrainModel, normalized);
    }
  }

  Future<void> setSearchMaxRounds(int rounds) async {
    final bounded = rounds.clamp(kMinSearchMaxRounds, kMaxSearchMaxRounds);
    state = AsyncData(_current.copyWith(searchMaxRounds: bounded));
    await ref
        .read(sharedPrefsProvider)
        .setInt(kSettingsSearchMaxRounds, bounded);
  }

  Future<void> setSearchMode(SearchMode mode) async {
    if (_current.searchMode == mode) return;
    state = AsyncData(_current.copyWith(searchMode: mode));
    final saved = await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsComposerSearchMode, mode.wire);
    if (!saved) throw StateError('搜索设置保存失败');
  }

  Future<void> setImageGenMode(ImageGenMode mode) async {
    if (_current.imageGenMode == mode) return;
    state = AsyncData(_current.copyWith(imageGenMode: mode));
    final saved = await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsComposerImageGenMode, mode.wire);
    if (!saved) throw StateError('配图设置保存失败');
  }

  Future<void> setReasoningEffort(ReasoningEffort effort) async {
    state = AsyncData(
      _current.copyWith(
        reasoningEffort: effort,
        hasReasoningEffortOverride: true,
      ),
    );
    await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsReasoningEffort, effort.wire);
  }

  Future<void> setSearchMaxResults(int results) async {
    final bounded = results.clamp(kMinSearchMaxResults, kMaxSearchMaxResults);
    state = AsyncData(_current.copyWith(searchMaxResults: bounded));
    await ref
        .read(sharedPrefsProvider)
        .setInt(kSettingsSearchMaxResults, bounded);
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
      await _storage.clearGatewayAuthSession();
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
        .setString(kSettingsGateway, jsonEncode(next.toJson()));
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
        .write(key: kSettingsGatewayTokenSecure, value: token);
  }

  Future<void> signInGateway() async {
    final config = _current.gateway;
    final session = await ref.read(gatewayAuthServiceProvider).signIn(config);
    await _storage.persistGatewayAuthSession(session);
    state = AsyncData(
      _current.copyWith(
        gatewayToken: session.accessToken,
        gatewayAuthSession: session,
        gatewayTokenProvider: _freshGatewayToken,
      ),
    );
  }

  Future<void> signOutGateway() async {
    await _storage.clearGatewayAuthSession();
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
      await _storage.persistGatewayAuthSession(refreshed);
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

  Future<void> setGatewayCapabilities({
    required List<String> capabilities,
    required String serverVersion,
    List<DiscoveredMcpTool> mcpTools = const [],
  }) => setGatewayConfig(
    _current.gateway.copyWith(
      capabilitiesDiscovered: true,
      capabilities: capabilities.toSet().toList()..sort(),
      serverVersion: serverVersion,
      mcpTools: mcpTools,
    ),
  );

  Future<void> addCustomMcpServer({
    required String id,
    required String name,
    required String baseUrl,
    String token = '',
    McpProcessConfig? localProcess,
    bool computerUse = false,
    bool allowForeground = false,
  }) async {
    final trimmedName = name.trim();
    final trimmedUrl = baseUrl.trim();
    if (id.trim().isEmpty ||
        trimmedName.isEmpty ||
        !(localProcess?.isConfigured ??
            GatewayConfig.normalizeBaseUrl(trimmedUrl).isNotEmpty)) {
      return;
    }
    if (_current.gateway.customMcpServers.any((server) => server.id == id)) {
      return;
    }
    await setGatewayConfig(
      _current.gateway.copyWith(
        customMcpServers: [
          ..._current.gateway.customMcpServers,
          CustomMcpServer(
            id: id,
            name: trimmedName,
            baseUrl: trimmedUrl,
            localProcess: localProcess,
            computerUse: computerUse,
            allowForeground: allowForeground,
          ),
        ],
      ),
    );
    if (token.isNotEmpty) await setCustomMcpToken(id, token);
  }

  Future<void> updateCustomMcpServer({
    required String id,
    required String name,
    required String baseUrl,
    McpProcessConfig? localProcess,
    bool computerUse = false,
    bool allowForeground = false,
  }) async {
    await ref.read(mcpClientProvider).stopLocalServers();
    await _updateCustomMcpServer(id, (server) {
      final nextUrl = GatewayConfig.normalizeBaseUrl(baseUrl);
      final urlChanged =
          nextUrl != server.normalizedBaseUrl ||
          localProcess?.identity != server.localProcess?.identity ||
          computerUse != server.computerUse;
      return server.copyWith(
        name: name.trim(),
        baseUrl: baseUrl.trim(),
        localProcess: localProcess,
        computerUse: computerUse,
        allowForeground: allowForeground,
        toolsDiscovered: urlChanged ? false : server.toolsDiscovered,
        tools: urlChanged ? const <DiscoveredMcpTool>[] : server.tools,
        serverVersion: urlChanged ? null : server.serverVersion,
        lastError: urlChanged ? null : server.lastError,
      );
    });
  }

  Future<void> setCustomMcpEnabled(String id, bool enabled) async {
    if (!enabled) await ref.read(mcpClientProvider).stopLocalServers();
    await _updateCustomMcpServer(
      id,
      (server) => server.copyWith(enabled: enabled),
    );
  }

  Future<void> setCustomMcpDiscovered(
    String id, {
    required List<DiscoveredMcpTool> tools,
    required String serverVersion,
  }) => _updateCustomMcpServer(
    id,
    (server) => server.copyWith(
      toolsDiscovered: true,
      tools: tools,
      serverVersion: serverVersion,
      lastError: null,
    ),
  );

  Future<void> setCustomMcpError(String id, String error) =>
      _updateCustomMcpServer(id, (server) => server.copyWith(lastError: error));

  Future<void> deleteCustomMcpServer(String id) async {
    await ref.read(mcpClientProvider).stopLocalServers();
    await setGatewayConfig(
      _current.gateway.copyWith(
        customMcpServers: [
          for (final server in _current.gateway.customMcpServers)
            if (server.id != id) server,
        ],
      ),
    );
    await setCustomMcpToken(id, '');
  }

  Future<void> setCustomMcpToken(String id, String token) async {
    if (id.isEmpty) return;
    final next = Map<String, String>.from(_current.customMcpTokens);
    final secure = ref.read(secureStorageProvider);
    if (token.isEmpty) {
      next.remove(id);
      await secure.delete(key: customMcpTokenStorageKey(id));
    } else {
      next[id] = token;
      await secure.write(key: customMcpTokenStorageKey(id), value: token);
    }
    if (!ref.mounted) return;
    state = AsyncData(_current.copyWith(customMcpTokens: next));
  }

  Future<void> _updateCustomMcpServer(
    String id,
    CustomMcpServer Function(CustomMcpServer server) update,
  ) async {
    final current = _current.gateway.customMcpServers;
    final index = current.indexWhere((server) => server.id == id);
    if (index < 0) return;
    final next = [...current];
    next[index] = update(current[index]);
    await setGatewayConfig(_current.gateway.copyWith(customMcpServers: next));
  }

  Future<void> setJevConfig(JevConfig config) async {
    final next = config.normalized();
    await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsJevConfig, jsonEncode(next.toJson()));
    if (!ref.mounted) return;
    state = AsyncData(_current.copyWith(jevConfig: next));
  }

  Future<void> _jevKeyWriteTail = Future<void>.value();

  Future<void> setJevApiKey(String value) {
    final key = value.trim();
    final secure = ref.read(secureStorageProvider);
    final write = _jevKeyWriteTail.catchError((Object _) {}).then((_) async {
      if (key.isEmpty) {
        await secure.delete(key: kSettingsJevApiKeySecure);
      } else {
        await secure.write(key: kSettingsJevApiKeySecure, value: key);
      }
      if (!ref.mounted) return;
      state = AsyncData(_current.copyWith(jevApiKey: key));
    });
    _jevKeyWriteTail = write;
    return write;
  }

  Future<void> setChatSkills(ChatSkillCatalog catalog) async {
    final next = catalog.sanitize(legacySystemPrompt: _current.systemPrompt);
    state = AsyncData(
      _current.copyWith(chatSkills: next, systemPrompt: next.fallback.prompt),
    );
    final prefs = ref.read(sharedPrefsProvider);
    await prefs.setString(kSettingsChatSkills, next.encode());
    await prefs.setString(kSettingsSystemPrompt, next.fallback.prompt);
  }

  Future<void> setWorkAgentInstructions(String value) async {
    if (value.length > 24000) throw const FormatException('系统指令最多 24000 字符');
    final text = value.trim();
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsWorkAgentInstructions, text)) {
      throw StateError('工作主代理系统指令保存失败');
    }
    if (ref.mounted)
      state = AsyncData(_current.copyWith(workAgentInstructions: text));
  }

  Future<void> setSubagentInstructions(String value) async {
    if (value.length > 24000) throw const FormatException('系统指令最多 24000 字符');
    final text = value.trim();
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsSubagentInstructions, text)) {
      throw StateError('子代理系统指令保存失败');
    }
    if (ref.mounted)
      state = AsyncData(_current.copyWith(subagentInstructions: text));
  }

  Future<void> setSubagentRoles(List<SubagentRole> roles) async {
    if (roles.length > 40 ||
        roles.any(
          (r) =>
              r.instructions.length > 24000 ||
              r.name.trim().isEmpty ||
              r.id.isEmpty,
        )) {
      throw const FormatException('最多 40 个角色；角色名称不能为空，单个指令最多 24000 字符');
    }
    if (roles.map((r) => r.id).toSet().length != roles.length)
      throw const FormatException('角色标识重复');
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(
          kSettingsSubagentRoles,
          jsonEncode(roles.map((r) => r.toJson()).toList()),
        ))
      throw StateError('角色库保存失败');
    if (ref.mounted)
      state = AsyncData(
        _current.copyWith(subagentRoles: List.unmodifiable(roles)),
      );
  }

  Future<void> setSubagentRouterModel(String model) async {
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsSubagentRouterModel, model))
      throw StateError('分配模型保存失败');
    if (ref.mounted)
      state = AsyncData(_current.copyWith(subagentRouterModel: model));
  }

  Future<void> _presetWriteTail = Future<void>.value();
  Future<void> setPromptPresets(PromptPresets presets) {
    final normalized = PromptPresets.decode(jsonEncode(presets.toJson()));
    final prefs = ref.read(sharedPrefsProvider);
    state = AsyncData(_current.copyWith(promptPresets: normalized));
    return _presetWriteTail = _presetWriteTail.catchError((Object _) {}).then((
      _,
    ) async {
      await prefs.setString(
        PromptPresets.storageKey,
        jsonEncode(normalized.toJson()),
      );
    });
  }

  Future<void> selectPromptPreset(String? id) => setPromptPresets(
    PromptPresets(items: _current.promptPresets.items, activeId: id),
  );

  /// Set the global preset/system prompt (persisted in shared preferences).
  Future<void> setSystemPrompt(String prompt) async {
    final updated = _current.chatSkills.update(
      (s) => s.id == _current.chatSkills.fallback.id
          ? s.copyWith(prompt: prompt)
          : s,
    );
    await setChatSkills(updated);
  }

  Future<void> setModelContextPrefs(
    String endpoint,
    String model,
    ContextPrefs? value,
  ) async {
    final key = modelContextKey(endpoint, model);
    final next = {..._current.modelContexts};
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    await ref
        .read(sharedPrefsProvider)
        .setString(
          kSettingsModelContexts,
          jsonEncode(next.map((key, value) => MapEntry(key, value.toJson()))),
        );
    if (ref.mounted) state = AsyncData(_current.copyWith(modelContexts: next));
  }

  Future<void> setContextPrefs(ContextPrefs context) async {
    state = AsyncData(_current.copyWith(context: context));
    await ref
        .read(sharedPrefsProvider)
        .setString(kSettingsContextPrefs, jsonEncode(context.toJson()));
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
        await prefs.setString(kSettingsVisionApi, encoded);
      case MediaApiKind.imageGeneration:
        state = AsyncData(_current.copyWith(imageGenerationApi: config));
        await prefs.setString(kSettingsImageGenerationApi, encoded);
      case MediaApiKind.tts:
        state = AsyncData(_current.copyWith(ttsApi: config));
        await prefs.setString(kSettingsTtsApi, encoded);
        await prefs.setString(
          ttsApiProfilePrefsKey(config.effectiveSpeechProtocol),
          encoded,
        );
      case MediaApiKind.asr:
        state = AsyncData(_current.copyWith(asrApi: config));
        await prefs.setString(kSettingsAsrApi, encoded);
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
        await secure.write(key: kSettingsVisionApiKeySecure, value: key);
      case MediaApiKind.imageGeneration:
        state = AsyncData(_current.copyWith(imageGenerationApiKey: key));
        await secure.write(
          key: kSettingsImageGenerationApiKeySecure,
          value: key,
        );
      case MediaApiKind.tts:
        final protocol = _current.ttsApi.effectiveSpeechProtocol;
        state = AsyncData(_current.copyWith(ttsApiKey: key));
        await secure.write(key: kSettingsTtsApiKeySecure, value: key);
        await secure.write(key: ttsApiProfileSecureKey(protocol), value: key);
      case MediaApiKind.asr:
        state = AsyncData(_current.copyWith(asrApiKey: key));
        await secure.write(key: kSettingsAsrApiKeySecure, value: key);
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
      ttsApiProfilePrefsKey(currentProtocol),
      jsonEncode(current.ttsApi.toJson()),
    );
    await secure.write(
      key: ttsApiProfileSecureKey(currentProtocol),
      value: current.ttsApiKey,
    );

    final targetConfig =
        SettingsStorage.readMediaApiOrNull(
          prefs,
          ttsApiProfilePrefsKey(protocol),
        ) ??
        fallback.copyWith(speechProtocol: protocol);
    final targetApiKey =
        await secure.read(key: ttsApiProfileSecureKey(protocol)) ?? '';
    if (!ref.mounted) return;

    state = AsyncData(
      _current.copyWith(ttsApi: targetConfig, ttsApiKey: targetApiKey),
    );

    // Mirror the selected profile to the original active TTS keys.
    await prefs.setString(kSettingsTtsApi, jsonEncode(targetConfig.toJson()));
    await secure.write(key: kSettingsTtsApiKeySecure, value: targetApiKey);
  }

  /// Save a verified setup draft without publishing a half-written profile.
  Future<void> saveVerifiedConnection(
    ProviderProfile profile,
    String apiKey,
  ) async {
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);
    await _profileKeyWrites[profile.id];
    final keyName = providerApiKeyStorageKey(profile.id);
    final oldKey = await secure.read(key: keyName);
    final oldValues = {
      for (final key in [
        kSettingsProfiles,
        kSettingsActiveProfile,
        kSettingsSelectedModel,
      ])
        key: prefs.getString(key),
    };
    final profiles = [
      for (final p in _current.profiles)
        if (p.id != profile.id) p,
      profile,
    ];
    Future<void> writePreference(String key, String? value) async {
      final ok = value == null
          ? await prefs.remove(key)
          : await prefs.setString(key, value);
      if (!ok) throw StateError('本地保存失败，请检查存储空间后重试。');
    }

    try {
      await secure.write(key: keyName, value: apiKey.trim());
      await writePreference(
        kSettingsProfiles,
        jsonEncode(profiles.map((p) => p.toJson()).toList()),
      );
      await writePreference(kSettingsActiveProfile, profile.id);
      await writePreference(kSettingsSelectedModel, null);
    } catch (error) {
      // Restore all touched fields independently, even if one rollback fails.
      var rollbackFailed = false;
      try {
        if (oldKey == null) {
          await secure.delete(key: keyName);
        } else {
          await secure.write(key: keyName, value: oldKey);
        }
      } catch (_) {
        rollbackFailed = true;
      }
      for (final entry in oldValues.entries) {
        try {
          await writePreference(entry.key, entry.value);
        } catch (_) {
          rollbackFailed = true;
        }
      }
      if (rollbackFailed) throw StateError('配置未能完整保存，请保留当前填写内容，重启后检查设置。');
      rethrow;
    }
    if (ref.mounted) {
      state = AsyncData(
        _current.copyWith(
          profiles: profiles,
          activeProfileId: profile.id,
          apiKey: apiKey.trim(),
          selectedModel: null,
        ),
      );
    }
  }

  /// Save a service without changing the currently selected model.
  Future<void> saveModelService(ProviderProfile profile, String apiKey) async {
    final profiles = [
      for (final current in _current.profiles)
        if (current.id == profile.id) profile else current,
      if (!_current.profiles.any((current) => current.id == profile.id))
        profile,
    ];
    final storage = ref.read(secureStorageProvider);
    final key = providerApiKeyStorageKey(profile.id);
    final previousKey = await storage.read(key: key);
    try {
      await storage.write(key: key, value: apiKey.trim());
      await SettingsStorage.writeProfiles(
        ref.read(sharedPrefsProvider),
        profiles,
      );
    } catch (_) {
      if (previousKey == null) {
        await storage.delete(key: key);
      } else {
        await storage.write(key: key, value: previousKey);
      }
      rethrow;
    }
    if (ref.mounted)
      state = AsyncData(
        _current.copyWith(
          profiles: profiles,
          apiKey: _current.activeProfileId == profile.id
              ? apiKey.trim()
              : _current.apiKey,
        ),
      );
  }

  /// Switch the active profile, loading its stored key.
  Future<void> selectProfile(String id) async {
    if (!_current.profiles.any((p) => p.id == id)) return;
    await _profileKeyWrites[id];
    final key =
        await ref
            .read(secureStorageProvider)
            .read(key: providerApiKeyStorageKey(id)) ??
        '';
    state = AsyncData(
      _current.copyWith(activeProfileId: id, apiKey: key, selectedModel: null),
    );
    final prefs = ref.read(sharedPrefsProvider);
    await prefs.setString(kSettingsActiveProfile, id);
    await prefs.remove(kSettingsSelectedModel);
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
    await SettingsStorage.writeProfiles(prefs, profiles);
    await prefs.setString(kSettingsActiveProfile, profile.id);
    await prefs.remove(kSettingsSelectedModel);
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
    if (overrideStale) await prefs.remove(kSettingsSelectedModel);
    await SettingsStorage.writeProfiles(prefs, profiles);
  }

  /// Delete a profile and its stored key. Falls back to another profile, or a
  /// fresh DeepSeek preset if none remain.
  Future<void> deleteProfile(String id) async {
    await _profileKeyWrites[id];
    final remaining = _current.profiles.where((p) => p.id != id).toList();
    final secure = ref.read(secureStorageProvider);
    await secure.delete(key: providerApiKeyStorageKey(id));

    final prefs = ref.read(sharedPrefsProvider);
    if (remaining.isEmpty) {
      final fresh = ProviderPreset.presets.first.toProfile();
      // copyWith keeps in-memory settings that still live in secure storage
      // / prefs; reconstructing SettingsState would drop them until restart.
      state = AsyncData(
        _current.copyWith(
          profiles: [fresh],
          activeProfileId: fresh.id,
          apiKey: '',
          // The override pointed into the deleted profile; start clean.
          selectedModel: null,
        ),
      );
      await SettingsStorage.writeProfiles(prefs, [fresh]);
      await prefs.setString(kSettingsActiveProfile, fresh.id);
      await prefs.remove(kSettingsSelectedModel);
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
    await SettingsStorage.writeProfiles(prefs, remaining);
    await prefs.setString(kSettingsActiveProfile, activeId!);
  }

  /// Snapshot of API endpoints, keys, gateway, and related prefs as pretty JSON.
  Future<String> exportSettingsJson() async {
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);
    final current = _current;

    final profiles = <Map<String, dynamic>>[];
    for (final profile in current.profiles) {
      final key = profile.id == current.activeProfileId
          ? current.apiKey
          : await secure.read(key: providerApiKeyStorageKey(profile.id)) ?? '';
      profiles.add({...profile.toJson(), 'apiKey': key});
    }

    final ttsProfiles = <String, dynamic>{};
    for (final protocol in SpeechApiProtocol.values) {
      final isActive = protocol == current.ttsApi.effectiveSpeechProtocol;
      final config = isActive
          ? current.ttsApi
          : SettingsStorage.readMediaApiOrNull(
                  prefs,
                  ttsApiProfilePrefsKey(protocol),
                ) ??
                const MediaApiConfig();
      final key = isActive
          ? current.ttsApiKey
          : await secure.read(key: ttsApiProfileSecureKey(protocol)) ?? '';
      if (config.baseUrl.trim().isEmpty &&
          config.model.trim().isEmpty &&
          key.trim().isEmpty) {
        continue;
      }
      ttsProfiles[protocol.name] = SettingsBundle.mediaToJson(config, key);
    }

    return SettingsBundle.encode({
      'profiles': profiles,
      'activeProfileId': current.activeProfileId,
      'selectedModel': current.selectedModel,
      'themeMode': current.themeMode.name,
      'search': {
        'backend': current.searchBackend.wire,
        'apiKey': current.searchApiKey,
        'brainModel': current.searchBrainModel,
        'maxRounds': current.searchMaxRounds,
        'maxResults': current.searchMaxResults,
        'mode': current.searchMode.wire,
      },
      'imageGenMode': current.imageGenMode.wire,
      'taskBudget': current.taskBudget.toJson(),
      'reasoningEffort': current.reasoningEffort.wire,
      'systemPrompt': current.systemPrompt,
      'workAgentInstructions': current.workAgentInstructions,
      'subagentInstructions': current.subagentInstructions,
      'subagentRoles': current.effectiveSubagentRoles
          .map((r) => r.toJson())
          .toList(),
      'subagentRouterModel': current.subagentRouterModel,
      'promptPresets': current.promptPresets.toJson(),
      'jev': {...current.jevConfig.toJson(), 'apiKey': current.jevApiKey},
      'chatSkills': [
        for (final skill in current.chatSkills.skills) skill.toJson(),
      ],
      'ui': current.ui.toJson(),
      'vision': SettingsBundle.mediaToJson(
        current.visionApi,
        current.visionApiKey,
      ),
      'imageGeneration': SettingsBundle.mediaToJson(
        current.imageGenerationApi,
        current.imageGenerationApiKey,
      ),
      'tts': SettingsBundle.mediaToJson(current.ttsApi, current.ttsApiKey),
      'ttsProfiles': ttsProfiles,
      'asr': SettingsBundle.mediaToJson(current.asrApi, current.asrApiKey),
      'context': current.context.toJson(),
      'modelContexts': current.modelContexts.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'gateway': {
        ...current.gateway.toJson(),
        'token': current.gatewayLegacyToken,
      },
      'customMcpTokens': current.customMcpTokens,
      'memoryEnabled': current.memoryEnabled,
      'researchModeEnabled': current.researchModeEnabled,
      'studyModeEnabled': current.studyModeEnabled,
      'creationModeEnabled': current.creationModeEnabled,
    });
  }

  /// Replace local API/settings from an exported JSON snapshot, then reload.
  Future<void> importSettingsJson(String raw) async {
    final json = SettingsBundle.decode(raw);
    await _persistImportedSettings(json);
    if (!ref.mounted) return;
    ref.invalidateSelf();
    await future;
  }

  Future<void> _persistImportedSettings(Map<String, dynamic> json) async {
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);

    final profileRaw = json['profiles'];
    if (profileRaw is List) {
      final profiles = <ProviderProfile>[];
      final keys = <String, String>{};
      for (final item in profileRaw) {
        final map = SettingsBundle.asMap(item);
        if (map == null) continue;
        final apiKey = map.remove('apiKey')?.toString() ?? '';
        final profile = ProviderProfile.fromJson(map);
        if (profile.name.trim().isEmpty && profile.baseUrl.trim().isEmpty) {
          continue;
        }
        profiles.add(profile);
        keys[profile.id] = apiKey;
      }
      if (profiles.isNotEmpty) {
        final oldIds = {for (final profile in _current.profiles) profile.id};
        final newIds = {for (final profile in profiles) profile.id};
        for (final id in oldIds.difference(newIds)) {
          await secure.delete(key: providerApiKeyStorageKey(id));
        }
        await SettingsStorage.writeProfiles(prefs, profiles);
        for (final profile in profiles) {
          await secure.write(
            key: providerApiKeyStorageKey(profile.id),
            value: keys[profile.id] ?? '',
          );
        }
        final requestedActive = json['activeProfileId']?.toString();
        final activeId =
            (requestedActive != null && newIds.contains(requestedActive))
            ? requestedActive
            : profiles.first.id;
        await prefs.setString(kSettingsActiveProfile, activeId);
      }
    }

    if (json.containsKey('selectedModel')) {
      final model = json['selectedModel']?.toString();
      if (model == null || model.isEmpty) {
        await prefs.remove(kSettingsSelectedModel);
      } else {
        await prefs.setString(kSettingsSelectedModel, model);
      }
    }

    final themeName = json['themeMode']?.toString();
    if (themeName != null) {
      var mode = ThemeMode.system;
      for (final value in ThemeMode.values) {
        if (value.name == themeName) {
          mode = value;
          break;
        }
      }
      await prefs.setInt(kSettingsThemeMode, mode.index);
    }

    final search = SettingsBundle.asMap(json['search']);
    if (search != null) {
      if (search['backend'] != null) {
        await prefs.setString(
          kSettingsSearchBackend,
          SearchBackendInfo.fromWire(search['backend']?.toString()).wire,
        );
      }
      if (search.containsKey('apiKey')) {
        await secure.write(
          key: search['backend'] == SearchBackend.deepseek.wire
              ? kSettingsDeepSeekSearchApiKeySecure
              : kSettingsSearchApiKeySecure,
          value: search['apiKey']?.toString() ?? '',
        );
      }
      if (search.containsKey('brainModel')) {
        final brain = search['brainModel']?.toString().trim() ?? '';
        if (brain.isEmpty) {
          await prefs.remove(kSettingsSearchBrainModel);
        } else {
          await prefs.setString(kSettingsSearchBrainModel, brain);
        }
      }
      if (search['maxRounds'] is num) {
        await prefs.setInt(
          kSettingsSearchMaxRounds,
          (search['maxRounds'] as num).toInt().clamp(
            kMinSearchMaxRounds,
            kMaxSearchMaxRounds,
          ),
        );
      }
      if (search['maxResults'] is num) {
        await prefs.setInt(
          kSettingsSearchMaxResults,
          (search['maxResults'] as num).toInt().clamp(
            kMinSearchMaxResults,
            kMaxSearchMaxResults,
          ),
        );
      }
      if (search['mode'] != null) {
        await prefs.setString(
          kSettingsComposerSearchMode,
          SearchModeInfo.fromWire(search['mode']?.toString()).wire,
        );
      }
    }

    if (json['imageGenMode'] != null) {
      await prefs.setString(
        kSettingsComposerImageGenMode,
        ImageGenModeInfo.fromWire(json['imageGenMode']?.toString()).wire,
      );
    }
    if (json['reasoningEffort'] != null) {
      await prefs.setString(
        kSettingsReasoningEffort,
        ReasoningEffort.fromWire(json['reasoningEffort']?.toString()).wire,
      );
    }

    final jev = SettingsBundle.asMap(json['jev']);
    if (jev != null) {
      await prefs.setString(
        kSettingsJevConfig,
        jsonEncode(JevConfig.fromJson(jev).toJson()),
      );
      if (jev['apiKey'] is String) {
        await setJevApiKey(jev['apiKey'] as String);
      }
    }

    final skillsRaw = json['chatSkills'];
    if (json['promptPresets'] is Map) {
      await setPromptPresets(
        PromptPresets.decode(jsonEncode(json['promptPresets'])),
      );
    }
    if (skillsRaw is List || skillsRaw is String) {
      final encoded = skillsRaw is String ? skillsRaw : jsonEncode(skillsRaw);
      final catalog = ChatSkillCatalog.decode(
        encoded,
        legacySystemPrompt: json['systemPrompt']?.toString() ?? '',
      );
      await prefs.setString(kSettingsChatSkills, catalog.encode());
      await prefs.setString(kSettingsSystemPrompt, catalog.fallback.prompt);
    } else if (json['systemPrompt'] is String) {
      await prefs.setString(
        kSettingsSystemPrompt,
        json['systemPrompt'] as String,
      );
    }

    if (json['workAgentInstructions'] is String) {
      await prefs.setString(
        kSettingsWorkAgentInstructions,
        json['workAgentInstructions'] as String,
      );
    }
    if (json['subagentInstructions'] is String) {
      await prefs.setString(
        kSettingsSubagentInstructions,
        json['subagentInstructions'] as String,
      );
    }
    if (json['subagentRoles'] is List) {
      final roles = SubagentRole.decode(jsonEncode(json['subagentRoles']))!;
      await prefs.setString(
        kSettingsSubagentRoles,
        jsonEncode(roles.map((r) => r.toJson()).toList()),
      );
    }
    if (json['subagentRouterModel'] is String)
      await prefs.setString(
        kSettingsSubagentRouterModel,
        json['subagentRouterModel'] as String,
      );
    final ui = SettingsBundle.asMap(json['ui']);
    if (ui != null) {
      await prefs.setString(
        kSettingsUiPrefs,
        jsonEncode(UiPrefs.fromJson(ui).toJson()),
      );
    }

    if (json['modelContexts'] is Map) {
      final values = decodeModelContexts(jsonEncode(json['modelContexts']));
      await prefs.setString(
        kSettingsModelContexts,
        jsonEncode(values.map((key, value) => MapEntry(key, value.toJson()))),
      );
    }
    final context = SettingsBundle.asMap(json['context']);
    if (context != null) {
      await prefs.setString(
        kSettingsContextPrefs,
        jsonEncode(ContextPrefs.fromJson(context).toJson()),
      );
    }

    Future<void> writeMedia({
      required Object? raw,
      required String prefsKey,
      required String secureKey,
    }) async {
      final slot = SettingsBundle.mediaFromJson(raw);
      if (slot == null) return;
      await prefs.setString(prefsKey, jsonEncode(slot.config.toJson()));
      await secure.write(key: secureKey, value: slot.apiKey);
    }

    await writeMedia(
      raw: json['vision'],
      prefsKey: kSettingsVisionApi,
      secureKey: kSettingsVisionApiKeySecure,
    );
    await writeMedia(
      raw: json['imageGeneration'],
      prefsKey: kSettingsImageGenerationApi,
      secureKey: kSettingsImageGenerationApiKeySecure,
    );
    await writeMedia(
      raw: json['asr'],
      prefsKey: kSettingsAsrApi,
      secureKey: kSettingsAsrApiKeySecure,
    );

    final ttsProfiles = SettingsBundle.asMap(json['ttsProfiles']);
    if (ttsProfiles != null) {
      for (final protocol in SpeechApiProtocol.values) {
        final slot = SettingsBundle.mediaFromJson(ttsProfiles[protocol.name]);
        if (slot == null) continue;
        await prefs.setString(
          ttsApiProfilePrefsKey(protocol),
          jsonEncode(slot.config.toJson()),
        );
        await secure.write(
          key: ttsApiProfileSecureKey(protocol),
          value: slot.apiKey,
        );
      }
    }
    final tts = SettingsBundle.mediaFromJson(json['tts']);
    if (tts != null) {
      await prefs.setString(kSettingsTtsApi, jsonEncode(tts.config.toJson()));
      await secure.write(key: kSettingsTtsApiKeySecure, value: tts.apiKey);
      await prefs.setString(
        ttsApiProfilePrefsKey(tts.config.effectiveSpeechProtocol),
        jsonEncode(tts.config.toJson()),
      );
      await secure.write(
        key: ttsApiProfileSecureKey(tts.config.effectiveSpeechProtocol),
        value: tts.apiKey,
      );
    }

    final oldMcpIds = {
      for (final server in _current.gateway.customMcpServers) server.id,
    };
    final gatewayRaw = SettingsBundle.asMap(json['gateway']);
    if (gatewayRaw != null) {
      final token =
          gatewayRaw.remove('token')?.toString() ??
          gatewayRaw.remove('apiToken')?.toString();
      var config = GatewayConfig.fromJson(gatewayRaw);
      // A portable file cannot authorize executing new local programs.
      config = config.copyWith(
        customMcpServers: [
          for (final server in config.customMcpServers)
            if (server.localProcess != null)
              server.copyWith(
                enabled: false,
                toolsDiscovered: false,
                tools: const [],
                allowForeground: false,
              )
            else
              server,
        ],
      );
      await ref.read(mcpClientProvider).stopLocalServers();
      final current = _current.gateway;
      final authChanged =
          config.normalizedAuthServiceUrl != current.normalizedAuthServiceUrl ||
          config.oidcClientId.trim() != current.oidcClientId.trim() ||
          config.oidcRedirectUri.trim() != current.oidcRedirectUri.trim();
      final urlChanged = config.normalizedBaseUrl != current.normalizedBaseUrl;
      if (urlChanged) {
        config = config.clearDiscovery();
      }
      if (authChanged || urlChanged) {
        await _storage.clearGatewayAuthSession();
      }
      await prefs.setString(kSettingsGateway, jsonEncode(config.toJson()));
      if (token != null) {
        await secure.write(key: kSettingsGatewayTokenSecure, value: token);
      }
      final newMcpIds = {
        for (final server in config.customMcpServers) server.id,
      };
      for (final id in oldMcpIds.difference(newMcpIds)) {
        await secure.delete(key: customMcpTokenStorageKey(id));
      }
    }

    final mcpTokens = SettingsBundle.asMap(json['customMcpTokens']);
    if (mcpTokens != null) {
      for (final entry in mcpTokens.entries) {
        final id = entry.key.toString();
        if (id.isEmpty) continue;
        final value = entry.value?.toString() ?? '';
        if (value.isEmpty) {
          await secure.delete(key: customMcpTokenStorageKey(id));
        } else {
          await secure.write(key: customMcpTokenStorageKey(id), value: value);
        }
      }
    }

    Future<void> writeFlag(String key, Object? value) async {
      if (value is bool) await prefs.setBool(key, value);
    }

    await writeFlag(kSettingsMemoryEnabled, json['memoryEnabled']);
    if (json['taskBudget'] is Map) {
      await prefs.setString(
        'taskBudget',
        jsonEncode(TaskBudgetPrefs.fromJson(json['taskBudget']).toJson()),
      );
    }
    await writeFlag(kSettingsResearchModeEnabled, json['researchModeEnabled']);
    await writeFlag(kSettingsStudyModeEnabled, json['studyModeEnabled']);
    await writeFlag(kSettingsCreationModeEnabled, json['creationModeEnabled']);
  }
}

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, SettingsState>(
      SettingsController.new,
      // Re-reading unchanged malformed JSON cannot repair it.
      retry: (count, error) => error is FormatException
          ? null
          : ProviderContainer.defaultRetry(count, error),
    );
