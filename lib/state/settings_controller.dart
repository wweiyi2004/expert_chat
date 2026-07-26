import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers.dart';
import '../data/context_prefs.dart';
import '../data/media_api_config.dart';
import '../data/provider_profile.dart';
import '../data/ui_prefs.dart';
import '../domain/llm/llm_provider.dart';
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
    this.context = const ContextPrefs(),
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
  final ContextPrefs context;

  bool get searchConfigured => searchApiKey.trim().isNotEmpty;
  bool get visionConfigured => visionApi.isConfiguredWith(visionApiKey);
  bool get imageGenerationConfigured =>
      imageGenerationApi.isConfiguredWith(imageGenerationApiKey);
  bool get ttsConfigured => ttsApi.isConfiguredWith(ttsApiKey);

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
    ContextPrefs? context,
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
    context: context ?? this.context,
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
const _kContextPrefs = 'contextPrefs';

// Legacy M1 keys (single-config) — read once for migration.
const _kLegacyBaseUrl = 'baseUrl';
const _kLegacyModel = 'model';
const _kLegacyApiKeySecure = 'llm_api_key';

String _secureKeyForProfile(String profileId) => 'apikey_$profileId';

/// Loads settings (profiles + active key) and persists changes. Migrates the
/// M1 single-config layout to a profile on first run.
class SettingsController extends AsyncNotifier<SettingsState> {
  @override
  Future<SettingsState> build() async {
    final prefs = ref.read(sharedPrefsProvider);
    final secure = ref.read(secureStorageProvider);

    List<ProviderProfile> profiles = _readProfiles(prefs);
    String? activeId = prefs.getString(_kActiveProfile);

    // First run / migration from the M1 single-config layout.
    if (profiles.isEmpty) {
      final legacyKey = await secure.read(key: _kLegacyApiKeySecure);
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
            key: _secureKeyForProfile(migrated.id),
            value: legacyKey,
          );
        }
      } else {
        profiles = [ProviderPreset.presets.first.toProfile()];
      }
      activeId = profiles.first.id;
      await _writeProfiles(prefs, profiles);
      await prefs.setString(_kActiveProfile, activeId);
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

    activeId ??= profiles.first.id;
    final apiKey = await secure.read(key: _secureKeyForProfile(activeId)) ?? '';
    final searchApiKey = await secure.read(key: _kSearchApiKeySecure) ?? '';
    final visionApiKey = await secure.read(key: _kVisionApiKeySecure) ?? '';
    final imageGenerationApiKey =
        await secure.read(key: _kImageGenerationApiKeySecure) ?? '';
    final ttsApiKey = await secure.read(key: _kTtsApiKeySecure) ?? '';

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
      themeMode: ThemeMode.values[prefs.getInt(_kThemeMode) ?? 0],
      searchBackend: SearchBackendInfo.fromWire(
        prefs.getString(_kSearchBackend),
      ),
      searchApiKey: searchApiKey,
      searchBrainModel: prefs.getString(_kSearchBrainModel),
      searchMaxRounds: (prefs.getInt(_kSearchMaxRounds) ??
              kDefaultSearchMaxRounds)
          .clamp(kMinSearchMaxRounds, kMaxSearchMaxRounds),
      searchMaxResults: (prefs.getInt(_kSearchMaxResults) ??
              kDefaultSearchMaxResults)
          .clamp(kMinSearchMaxResults, kMaxSearchMaxResults),
      systemPrompt: prefs.getString(_kSystemPrompt) ?? '',
      ui: _readUiPrefs(prefs),
      visionApi: _readMediaApi(prefs, _kVisionApi),
      visionApiKey: visionApiKey,
      imageGenerationApi: _readMediaApi(prefs, _kImageGenerationApi),
      imageGenerationApiKey: imageGenerationApiKey,
      ttsApi: _readMediaApi(prefs, _kTtsApi),
      ttsApiKey: ttsApiKey,
      context: _readContextPrefs(prefs),
    );
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
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const MediaApiConfig();
    try {
      return MediaApiConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const MediaApiConfig();
    }
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

  List<ProviderProfile> _readProfiles(SharedPreferences prefs) {
    final raw = prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ProviderProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
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
        .write(key: _secureKeyForProfile(active.id), value: apiKey);
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
    }
  }

  Future<void> setMediaApiKey(MediaApiKind kind, String key) async {
    final secure = ref.read(secureStorageProvider);
    switch (kind) {
      case MediaApiKind.vision:
        state = AsyncData(_current.copyWith(visionApiKey: key));
        await secure.write(key: _kVisionApiKeySecure, value: key);
      case MediaApiKind.imageGeneration:
        state = AsyncData(_current.copyWith(imageGenerationApiKey: key));
        await secure.write(key: _kImageGenerationApiKeySecure, value: key);
      case MediaApiKind.tts:
        state = AsyncData(_current.copyWith(ttsApiKey: key));
        await secure.write(key: _kTtsApiKeySecure, value: key);
    }
  }

  /// Switch the active profile, loading its stored key.
  Future<void> selectProfile(String id) async {
    if (!_current.profiles.any((p) => p.id == id)) return;
    final key =
        await ref
            .read(secureStorageProvider)
            .read(key: _secureKeyForProfile(id)) ??
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
    await secure.delete(key: _secureKeyForProfile(id));

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
          context: _current.context,
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
      apiKey = await secure.read(key: _secureKeyForProfile(activeId)) ?? '';
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
