import 'dart:async';
import 'package:riverpod/riverpod.dart';
import 'settings_controller.dart';
import '../domain/host/host_client.dart';
import '../domain/host/wire_models.dart';
import '../data/provider_profile.dart';
import '../data/model_service_credential_snapshot.dart';
import '../data/subagent_role.dart';
import '../data/prompt_presets.dart';
import '../data/chat_skill.dart';
import '../data/jev_config.dart';
import '../data/ui_prefs.dart';
import '../data/media_api_config.dart';
import '../data/context_prefs.dart';
import '../data/gateway_config.dart';
import '../data/task_budget_prefs.dart';
import '../data/composer_modes.dart';
import '../platform/theme_mode.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/tools/search_provider.dart';

/// GUI adapter: mutations run in the one shared host service.
class HostSettingsController extends SettingsController {
  HostClient get _client => HostClient.current!;
  int _revision = -1;
  @override
  Future<SettingsState> build() async {
    await _client.refresh(force: true);
    final subscription = _client.updates.listen(_accept);
    ref.onDispose(subscription.cancel);
    _revision = _client.state['settings_revision'] as int? ?? -1;
    return _decode();
  }

  SettingsState _decode() => decodeSettingsState(
    wireMap(_client.state['settings']),
    gatewayTokenProvider: () => freshGatewayTokenForHost(),
  );
  void _accept(Map<String, dynamic> update) {
    final revision = update['settings_revision'];
    if (!ref.mounted || update['settings'] == null || revision == _revision) {
      return;
    }
    _revision = revision as int? ?? _revision;
    state = AsyncData(_decode());
  }

  Future<Object?> _call(String operation, Map<String, Object?> args) async {
    final result = await _client.call('settings', operation, args);
    if (ref.mounted) _accept(_client.state);
    return result;
  }

  @override
  Future<String> freshGatewayTokenForHost() async {
    return await _call('freshGatewayTokenForHost', {}) as String;
  }

  @override
  Future<void> setMemoryEnabled(bool enabled) async {
    await _call('setMemoryEnabled', {'enabled': encodeHostValue(enabled)});
  }

  @override
  Future<void> setResearchModeEnabled(bool enabled) async {
    await _call('setResearchModeEnabled', {
      'enabled': encodeHostValue(enabled),
    });
  }

  @override
  Future<void> setStudyModeEnabled(bool enabled) async {
    await _call('setStudyModeEnabled', {'enabled': encodeHostValue(enabled)});
  }

  @override
  Future<void> setCreationModeEnabled(bool enabled) async {
    await _call('setCreationModeEnabled', {
      'enabled': encodeHostValue(enabled),
    });
  }

  @override
  Future<void> apply({
    Object? selectedModel = SettingsState.unchanged,
    ThemePreference? themeMode,
  }) async {
    await _call('apply', {
      if (!identical(selectedModel, SettingsState.unchanged))
        'selectedModel': encodeHostValue(selectedModel),
      'themeMode': encodeHostValue(themeMode),
    });
  }

  @override
  Future<void> setUiPrefs(UiPrefs ui) async {
    await _call('setUiPrefs', {'ui': encodeHostValue(ui)});
  }

  @override
  Future<void> setApiKey(String apiKey) async {
    await _call('setApiKey', {'apiKey': encodeHostValue(apiKey)});
  }

  @override
  Future<void> setTaskBudget(TaskBudgetPrefs value) async {
    await _call('setTaskBudget', {'value': encodeHostValue(value)});
  }

  @override
  Future<void> waitForProfileMutations() async {
    await _call('waitForProfileMutations', {});
  }

  @override
  Future<ModelServiceCredentialSnapshot> readCurrentProfileCredentials(
    String id,
  ) async {
    final result = wireMap(
      await _call('readCurrentProfileCredentials', {'id': encodeHostValue(id)}),
    );
    return ModelServiceCredentialSnapshot(
      profile: ProviderProfile.fromJson(wireMap(result['profile'])),
      apiKey: result['apiKey'] as String,
      epoch: result['epoch'] as int,
    );
  }

  @override
  Future<void> setProfileApiKey(String profileId, String apiKey) async {
    await _call('setProfileApiKey', {
      'profileId': encodeHostValue(profileId),
      'apiKey': encodeHostValue(apiKey),
    });
  }

  @override
  Future<void> setSearchBackend(SearchBackend backend) async {
    await _call('setSearchBackend', {'backend': encodeHostValue(backend)});
  }

  @override
  Future<void> setSearchApiKey(String key) async {
    await _call('setSearchApiKey', {'key': encodeHostValue(key)});
  }

  @override
  Future<void> setSearchBrainModel(String? model) async {
    await _call('setSearchBrainModel', {'model': encodeHostValue(model)});
  }

  @override
  Future<void> setSearchMaxRounds(int rounds) async {
    await _call('setSearchMaxRounds', {'rounds': encodeHostValue(rounds)});
  }

  @override
  Future<void> setSearchMode(SearchMode mode) async {
    await _call('setSearchMode', {'mode': encodeHostValue(mode)});
  }

  @override
  Future<void> setImageGenMode(ImageGenMode mode) async {
    await _call('setImageGenMode', {'mode': encodeHostValue(mode)});
  }

  @override
  Future<void> setReasoningEffort(ReasoningEffort effort) async {
    await _call('setReasoningEffort', {'effort': encodeHostValue(effort)});
  }

  @override
  Future<void> setSearchMaxResults(int results) async {
    await _call('setSearchMaxResults', {'results': encodeHostValue(results)});
  }

  @override
  Future<void> setGatewayConfig(GatewayConfig config) async {
    await _call('setGatewayConfig', {'config': encodeHostValue(config)});
  }

  @override
  Future<void> setGatewayToken(String token) async {
    await _call('setGatewayToken', {'token': encodeHostValue(token)});
  }

  @override
  Future<void> signInGateway() async {
    await _call('signInGateway', {});
  }

  @override
  Future<void> signOutGateway() async {
    await _call('signOutGateway', {});
  }

  @override
  Future<void> setGatewayCapabilities({
    required List<String> capabilities,
    required String serverVersion,
    List<DiscoveredMcpTool> mcpTools = const [],
  }) async {
    await _call('setGatewayCapabilities', {
      'capabilities': encodeHostValue(capabilities),
      'serverVersion': encodeHostValue(serverVersion),
      'mcpTools': encodeHostValue(mcpTools),
    });
  }

  @override
  Future<void> addCustomMcpServer({
    required String id,
    required String name,
    required String baseUrl,
    String token = '',
    McpProcessConfig? localProcess,
    bool computerUse = false,
    bool allowForeground = false,
  }) async {
    await _call('addCustomMcpServer', {
      'id': encodeHostValue(id),
      'name': encodeHostValue(name),
      'baseUrl': encodeHostValue(baseUrl),
      'token': encodeHostValue(token),
      'localProcess': encodeHostValue(localProcess),
      'computerUse': encodeHostValue(computerUse),
      'allowForeground': encodeHostValue(allowForeground),
    });
  }

  @override
  Future<void> updateCustomMcpServer({
    required String id,
    required String name,
    required String baseUrl,
    McpProcessConfig? localProcess,
    bool computerUse = false,
    bool allowForeground = false,
  }) async {
    await _call('updateCustomMcpServer', {
      'id': encodeHostValue(id),
      'name': encodeHostValue(name),
      'baseUrl': encodeHostValue(baseUrl),
      'localProcess': encodeHostValue(localProcess),
      'computerUse': encodeHostValue(computerUse),
      'allowForeground': encodeHostValue(allowForeground),
    });
  }

  @override
  Future<void> setCustomMcpEnabled(String id, bool enabled) async {
    await _call('setCustomMcpEnabled', {
      'id': encodeHostValue(id),
      'enabled': encodeHostValue(enabled),
    });
  }

  @override
  Future<void> setCustomMcpDiscovered(
    String id, {
    required List<DiscoveredMcpTool> tools,
    required String serverVersion,
  }) async {
    await _call('setCustomMcpDiscovered', {
      'id': encodeHostValue(id),
      'tools': encodeHostValue(tools),
      'serverVersion': encodeHostValue(serverVersion),
    });
  }

  @override
  Future<void> setCustomMcpError(String id, String error) async {
    await _call('setCustomMcpError', {
      'id': encodeHostValue(id),
      'error': encodeHostValue(error),
    });
  }

  @override
  Future<void> deleteCustomMcpServer(String id) async {
    await _call('deleteCustomMcpServer', {'id': encodeHostValue(id)});
  }

  @override
  Future<void> setCustomMcpSecrets(
    String id, {
    Map<String, String>? environment,
    Map<String, String>? headers,
  }) async {
    await _call('setCustomMcpSecrets', {
      'id': encodeHostValue(id),
      'environment': encodeHostValue(environment),
      'headers': encodeHostValue(headers),
    });
  }

  @override
  Future<void> setCustomMcpToken(String id, String token) async {
    await _call('setCustomMcpToken', {
      'id': encodeHostValue(id),
      'token': encodeHostValue(token),
    });
  }

  @override
  Future<void> setJevConfig(JevConfig config) async {
    await _call('setJevConfig', {'config': encodeHostValue(config)});
  }

  @override
  Future<void> setJevApiKey(String value) async {
    await _call('setJevApiKey', {'value': encodeHostValue(value)});
  }

  @override
  Future<void> setChatSkills(ChatSkillCatalog catalog) async {
    await _call('setChatSkills', {'catalog': encodeHostValue(catalog)});
  }

  @override
  Future<void> setWorkAgentInstructions(String value) async {
    await _call('setWorkAgentInstructions', {'value': encodeHostValue(value)});
  }

  @override
  Future<void> setSubagentInstructions(String value) async {
    await _call('setSubagentInstructions', {'value': encodeHostValue(value)});
  }

  @override
  Future<void> setSubagentRoles(List<SubagentRole> roles) async {
    await _call('setSubagentRoles', {'roles': encodeHostValue(roles)});
  }

  @override
  Future<void> setSubagentRouterModel(String model) async {
    await _call('setSubagentRouterModel', {'model': encodeHostValue(model)});
  }

  @override
  Future<void> setPromptPresets(PromptPresets presets) async {
    await _call('setPromptPresets', {'presets': encodeHostValue(presets)});
  }

  @override
  Future<void> selectPromptPreset(String? id) async {
    await _call('selectPromptPreset', {'id': encodeHostValue(id)});
  }

  @override
  Future<void> setSystemPrompt(String prompt) async {
    await _call('setSystemPrompt', {'prompt': encodeHostValue(prompt)});
  }

  @override
  Future<void> setModelContextPrefs(
    String endpoint,
    String model,
    ContextPrefs? value,
  ) async {
    await _call('setModelContextPrefs', {
      'endpoint': encodeHostValue(endpoint),
      'model': encodeHostValue(model),
      'value': encodeHostValue(value),
    });
  }

  @override
  Future<void> setContextPrefs(ContextPrefs context) async {
    await _call('setContextPrefs', {'context': encodeHostValue(context)});
  }

  @override
  Future<void> setAsrEnabled(bool enabled) async {
    await _call('setAsrEnabled', {'enabled': encodeHostValue(enabled)});
  }

  @override
  Future<void> setMediaApiConfig(
    MediaApiKind kind,
    MediaApiConfig config,
  ) async {
    await _call('setMediaApiConfig', {
      'kind': encodeHostValue(kind),
      'config': encodeHostValue(config),
    });
  }

  @override
  Future<void> setMediaApiKey(MediaApiKind kind, String key) async {
    await _call('setMediaApiKey', {
      'kind': encodeHostValue(kind),
      'key': encodeHostValue(key),
    });
  }

  @override
  Future<void> selectTtsProvider(
    SpeechApiProtocol protocol,
    MediaApiConfig fallback,
  ) async {
    await _call('selectTtsProvider', {
      'protocol': encodeHostValue(protocol),
      'fallback': encodeHostValue(fallback),
    });
  }

  @override
  Future<void> saveVerifiedConnection(
    ProviderProfile profile,
    String apiKey,
  ) async {
    await _call('saveVerifiedConnection', {
      'profile': encodeHostValue(profile),
      'apiKey': encodeHostValue(apiKey),
    });
  }

  @override
  Future<void> saveModelService(ProviderProfile profile, String apiKey) async {
    await _call('saveModelService', {
      'profile': encodeHostValue(profile),
      'apiKey': encodeHostValue(apiKey),
    });
  }

  @override
  Future<void> selectProfile(String id) async {
    await _call('selectProfile', {'id': encodeHostValue(id)});
  }

  @override
  Future<void> addProfile(ProviderProfile profile) async {
    await _call('addProfile', {'profile': encodeHostValue(profile)});
  }

  @override
  Future<void> updateProfile(ProviderProfile updated) async {
    await _call('updateProfile', {'updated': encodeHostValue(updated)});
  }

  @override
  Future<void> deleteProfile(String id) async {
    await _call('deleteProfile', {'id': encodeHostValue(id)});
  }

  @override
  Future<String> exportSettingsJson() async {
    return await _call('exportSettingsJson', {}) as String;
  }

  @override
  Future<void> importSettingsJson(String raw) async {
    await _call('importSettingsJson', {'raw': encodeHostValue(raw)});
  }

  @override
  Future<bool> appendValidatedRoleIfAbsent(
    SubagentRole role, {
    bool Function()? stillValid,
  }) async {
    if (stillValid?.call() == false) return false;
    final revision = _client.state['revision'];
    return await _call('appendValidatedRoleIfAbsent', {
          'role': role.toJson(),
          'guard_revision': revision,
        }) ==
        true;
  }
}
