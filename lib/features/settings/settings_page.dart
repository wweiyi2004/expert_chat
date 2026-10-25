import 'package:expert_chat/core/app_toast.dart';
import 'widgets/model_context_settings.dart';
import 'widgets/tool_registry_panel.dart';
import 'widgets/supervisor_settings_panel.dart';
import 'model_services_panel.dart';
import 'widgets/media_service_picker.dart';
import 'widgets/media_capabilities_overview.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../shared/recovery_notice.dart';
import '../../core/prototype_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../core/settings_form_style.dart';
import '../../data/custom_tts_voices.dart';
import '../../data/agent_defaults.dart';
import '../../data/gateway_config.dart';
import '../../data/media_api_config.dart';
import '../../data/settings_bundle.dart';
import '../../data/ui_prefs.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/speech/custom_tts_voice_installer.dart';
import '../../domain/tools/search_provider.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/deepseek_search.dart';
import '../shell/shell_tab.dart';
import 'widgets/jev_settings_card.dart';
import 'widgets/task_budget_editor.dart';
import 'backup_page.dart';
import 'support_page.dart';
import '../../domain/support/diagnostic_report.dart';
import '../shell/tools_page.dart';
import '../chat/widgets/model_pricing_dialog.dart';
import '../../state/model_pricing.dart';
import 'model_setup_page.dart';

import 'widgets/mcp_settings_widgets.dart';
import 'widgets/media_api_settings_card.dart';
import 'widgets/model_settings_widgets.dart';
import 'widgets/appearance_settings_widgets.dart';
import 'widgets/reading_appearance_settings.dart';
import 'widgets/agent_instructions_editor.dart';
import 'widgets/subagent_roles_editor.dart';
import 'widgets/about_update_tile.dart';
import 'widgets/chat_skills_editor.dart';
import 'widgets/memory_settings_card.dart';
import 'widgets/settings_primitives.dart';
import '../workbench/agents/work_agent_model_pool.dart';
import '../workbench/agents/work_agents_panel.dart' show WorkAgentLimitsEditor;

enum SettingsCategory {
  model('模型', Icons.memory_outlined),
  assistants('助手与技能', Icons.auto_awesome_outlined),
  connections('连接', Icons.link_outlined),
  media('多媒体', Icons.perm_media_outlined),
  appearanceData('外观与数据', Icons.palette_outlined);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

String _gatewayCapabilityLabel(String id) => switch (id) {
  GatewayCapabilityIds.longTasks => '文件长任务',
  GatewayCapabilityIds.documentEdit => '文档编辑',
  GatewayCapabilityIds.documentConvert => '格式转换',
  _ => id,
};

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.asRootTab = false,
    this.onOpenNavigation,
    this.initialCategory,
    this.shellHeader = false,
  });
  final VoidCallback? onOpenNavigation;
  final SettingsCategory? initialCategory;
  final bool shellHeader;

  /// When true (bottom-nav「设置」), hide the back affordance.
  final bool asRootTab;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _searchKey = TextEditingController();
  final _gatewayUrl = TextEditingController();
  final _gatewayToken = TextEditingController();
  bool _obscureSearch = true;
  bool _obscureGatewayToken = true;
  bool _searchKeySynced = false;
  bool _gatewaySynced = false;
  bool _clearingCache = false;
  bool _exportingSettings = false;
  bool _importingSettings = false;
  bool _testingSearch = false;
  bool _testingGateway = false;
  String? _discoveringCustomMcpId;
  String? _searchTestResult;
  String? _gatewayTestResult;
  SettingsCategory _category = SettingsCategory.model;
  bool _showOverview = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialCategory != null) {
      _category = widget.initialCategory!;
      _showOverview = false;
    }
    // Sync text fields outside build: writing controllers during build can
    // assert or fight focus when the provider rebuilds mid-frame.
    ref.listenManual<AsyncValue<SettingsState>>(settingsControllerProvider, (
      previous,
      next,
    ) {
      next.whenData(_syncFieldsFromState);
    }, fireImmediately: true);
  }

  void _syncFieldsFromState(SettingsState s) {
    if (!_searchKeySynced) {
      _searchKey.text = s.searchApiKey;
      _searchKeySynced = true;
    }
    if (!_gatewaySynced) {
      _gatewayUrl.text = s.gateway.baseUrl;
      _gatewayToken.text = s.gatewayLegacyToken;
      _gatewaySynced = true;
    }
  }

  @override
  void dispose() {
    _searchKey.dispose();
    _gatewayUrl.dispose();
    _gatewayToken.dispose();
    super.dispose();
  }

  Future<void> _testGateway() async {
    final s = ref.read(settingsControllerProvider).value;
    if (s == null || _testingGateway) return;
    setState(() {
      _testingGateway = true;
      _gatewayTestResult = null;
    });
    try {
      final capabilities = await ref
          .read(gatewayClientProvider)
          .discover(connection: s.gatewayConnection);
      if (!mounted) return;
      await ref
          .read(settingsControllerProvider.notifier)
          .setGatewayCapabilities(
            capabilities: capabilities.ids,
            serverVersion: capabilities.gatewayVersion,
            mcpTools: capabilities.tools,
          );
      if (!mounted) return;
      setState(() {
        _gatewayTestResult =
            '连通正常：MCP ${capabilities.gatewayVersion}，'
            '发现 ${capabilities.tools.length} 个 Tools。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _gatewayTestResult = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _testingGateway = false);
    }
  }

  Future<void> _addCustomMcp() async {
    final result = await _showCustomMcpEditor();
    if (result == null || !mounted) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .addCustomMcpServer(
          id: const Uuid().v4(),
          name: result.name,
          baseUrl: result.url,
          token: result.token,
          localProcess: result.localProcess,
          computerUse: result.computerUse,
          allowForeground: result.allowForeground,
        );
  }

  Future<void> _editCustomMcp(CustomMcpServer server) async {
    final current = ref.read(settingsControllerProvider).value;
    final result = await _showCustomMcpEditor(
      name: server.name,
      url: server.baseUrl,
      token: current?.customMcpTokens[server.id] ?? '',
      localProcess: server.localProcess,
      computerUse: server.computerUse,
      allowForeground: server.allowForeground,
    );
    if (result == null || !mounted) return;
    final controller = ref.read(settingsControllerProvider.notifier);
    await controller.updateCustomMcpServer(
      id: server.id,
      name: result.name,
      baseUrl: result.url,
      localProcess: result.localProcess,
      computerUse: result.computerUse,
      allowForeground: result.allowForeground,
    );
    await controller.setCustomMcpToken(server.id, result.token);
  }

  Future<void> _deleteCustomMcp(CustomMcpServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除自定义 MCP 服务器？'),
        content: Text('“${server.name}”的配置、Token 和已缓存的工具列表都会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .deleteCustomMcpServer(server.id);
  }

  Future<void> _discoverCustomMcp(CustomMcpServer server) async {
    final s = ref.read(settingsControllerProvider).value;
    if (s == null || _discoveringCustomMcpId != null) return;
    setState(() => _discoveringCustomMcpId = server.id);
    final controller = ref.read(settingsControllerProvider.notifier);
    try {
      final capabilities = await ref
          .read(gatewayClientProvider)
          .discover(
            connection: s.gateway.connectionForCustom(
              server,
              s.customMcpTokens[server.id] ?? '',
            ),
          );
      if (!mounted) return;
      await controller.setCustomMcpDiscovered(
        server.id,
        tools: capabilities.tools,
        serverVersion: capabilities.gatewayVersion,
      );
    } catch (error) {
      if (!mounted) return;
      await controller.setCustomMcpError(server.id, error.toString());
    } finally {
      if (mounted) setState(() => _discoveringCustomMcpId = null);
    }
  }

  Future<
    ({
      String name,
      String url,
      String token,
      McpProcessConfig? localProcess,
      bool computerUse,
      bool allowForeground,
    })?
  >
  _showCustomMcpEditor({
    String name = '',
    String url = '',
    String token = '',
    McpProcessConfig? localProcess,
    bool computerUse = false,
    bool allowForeground = false,
  }) {
    return showDialog<
      ({
        String name,
        String url,
        String token,
        McpProcessConfig? localProcess,
        bool computerUse,
        bool allowForeground,
      })
    >(
      context: context,
      builder: (dialogContext) => CustomMcpEditorDialog(
        name: name,
        url: url,
        token: token,
        localProcess: localProcess,
        computerUse: computerUse,
        allowForeground: allowForeground,
      ),
    );
  }

  /// Fires one real search against the configured backend so the user learns
  /// right here whether key/network work — instead of at first use in chat.
  Future<void> _testSearch() async {
    final s = ref.read(settingsControllerProvider).value;
    if (s == null || _testingSearch) return;
    setState(() {
      _testingSearch = true;
      _searchTestResult = null;
    });
    if (s.effectiveSearchBackend.isProviderHosted) {
      final model = s.model;
      final ok = ModelCapabilities.resolve(model).supportsServerWebSearch;
      setState(() {
        _searchTestResult = ok
            ? '官方联网已就绪：当前模型「$model」支持 DeepSeek Responses web_search。'
                  '请在聊天中开启「联网」实测（此处不单独发起搜索请求）。'
            : '当前模型「$model」尚不支持官方联网，请改用客户端搜索。';
        _testingSearch = false;
      });
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      final searchSettings = await resolveDeepSeekSearchCredentials(
        s,
        (key) => ref.read(secureStorageProvider).read(key: key),
      );
      if (!searchSettings.searchConfigured) {
        throw StateError(
          '请填写 DeepSeek 官方搜索 Key，或在模型服务中配置 DeepSeek 官方账号的 API Key。',
        );
      }
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: SearchBackend.deepseek,
        apiKey: searchSettings.effectiveSearchApiKey,
      );
      final context = await engine.runSearch('Flutter 最新稳定版本', maxResults: 3);
      stopwatch.stop();
      if (!mounted) return;
      final sources = context.citations.length;
      final seconds = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      setState(
        () => _searchTestResult = sources > 0
            ? '连通正常：返回 $sources 个来源，耗时 $seconds 秒。'
            : '已连通，但未返回可用结果；可尝试更换搜索服务。',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchTestResult = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _testingSearch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncSettings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final activePage =
        !widget.asRootTab || ref.watch(shellTabProvider) == ShellTab.settings;

    return PopScope(
      canPop: !activePage || (!widget.asRootTab && _showOverview),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && activePage && !_showOverview) {
          setState(() => _showOverview = true);
        } else if (!didPop && activePage && widget.asRootTab) {
          ref.read(shellTabProvider.notifier).set(ShellTab.chat);
        }
      },
      child: Scaffold(
        appBar: widget.shellHeader
            ? null
            : AppBar(
                toolbarHeight: 52,
                titleTextStyle: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                actions: [
                  if (widget.onOpenNavigation != null)
                    IconButton(
                      tooltip: '打开侧边栏',
                      onPressed: widget.onOpenNavigation,
                      icon: const Icon(Icons.menu),
                    ),
                ],
                title: Text(_showOverview ? '设置' : _category.label),
                leading: !_showOverview
                    ? IconButton(
                        tooltip: '返回设置',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => _showOverview = true),
                      )
                    : BackButton(
                        onPressed: () {
                          if (widget.asRootTab) {
                            ref
                                .read(shellTabProvider.notifier)
                                .set(ShellTab.chat);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                automaticallyImplyLeading: !widget.asRootTab,
              ),
        body: asyncSettings.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: RecoveryNotice(
                error: e,
                title: '设置暂时无法加载',
                onRetry: () async {
                  ref.invalidate(settingsControllerProvider);
                  await ref.read(settingsControllerProvider.future);
                },
              ),
            ),
          ),
          data: (s) {
            final active = s.active;
            final wide = MediaQuery.sizeOf(context).width >= 840;
            if (_showOverview && !wide) {
              return _SettingsOverview(
                settings: s,
                onCategory: (category) => setState(() {
                  _category = category;
                  _showOverview = false;
                }),
              );
            }
            final details = SafeArea(
              child: Center(
                child: ConstrainedBox(
                  key: const ValueKey('prototype-settings-content'),
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ListView(
                          // A PageStorageKey here is also inherited by nested
                          // ExpansionTiles and TextFields. They persist different
                          // value types (bool vs. double) and can otherwise write
                          // to the same PageStorage slot.
                          key: ValueKey<String>('settings-${_category.name}'),
                          padding: EdgeInsets.fromLTRB(
                            wide ? 24 : 14,
                            wide ? 20 : 14,
                            wide ? 24 : 14,
                            wide ? 32 : 24,
                          ),
                          children: _prototypeSettingsGroups(context, _category, [
                            if (_category == SettingsCategory.model) ...[
                              const ModelServicesPanel(embedded: true),
                              ListTile(
                                title: const Text('首次模型设置向导'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const ModelSetupPage(),
                                  ),
                                ),
                              ),
                              ListTile(
                                title: const Text('用量与单价'),
                                subtitle: const Text('按模型设置实际计费单价'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => showModelPricing(context, ref, {
                                  modelPricingKey(s.baseUrl, s.model),
                                }),
                              ),
                              const SizedBox(height: 24),
                              if (LlmConfig(
                                baseUrl: s.baseUrl,
                                apiKey: s.apiKey,
                                model: s.model,
                              ).isOfficialDeepSeek) ...[
                                DeepSeekBalanceCard(
                                  baseUrl: s.baseUrl,
                                  apiKey: s.apiKey,
                                  model: s.model,
                                ),
                                const SizedBox(height: 16),
                              ],
                              ModelUsageCard(
                                endpoint: s.baseUrl,
                                selectedModel: s.model,
                              ),
                              const SizedBox(height: 32),
                              const SettingsSectionTitle('上下文管理'),
                              const ModelContextSettings(),
                              const SizedBox(height: 32),
                            ],
                            if (_category == SettingsCategory.connections) ...[
                              const SettingsSectionTitle('执行位置'),
                              const ToolsPage(
                                embedded: true,
                                showModules: false,
                              ),
                              ListTile(
                                leading: const Icon(Icons.perm_media_outlined),
                                title: const Text('多媒体设置'),
                                subtitle: const Text('视觉理解、图片生成、语音识别与合成'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => setState(() {
                                  _category = SettingsCategory.media;
                                }),
                              ),
                            ],
                            if (_category == SettingsCategory.media) ...[
                              MediaCapabilitiesOverview(settings: s),
                              const SettingsSectionTitle('在聊天中使用'),
                              const Text(
                                '识图：在聊天输入框点「+」添加图片。\n'
                                '生图：点「+」→「图片生成」。\n'
                                '语音：点「+」→「语音对话」，或点麦克风输入。\n'
                                '朗读：在回复的操作菜单中选择「朗读」。',
                                style: TextStyle(height: 1.7),
                              ),
                              const SizedBox(height: 18),
                              const SettingsSectionTitle('多媒体服务'),
                              MediaApiSettingsCard(
                                title: '视觉理解',
                                icon: Icons.visibility_outlined,
                                onImportService: () =>
                                    _importMediaService(MediaApiKind.vision),
                                config: s.visionApi,
                                apiKey: s.visionApiKey,
                                configured: s.visionConfigured,
                                showApiFormat: true,
                                latestConfig: () =>
                                    ref
                                        .read(settingsControllerProvider)
                                        .value
                                        ?.visionApi ??
                                    const MediaApiConfig(),
                                onConfigChanged: (value) =>
                                    controller.setMediaApiConfig(
                                      MediaApiKind.vision,
                                      value,
                                    ),
                                onApiKeyChanged: (value) => controller
                                    .setMediaApiKey(MediaApiKind.vision, value),
                              ),
                              const SizedBox(height: 10),
                              MediaApiSettingsCard(
                                title: '图片生成',
                                icon: Icons.auto_awesome_outlined,
                                onImportService: () => _importMediaService(
                                  MediaApiKind.imageGeneration,
                                ),
                                config: s.imageGenerationApi,
                                apiKey: s.imageGenerationApiKey,
                                configured: s.imageGenerationConfigured,
                                showApiFormat: true,
                                latestConfig: () =>
                                    ref
                                        .read(settingsControllerProvider)
                                        .value
                                        ?.imageGenerationApi ??
                                    const MediaApiConfig(),
                                showImageSize: true,
                                onConfigChanged: (value) =>
                                    controller.setMediaApiConfig(
                                      MediaApiKind.imageGeneration,
                                      value,
                                    ),
                                onApiKeyChanged: (value) =>
                                    controller.setMediaApiKey(
                                      MediaApiKind.imageGeneration,
                                      value,
                                    ),
                              ),
                              const SizedBox(height: 10),
                              MediaApiSettingsCard(
                                title: '云端语音识别（MiMo ASR）',
                                icon: Icons.mic_none_outlined,
                                onImportService: () =>
                                    _importMediaService(MediaApiKind.asr),
                                config: s.asrApi,
                                apiKey: s.asrApiKey,
                                configured: s.asrConfigured,
                                latestConfig: () =>
                                    ref
                                        .read(settingsControllerProvider)
                                        .value
                                        ?.asrApi ??
                                    const MediaApiConfig(),
                                mimoPreset: const MediaApiConfig(
                                  baseUrl: MediaApiConfig.mimoBaseUrl,
                                  model: MediaApiConfig.mimoAsrModel,
                                  speechProtocol:
                                      SpeechApiProtocol.mimoChatCompletions,
                                ),
                                onConfigChanged: (value) => controller
                                    .setMediaApiConfig(MediaApiKind.asr, value),
                                onApiKeyChanged: (value) => controller
                                    .setMediaApiKey(MediaApiKind.asr, value),
                              ),
                              const SizedBox(height: 10),
                              MediaApiSettingsCard(
                                title: '云端语音合成',
                                icon: Icons.record_voice_over_outlined,
                                onImportService: () =>
                                    _importMediaService(MediaApiKind.tts),
                                config: s.ttsApi,
                                apiKey: s.ttsApiKey,
                                configured: s.ttsConfigured,
                                latestConfig: () =>
                                    ref
                                        .read(settingsControllerProvider)
                                        .value
                                        ?.ttsApi ??
                                    const MediaApiConfig(),
                                showVoice: true,
                                showSpeechProtocol: true,
                                mimoPreset: const MediaApiConfig(
                                  baseUrl: MediaApiConfig.mimoBaseUrl,
                                  model: MediaApiConfig.mimoTtsModel,
                                  voice: MediaApiConfig.mimoDefaultVoice,
                                  speechProtocol:
                                      SpeechApiProtocol.mimoChatCompletions,
                                ),
                                aliyunTtsPreset: const MediaApiConfig(
                                  baseUrl:
                                      MediaApiConfig.aliyunModelStudioBaseUrl,
                                  model: MediaApiConfig.aliyunQwen3TtsModel,
                                  voice: MediaApiConfig.aliyunQwen3DefaultVoice,
                                  speechProtocol:
                                      SpeechApiProtocol.aliyunModelStudio,
                                ),
                                onConfigChanged: (value) => controller
                                    .setMediaApiConfig(MediaApiKind.tts, value),
                                onApiKeyChanged: (value) => controller
                                    .setMediaApiKey(MediaApiKind.tts, value),
                                onSpeechProviderSelected:
                                    controller.selectTtsProvider,
                              ),
                              const SizedBox(height: 24),
                            ],
                            if (_category ==
                                SettingsCategory.appearanceData) ...[
                              const SettingsSectionTitle('语音朗读'),
                              SettingsPrefRow(
                                label: '朗读速度',
                                child: _PrototypeSettingsSegments<TtsSpeedPref>(
                                  segments: [
                                    for (final speed in TtsSpeedPref.values)
                                      ButtonSegment<TtsSpeedPref>(
                                        value: speed,
                                        label: Text(speed.label),
                                      ),
                                  ],
                                  selected: {s.ui.ttsSpeed},
                                  onSelectionChanged: (values) =>
                                      controller.setUiPrefs(
                                        s.ui.copyWith(ttsSpeed: values.first),
                                      ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _PrototypeSettingsSwitch(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('自动语气'),
                                value: s.ui.ttsAutoEmotion,
                                onChanged: (value) => controller.setUiPrefs(
                                  s.ui.copyWith(ttsAutoEmotion: value),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '自制音色（动漫风）',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              AnimeVoicePackGrid(
                                selectedId: s.ui.ttsVoicePackId,
                                onSelect: (pack) async {
                                  final installer = CustomTtsVoiceInstaller();
                                  final next = await installer.applyPack(
                                    pack: pack,
                                    current: s.ttsApi,
                                    preferredMode:
                                        CustomTtsVoiceApplyMode.design,
                                  );
                                  await controller.setMediaApiConfig(
                                    MediaApiKind.tts,
                                    next,
                                  );
                                  await controller.setUiPrefs(
                                    s.ui.copyWith(ttsVoicePackId: pack.id),
                                  );
                                  if (!context.mounted) return;
                                  AppToastMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已套用「${pack.name}」：${pack.tagline}',
                                      ),
                                    ),
                                  );
                                },
                                onClear: () async {
                                  await controller.setUiPrefs(
                                    s.ui.copyWith(ttsVoicePackId: ''),
                                  );
                                },
                              ),
                              const SizedBox(height: 32),
                            ],
                            if (_category == SettingsCategory.assistants) ...[
                              const SupervisorSettingsPanel(),
                              const SettingsSectionTitle('工作 Agent 系统指令'),
                              const Text(
                                '主代理负责统筹，子代理按角色分工。两者不互相继承自定义指令；普通聊天不受影响。',
                              ),
                              const SizedBox(height: 12),
                              AgentInstructionsEditor(
                                key: const ValueKey('work-agent-instructions'),
                                title: '工作主代理',
                                icon: Icons.account_tree_outlined,
                                description: '用于主任务的规划、分工、结果整合和最终回复。',
                                value: s.workAgentInstructions,
                                defaultValue: AgentDefaults.work,
                                onSaved: controller.setWorkAgentInstructions,
                              ),
                              const SettingsSectionTitle('子代理'),
                              const WorkAgentModelPoolSettings(
                                key: ValueKey('settings-subagent-model-pool'),
                              ),
                              const ExpansionTile(
                                key: ValueKey('settings-subagent-limits'),
                                title: Text('子代理限制'),
                                subtitle: Text('全局默认，应用于新建子任务'),
                                children: [WorkAgentLimitsEditor()],
                              ),
                              const SubagentRolesEditor(),
                              const SettingsSectionTitle('限制与预算'),
                              const Text(
                                '模型响应等待与任务执行预算同时适用于工作主代理和子代理；当前会话轮次仍在聊天轮次条与会话操作中设置。',
                              ),
                              TaskBudgetEditor(
                                value: s.taskBudget,
                                onChanged: controller.setTaskBudget,
                              ),

                              const SizedBox(height: 24),
                              const SettingsSectionTitle('回答方式与技能路由'),

                              JevSettingsCard(
                                config: s.jevConfig,
                                apiKey: s.jevApiKey,
                                client: ref.read(jevClientProvider),
                                onConfigChanged: controller.setJevConfig,
                                onApiKeySaved: controller.setJevApiKey,
                              ),
                              const SizedBox(height: 24),
                              const SettingsSectionTitle('自动聊天技能'),
                              Text('按问题自动选择技能，未匹配时使用通用技能；Jev 是可选路由器，当前模型负责回答。'),
                              const SizedBox(height: 12),
                              ChatSkillsEditor(
                                catalog: s.chatSkills.sanitize(
                                  legacySystemPrompt: s.systemPrompt,
                                ),
                                onChanged: controller.setChatSkills,
                              ),
                              const SizedBox(height: 32),
                            ],
                            if (_category ==
                                SettingsCategory.appearanceData) ...[
                              const SettingsSectionTitle('功能模块'),
                              const ToolsPage(
                                embedded: true,
                                showConnections: false,
                              ),
                              const SettingsSectionTitle('外观'),
                              Text(
                                '明暗模式',
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              _PrototypeSettingsSegments<ThemeMode>(
                                segments: const [
                                  ButtonSegment(
                                    value: ThemeMode.system,
                                    label: Text('跟随'),
                                    icon: Icon(Icons.brightness_auto, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.light,
                                    label: Text('浅色'),
                                    icon: Icon(Icons.light_mode, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.dark,
                                    label: Text('深色'),
                                    icon: Icon(Icons.dark_mode, size: 18),
                                  ),
                                ],
                                selected: {s.themeMode},
                                onSelectionChanged: (set) =>
                                    controller.apply(themeMode: set.first),
                              ),
                              const SizedBox(height: 22),
                              Text(
                                '配色方案',
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              ColorThemeLivePreview(
                                theme: s.ui.colorTheme,
                                themeMode: s.themeMode,
                              ),
                              const SizedBox(height: 14),
                              ColorThemePicker(
                                selected: s.ui.colorTheme,
                                onSelected: (theme) => controller.setUiPrefs(
                                  s.ui.copyWith(colorTheme: theme),
                                ),
                              ),
                              const SizedBox(height: 22),
                              SettingsPrefRow(
                                label: '文字大小',
                                child:
                                    _PrototypeSettingsSegments<TextScalePref>(
                                      segments: [
                                        for (final v in TextScalePref.values)
                                          ButtonSegment(
                                            value: v,
                                            label: Text(v.label),
                                          ),
                                      ],
                                      selected: {s.ui.textScale},
                                      onSelectionChanged: (set) =>
                                          controller.setUiPrefs(
                                            s.ui.copyWith(textScale: set.first),
                                          ),
                                    ),
                              ),
                              const SizedBox(height: 12),
                              ReadingAppearanceSettings(
                                prefs: s.ui,
                                onChanged: controller.setUiPrefs,
                              ),
                              const SizedBox(height: 12),
                              ExpansionTile(
                                key: const ValueKey('advanced-appearance'),
                                tilePadding: EdgeInsets.zero,
                                title: const Text('更多外观设置'),
                                children: [
                                  SettingsPrefRow(
                                    label: '圆角风格',
                                    child:
                                        _PrototypeSettingsSegments<
                                          CornerStylePref
                                        >(
                                          segments: [
                                            for (final v
                                                in CornerStylePref.values)
                                              ButtonSegment(
                                                value: v,
                                                label: Text(v.label),
                                              ),
                                          ],
                                          selected: {s.ui.cornerStyle},
                                          onSelectionChanged: (set) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(
                                                  cornerStyle: set.first,
                                                ),
                                              ),
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  SettingsPrefRow(
                                    label: '聊天背景',
                                    child:
                                        _PrototypeSettingsSegments<
                                          ChatSurfacePref
                                        >(
                                          segments: [
                                            for (final v
                                                in ChatSurfacePref.values)
                                              ButtonSegment(
                                                value: v,
                                                label: Text(v.label),
                                                tooltip: v.description,
                                              ),
                                          ],
                                          selected: {s.ui.chatSurface},
                                          onSelectionChanged: (set) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(
                                                  chatSurface: set.first,
                                                ),
                                              ),
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '阅读与布局',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  SettingsPrefRow(
                                    label: '界面密度',
                                    child:
                                        _PrototypeSettingsSegments<DensityPref>(
                                          segments: [
                                            for (final v in DensityPref.values)
                                              ButtonSegment(
                                                value: v,
                                                label: Text(v.label),
                                              ),
                                          ],
                                          selected: {s.ui.density},
                                          onSelectionChanged: (set) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(
                                                  density: set.first,
                                                ),
                                              ),
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  SettingsPrefRow(
                                    label: '聊天消息样式',
                                    child:
                                        _PrototypeSettingsSegments<
                                          MessageStylePref
                                        >(
                                          segments: [
                                            for (final v
                                                in MessageStylePref.values)
                                              ButtonSegment(
                                                value: v,
                                                label: Text(v.label),
                                              ),
                                          ],
                                          selected: {s.ui.messageStyle},
                                          onSelectionChanged: (set) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(
                                                  messageStyle: set.first,
                                                ),
                                              ),
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Markdown 渲染',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final v in MarkdownStylePref.values)
                                        ChoiceChip(
                                          label: Text(v.label),
                                          selected: s.ui.markdownStyle == v,
                                          onSelected: (_) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(markdownStyle: v),
                                              ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  MarkdownStylePreview(
                                    style: s.ui.markdownStyle,
                                  ),
                                  const SizedBox(height: 12),
                                  SettingsPrefRow(
                                    label: '聊天内容宽度',
                                    child:
                                        _PrototypeSettingsSegments<
                                          ContentWidthPref
                                        >(
                                          segments: [
                                            for (final v
                                                in ContentWidthPref.values)
                                              ButtonSegment(
                                                value: v,
                                                label: Text(v.label),
                                              ),
                                          ],
                                          selected: {s.ui.contentWidth},
                                          onSelectionChanged: (set) =>
                                              controller.setUiPrefs(
                                                s.ui.copyWith(
                                                  contentWidth: set.first,
                                                ),
                                              ),
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  _PrototypeSettingsSwitch(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('流式实时 Markdown'),
                                    value: s.ui.liveMarkdown,
                                    onChanged: (v) => controller.setUiPrefs(
                                      s.ui.copyWith(liveMarkdown: v),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 32),
                            ],
                            if (_category == SettingsCategory.connections) ...[
                              const SettingsSectionTitle('联网搜索'),
                              const ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.travel_explore),
                                title: Text('DeepSeek 官方 Search / Fetch'),
                                subtitle: Text('聊天、工作和子代理统一使用官方搜索与网页抓取 API。'),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: _searchKey,
                                obscureText: _obscureSearch,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: InputDecoration(
                                  labelText: 'DeepSeek 官方搜索 API Key（可选）',
                                  helperText:
                                      '优先使用此 Key；留空时自动读取已配置的 DeepSeek 官方服务 Key，与当前对话模型无关。第三方模型服务的 Key 不用于官方搜索。',
                                  helperMaxLines: 4,
                                  suffixIcon: IconButton(
                                    tooltip: _obscureSearch
                                        ? '显示搜索 API Key'
                                        : '隐藏搜索 API Key',
                                    icon: Icon(
                                      _obscureSearch
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureSearch = !_obscureSearch,
                                    ),
                                  ),
                                ),
                                onChanged: controller.setSearchApiKey,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _testingSearch
                                        ? null
                                        : _testSearch,
                                    icon: _testingSearch
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.network_check_outlined,
                                            size: 18,
                                          ),
                                    label: Text(
                                      _testingSearch ? '测试中…' : '测试搜索连通性',
                                    ),
                                  ),
                                ],
                              ),
                              if (_searchTestResult != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _searchTestResult!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color:
                                            _searchTestResult!.startsWith(
                                              '测试失败',
                                            )
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : null,
                                      ),
                                ),
                              ],
                              const SizedBox(height: 16),
                              DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue:
                                    (s.searchBrainModel != null &&
                                        (active?.models.contains(
                                              s.searchBrainModel,
                                            ) ??
                                            false))
                                    ? s.searchBrainModel
                                    : null,
                                decoration: const InputDecoration(
                                  labelText: '搜索规划模型（搜索大脑）',
                                ),
                                items: [
                                  const DropdownMenuItem<String>(
                                    value: null,
                                    child: Text('跟随对话模型（默认）'),
                                  ),
                                  for (final m
                                      in active?.models ?? const <String>[])
                                    if (ModelCapabilities.resolve(
                                      m,
                                    ).supportsTools)
                                      DropdownMenuItem(
                                        value: m,
                                        child: Text(m),
                                      ),
                                ],
                                onChanged: controller.setSearchBrainModel,
                              ),
                              const SizedBox(height: 8),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('最多搜索轮数'),
                                subtitle: Slider(
                                  value: s.searchMaxRounds.toDouble(),
                                  min: kMinSearchMaxRounds.toDouble(),
                                  max: kMaxSearchMaxRounds.toDouble(),
                                  divisions:
                                      kMaxSearchMaxRounds - kMinSearchMaxRounds,
                                  label: '${s.searchMaxRounds}',
                                  onChanged: (v) =>
                                      controller.setSearchMaxRounds(v.round()),
                                ),
                                trailing: Text('${s.searchMaxRounds} 轮'),
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('单次搜索结果数'),
                                subtitle: Slider(
                                  value: s.searchMaxResults.toDouble(),
                                  min: kMinSearchMaxResults.toDouble(),
                                  max: kMaxSearchMaxResults.toDouble(),
                                  divisions:
                                      kMaxSearchMaxResults -
                                      kMinSearchMaxResults,
                                  label: '${s.searchMaxResults}',
                                  onChanged: (v) =>
                                      controller.setSearchMaxResults(v.round()),
                                ),
                                trailing: Text('${s.searchMaxResults} 条'),
                              ),
                              const SizedBox(height: 32),

                              const SizedBox(height: 24),
                              const SettingsSectionTitle(
                                'Expert Chat MCP Server',
                              ),
                              _PrototypeSettingsSwitch(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('启用 MCP Server'),
                                value: s.gateway.enabled,
                                onChanged: (v) => controller.setGatewayConfig(
                                  s.gateway.copyWith(enabled: v),
                                ),
                              ),
                              TextField(
                                controller: _gatewayUrl,
                                autocorrect: false,
                                enableSuggestions: false,
                                keyboardType: TextInputType.url,
                                decoration: const InputDecoration(
                                  labelText: 'MCP Server URL',
                                  hintText: 'http://192.168.1.10:8790',
                                ),
                                onChanged: (v) => controller.setGatewayConfig(
                                  s.gateway.copyWith(baseUrl: v),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _gatewayToken,
                                obscureText: _obscureGatewayToken,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: InputDecoration(
                                  labelText: 'MCP Token',
                                  suffixIcon: IconButton(
                                    tooltip: _obscureGatewayToken
                                        ? '显示 Token'
                                        : '隐藏 Token',
                                    icon: Icon(
                                      _obscureGatewayToken
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureGatewayToken =
                                          !_obscureGatewayToken,
                                    ),
                                  ),
                                ),
                                onChanged: controller.setGatewayToken,
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('MCP 请求超时'),
                                subtitle: Slider(
                                  value: s.gateway.requestTimeoutSeconds
                                      .toDouble(),
                                  min: GatewayConfig.minRequestTimeoutSeconds
                                      .toDouble(),
                                  max: GatewayConfig.maxRequestTimeoutSeconds
                                      .toDouble(),
                                  divisions:
                                      (GatewayConfig.maxRequestTimeoutSeconds -
                                          GatewayConfig
                                              .minRequestTimeoutSeconds) ~/
                                      30,
                                  label: '${s.gateway.requestTimeoutSeconds}s',
                                  onChanged: (v) => controller.setGatewayConfig(
                                    s.gateway.copyWith(
                                      requestTimeoutSeconds: v.round(),
                                    ),
                                  ),
                                ),
                                trailing: Text(
                                  '${s.gateway.requestTimeoutSeconds}s',
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: _testingGateway
                                    ? null
                                    : _testGateway,
                                icon: _testingGateway
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.hub_outlined, size: 18),
                                label: Text(
                                  _testingGateway ? '连接中…' : '连接并获取工具',
                                ),
                              ),
                              if (_gatewayTestResult != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _gatewayTestResult!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color:
                                            _gatewayTestResult!.startsWith(
                                              '测试失败',
                                            )
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                              if (s.gateway.capabilitiesDiscovered) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    for (final id in s.gateway.capabilities)
                                      Chip(
                                        avatar: const Icon(
                                          Icons.extension_outlined,
                                          size: 17,
                                        ),
                                        label: Text(
                                          _gatewayCapabilityLabel(id),
                                        ),
                                      ),
                                    for (final tool in s.modelDocumentMcpTools)
                                      Chip(
                                        avatar: const Icon(
                                          Icons.build_outlined,
                                          size: 17,
                                        ),
                                        label: Text(tool.name),
                                      ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 32),
                              const SettingsSectionTitle('自定义 MCP 服务器'),
                              const ToolRegistryPanel(),
                              for (final server
                                  in s.gateway.customMcpServers) ...[
                                CustomMcpServerCard(
                                  server: server,
                                  token: s.customMcpTokens[server.id] ?? '',
                                  discovering:
                                      _discoveringCustomMcpId == server.id,
                                  onEnabled: (enabled) => ref
                                      .read(settingsControllerProvider.notifier)
                                      .setCustomMcpEnabled(server.id, enabled),
                                  onDiscover: () => _discoverCustomMcp(server),
                                  onEdit: () => _editCustomMcp(server),
                                  onDelete: () => _deleteCustomMcp(server),
                                ),
                                const SizedBox(height: 12),
                              ],
                              OutlinedButton.icon(
                                onPressed: _addCustomMcp,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('添加 MCP 服务器'),
                              ),
                              const SizedBox(height: 32),
                              const SizedBox(height: 32),
                            ],
                            if (_category ==
                                SettingsCategory.appearanceData) ...[
                              Card(
                                child: ListTile(
                                  leading: const Icon(Icons.save_outlined),
                                  title: const Text('完整备份与恢复'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const BackupPage(),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              const SettingsSectionTitle('配置迁移'),
                              Card(
                                child: Column(
                                  children: [
                                    ListTile(
                                      leading: const Icon(
                                        Icons.file_download_outlined,
                                      ),
                                      title: const Text('导出 API 配置'),
                                      subtitle: const Text('文件含密钥，请勿分享或公开'),
                                      trailing: _exportingSettings
                                          ? const SizedBox.square(
                                              dimension: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.chevron_right),
                                      onTap: _exportingSettings
                                          ? null
                                          : _exportSettings,
                                    ),
                                    const Divider(height: 1),
                                    ListTile(
                                      leading: const Icon(
                                        Icons.file_upload_outlined,
                                      ),
                                      title: const Text('导入 API 配置'),
                                      subtitle: const Text('会覆盖本机配置'),
                                      trailing: _importingSettings
                                          ? const SizedBox.square(
                                              dimension: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.chevron_right),
                                      onTap: _importingSettings
                                          ? null
                                          : _importSettings,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 32),
                              const SettingsSectionTitle('长期记忆'),
                              MemorySettingsCard(
                                enabled: s.memoryEnabled,
                                onEnabledChanged: controller.setMemoryEnabled,
                              ),
                              const SizedBox(height: 32),
                              const SettingsSectionTitle('存储与缓存'),
                              Card(
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.cleaning_services_outlined,
                                  ),
                                  title: const Text('清除软件缓存'),
                                  subtitle: const Text('不影响聊天和设置'),
                                  trailing: _clearingCache
                                      ? const SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.chevron_right),
                                  onTap: _clearingCache ? null : _clearCache,
                                ),
                              ),
                              const SizedBox(height: 32),
                              const SettingsSectionTitle('关于与更新'),
                              Card(
                                child: ListTile(
                                  leading: const Icon(Icons.info_outline),
                                  title: const Text('帮助与反馈'),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () {
                                    final database = ref.read(
                                      appDatabaseProvider,
                                    );
                                    final chat = ref
                                        .read(chatControllerProvider)
                                        .value;
                                    final error =
                                        chat != null &&
                                            chat.errorVisibleFor(chat.currentId)
                                        ? chat.error
                                        : null;
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (_) => SupportPage(
                                          initialError: error,
                                          readCounts: () =>
                                              readDiagnosticCounts(database),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 12),
                              const AboutUpdateTile(),
                            ],
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            if (!wide) return details;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('prototype-settings-nav'),
                  width: 200,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 14,
                    ),
                    children: [
                      for (final category in SettingsCategory.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _SettingsCategoryRow(
                            category: category,
                            selected: _category == category,
                            onTap: () => setState(() {
                              _category = category;
                              _showOverview = false;
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: details),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _importMediaService(MediaApiKind kind) async {
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null) return;
    final selected = await showDialog<MediaServiceSelection>(
      context: context,
      builder: (_) => MediaServicePicker(profiles: settings.profiles),
    );
    if (selected == null || !mounted) return;
    try {
      final key =
          await ref
              .read(secureStorageProvider)
              .read(key: providerApiKeyStorageKey(selected.profile.id)) ??
          '';
      final current = ref.read(settingsControllerProvider).requireValue;
      final config = switch (kind) {
        MediaApiKind.vision => current.visionApi,
        MediaApiKind.imageGeneration => current.imageGenerationApi,
        MediaApiKind.asr => current.asrApi,
        MediaApiKind.tts => current.ttsApi,
      };
      final controller = ref.read(settingsControllerProvider.notifier);
      await controller.setMediaApiConfig(
        kind,
        config.copyWith(
          baseUrl: selected.profile.baseUrl,
          model: selected.model,
          apiFormat: selected.profile.apiFormat,
          speechProtocol: SpeechApiProtocol.openAiAudio,
        ),
      );
      await controller.setMediaApiKey(kind, key);
    } catch (error) {
      if (mounted) {
        AppToastMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _exportSettings() async {
    if (_exportingSettings) return;
    setState(() => _exportingSettings = true);
    try {
      final json = await ref
          .read(settingsControllerProvider.notifier)
          .exportSettingsJson();
      final path = await ref
          .read(settingsBundleFileServiceProvider)
          .exportJson(json: json, fileName: SettingsBundle.fileName);
      if (!mounted || path == null) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出配置：$path'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e'), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _exportingSettings = false);
    }
  }

  Future<void> _importSettings() async {
    if (_importingSettings) return;
    try {
      final raw = await ref.read(settingsBundleFileServiceProvider).pickJson();
      if (raw == null || !mounted) return;
      SettingsBundle.decode(raw);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.file_upload_outlined),
          title: const Text('导入 API 配置？'),
          content: const Text(
            '会覆盖本机的服务商、API Key、网关、搜索和多媒体配置。'
            '聊天记录、素材库和长期记忆不会改动。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _importingSettings = true);
      _searchKeySynced = false;
      _gatewaySynced = false;
      await ref
          .read(settingsControllerProvider.notifier)
          .importSettingsJson(raw);
      final imported = ref.read(settingsControllerProvider).value;
      if (imported != null) {
        ref
            .read(chatControllerProvider.notifier)
            .applyComposerPrefs(
              searchMode: imported.searchMode,
              imageGenMode: imported.imageGenMode,
              reasoningEffort: imported.reasoningEffort,
            );
      }
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已导入配置。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e'), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _importingSettings = false);
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_outlined),
        title: const Text('清除软件缓存？'),
        content: const Text(
          '这会清除临时网页预览、图片内存和短期搜索结果。'
          '聊天记录、角色、生成图片、配置及 API Key 都会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingCache = true);
    try {
      ref.read(toolEnginePoolProvider).clear();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      final result = await ref
          .read(appCacheServiceProvider)
          .clearOwnedTemporaryFiles();
      if (!mounted) return;
      final removed = _formatBytes(result.bytesRemoved);
      final failure = result.failures == 0 ? '' : '，${result.failures} 个文件清理失败';
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '缓存已清除（临时文件 ${result.filesRemoved} 个，$removed$failure）',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('清除缓存失败：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

String _settingsDescription(SettingsCategory category) => switch (category) {
  SettingsCategory.model => '服务、默认模型、路由、用量与单价',
  SettingsCategory.assistants => '主代理、子代理角色、任务类型、监督',
  SettingsCategory.connections => 'MCP、SSH、远程电脑、本机目录、手机控制',
  SettingsCategory.media => '视觉理解、图片生成、语音识别、语音合成',
  SettingsCategory.appearanceData => '主题、阅读、记忆、备份、更新',
};

class _SettingsCategoryRow extends StatelessWidget {
  const _SettingsCategoryRow({
    required this.category,
    required this.selected,
    required this.onTap,
    this.overview = false,
  });
  final SettingsCategory category;
  final bool selected, overview;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = PrototypeColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.panel : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: overview ? 14 : 10,
                vertical: overview ? 10 : 8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          category.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _settingsDescription(category),
                          style: TextStyle(
                            fontSize: overview ? 12 : 11.5,
                            height: 1.4,
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (overview) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.chevron_right, size: 16, color: colors.muted),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview({required this.settings, required this.onCategory});
  final SettingsState settings;
  final ValueChanged<SettingsCategory> onCategory;
  @override
  Widget build(BuildContext context) {
    final colors = PrototypeColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const ValueKey('settings-overview'),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            Container(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final category in SettingsCategory.values) ...[
                    if (category != SettingsCategory.values.first)
                      Divider(height: 1, color: colors.line),
                    _SettingsCategoryRow(
                      category: category,
                      selected: false,
                      overview: true,
                      onTap: () => onCategory(category),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// All existing editors/callbacks are retained; only their section geometry changes.
List<Widget> _prototypeSettingsGroups(
  BuildContext context,
  SettingsCategory category,
  List<Widget> original,
) {
  final groups = <(String, List<Widget>)>[];
  var title = category == SettingsCategory.model ? '模型服务' : category.label;
  var body = <Widget>[];
  final palette = <Widget>[];
  void flush() {
    while (body.isNotEmpty && body.last is SizedBox) {
      body.removeLast();
    }
    if (body.isNotEmpty) groups.add((title, body));
    body = [];
  }

  for (final child in original) {
    if (child is ModelServicesPanel) {
      flush();
      groups.add(('', [child]));
      title = '用量与单价';
      continue;
    }
    if (child is SettingsSectionTitle) {
      flush();
      title = child.text;
      continue;
    }
    if (child is SizedBox && child.child == null && child.height != null) {
      if (body.isNotEmpty) {
        body.add(SizedBox(height: child.height!.clamp(8, 24).toDouble()));
      }
      continue;
    }
    if (category == SettingsCategory.appearanceData &&
        (child is ColorThemePicker || child is ColorThemeLivePreview)) {
      palette.add(child);
      continue;
    }
    if (category == SettingsCategory.appearanceData &&
        child is Text &&
        child.data == '配色方案') {
      continue;
    }
    body.add(child);
  }
  flush();
  if (category == SettingsCategory.appearanceData) {
    const rank = {
      '外观': 0,
      '语音朗读': 1,
      '功能模块': 2,
      '长期记忆': 3,
      '配置迁移': 4,
      '存储与缓存': 5,
      '关于与更新': 6,
    };
    groups.sort((a, b) => (rank[a.$1] ?? 9).compareTo(rank[b.$1] ?? 9));
    if (palette.isNotEmpty) {
      palette.sort(
        (a, b) => a is ColorThemePicker
            ? -1
            : b is ColorThemePicker
            ? 1
            : 0,
      );
      groups.insert(0, ('配色', palette));
    }
  }
  if (category == SettingsCategory.model) {
    final usage = groups.indexWhere((g) => g.$1 == '用量与单价');
    final services = groups.indexWhere(
      (g) => g.$1.isEmpty && g.$2.first is ModelServicesPanel,
    );
    if (usage >= 0 && services >= 0) {
      final widgets = groups[usage].$2;
      final content = PrototypePanel(
        title: '用量与单价',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widgets.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              widgets[i],
            ],
          ],
        ),
      );
      groups[services] = (
        '',
        [ModelServicesPanel(embedded: true, beforeSubscriptions: content)],
      );
      groups.removeAt(usage);
    }
  }
  final theme = Theme.of(context);
  final comfortable = theme.copyWith(
    listTileTheme: theme.listTileTheme.copyWith(
      dense: false,
      minTileHeight: 52,
      minVerticalPadding: 10,
      contentPadding: EdgeInsets.zero,
      horizontalTitleGap: 8,
      minLeadingWidth: 16,
      titleTextStyle: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.45,
      ),
      subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.45,
      ),
    ),
    expansionTileTheme: theme.expansionTileTheme.copyWith(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
    ),
  );
  return [
    for (final group in groups) ...[
      if (group.$1.isEmpty)
        for (final child in group.$2)
          Theme(
            data: comfortable,
            child: SettingsFormStyle(child: child),
          )
      else
        Theme(
          data: comfortable,
          child: SettingsFormStyle(
            child: PrototypePanel(
              title: group.$1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < group.$2.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    group.$2[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 16),
    ],
  ];
}

class _PrototypeSettingsSegments<T> extends StatelessWidget {
  const _PrototypeSettingsSegments({
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
  });
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: PrototypeSegmentedControl<T>(
        value: selected.first,
        segments: [
          for (final segment in segments)
            PrototypeSegment<T>(
              value: segment.value,
              label: segment.label is Text
                  ? (segment.label as Text).data ?? segment.value.toString()
                  : segment.value.toString(),
              icon: segment.icon is Icon ? (segment.icon as Icon).icon : null,
              enabled: segment.enabled,
            ),
        ],
        onChanged: onSelectionChanged == null
            ? null
            : (value) => onSelectionChanged!({value}),
      ),
    ),
  );
}

class _PrototypeSettingsSwitch extends StatelessWidget {
  const _PrototypeSettingsSwitch({
    this.contentPadding,
    required this.title,
    required this.value,
    required this.onChanged,
  });
  final EdgeInsetsGeometry? contentPadding;
  final Widget title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: 10),
            PrototypeSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    ),
  );
}
