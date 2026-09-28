import 'dart:async';

import 'package:flutter/material.dart';
import 'model_setup_page.dart';
import '../shared/recovery_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../data/custom_tts_voices.dart';
import '../../data/gateway_config.dart';
import '../../data/provider_profile.dart';
import '../../data/media_api_config.dart';
import '../../data/settings_bundle.dart';
import '../../data/ui_prefs.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/speech/custom_tts_voice_installer.dart';
import '../../domain/tools/search_provider.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import 'widgets/debounced_secret_field.dart';
import 'widgets/jev_settings_card.dart';
import 'widgets/task_budget_editor.dart';
import 'backup_page.dart';
import 'support_page.dart';
import '../../domain/support/diagnostic_report.dart';
import '../library/resources_page.dart';

import 'widgets/mcp_settings_widgets.dart';
import 'widgets/context_settings_card.dart';
import 'widgets/media_api_settings_card.dart';
import 'widgets/model_settings_widgets.dart';
import 'widgets/appearance_settings_widgets.dart';
import 'widgets/about_update_tile.dart';
import 'widgets/chat_skills_editor.dart';
import 'widgets/memory_settings_card.dart';
import 'widgets/settings_primitives.dart';

enum _SettingsCategory {
  model('模型', Icons.memory_outlined),
  capabilities('能力', Icons.auto_awesome_outlined),
  appearance('外观', Icons.palette_outlined),
  data('数据', Icons.storage_outlined);

  const _SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

String _modelPickerLabel(String model) {
  final tags = <String>[
    if (KnownModels.isReasoner(model)) '深度思考',
    if (KnownModels.supportsVision(model)) '视觉',
  ];
  if (tags.isEmpty) return model;
  return '$model（${tags.join(' · ')}）';
}

String _gatewayCapabilityLabel(String id) => switch (id) {
  GatewayCapabilityIds.longTasks => '文件长任务',
  GatewayCapabilityIds.documentEdit => '文档编辑',
  GatewayCapabilityIds.documentConvert => '格式转换',
  _ => id,
};

class _SettingsCategoryBar extends StatelessWidget {
  const _SettingsCategoryBar({
    required this.selected,
    required this.onSelected,
  });

  final _SettingsCategory selected;
  final ValueChanged<_SettingsCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '设置分类',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: SegmentedButton<_SettingsCategory>(
          showSelectedIcon: false,
          segments: [
            for (final category in _SettingsCategory.values)
              ButtonSegment<_SettingsCategory>(
                value: category,
                icon: Icon(category.icon, size: 19),
                label: Text(category.label),
              ),
          ],
          selected: {selected},
          onSelectionChanged: (selection) => onSelected(selection.first),
        ),
      ),
    );
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.asRootTab = false});

  /// When true (bottom-nav「设置」), hide the back affordance.
  final bool asRootTab;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _searchKey = TextEditingController();
  final _gatewayUrl = TextEditingController();
  final _gatewayToken = TextEditingController();
  bool _obscure = true;
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
  _SettingsCategory _category = _SettingsCategory.model;

  @override
  void initState() {
    super.initState();
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
    if (s.searchBackend.isProviderHosted) {
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
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: s.searchBackend,
        apiKey: s.searchApiKey,
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
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
          return SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingsCategoryBar(
                      selected: _category,
                      onSelected: (category) {
                        if (category == _category) return;
                        FocusManager.instance.primaryFocus?.unfocus();
                        setState(() => _category = category);
                      },
                    ),
                    Divider(
                      height: 1,
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.7),
                    ),
                    Expanded(
                      child: ListView(
                        // A PageStorageKey here is also inherited by nested
                        // ExpansionTiles and TextFields. They persist different
                        // value types (bool vs. double) and can otherwise write
                        // to the same PageStorage slot.
                        key: ValueKey<String>('settings-${_category.name}'),
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                        children: [
                          if (_category == _SettingsCategory.model) ...[
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.chat_bubble_outline),
                                title: Text(
                                  s.config.isReady ? '验证模型连接' : '连接模型，开始使用',
                                ),
                                subtitle: const Text('填写服务信息，测试成功后开始对话'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () async {
                                  final saved = await showModelSetup(context);
                                  if (saved && context.mounted) {
                                    openShellTab(ref, ShellTab.chat);
                                    if (!widget.asRootTab) {
                                      Navigator.pop(context);
                                    }
                                  }
                                },
                              ),
                            ),
                            const SizedBox(height: 20),
                            const SettingsSectionTitle('模型服务'),
                            ProfileSelector(
                              profiles: s.profiles,
                              activeId: active?.id,
                              onSelect: controller.selectProfile,
                              onAddPreset: (preset) =>
                                  controller.addProfile(preset.toProfile()),
                              onAddCustom: () => _editProfile(context, null),
                              onEdit: active == null
                                  ? null
                                  : () => _editProfile(context, active),
                              onDelete: active == null
                                  ? null
                                  : () => _confirmDeleteProfile(active),
                            ),
                            const SizedBox(height: 16),
                            DebouncedSecretField(
                              key: ValueKey('provider-api-key-${active?.id}'),
                              value: s.apiKey,
                              onSaved: (value) async {
                                if (active != null) {
                                  await controller.setProfileApiKey(
                                    active.id,
                                    value,
                                  );
                                }
                              },
                              obscureText: _obscure,
                              decoration: InputDecoration(
                                labelText: 'API Key',
                                hintText: 'sk-...',
                                helperText: active == null
                                    ? null
                                    : '用于 ${active.name}（${active.baseUrl}）',
                                suffixIcon: IconButton(
                                  tooltip: _obscure
                                      ? '显示 API Key'
                                      : '隐藏 API Key',
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility
                                        : Icons.visibility_off,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: s.availableModels.contains(s.model)
                                  ? s.model
                                  : (s.availableModels.isNotEmpty
                                        ? s.availableModels.first
                                        : null),
                              decoration: const InputDecoration(
                                labelText: '模型',
                              ),
                              items: [
                                for (final m in s.availableModels)
                                  DropdownMenuItem(
                                    value: m,
                                    child: Text(
                                      _modelPickerLabel(m),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                              ],
                              onChanged: (v) => v == null
                                  ? null
                                  : controller.apply(selectedModel: v),
                            ),
                            const SizedBox(height: 20),
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
                            ContextSettingsCard(
                              prefs: s.context,
                              onChanged: controller.setContextPrefs,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.capabilities) ...[
                            const SettingsSectionTitle('多媒体能力（可选）'),
                            Text(
                              '对话模型本身支持视觉时（如 deepseek-flash、deepseek-v4-flash-vision-exp、GPT-4o）可直接看图。'
                              '也可单独配置视觉 API，由对话模型通过 analyze_image 调用。'
                              '视觉、生图和语音的 API Key 与聊天服务互不共用。'
                              'MiMo 的 ASR 与 TTS 走 /chat/completions；'
                              'TTS 也支持阿里百炼和 OpenAI /audio/speech。'
                              '粘贴服务地址或模型时会自动选用正确协议。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            MediaApiSettingsCard(
                              title: '视觉理解',
                              description:
                                  '给不支持看图的对话模型用。DeepSeek 请填 deepseek-flash，'
                                  '也可直接把聊天模型换成该视觉模型',
                              icon: Icons.visibility_outlined,
                              config: s.visionApi,
                              apiKey: s.visionApiKey,
                              configured: s.visionConfigured,
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
                              description: '使用 /images/generations 生成图片',
                              icon: Icons.auto_awesome_outlined,
                              config: s.imageGenerationApi,
                              apiKey: s.imageGenerationApiKey,
                              configured: s.imageGenerationConfigured,
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
                              description:
                                  '录音结束后上传到 MiMo /chat/completions；配置后优先使用它',
                              icon: Icons.mic_none_outlined,
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
                              description: '阿里百炼 Qwen/CosyVoice、OpenAI 或 MiMo',
                              icon: Icons.record_voice_over_outlined,
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
                            const SettingsSectionTitle('语音朗读'),
                            Text(
                              '每条已完成的 AI 回复都可点“朗读”。开启自动语气后，会按句子'
                              '推断情绪（开心/感伤/叙事等）并调整演绎；也可一键套用'
                              '动漫风自制音色。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            SettingsPrefRow(
                              label: '朗读速度',
                              child: SegmentedButton<TtsSpeedPref>(
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
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('自动语气'),
                              subtitle: const Text('按每句内容自动选择情绪与演绎方式，长文更有感情'),
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
                            Text(
                              '基于角色人设的文案设计音色；有样本时也可走克隆。'
                              '并非搬运正版动漫原声，避免版权问题。',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            AnimeVoicePackGrid(
                              selectedId: s.ui.ttsVoicePackId,
                              onSelect: (pack) async {
                                final installer = CustomTtsVoiceInstaller();
                                final next = await installer.applyPack(
                                  pack: pack,
                                  current: s.ttsApi,
                                  preferredMode: CustomTtsVoiceApplyMode.design,
                                );
                                await controller.setMediaApiConfig(
                                  MediaApiKind.tts,
                                  next,
                                );
                                await controller.setUiPrefs(
                                  s.ui.copyWith(ttsVoicePackId: pack.id),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
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
                          if (_category == _SettingsCategory.model) ...[
                            const SettingsSectionTitle('预设提示词'),
                            JevSettingsCard(
                              config: s.jevConfig,
                              apiKey: s.jevApiKey,
                              client: ref.read(jevClientProvider),
                              onConfigChanged: controller.setJevConfig,
                              onApiKeySaved: controller.setJevApiKey,
                            ),
                            const SizedBox(height: 24),
                            ChatSkillsEditor(
                              catalog: s.chatSkills.sanitize(
                                legacySystemPrompt: s.systemPrompt,
                              ),
                              onChanged: controller.setChatSkills,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.appearance) ...[
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
                            SegmentedButton<ThemeMode>(
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
                            Text(
                              '点选即时生效 · 已选「${s.ui.colorTheme.label}」',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
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
                              child: SegmentedButton<TextScalePref>(
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
                            ExpansionTile(
                              key: const ValueKey('advanced-appearance'),
                              tilePadding: EdgeInsets.zero,
                              title: const Text('更多外观设置'),
                              subtitle: const Text('圆角、背景、消息样式与排版'),
                              children: [
                                SettingsPrefRow(
                                  label: '圆角风格',
                                  child: SegmentedButton<CornerStylePref>(
                                    segments: [
                                      for (final v in CornerStylePref.values)
                                        ButtonSegment(
                                          value: v,
                                          label: Text(v.label),
                                        ),
                                    ],
                                    selected: {s.ui.cornerStyle},
                                    onSelectionChanged: (set) =>
                                        controller.setUiPrefs(
                                          s.ui.copyWith(cornerStyle: set.first),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SettingsPrefRow(
                                  label: '聊天背景',
                                  child: SegmentedButton<ChatSurfacePref>(
                                    segments: [
                                      for (final v in ChatSurfacePref.values)
                                        ButtonSegment(
                                          value: v,
                                          label: Text(v.label),
                                          tooltip: v.description,
                                        ),
                                    ],
                                    selected: {s.ui.chatSurface},
                                    onSelectionChanged: (set) =>
                                        controller.setUiPrefs(
                                          s.ui.copyWith(chatSurface: set.first),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  s.ui.chatSurface.description,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 22),
                                Text(
                                  '阅读与布局',
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                SettingsPrefRow(
                                  label: '界面密度',
                                  child: SegmentedButton<DensityPref>(
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
                                          s.ui.copyWith(density: set.first),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SettingsPrefRow(
                                  label: '消息样式',
                                  child: SegmentedButton<MessageStylePref>(
                                    segments: [
                                      for (final v in MessageStylePref.values)
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
                                  style: Theme.of(context).textTheme.labelLarge
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
                                Text(
                                  s.ui.markdownStyle.description,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 10),
                                MarkdownStylePreview(style: s.ui.markdownStyle),
                                const SizedBox(height: 12),
                                SettingsPrefRow(
                                  label: '内容宽度',
                                  child: SegmentedButton<ContentWidthPref>(
                                    segments: [
                                      for (final v in ContentWidthPref.values)
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
                                Text(
                                  '内容宽度主要影响平板 / 桌面宽屏；手机上消息仍铺满可用宽度。',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 12),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('流式实时 Markdown'),
                                  subtitle: const Text(
                                    '开启后生成过程中即渲染格式；关闭则先纯文本、结束后再排版。',
                                  ),
                                  value: s.ui.liveMarkdown,
                                  onChanged: (v) => controller.setUiPrefs(
                                    s.ui.copyWith(liveMarkdown: v),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.capabilities) ...[
                            const SettingsSectionTitle('联网搜索'),
                            Text(
                              '聊天输入框的「联网」开关分三档：关闭 / 自动（模型自行判断）/ '
                              '强制（先搜索再回答）。搜索过程会在回答上方逐步展示。\n'
                              '「API 提供商官方联网」使用 DeepSeek Responses 的服务端 '
                              'web_search（flash / pro / vision-exp），无需搜索 Key。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<SearchBackend>(
                              isExpanded: true,
                              initialValue: s.searchBackend,
                              decoration: const InputDecoration(
                                labelText: '搜索服务',
                              ),
                              items: [
                                for (final b in SearchBackend.values)
                                  DropdownMenuItem(
                                    value: b,
                                    child: Text(b.label),
                                  ),
                              ],
                              onChanged: (v) => v == null
                                  ? null
                                  : controller.setSearchBackend(v),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _searchKey,
                              obscureText: _obscureSearch,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: '搜索 API Key（可选）',
                                helperText: s.searchBackend.isProviderHosted
                                    ? '官方联网使用 LLM API Key，此处可留空。'
                                    : 'DuckDuckGo 免费后端可留空；Tavily / Exa / 博查需要填写 Key。',
                                helperMaxLines: 2,
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
                                          _searchTestResult!.startsWith('测试失败')
                                          ? Theme.of(context).colorScheme.error
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
                                helperText:
                                    '为深度思考等不支持工具调用的模型改写搜索词并编排多轮检索；'
                                    '默认跟随当前配置的对话模型。',
                                helperMaxLines: 3,
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
                                    DropdownMenuItem(value: m, child: Text(m)),
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
                                    kMaxSearchMaxResults - kMinSearchMaxResults,
                                label: '${s.searchMaxResults}',
                                onChanged: (v) =>
                                    controller.setSearchMaxResults(v.round()),
                              ),
                              trailing: Text('${s.searchMaxResults} 条'),
                            ),
                            const SizedBox(height: 32),
                            TaskBudgetEditor(
                              value: s.taskBudget,
                              onChanged: controller.setTaskBudget,
                            ),
                            const SizedBox(height: 24),
                            const SettingsSectionTitle(
                              'Expert Chat MCP Server',
                            ),
                            Text(
                              '连接文档服务后，可编辑和转换文件。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
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
                                helperText:
                                    '例如 http://192.168.1.10:8790；也可直接填写以 /mcp 结尾的地址',
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
                                helperText: '填写服务提供方给你的访问令牌',
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
                              onPressed: _testingGateway ? null : _testGateway,
                              icon: _testingGateway
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.hub_outlined, size: 18),
                              label: Text(_testingGateway ? '连接中…' : '连接并获取工具'),
                            ),
                            if (_gatewayTestResult != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _gatewayTestResult!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color:
                                          _gatewayTestResult!.startsWith('测试失败')
                                          ? Theme.of(context).colorScheme.error
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
                                      label: Text(_gatewayCapabilityLabel(id)),
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
                            Text(
                              '连接外部工具，扩展对话能力。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
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
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.extension_outlined),
                                title: const Text('可选工具'),
                                subtitle: const Text('学习、创作和科研终端的入口与开关'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () {
                                  openShellTab(ref, ShellTab.tools);
                                  Navigator.of(
                                    context,
                                  ).popUntil((route) => route.isFirst);
                                },
                              ),
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.data) ...[
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: const Text('资料'),
                                subtitle: const Text('项目、素材库与生图记录'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const ResourcesPage(),
                                  ),
                                ),
                              ),
                            ),
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.save_outlined),
                                title: const Text('完整备份与恢复'),
                                subtitle: const Text('会话、记忆、学习和素材；校验后导入副本'),
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
                                    subtitle: const Text(
                                      '用于在其他设备导入配置。文件含密钥，请勿分享或公开。',
                                    ),
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
                                    subtitle: const Text(
                                      '从 JSON 覆盖本机的服务商、密钥、网关和多媒体设置。',
                                    ),
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
                                subtitle: const Text(
                                  '清除临时网页预览、图片内存和联网搜索缓存；'
                                  '不会删除聊天、角色、生成图片、设置或 API Key。',
                                ),
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
                            Text(
                              'API Key 保存在本机系统安全存储中，仅用于向你配置的服务发送请求认证。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 32),
                            const SettingsSectionTitle('关于与更新'),
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.info_outline),
                                title: const Text('帮助与反馈'),
                                subtitle: const Text('检查常见问题，预览并复制诊断摘要'),
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editProfile(
    BuildContext context,
    ProviderProfile? existing,
  ) async {
    final result = await Navigator.of(context).push<ProviderProfile>(
      MaterialPageRoute(builder: (_) => ProfileEditPage(existing: existing)),
    );
    if (result == null) return;
    final controller = ref.read(settingsControllerProvider.notifier);
    if (existing == null) {
      await controller.addProfile(result);
    } else {
      await controller.updateProfile(result);
    }
  }

  Future<void> _confirmDeleteProfile(ProviderProfile profile) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: const Text('删除当前服务商？'),
        content: Text('“${profile.name}”的配置和本机保存的 API Key 会被删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .deleteProfile(profile.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('删除服务商失败，请重试。')));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出配置：$path'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已导入配置。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '缓存已清除（临时文件 ${result.filesRemoved} 个，$removed$failure）',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
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
