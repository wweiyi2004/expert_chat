import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers.dart';
import '../data/provider_profile.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/tools/search_provider.dart';

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
    this.systemPrompt = '',
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

  /// Optional global preset/persona prompt, prepended as a `system` message on
  /// every request. Empty = no preset (model uses its own default behavior).
  final String systemPrompt;

  bool get searchConfigured => searchApiKey.trim().isNotEmpty;

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

  /// Models offered in the picker for the active profile.
  List<String> get availableModels =>
      active?.models ?? const [KnownModels.chat, KnownModels.reasoner];

  LlmConfig get config =>
      LlmConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);

  SettingsState copyWith({
    List<ProviderProfile>? profiles,
    String? activeProfileId,
    String? apiKey,
    Object? selectedModel = _sentinel,
    ThemeMode? themeMode,
    SearchBackend? searchBackend,
    String? searchApiKey,
    String? systemPrompt,
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
    systemPrompt: systemPrompt ?? this.systemPrompt,
  );

  static const _sentinel = Object();
}

const _kProfiles = 'providerProfiles';
const _kActiveProfile = 'activeProfileId';
const _kSelectedModel = 'selectedModel';
const _kThemeMode = 'themeMode';
const _kSearchBackend = 'searchBackend';
const _kSearchApiKeySecure = 'search_api_key';
const _kSystemPrompt = 'systemPrompt';

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
      systemPrompt: prefs.getString(_kSystemPrompt) ?? '',
    );
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

  /// Update theme or model selection (lightweight, frequently called).
  Future<void> apply({String? selectedModel, ThemeMode? themeMode}) async {
    final next = _current.copyWith(
      selectedModel: selectedModel,
      themeMode: themeMode,
    );
    state = AsyncData(next);
    final prefs = ref.read(sharedPrefsProvider);
    if (selectedModel != null) {
      await prefs.setString(_kSelectedModel, selectedModel);
    }
    if (themeMode != null) await prefs.setInt(_kThemeMode, themeMode.index);
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

  /// Set the global preset/system prompt (persisted in shared preferences).
  Future<void> setSystemPrompt(String prompt) async {
    state = AsyncData(_current.copyWith(systemPrompt: prompt));
    await ref.read(sharedPrefsProvider).setString(_kSystemPrompt, prompt);
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
      state = AsyncData(
        SettingsState(
          profiles: [fresh],
          activeProfileId: fresh.id,
          apiKey: '',
          themeMode: _current.themeMode,
        ),
      );
      await _writeProfiles(prefs, [fresh]);
      await prefs.setString(_kActiveProfile, fresh.id);
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
