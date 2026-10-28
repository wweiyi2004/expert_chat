import 'dart:convert';
import '../../state/settings_controller.dart';
import '../../data/composer_modes.dart';
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
import '../../features/tui_bridge/protocol.dart';
import 'wire_models.dart';

/// Explicit RPC allowlist for the existing shared settings service.
class HostSettingsApi {
  HostSettingsApi(this.controller, {required this.revision});
  final SettingsController controller;
  final int Function() revision;
  Future<Object?> invoke(String operation, Map<String, dynamic> a) async {
    String string(String key) => requiredString(a, key);
    String text(String key) => a[key] as String? ?? '';
    List<String> strings(String key) => (a[key] as List? ?? []).cast<String>();
    MediaApiKind kind() => MediaApiKind.values.byName(string('kind'));
    switch (operation) {
      case 'setMemoryEnabled':
        await controller.setMemoryEnabled(a['enabled'] as bool);
      case 'setResearchModeEnabled':
        await controller.setResearchModeEnabled(a['enabled'] as bool);
      case 'setStudyModeEnabled':
        await controller.setStudyModeEnabled(a['enabled'] as bool);
      case 'setCreationModeEnabled':
        await controller.setCreationModeEnabled(a['enabled'] as bool);
      case 'apply':
        await controller.apply(
          selectedModel: a.containsKey('selectedModel')
              ? a['selectedModel']
              : SettingsState.unchanged,
          themeMode: a['themeMode'] == null
              ? null
              : ThemePreference.values.byName(a['themeMode'] as String),
        );
      case 'setUiPrefs':
        await controller.setUiPrefs(UiPrefs.fromJson(wireMap(a['ui'])));
      case 'setApiKey':
        await controller.setApiKey(text('apiKey'));
      case 'setTaskBudget':
        await controller.setTaskBudget(TaskBudgetPrefs.fromJson(a['value']));
      case 'waitForProfileMutations':
        await controller.waitForProfileMutations();
      case 'freshGatewayTokenForHost':
        return controller.freshGatewayTokenForHost();
      case 'appendValidatedRoleIfAbsent':
        final expected = a['guard_revision'];
        if (expected is! int || expected != revision()) return false;
        return controller.appendValidatedRoleIfAbsent(
          SubagentRole.fromJson(wireMap(a['role'])),
          stillValid: () => expected == revision(),
        );
      case 'readCurrentProfileCredentials':
        final value = await controller.readCurrentProfileCredentials(
          string('id'),
        );
        return {
          'profile': value.profile.toJson(),
          'apiKey': value.apiKey,
          'epoch': value.epoch,
        };
      case 'setProfileApiKey':
        await controller.setProfileApiKey(string('profileId'), text('apiKey'));
      case 'setSearchBackend':
        await controller.setSearchBackend(
          SearchBackend.values.byName(string('backend')),
        );
      case 'setSearchApiKey':
        await controller.setSearchApiKey(text('key'));
      case 'setSearchBrainModel':
        await controller.setSearchBrainModel(a['model'] as String?);
      case 'setSearchMaxRounds':
        await controller.setSearchMaxRounds(a['rounds'] as int);
      case 'setSearchMaxResults':
        await controller.setSearchMaxResults(a['results'] as int);
      case 'setSearchMode':
        await controller.setSearchMode(
          SearchMode.values.byName(string('mode')),
        );
      case 'setImageGenMode':
        await controller.setImageGenMode(
          ImageGenMode.values.byName(string('mode')),
        );
      case 'setReasoningEffort':
        await controller.setReasoningEffort(
          ReasoningEffort.values.byName(string('effort')),
        );
      case 'setGatewayConfig':
        await controller.setGatewayConfig(
          GatewayConfig.fromJson(wireMap(a['config'])),
        );
      case 'setGatewayToken':
        await controller.setGatewayToken(text('token'));
      case 'signInGateway':
        await controller.signInGateway();
      case 'signOutGateway':
        await controller.signOutGateway();
      case 'setGatewayCapabilities':
        await controller.setGatewayCapabilities(
          capabilities: strings('capabilities'),
          serverVersion: text('serverVersion'),
          mcpTools: wireRows(
            a['mcpTools'],
          ).map(DiscoveredMcpTool.fromJson).toList(),
        );
      case 'addCustomMcpServer':
        await controller.addCustomMcpServer(
          id: string('id'),
          name: string('name'),
          baseUrl: text('baseUrl'),
          token: text('token'),
          localProcess: a['localProcess'] == null
              ? null
              : McpProcessConfig.fromJson(wireMap(a['localProcess'])),
          computerUse: a['computerUse'] == true,
          allowForeground: a['allowForeground'] == true,
        );
      case 'updateCustomMcpServer':
        await controller.updateCustomMcpServer(
          id: string('id'),
          name: string('name'),
          baseUrl: text('baseUrl'),
          localProcess: a['localProcess'] == null
              ? null
              : McpProcessConfig.fromJson(wireMap(a['localProcess'])),
          computerUse: a['computerUse'] == true,
          allowForeground: a['allowForeground'] == true,
        );
      case 'setCustomMcpEnabled':
        await controller.setCustomMcpEnabled(
          string('id'),
          a['enabled'] as bool,
        );
      case 'setCustomMcpDiscovered':
        await controller.setCustomMcpDiscovered(
          string('id'),
          tools: wireRows(a['tools']).map(DiscoveredMcpTool.fromJson).toList(),
          serverVersion: text('serverVersion'),
        );
      case 'setCustomMcpError':
        await controller.setCustomMcpError(string('id'), text('error'));
      case 'deleteCustomMcpServer':
        await controller.deleteCustomMcpServer(string('id'));
      case 'setCustomMcpSecrets':
        await controller.setCustomMcpSecrets(
          string('id'),
          environment: a['environment'] == null
              ? null
              : Map<String, String>.from(a['environment'] as Map),
          headers: a['headers'] == null
              ? null
              : Map<String, String>.from(a['headers'] as Map),
        );
      case 'setCustomMcpToken':
        await controller.setCustomMcpToken(string('id'), text('token'));
      case 'setJevConfig':
        await controller.setJevConfig(JevConfig.fromJson(wireMap(a['config'])));
      case 'setJevApiKey':
        await controller.setJevApiKey(text('value'));
      case 'setChatSkills':
        await controller.setChatSkills(
          ChatSkillCatalog(
            wireRows(a['catalog']).map(ChatSkill.fromJson).toList(),
          ),
        );
      case 'setWorkAgentInstructions':
        await controller.setWorkAgentInstructions(text('value'));
      case 'setSubagentInstructions':
        await controller.setSubagentInstructions(text('value'));
      case 'setSubagentRoles':
        await controller.setSubagentRoles(
          wireRows(a['roles']).map(SubagentRole.fromJson).toList(),
        );
      case 'setSubagentRouterModel':
        await controller.setSubagentRouterModel(text('model'));
      case 'setPromptPresets':
        await controller.setPromptPresets(
          PromptPresets.decode(jsonEncode(a['presets'])),
        );
      case 'selectPromptPreset':
        await controller.selectPromptPreset(a['id'] as String?);
      case 'setSystemPrompt':
        await controller.setSystemPrompt(text('prompt'));
      case 'setModelContextPrefs':
        await controller.setModelContextPrefs(
          string('endpoint'),
          string('model'),
          a['value'] == null
              ? null
              : ContextPrefs.fromJson(wireMap(a['value'])),
        );
      case 'setContextPrefs':
        await controller.setContextPrefs(
          ContextPrefs.fromJson(wireMap(a['context'])),
        );
      case 'setAsrEnabled':
        await controller.setAsrEnabled(a['enabled'] as bool);
      case 'setMediaApiConfig':
        await controller.setMediaApiConfig(
          kind(),
          MediaApiConfig.fromJson(wireMap(a['config'])),
        );
      case 'setMediaApiKey':
        await controller.setMediaApiKey(kind(), text('key'));
      case 'selectTtsProvider':
        await controller.selectTtsProvider(
          SpeechApiProtocol.values.byName(string('protocol')),
          MediaApiConfig.fromJson(wireMap(a['fallback'])),
        );
      case 'saveVerifiedConnection':
        await controller.saveVerifiedConnection(
          ProviderProfile.fromJson(wireMap(a['profile'])),
          text('apiKey'),
        );
      case 'saveModelService':
        await controller.saveModelService(
          ProviderProfile.fromJson(wireMap(a['profile'])),
          text('apiKey'),
        );
      case 'selectProfile':
        await controller.selectProfile(string('id'));
      case 'addProfile':
        await controller.addProfile(
          ProviderProfile.fromJson(wireMap(a['profile'])),
        );
      case 'updateProfile':
        await controller.updateProfile(
          ProviderProfile.fromJson(wireMap(a['updated'])),
        );
      case 'deleteProfile':
        await controller.deleteProfile(string('id'));
      case 'exportSettingsJson':
        return controller.exportSettingsJson();
      case 'importSettingsJson':
        await controller.importSettingsJson(string('raw'));
      default:
        throw const BridgeFailure('unsupported', '未注册的设置操作');
    }
    return null;
  }
}
