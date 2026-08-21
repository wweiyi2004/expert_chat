import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../data/chat_skill.dart';
import '../../data/context_prefs.dart';
import '../../data/custom_tts_voices.dart';
import '../../data/gateway_config.dart';
import '../../data/provider_profile.dart';
import '../../data/media_api_config.dart';
import '../../data/ui_prefs.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/speech/custom_tts_voice_installer.dart';
import '../../domain/tools/search_provider.dart';
import '../../domain/update/shorebird_patch.dart';
import '../../domain/update/shorebird_ui.dart';
import '../../domain/update/update_ui.dart';
import '../../state/memory_controller.dart';
import '../../state/research_mode_fx.dart';
import '../../state/research_terminal_controller.dart';
import '../../state/settings_controller.dart';
import '../memory/memory_page.dart';
import '../shell/shell_tab.dart';

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
  final _apiKey = TextEditingController();
  final _searchKey = TextEditingController();
  final _gatewayUrl = TextEditingController();
  final _gatewayUploadUrl = TextEditingController();
  final _gatewayAuthUrl = TextEditingController();
  final _gatewayOidcClientId = TextEditingController();
  final _gatewayOidcRedirectUri = TextEditingController();
  final _gatewayToken = TextEditingController();
  final _gatewayTaskModel = TextEditingController();
  bool _obscure = true;
  bool _obscureSearch = true;
  bool _obscureGatewayToken = true;
  String? _syncedForProfile; // profile id whose key is in the field
  bool _searchKeySynced = false;
  bool _gatewaySynced = false;
  bool _clearingCache = false;
  bool _testingSearch = false;
  bool _testingGateway = false;
  bool _signingGatewayIn = false;
  String? _searchTestResult;
  String? _gatewayTestResult;
  String? _gatewayAuthResult;
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
    final activeId = s.active?.id;
    if (_syncedForProfile != activeId) {
      _apiKey.text = s.apiKey;
      _syncedForProfile = activeId;
    }
    if (!_searchKeySynced) {
      _searchKey.text = s.searchApiKey;
      _searchKeySynced = true;
    }
    if (!_gatewaySynced) {
      _gatewayUrl.text = s.gateway.baseUrl;
      _gatewayUploadUrl.text = s.gateway.uploadBaseUrl;
      _gatewayAuthUrl.text = s.gateway.authServiceUrl;
      _gatewayOidcClientId.text = s.gateway.oidcClientId;
      _gatewayOidcRedirectUri.text = s.gateway.oidcRedirectUri;
      _gatewayToken.text = s.gatewayLegacyToken;
      _gatewayTaskModel.text = s.gateway.taskModel;
      _gatewaySynced = true;
    }
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _searchKey.dispose();
    _gatewayUrl.dispose();
    _gatewayUploadUrl.dispose();
    _gatewayAuthUrl.dispose();
    _gatewayOidcClientId.dispose();
    _gatewayOidcRedirectUri.dispose();
    _gatewayToken.dispose();
    _gatewayTaskModel.dispose();
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
          );
      if (!mounted) return;
      setState(() {
        _gatewayTestResult =
            '连通正常：Gateway ${capabilities.gatewayVersion}，'
            '发现 ${capabilities.ids.length} 项能力。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _gatewayTestResult = '测试失败：$e');
    } finally {
      if (mounted) setState(() => _testingGateway = false);
    }
  }

  Future<void> _signInGateway() async {
    if (_signingGatewayIn) return;
    setState(() {
      _signingGatewayIn = true;
      _gatewayAuthResult = null;
    });
    try {
      await ref.read(settingsControllerProvider.notifier).signInGateway();
      if (!mounted) return;
      setState(() => _gatewayAuthResult = '登录成功，Gateway 将自动刷新访问令牌。');
    } catch (error) {
      if (!mounted) return;
      setState(() => _gatewayAuthResult = '登录失败：$error');
    } finally {
      if (mounted) setState(() => _signingGatewayIn = false);
    }
  }

  Future<void> _signOutGateway() async {
    await ref.read(settingsControllerProvider.notifier).signOutGateway();
    if (mounted) setState(() => _gatewayAuthResult = '已退出 AuthService 账户。');
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
            : '当前模型「$model」尚不支持官方联网（需 DeepSeek V4）。'
                  '换用 deepseek-v4-flash / pro / vision-exp，或改用客户端搜索。';
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
        error: (e, _) => Center(child: Text('加载失败：$e')),
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
                            const _SectionTitle('模型服务'),
                            _ProfileSelector(
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
                            TextField(
                              controller: _apiKey,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
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
                              onChanged: controller.setApiKey,
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
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
                                    child: Text(_modelPickerLabel(m)),
                                  ),
                              ],
                              onChanged: (v) => v == null
                                  ? null
                                  : controller.apply(selectedModel: v),
                            ),
                            const SizedBox(height: 20),
                            _ModelUsageCard(
                              endpoint: s.baseUrl,
                              selectedModel: s.model,
                            ),
                            const SizedBox(height: 32),
                            const _SectionTitle('上下文管理'),
                            _ContextSettingsCard(
                              prefs: s.context,
                              onChanged: controller.setContextPrefs,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.capabilities) ...[
                            const _SectionTitle('多媒体能力（可选）'),
                            Text(
                              '对话模型本身支持视觉时（如 DeepSeek deepseek-v4-flash-vision-exp、GPT-4o）可直接看图。'
                              '也可单独配置视觉 API，由对话模型通过 analyze_image 调用。'
                              '视觉、生图和语音的 API Key 与聊天服务互不共用。'
                              'MiMo 的 ASR 与 TTS 走 /chat/completions；'
                              'TTS 也支持阿里百炼和 OpenAI /audio/speech。'
                              '粘贴服务地址或模型时会自动选用正确协议。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            _OptionalApiCard(
                              title: '视觉理解',
                              description:
                                  '给不支持看图的对话模型用。DeepSeek 请填 deepseek-v4-flash-vision-exp，'
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
                            _OptionalApiCard(
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
                            _OptionalApiCard(
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
                            _OptionalApiCard(
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
                            const _SectionTitle('语音朗读'),
                            Text(
                              '每条已完成的 AI 回复都可点“朗读”。开启自动语气后，会按句子'
                              '推断情绪（开心/感伤/叙事等）并调整演绎；也可一键套用'
                              '动漫风自制音色。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            _PrefRow(
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
                            _AnimeVoicePackGrid(
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
                            const _SectionTitle('预设提示词'),
                            _ChatSkillsEditor(
                              catalog: s.chatSkills.sanitize(
                                legacySystemPrompt: s.systemPrompt,
                              ),
                              onChanged: controller.setChatSkills,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.appearance) ...[
                            const _SectionTitle('外观'),
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
                            _ColorThemeLivePreview(
                              theme: s.ui.colorTheme,
                              themeMode: s.themeMode,
                            ),
                            const SizedBox(height: 14),
                            _ColorThemePicker(
                              selected: s.ui.colorTheme,
                              onSelected: (theme) => controller.setUiPrefs(
                                s.ui.copyWith(colorTheme: theme),
                              ),
                            ),
                            const SizedBox(height: 22),
                            _PrefRow(
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
                            _PrefRow(
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
                            _PrefRow(
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
                            _PrefRow(
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
                            _PrefRow(
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
                                      s.ui.copyWith(messageStyle: set.first),
                                    ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _PrefRow(
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
                                      s.ui.copyWith(contentWidth: set.first),
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
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.capabilities) ...[
                            const _SectionTitle('联网搜索'),
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
                            const _SectionTitle('Expert Chat Gateway'),
                            Text(
                              '统一承载文件长任务、文档编辑与格式转换。这里只配置一套地址和 '
                              'Token；新增服务端能力会通过能力发现自动接入，不再重复增加 Gateway 设置。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用 Gateway'),
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
                                labelText: 'Gateway Base URL',
                                helperText: '例如 http://192.168.1.10:8790',
                              ),
                              onChanged: (v) => controller.setGatewayConfig(
                                s.gateway.copyWith(baseUrl: v),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _gatewayUploadUrl,
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                labelText: '文件上传地址（可选）',
                                helperText: '仅 POST /v1/files 使用；留空则走主 Gateway',
                              ),
                              onChanged: (v) => controller.setGatewayConfig(
                                s.gateway.copyWith(uploadBaseUrl: v),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '账户登录',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _gatewayAuthUrl,
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                labelText: 'AuthService 地址',
                                hintText: 'https://auth.example.com',
                                helperText: '使用浏览器完成 OIDC + PKCE 登录；必须使用 HTTPS',
                              ),
                              onChanged: (v) => controller.setGatewayConfig(
                                s.gateway.copyWith(authServiceUrl: v),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _gatewayOidcClientId,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                      labelText: 'OIDC Client ID',
                                      helperText:
                                          'AuthService 中创建的 Public Client',
                                    ),
                                    onChanged: (v) =>
                                        controller.setGatewayConfig(
                                          s.gateway.copyWith(oidcClientId: v),
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextField(
                                    controller: _gatewayOidcRedirectUri,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                      labelText: '回调地址',
                                      helperText:
                                          '默认 expertchat://auth/callback',
                                    ),
                                    onChanged: (v) =>
                                        controller.setGatewayConfig(
                                          s.gateway.copyWith(
                                            oidcRedirectUri: v,
                                          ),
                                        ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (s.gatewaySignedIn)
                              Card(
                                margin: EdgeInsets.zero,
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Text(
                                      (s.gatewayAuthSession!.displayName
                                                  .trim()
                                                  .isEmpty
                                              ? s.gatewayAuthSession!.subject
                                              : s
                                                    .gatewayAuthSession!
                                                    .displayName)
                                          .characters
                                          .first
                                          .toUpperCase(),
                                    ),
                                  ),
                                  title: Text(
                                    s.gatewayAuthSession!.displayName
                                            .trim()
                                            .isEmpty
                                        ? '已登录'
                                        : s.gatewayAuthSession!.displayName,
                                  ),
                                  subtitle: Text(
                                    '账户 ${s.gatewayAuthSession!.subject}\n'
                                    '访问令牌到期前会自动刷新',
                                  ),
                                  isThreeLine: true,
                                  trailing: TextButton(
                                    onPressed: _signOutGateway,
                                    child: const Text('退出'),
                                  ),
                                ),
                              )
                            else
                              FilledButton.icon(
                                onPressed:
                                    s.gateway.authServiceConfigured &&
                                        !_signingGatewayIn
                                    ? _signInGateway
                                    : null,
                                icon: _signingGatewayIn
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.login, size: 18),
                                label: Text(
                                  _signingGatewayIn
                                      ? '正在打开登录…'
                                      : '使用 AuthService 登录',
                                ),
                              ),
                            if (_gatewayAuthResult != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _gatewayAuthResult!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color:
                                          _gatewayAuthResult!.startsWith('登录失败')
                                          ? Theme.of(context).colorScheme.error
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Text(
                              '旧 Token 兼容',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '仅用于迁移期或单用户部署；登录 AuthService 后会优先使用账户令牌。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _gatewayToken,
                              obscureText: _obscureGatewayToken,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: InputDecoration(
                                labelText: 'Gateway Token',
                                helperText:
                                    '对应服务器 GATEWAY_API_TOKEN；完成多账户迁移后可留空',
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
                            const SizedBox(height: 12),
                            TextField(
                              controller: _gatewayTaskModel,
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: const InputDecoration(
                                labelText: '长任务模型覆盖（可选）',
                                helperText: '只影响长文档任务；留空使用服务器默认模型',
                              ),
                              onChanged: (v) => controller.setGatewayConfig(
                                s.gateway.copyWith(taskModel: v),
                              ),
                            ),
                            const SizedBox(height: 8),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('长任务状态同步间隔'),
                              subtitle: Slider(
                                value: s.gateway.taskPollSeconds.toDouble(),
                                min: GatewayConfig.minTaskPollSeconds
                                    .toDouble(),
                                max: GatewayConfig.maxTaskPollSeconds
                                    .toDouble(),
                                divisions:
                                    GatewayConfig.maxTaskPollSeconds -
                                    GatewayConfig.minTaskPollSeconds,
                                label: '${s.gateway.taskPollSeconds}s',
                                onChanged: (v) => controller.setGatewayConfig(
                                  s.gateway.copyWith(
                                    taskPollSeconds: v.round(),
                                  ),
                                ),
                              ),
                              trailing: Text('${s.gateway.taskPollSeconds}s'),
                            ),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('文件处理请求超时'),
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
                                  : const Icon(
                                      Icons.cloud_done_outlined,
                                      size: 18,
                                    ),
                              label: Text(_testingGateway ? '发现中…' : '连接并发现能力'),
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
                                ],
                              ),
                            ],
                            const SizedBox(height: 32),
                            const _SectionTitle('实验功能'),
                            _StudyModeCard(
                              enabled: s.studyModeEnabled,
                              onChanged: _setStudyModeEnabled,
                              onOpenStudy: s.studyModeEnabled
                                  ? () => openShellTab(ref, ShellTab.study)
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _CreationModeCard(
                              enabled: s.creationModeEnabled,
                              onChanged: _setCreationModeEnabled,
                              onOpenStudio: s.creationModeEnabled
                                  ? () => openShellTab(ref, ShellTab.studio)
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _ResearchModeCard(
                              enabled: s.researchModeEnabled,
                              onChanged: (v, origin) => _setResearchModeEnabled(
                                v,
                                originGlobal: origin,
                              ),
                              onOpenTerminal: s.researchModeEnabled
                                  ? () => openShellTab(ref, ShellTab.terminal)
                                  : null,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.data) ...[
                            const _SectionTitle('长期记忆'),
                            _MemorySettingsCard(
                              enabled: s.memoryEnabled,
                              onEnabledChanged: controller.setMemoryEnabled,
                            ),
                            const SizedBox(height: 32),
                            const _SectionTitle('存储与缓存'),
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
                              'API Key 通过系统安全存储保存在本机，不会上传到任何服务器。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 32),
                            const _SectionTitle('关于与更新'),
                            const _AboutUpdateTile(),
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
      MaterialPageRoute(builder: (_) => _ProfileEditPage(existing: existing)),
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

  Future<void> _setStudyModeEnabled(bool enabled) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setStudyModeEnabled(true);
      return;
    }
    if (ref.read(shellTabProvider) == ShellTab.study) {
      ref.read(shellTabProvider.notifier).set(ShellTab.settings);
    }
    await controller.setStudyModeEnabled(false);
  }

  Future<void> _setCreationModeEnabled(bool enabled) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setCreationModeEnabled(true);
      return;
    }
    if (ref.read(shellTabProvider) == ShellTab.studio) {
      ref.read(shellTabProvider.notifier).set(ShellTab.settings);
    }
    await controller.setCreationModeEnabled(false);
  }

  Future<void> _setResearchModeEnabled(
    bool enabled, {
    Offset? originGlobal,
  }) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    if (enabled) {
      await controller.setResearchModeEnabled(true);
      // Rainbow ripple expands from the research switch itself.
      ref
          .read(researchModeFxProvider.notifier)
          .play(originGlobal: originGlobal);
      return;
    }

    final research = ref.read(researchTerminalProvider);
    final hasSession =
        research.isConnected ||
        research.status == ResearchConnectionStatus.connecting;
    if (hasSession) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.link_off_outlined),
          title: const Text('关闭科研模式？'),
          content: const Text(
            '将断开当前 SSH 连接；远端 tmux 中的任务仍会继续运行。'
            '终端入口会从导航中隐藏。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('断开并关闭'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    if (ref.read(shellTabProvider) == ShellTab.terminal) {
      ref.read(shellTabProvider.notifier).set(ShellTab.settings);
    }
    await ref.read(researchTerminalProvider.notifier).releaseAll();
    await controller.setResearchModeEnabled(false);
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

class _ContextSettingsCard extends StatelessWidget {
  const _ContextSettingsCard({required this.prefs, required this.onChanged});

  final ContextPrefs prefs;
  final ValueChanged<ContextPrefs> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final windows = <int>{
      8192,
      16384,
      32768,
      65536,
      128000,
      200000,
      256000,
      1000000,
      prefs.contextWindowTokens,
    }.toList()..sort();
    final outputOptions = <int>{
      1024,
      2048,
      4096,
      8192,
      16384,
      32768,
      65536,
      131072,
      262144,
      384000,
      prefs.reservedOutputTokens,
    }.where((v) => v < prefs.contextWindowTokens).toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动管理上下文'),
              subtitle: const Text('只裁剪发送给模型的临时请求，不修改已保存的聊天记录。'),
              value: prefs.enabled,
              onChanged: (value) => onChanged(prefs.copyWith(enabled: value)),
            ),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              key: ValueKey('context-window-${prefs.contextWindowTokens}'),
              initialValue: prefs.contextWindowTokens,
              decoration: const InputDecoration(labelText: '模型上下文窗口'),
              items: [
                for (final value in windows)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_formatTokens(value)),
                  ),
              ],
              onChanged: prefs.enabled
                  ? (value) {
                      if (value == null) return;
                      final maxReserved = value - 1024;
                      onChanged(
                        prefs.copyWith(
                          contextWindowTokens: value,
                          reservedOutputTokens:
                              prefs.reservedOutputTokens > maxReserved
                              ? maxReserved
                              : prefs.reservedOutputTokens,
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey(
                'context-output-${prefs.contextWindowTokens}-'
                '${prefs.reservedOutputTokens}',
              ),
              initialValue: prefs.reservedOutputTokens,
              decoration: const InputDecoration(labelText: '为回复预留'),
              items: [
                for (final value in outputOptions)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_formatTokens(value)),
                  ),
              ],
              onChanged: prefs.enabled
                  ? (value) {
                      if (value != null) {
                        onChanged(prefs.copyWith(reservedOutputTokens: value));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Text('最多携带历史消息')),
                Text(
                  '${prefs.maxHistoryMessages} 条',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: prefs.maxHistoryMessages.toDouble(),
              min: 4,
              max: 64,
              divisions: 15,
              label: '${prefs.maxHistoryMessages} 条',
              onChanged: prefs.enabled
                  ? (value) => onChanged(
                      prefs.copyWith(
                        maxHistoryMessages: ((value / 4).round() * 4).clamp(
                          4,
                          64,
                        ),
                      ),
                    )
                  : null,
            ),
            Text(
              '当前输入预算约为 ${_formatTokens(prefs.inputBudgetTokens)}。'
              '开启后：优先保留最近对话；装不下时会自动省略较早消息并生成简短历史摘要，'
              '顶栏可查看用量与是否已压缩。'
              'Token 为跨模型保守估算，实际计费以服务商返回值为准。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M Token';
    }
    if (value >= 1000) {
      final digits = value % 1000 == 0 ? 0 : 1;
      return '${(value / 1000).toStringAsFixed(digits)}K Token';
    }
    return '$value Token';
  }
}

class _OptionalApiCard extends StatefulWidget {
  const _OptionalApiCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.config,
    required this.apiKey,
    required this.configured,
    required this.onConfigChanged,
    required this.onApiKeyChanged,
    this.showImageSize = false,
    this.showVoice = false,
    this.showSpeechProtocol = false,
    this.mimoPreset,
    this.aliyunTtsPreset,
    this.onSpeechProviderSelected,
    this.latestConfig,
  });

  final String title;
  final String description;
  final IconData icon;
  final MediaApiConfig config;
  final String apiKey;
  final bool configured;
  final ValueChanged<MediaApiConfig> onConfigChanged;
  final ValueChanged<String> onApiKeyChanged;
  final bool showImageSize;
  final bool showVoice;
  final bool showSpeechProtocol;
  final MediaApiConfig? mimoPreset;
  final MediaApiConfig? aliyunTtsPreset;
  final Future<void> Function(
    SpeechApiProtocol protocol,
    MediaApiConfig fallback,
  )?
  onSpeechProviderSelected;

  /// Returns the endpoint's most recent config at call time — the provider
  /// state, not the last build snapshot — so rapid same-frame field edits
  /// merge instead of having the second overwrite the first.
  final MediaApiConfig Function()? latestConfig;

  @override
  State<_OptionalApiCard> createState() => _OptionalApiCardState();
}

class _OptionalApiCardState extends State<_OptionalApiCard> {
  /// Pause before an API-key edit is persisted. Every keystroke resets it, so
  /// intermediate (incomplete) keys are never written to secure storage; only
  /// the value the user settles on lands.
  static const _apiKeySaveDebounce = Duration(milliseconds: 500);

  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _voiceDesignPrompt;
  late final TextEditingController _apiKey;
  bool _obscure = true;
  bool _pickingCloneSample = false;
  Timer? _apiKeySaveTimer;

  /// True while [onApiKeyChanged] owes the controller a debounced save.
  /// Guards [didUpdateWidget] from reverting in-flight typing to the last
  /// persisted value.
  bool _apiKeyDirty = false;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: widget.config.baseUrl);
    _model = TextEditingController(text: widget.config.model);
    _voice = TextEditingController(text: widget.config.voice);
    _voiceDesignPrompt = TextEditingController(
      text: widget.config.voiceDesignPrompt,
    );
    _apiKey = TextEditingController(text: widget.apiKey);
  }

  @override
  void didUpdateWidget(_OptionalApiCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(_baseUrl, widget.config.baseUrl);
    _sync(_model, widget.config.model);
    _sync(_voice, widget.config.voice);
    _sync(_voiceDesignPrompt, widget.config.voiceDesignPrompt);
    if (!_apiKeyDirty) _sync(_apiKey, widget.apiKey);
  }

  void _sync(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _onApiKeyChanged(String value) {
    _apiKeyDirty = true;
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = Timer(_apiKeySaveDebounce, () {
      _commitApiKey(value);
    });
  }

  /// Persists the latest key field immediately (debounce complete or leave).
  void _commitApiKey(String value) {
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = null;
    _apiKeyDirty = false;
    widget.onApiKeyChanged(value);
  }

  MediaApiConfig _fallbackForSpeechProtocol(SpeechApiProtocol protocol) =>
      switch (protocol) {
        SpeechApiProtocol.mimoChatCompletions =>
          widget.mimoPreset ??
              const MediaApiConfig(
                baseUrl: MediaApiConfig.mimoBaseUrl,
                model: MediaApiConfig.mimoTtsModel,
                voice: MediaApiConfig.mimoDefaultVoice,
                speechProtocol: SpeechApiProtocol.mimoChatCompletions,
              ),
        SpeechApiProtocol.aliyunModelStudio =>
          widget.aliyunTtsPreset ??
              const MediaApiConfig(
                baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
                model: MediaApiConfig.aliyunQwen3TtsModel,
                voice: MediaApiConfig.aliyunQwen3DefaultVoice,
                speechProtocol: SpeechApiProtocol.aliyunModelStudio,
              ),
        SpeechApiProtocol.openAiAudio => const MediaApiConfig(
          voice: '',
          speechProtocol: SpeechApiProtocol.openAiAudio,
        ),
      };

  Future<void> _switchSpeechProvider(
    SpeechApiProtocol protocol, {
    MediaApiConfig? fallback,
  }) async {
    // A provider switch is also a settle point for debounced key editing. Save
    // the current field before changing profiles so the key cannot land in
    // the newly selected provider's secure-storage slot.
    if (_apiKeyDirty) _commitApiKey(_apiKey.text);
    final target = fallback ?? _fallbackForSpeechProtocol(protocol);
    final select = widget.onSpeechProviderSelected;
    if (select != null) {
      await select(protocol, target);
    } else {
      widget.onConfigChanged(target);
    }
  }

  /// Flush any in-flight key edit so leaving the card/page cannot drop it.
  ///
  /// Debounce still avoids writing every intermediate keystroke while the
  /// user is actively typing; dispose / category switch is the settle point.
  ///
  /// The actual write is deferred with [scheduleMicrotask]: calling the
  /// settings controller *during* [dispose] can hit an unmounted Riverpod
  /// ref when the whole tree is tearing down, and can also assert if a
  /// parent rebuild is interleaved with the unmount walk.
  void _flushPendingApiKey() {
    if (!_apiKeyDirty) {
      _apiKeySaveTimer?.cancel();
      _apiKeySaveTimer = null;
      return;
    }
    final value = _apiKey.text;
    final commit = widget.onApiKeyChanged;
    _apiKeySaveTimer?.cancel();
    _apiKeySaveTimer = null;
    _apiKeyDirty = false;
    scheduleMicrotask(() {
      try {
        commit(value);
      } catch (_) {
        // Settings provider already disposed (app/test teardown).
      }
    });
  }

  @override
  void dispose() {
    _flushPendingApiKey();
    _baseUrl.dispose();
    _model.dispose();
    _voice.dispose();
    _voiceDesignPrompt.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _patch({
    String? baseUrl,
    String? model,
    String? imageSize,
    String? voice,
    String? voiceDesignPrompt,
    String? voiceClonePath,
    SpeechApiProtocol? speechProtocol,
  }) {
    // Merge against the latest provider state rather than the last build
    // snapshot: two field edits landing in the same frame would otherwise
    // have the second overwrite the first.
    final current = (widget.latestConfig ?? () => widget.config)();
    final nextBaseUrl = baseUrl ?? current.baseUrl;
    final nextModel = model ?? current.model;
    // When the user pastes a MiMo URL/model on the TTS card, upgrade the
    // wire protocol automatically so requests do not hit /audio/speech.
    final nextProtocol =
        speechProtocol ??
        (widget.showSpeechProtocol
            ? MediaApiConfig.inferSpeechProtocol(
                baseUrl: nextBaseUrl,
                model: nextModel,
                current: current.speechProtocol,
              )
            : current.speechProtocol);
    var nextVoice = voice ?? current.voice;
    final nextConfigShape = MediaApiConfig(
      baseUrl: nextBaseUrl,
      model: nextModel,
      speechProtocol: nextProtocol,
    );
    if (nextProtocol != current.speechProtocol) {
      // Link the voice to the wire protocol, but only when it still holds
      // the *other* protocol's default: a MiMo-default voice must never
      // leak into OpenAI /audio/speech requests, and an empty / OpenAI
      // default voice becomes mimo_default on MiMo. A voice the user
      // picked (anything else) is kept untouched.
      final trimmedVoice = current.voice.trim();
      if (nextProtocol == SpeechApiProtocol.openAiAudio &&
          (trimmedVoice == MediaApiConfig.mimoDefaultVoice ||
              MediaApiConfig.mimoBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwen3BuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        // Empty = "use the endpoint default" (the gateway falls back to
        // `alloy`), which the helper text below explains.
        nextVoice = '';
      } else if (nextProtocol == SpeechApiProtocol.mimoChatCompletions &&
          (trimmedVoice.isEmpty ||
              trimmedVoice == MediaApiConfig.openAiDefaultVoice ||
              MediaApiConfig.openAiBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwen3BuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        nextVoice = MediaApiConfig.mimoDefaultVoice;
      } else if (nextProtocol == SpeechApiProtocol.aliyunModelStudio &&
          (trimmedVoice.isEmpty ||
              trimmedVoice == MediaApiConfig.mimoDefaultVoice ||
              MediaApiConfig.mimoBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ) ||
              MediaApiConfig.openAiBuiltinVoices.any(
                (v) => v.id == trimmedVoice,
              ))) {
        nextVoice = nextConfigShape.aliyunDefaultVoice;
      }
    } else if (nextProtocol == SpeechApiProtocol.aliyunModelStudio &&
        nextModel != current.model &&
        current.aliyunBuiltinVoices.any(
          (option) => option.id == current.voice.trim(),
        ) &&
        !nextConfigShape.aliyunBuiltinVoices.any(
          (option) => option.id == current.voice.trim(),
        )) {
      // A system voice belongs to one Alibaba model family only. When the
      // model changes, swap that known preset for the new family's default;
      // keep truly custom clone/design IDs untouched.
      nextVoice = nextConfigShape.aliyunDefaultVoice;
    }
    widget.onConfigChanged(
      current.copyWith(
        baseUrl: baseUrl,
        model: model,
        imageSize: imageSize,
        voice: nextVoice,
        voiceDesignPrompt: voiceDesignPrompt,
        voiceClonePath: voiceClonePath,
        speechProtocol: nextProtocol,
      ),
    );
  }

  void _selectMimoTtsMode(MimoTtsMode mode) {
    final current = (widget.latestConfig ?? () => widget.config)();
    final nextModel = MediaApiConfig.modelForMimoTtsMode(mode, current.model);
    var nextVoice = current.voice;
    if (mode == MimoTtsMode.builtin &&
        (nextVoice.trim().isEmpty ||
            nextVoice.trim().startsWith('data:') ||
            MediaApiConfig.openAiBuiltinVoices.any(
              (v) => v.id == nextVoice.trim(),
            ))) {
      nextVoice = MediaApiConfig.mimoDefaultVoice;
    }
    _patch(
      model: nextModel,
      voice: nextVoice,
      speechProtocol: SpeechApiProtocol.mimoChatCompletions,
    );
  }

  void _selectAliyunTtsModel(String model) {
    final current = (widget.latestConfig ?? () => widget.config)();
    final target = MediaApiConfig(
      baseUrl: current.baseUrl,
      model: model,
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );
    final selectedVoice = current.voice.trim();
    final isKnownProviderVoice =
        MediaApiConfig.openAiBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.mimoBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.aliyunQwen3BuiltinVoices.any(
          (option) => option.id == selectedVoice,
        ) ||
        MediaApiConfig.aliyunQwenAudioBuiltinVoices.any(
          (option) => option.id == selectedVoice,
        );
    final nextVoice = selectedVoice.isEmpty || isKnownProviderVoice
        ? target.aliyunDefaultVoice
        : selectedVoice;
    _patch(
      // Qwen3-TTS uses public DashScope. Qwen-Audio/CosyVoice keep the current
      // base so users can paste their workspace-scoped domain once.
      baseUrl: target.isAliyunQwen3TtsModel
          ? MediaApiConfig.aliyunModelStudioBaseUrl
          : current.baseUrl,
      model: model,
      voice: nextVoice,
      speechProtocol: SpeechApiProtocol.aliyunModelStudio,
    );
  }

  Future<void> _pickVoiceCloneSample() async {
    if (_pickingCloneSample || kIsWeb) return;
    setState(() => _pickingCloneSample = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'wav', 'mpeg'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      final sourcePath = picked.path;
      if (sourcePath == null || sourcePath.isEmpty) return;

      final source = File(sourcePath);
      if (!await source.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法读取所选音频文件。')));
        }
        return;
      }
      final size = await source.length();
      if (size > 7 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('样本过大，请选择不超过约 7 MB 的 mp3/wav。')),
          );
        }
        return;
      }

      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}tts-voice-clone',
      );
      await dir.create(recursive: true);
      final name = picked.name.toLowerCase();
      final ext = name.endsWith('.mp3') || name.endsWith('.mpeg')
          ? 'mp3'
          : 'wav';
      final dest = File('${dir.path}${Platform.pathSeparator}user-voice.$ext');
      await source.copy(dest.path);
      _selectMimoTtsMode(MimoTtsMode.clone);
      _patch(voiceClonePath: dest.path, voice: '');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存用户音色样本：${picked.name}')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入音色样本失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _pickingCloneSample = false);
    }
  }

  Future<void> _clearVoiceCloneSample() async {
    final path = widget.config.voiceClonePath.trim();
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best effort — missing file is fine.
      }
    }
    _patch(voiceClonePath: '');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(widget.icon, color: scheme.primary),
        title: Text(widget.title),
        subtitle: Text(widget.description),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: widget.configured
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                widget.configured ? '已启用' : '未配置',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: widget.configured
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        children: [
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.example.com/v1',
            ),
            onChanged: (value) => _patch(baseUrl: value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '模型',
              hintText: '输入服务商提供的模型 ID',
            ),
            onChanged: (value) => _patch(model: value),
          ),
          if (widget.showSpeechProtocol) ...[
            const SizedBox(height: 12),
            // Keyed by protocol so auto-inference / MiMo preset remounts the
            // field; FormField initialValue alone would keep a stale choice.
            DropdownButtonFormField<SpeechApiProtocol>(
              key: ValueKey(
                'speech-protocol-${widget.config.effectiveSpeechProtocol.name}',
              ),
              initialValue: widget.config.effectiveSpeechProtocol,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '语音 API 协议',
                helperText: widget.config.looksLikeMimoSpeechEndpoint
                    ? '已根据 MiMo 地址/模型自动选用 /chat/completions'
                    : widget.config.looksLikeAliyunSpeechEndpoint
                    ? '已根据百炼地址/模型自动选用 Model Studio HTTP API'
                    : null,
              ),
              items: const [
                DropdownMenuItem(
                  value: SpeechApiProtocol.openAiAudio,
                  child: Text(
                    'OpenAI /audio/speech',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: SpeechApiProtocol.mimoChatCompletions,
                  child: Text(
                    'MiMo /chat/completions（WAV）',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: SpeechApiProtocol.aliyunModelStudio,
                  child: Text(
                    '阿里百炼 Model Studio TTS',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) _switchSpeechProvider(value);
              },
            ),
          ],
          if (widget.showVoice &&
              widget.config.effectiveSpeechProtocol ==
                  SpeechApiProtocol.aliyunModelStudio) ...[
            const SizedBox(height: 12),
            _buildAliyunModelPresets(context),
          ],
          if (widget.showVoice) ...[
            const SizedBox(height: 12),
            _buildVoiceSection(context),
          ],
          if (widget.showImageSize) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue:
                  const [
                    '1024x1024',
                    '1536x1024',
                    '1024x1536',
                    'auto',
                  ].contains(widget.config.imageSize)
                  ? widget.config.imageSize
                  : '1024x1024',
              decoration: const InputDecoration(labelText: '图片尺寸'),
              items: const [
                DropdownMenuItem(
                  value: '1024x1024',
                  child: Text('1024 × 1024'),
                ),
                DropdownMenuItem(
                  value: '1536x1024',
                  child: Text('1536 × 1024'),
                ),
                DropdownMenuItem(
                  value: '1024x1536',
                  child: Text('1024 × 1536'),
                ),
                DropdownMenuItem(value: 'auto', child: Text('自动')),
              ],
              onChanged: (value) {
                if (value != null) _patch(imageSize: value);
              },
            ),
          ],
          if (widget.mimoPreset != null || widget.aliyunTtsPreset != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.aliyunTtsPreset != null)
                    FilledButton.tonalIcon(
                      onPressed: () => _switchSpeechProvider(
                        SpeechApiProtocol.aliyunModelStudio,
                        fallback: widget.aliyunTtsPreset!,
                      ),
                      icon: const Icon(Icons.graphic_eq_outlined),
                      label: const Text('切换到百炼 TTS'),
                    ),
                  if (widget.mimoPreset != null)
                    OutlinedButton.icon(
                      onPressed: () => _switchSpeechProvider(
                        SpeechApiProtocol.mimoChatCompletions,
                        fallback: widget.mimoPreset!,
                      ),
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: const Text('切换到 MiMo TTS'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '不同服务商的地址、模型、API Key 和音色会分别保存。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-...',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示 API Key' : '隐藏 API Key',
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: _onApiKeyChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildAliyunModelPresets(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = widget.config.model.trim();
    final needsWorkspace =
        widget.config.isAliyunQwenAudioTtsModel ||
        widget.config.isAliyunCosyVoiceTtsModel;
    const presets = <(String, String, String)>[
      (MediaApiConfig.aliyunQwen3TtsModel, 'Qwen3 性价比', '指令音色 · ¥0.8/万字'),
      (
        MediaApiConfig.aliyunQwenAudioTtsModel,
        'Qwen-Audio 低延迟',
        '情绪/复刻 · ¥1/万字',
      ),
      (
        MediaApiConfig.aliyunCosyVoiceTtsModel,
        'CosyVoice 自定义',
        '设计/复刻 · ¥0.8/万字',
      ),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('百炼 TTS 模型', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                ChoiceChip(
                  label: Text(preset.$2),
                  tooltip: '${preset.$1}\n${preset.$3}',
                  selected: model == preset.$1,
                  onSelected: (_) => _selectAliyunTtsModel(preset.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            needsWorkspace
                ? widget.config.hasAliyunWorkspaceBaseUrl
                      ? '已使用百炼 Workspace 地址。'
                      : '该模型需要把 Base URL 换成 '
                            'https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1'
                : 'Qwen3 使用公共 DashScope Base URL，可直接填写百炼 API Key。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: needsWorkspace && !widget.config.hasAliyunWorkspaceBaseUrl
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// TTS voice picker: MiMo modes (builtin / design / clone) + OpenAI chips +
  /// free-form custom id, matching the official MiMo V2.5 TTS docs.
  Widget _buildVoiceSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMimo =
        widget.config.effectiveSpeechProtocol ==
        SpeechApiProtocol.mimoChatCompletions;
    final isAliyun =
        widget.config.effectiveSpeechProtocol ==
        SpeechApiProtocol.aliyunModelStudio;
    final mode = widget.config.mimoTtsMode;
    final selectedVoice = widget.config.voice.trim();
    final builtinOptions = isMimo
        ? MediaApiConfig.mimoBuiltinVoices
        : isAliyun
        ? widget.config.aliyunBuiltinVoices
        : MediaApiConfig.openAiBuiltinVoices;
    final isKnownBuiltin = builtinOptions.any((v) => v.id == selectedVoice);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('音色', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          isMimo
              ? '支持官方内置音色、文案设计音色，以及上传录音克隆你的声音。'
              : isAliyun
              ? widget.config.isAliyunCosyVoiceTtsModel
                    ? 'CosyVoice v3.5 没有系统音色，请填写百炼中创建的复刻/设计 Voice ID。'
                    : '选择当前百炼模型支持的系统音色，或填写复刻/基础 Voice ID。'
              : '选择 OpenAI 兼容预设音色，或填写服务商自定义 Voice ID。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (isMimo) ...[
          const SizedBox(height: 12),
          SegmentedButton<MimoTtsMode>(
            showSelectedIcon: false,
            segments: [
              for (final value in MimoTtsMode.values)
                ButtonSegment<MimoTtsMode>(
                  value: value,
                  label: Text(value.label, overflow: TextOverflow.ellipsis),
                  tooltip: value.description,
                ),
            ],
            selected: {mode},
            onSelectionChanged: (values) {
              if (values.isNotEmpty) _selectMimoTtsMode(values.first);
            },
          ),
          const SizedBox(height: 8),
          Text(
            mode.description,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (!isMimo || mode == MimoTtsMode.builtin) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in builtinOptions)
                FilterChip(
                  label: Text(option.label),
                  tooltip: option.detail.isEmpty
                      ? option.id
                      : '${option.label}（${option.detail}）',
                  selected:
                      selectedVoice == option.id ||
                      (selectedVoice.isEmpty &&
                          option.id ==
                              (isMimo
                                  ? MediaApiConfig.mimoDefaultVoice
                                  : isAliyun
                                  ? widget.config.aliyunDefaultVoice
                                  : MediaApiConfig.openAiDefaultVoice)),
                  onSelected: (_) => _patch(voice: option.id),
                ),
              FilterChip(
                label: const Text('自定义 ID'),
                selected: !isKnownBuiltin,
                onSelected: (_) {
                  // Leave free-form mode: clear a preset/data-URI selection so
                  // the text field appears (empty = endpoint default).
                  if (isKnownBuiltin || selectedVoice.startsWith('data:')) {
                    _patch(voice: '');
                    _sync(_voice, '');
                  }
                },
              ),
            ],
          ),
          if (!isKnownBuiltin) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _voice,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '自定义 Voice ID',
                hintText: isMimo
                    ? '例如 冰糖、Chloe，或服务商自定义 ID'
                    : isAliyun
                    ? widget.config.isAliyunCosyVoiceTtsModel
                          ? '填写声音复刻/设计生成的 Voice ID'
                          : '例如 Cherry、longanhuan_v3.6 或复刻 ID'
                    : '例如 alloy、nova，以服务商为准',
                helperText: selectedVoice.isEmpty
                    ? isAliyun && widget.config.aliyunDefaultVoice.isEmpty
                          ? '当前模型必须填写 Voice ID'
                          : '将使用默认音色'
                    : null,
              ),
              onChanged: (value) => _patch(voice: value),
            ),
          ],
        ],
        if (isMimo && mode == MimoTtsMode.design) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '音色描述（必填）',
              alignLabelWithHint: true,
              hintText: '例如：二十多岁年轻女性，声音清亮柔和，语速适中，像电台深夜主播。',
              helperText: '用自然语言描述性别、年龄、质感、情绪与语速；中英文均可。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isMimo && mode == MimoTtsMode.clone) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.config.hasVoiceCloneSample ? '已导入用户音色样本' : '尚未导入音色样本',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.config.hasVoiceCloneSample
                      ? _basename(widget.config.voiceClonePath)
                      : '支持 mp3 / wav，建议清晰人声、数秒至一分钟，不超过约 7 MB。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _pickingCloneSample
                          ? null
                          : _pickVoiceCloneSample,
                      icon: _pickingCloneSample
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_outlined),
                      label: Text(
                        widget.config.hasVoiceCloneSample ? '重新上传' : '上传录音',
                      ),
                    ),
                    if (widget.config.hasVoiceCloneSample)
                      OutlinedButton.icon(
                        onPressed: _clearVoiceCloneSample,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清除样本'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '风格指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：温和、沉稳，适合连续阅读；或加入方言/情绪标签说明。',
              helperText: '会作为 user 指令发送，不影响克隆音色本身。',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isMimo && mode == MimoTtsMode.builtin) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '风格 / 导演指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：轻快上扬、略快语速；或（温柔）式标签说明。',
              helperText: '留空则使用默认「自然清晰、适合连续阅读」指令。',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
        if (isAliyun) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _voiceDesignPrompt,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: '风格 / 情绪指令（可选）',
              alignLabelWithHint: true,
              hintText: '例如：温柔亲切，像朋友聊天；语速稍慢，重点词轻微加重。',
              helperText: widget.config.isAliyunQwen3TtsModel
                  ? 'Qwen3 Instruct 会优化这条指令；开启自动语气后还会按句调整。'
                  : 'Qwen-Audio/CosyVoice 使用 instruction；自动语气可按句覆盖演绎。',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => _patch(voiceDesignPrompt: value),
          ),
        ],
      ],
    );
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? path : normalized.substring(index + 1);
  }
}

class _AnimeVoicePackGrid extends StatelessWidget {
  const _AnimeVoicePackGrid({
    required this.selectedId,
    required this.onSelect,
    required this.onClear,
  });

  final String selectedId;
  final Future<void> Function(CustomTtsVoicePack pack) onSelect;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final pack in kAnimeStyleVoicePacks)
              FilterChip(
                selected: selectedId == pack.id,
                label: Text(pack.name),
                tooltip: '${pack.tagline}\n点按套用到云端语音合成',
                onSelected: (_) => onSelect(pack),
              ),
            if (selectedId.isNotEmpty)
              ActionChip(
                avatar: Icon(
                  Icons.clear,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                label: const Text('清除套用'),
                onPressed: () => onClear(),
              ),
          ],
        ),
        if (selectedId.isNotEmpty) ...[
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final pack = customTtsVoicePackById(selectedId);
              if (pack == null) return const SizedBox.shrink();
              return Text(
                '当前：${pack.name} · ${pack.tagline}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.primary),
              );
            },
          ),
        ],
      ],
    );
  }
}

Future<ProviderPreset?> pickProviderPreset(BuildContext context) {
  return showDialog<ProviderPreset>(
    context: context,
    builder: (dialogContext) => const _ProviderPresetPickerDialog(),
  );
}

class _ProviderPresetPickerDialog extends StatefulWidget {
  const _ProviderPresetPickerDialog();

  @override
  State<_ProviderPresetPickerDialog> createState() =>
      _ProviderPresetPickerDialogState();
}

class _ProviderPresetPickerDialogState
    extends State<_ProviderPresetPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text;
    final grouped = <ProviderPresetGroup, List<ProviderPreset>>{
      for (final group in ProviderPresetGroup.values)
        group: [
          for (final preset in ProviderPreset.presets)
            if (preset.group == group && preset.matchesQuery(query)) preset,
        ],
    };
    final total = grouped.values.fold<int>(0, (sum, list) => sum + list.length);

    return AlertDialog(
      title: const Text('从预设添加服务商'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: '搜索厂商、地址或模型',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: total == 0
                  ? Center(
                      child: Text(
                        '没有匹配的预设',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final group in ProviderPresetGroup.values)
                          if (grouped[group]!.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                              child: Text(
                                group.label,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            for (final preset in grouped[group]!)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(preset.name),
                                subtitle: Text(
                                  preset.hint.isEmpty
                                      ? preset.baseUrl
                                      : '${preset.baseUrl}\n${preset.hint}',
                                ),
                                isThreeLine: preset.hint.isNotEmpty,
                                onTap: () => Navigator.pop(context, preset),
                              ),
                          ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _ProfileSelector extends StatelessWidget {
  const _ProfileSelector({
    required this.profiles,
    required this.activeId,
    required this.onSelect,
    required this.onAddPreset,
    required this.onAddCustom,
    required this.onEdit,
    required this.onDelete,
  });

  final List<ProviderProfile> profiles;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<ProviderPreset> onAddPreset;
  final VoidCallback onAddCustom;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  Future<void> _addFromPreset(BuildContext context) async {
    final preset = await pickProviderPreset(context);
    if (preset != null) onAddPreset(preset);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: profiles.any((p) => p.id == activeId)
                    ? activeId
                    : (profiles.isNotEmpty ? profiles.first.id : null),
                decoration: const InputDecoration(labelText: '服务商'),
                items: [
                  for (final p in profiles)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => v == null ? null : onSelect(v),
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: '管理服务商',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    onEdit?.call();
                  case 'delete':
                    onDelete?.call();
                  case 'custom':
                    onAddCustom();
                  case 'preset':
                    await _addFromPreset(context);
                }
              },
              itemBuilder: (context) => [
                if (onEdit != null)
                  const PopupMenuItem(value: 'edit', child: Text('编辑当前服务商')),
                if (onDelete != null)
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      '删除当前服务商',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'preset', child: Text('+ 从预设添加…')),
                const PopupMenuItem(value: 'custom', child: Text('+ 自定义服务商')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _addFromPreset(context),
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: const Text('从预设添加'),
            ),
            TextButton(onPressed: onAddCustom, child: const Text('自定义服务商')),
          ],
        ),
      ],
    );
  }
}

class _ModelUsageCard extends ConsumerWidget {
  const _ModelUsageCard({required this.endpoint, required this.selectedModel});

  final String endpoint;
  final String selectedModel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(modelUsageControllerProvider);
    final usageController = ref.read(modelUsageControllerProvider.notifier);
    final records = usageController.forEndpoint(endpoint);
    final totals = usageController.totals(endpoint: endpoint);
    final selected = usageController.find(
      endpoint: endpoint,
      model: selectedModel,
    );
    final scheme = Theme.of(context).colorScheme;

    Future<void> clearUsage() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清除模型用量？'),
          content: Text(
            endpoint.trim().isEmpty
                ? '这会清除本机保存的全部模型用量统计，不会影响聊天记录。'
                : '这会清除当前服务商的模型用量统计，不会影响聊天记录。',
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
      if (confirmed == true) {
        await usageController.clear(
          endpoint: endpoint.trim().isEmpty ? null : endpoint,
        );
      }
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bar_chart_rounded, color: scheme.primary),
              title: const Text('模型用量'),
              subtitle: Text(
                '统计服务商返回的真实 Token；仅保存在本机',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: '清除当前服务商用量',
                onPressed: records.isEmpty ? null : clearUsage,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ),
            if (records.isEmpty)
              Text(
                '完成一次模型请求后，这里会显示输入、输出和缓存命中用量。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: _UsageMetric(
                      label: '请求',
                      value: '${totals.requests}',
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '输入',
                      value: _formatUsageTokens(totals.inputTokens),
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '输出',
                      value: _formatUsageTokens(totals.outputTokens),
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '缓存',
                      value: _formatUsageTokens(totals.cachedInputTokens),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '当前模型：$selectedModel · 缓存命中率 ${(totals.cacheHitRate * 100).round()}%',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (records.length > 1) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 4),
                for (final record in records)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(record.model),
                    subtitle: Text(
                      '输入 ${_formatUsageTokens(record.inputTokens)} · '
                      '输出 ${_formatUsageTokens(record.outputTokens)} · '
                      '缓存 ${_formatUsageTokens(record.cachedInputTokens)}',
                    ),
                    trailing: Text('${record.requests} 次'),
                  ),
              ],
              if (selected != null && selected.reasoningTokens > 0)
                Text(
                  '当前模型推理 Token：${_formatUsageTokens(selected.reasoningTokens)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

String _formatUsageTokens(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) {
    final digits = value % 1000 == 0 ? 0 : 1;
    return '${(value / 1000).toStringAsFixed(digits)}K';
  }
  return '$value';
}

/// Add/edit dialog for a provider profile (name, base URL, models).
/// Full-page add/edit form for a provider profile (a page, not a modal, so it
/// doesn't occlude the settings behind it).
class _ProfileEditPage extends StatefulWidget {
  const _ProfileEditPage({this.existing});
  final ProviderProfile? existing;

  @override
  State<_ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<_ProfileEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _models;
  late final TextEditingController _chatModel;
  late final TextEditingController _reasonerModel;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _models = TextEditingController(text: e?.models.join(', ') ?? '');
    _chatModel = TextEditingController(text: e?.chatModel ?? '');
    _reasonerModel = TextEditingController(text: e?.reasonerModel ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _models.dispose();
    _chatModel.dispose();
    _reasonerModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新增服务商' : '编辑服务商'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final preset = await pickProviderPreset(context);
                if (preset == null || !mounted) return;
                setState(() {
                  if (_name.text.trim().isEmpty) _name.text = preset.name;
                  _baseUrl.text = preset.baseUrl;
                  _models.text = preset.models.join(', ');
                  _chatModel.text = preset.chatModel;
                  _reasonerModel.text = preset.reasonerModel;
                });
              },
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('从预设填入地址和模型'),
            ),
          ),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.example.com/v1',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _models,
            decoration: const InputDecoration(
              labelText: '模型列表（逗号分隔）',
              hintText: 'model-a, model-b',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _chatModel,
            decoration: const InputDecoration(labelText: '默认对话模型'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reasonerModel,
            decoration: const InputDecoration(
              labelText: '深度思考模型',
              hintText: '没有则与对话模型相同',
              helperText: 'DeepSeek V4 等自带思考开关的模型不会切换，只在当前模型上开启思考',
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    final models = _models.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final chat = _chatModel.text.trim().isNotEmpty
        ? _chatModel.text.trim()
        : (models.isNotEmpty ? models.first : '');
    final reasoner = _reasonerModel.text.trim().isNotEmpty
        ? _reasonerModel.text.trim()
        : chat;
    final base = widget.existing;
    final profile =
        (base ??
                ProviderProfile(
                  name: '',
                  baseUrl: '',
                  chatModel: '',
                  reasonerModel: '',
                ))
            .copyWith(
              name: _name.text.trim().isEmpty ? '未命名' : _name.text.trim(),
              baseUrl: _baseUrl.text.trim(),
              models: models.isEmpty ? [chat] : models,
              chatModel: chat,
              reasonerModel: reasoner,
            );
    Navigator.of(context).pop(profile);
  }
}

/// Mini chat mock using the selected palette (independent of applied ThemeData
/// timing so the card always previews the chosen seed/accent).
class _ColorThemeLivePreview extends StatelessWidget {
  const _ColorThemeLivePreview({required this.theme, required this.themeMode});

  final ColorThemePref theme;
  final ThemeMode themeMode;

  bool _preferDark(BuildContext context) {
    return switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
  }

  @override
  Widget build(BuildContext context) {
    final seed = Color(theme.previewArgb);
    final accent = Color(theme.accentPreviewArgb);
    final dark = _preferDark(context);
    final surface = dark
        ? Color.lerp(const Color(0xFF121418), seed, 0.18)!
        : Color.lerp(const Color(0xFFF7F5F1), seed, 0.08)!;
    final panel = dark
        ? Color.lerp(surface, Colors.white, 0.06)!
        : Color.lerp(surface, Colors.white, 0.55)!;
    final ink = dark ? const Color(0xFFE8EEF5) : const Color(0xFF1C2430);
    final muted = ink.withValues(alpha: 0.55);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: seed.withValues(alpha: dark ? 0.35 : 0.22)),
        boxShadow: [
          BoxShadow(
            color: seed.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: seed, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '预览 · ${theme.label}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              Text(
                dark ? '深色' : '浅色',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: panel,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                ),
                border: Border.all(color: seed.withValues(alpha: 0.12)),
              ),
              child: Text(
                '你好，我是助手。这是「${theme.label}」配色下的气泡样式。',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: ink),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: seed,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: const Text(
                '看起来不错，就用这套。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _PreviewChip(color: seed, label: '主色'),
              const SizedBox(width: 8),
              _PreviewChip(color: accent, label: '强调'),
              const Spacer(),
              Text(
                theme.description,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual grid of curated color themes.
class _ColorThemePicker extends StatelessWidget {
  const _ColorThemePicker({required this.selected, required this.onSelected});

  final ColorThemePref selected;
  final ValueChanged<ColorThemePref> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cross = width >= 900
            ? 5
            : width >= 680
            ? 4
            : width >= 420
            ? 3
            : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: ColorThemePref.values.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.92,
          ),
          itemBuilder: (context, index) {
            final theme = ColorThemePref.values[index];
            final isOn = theme == selected;
            final seed = Color(theme.previewArgb);
            final accent = Color(theme.accentPreviewArgb);
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSelected(theme),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isOn
                          ? seed
                          : scheme.outlineVariant.withValues(alpha: 0.85),
                      width: isOn ? 2 : 1,
                    ),
                    boxShadow: isOn
                        ? [
                            BoxShadow(
                              color: seed.withValues(alpha: 0.22),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 5,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    seed,
                                    Color.lerp(seed, accent, 0.55)!,
                                    accent,
                                  ],
                                  stops: const [0, 0.55, 1],
                                ),
                              ),
                            ),
                            // Soft paper wash so labels stay legible on neon seeds.
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                height: 28,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0),
                                      Colors.black.withValues(alpha: 0.18),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (isOn)
                              const Positioned(
                                top: 8,
                                right: 8,
                                child: _SelectedBadge(),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                theme.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: isOn ? seed : scheme.onSurface,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Expanded(
                                child: Text(
                                  theme.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        height: 1.2,
                                      ),
                                ),
                              ),
                              Row(
                                children: [
                                  _Dot(color: seed),
                                  const SizedBox(width: 4),
                                  _Dot(color: accent),
                                  const Spacer(),
                                  if (theme == ColorThemePref.inkTeal)
                                    Text(
                                      '默认',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: const Icon(
        Icons.check_rounded,
        size: 14,
        color: Color(0xFF1C2430),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.7),
          width: 0.8,
        ),
      ),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _AboutUpdateTile extends StatefulWidget {
  const _AboutUpdateTile();

  @override
  State<_AboutUpdateTile> createState() => _AboutUpdateTileState();
}

class _AboutUpdateTileState extends State<_AboutUpdateTile> {
  String _version = '…';
  String _patchLabel = '补丁：检测中…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = 'v${info.version} (${info.buildNumber})');
    });
    final patchService = ShorebirdPatchService();
    if (!patchService.isAvailable) {
      _patchLabel = '代码补丁：当前安装包未启用 Shorebird';
    }
    patchService.currentPatchNumber().then((n) {
      if (!mounted) return;
      setState(() {
        _patchLabel = !patchService.isAvailable
            ? '代码补丁：当前安装包未启用 Shorebird'
            : n == null
            ? '代码补丁：基座版本（暂无补丁）'
            : '代码补丁：#$n';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Expert Chat'),
            subtitle: Text('$_version\n$_patchLabel'),
            isThreeLine: true,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('检查代码补丁'),
            subtitle: const Text('Shorebird OTA：免重装下载 Dart 补丁，完全退出后再打开生效'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkShorebirdPatchInteractive(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查整包更新'),
            subtitle: const Text(
              'GitHub Releases：应用内下载；Android 可直接安装，Windows 保存 zip',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkForUpdatesInteractive(context),
          ),
        ],
      ),
    );
  }
}

class _ChatSkillsEditor extends StatelessWidget {
  const _ChatSkillsEditor({required this.catalog, required this.onChanged});

  final ChatSkillCatalog catalog;
  final ValueChanged<ChatSkillCatalog> onChanged;

  void _replace(ChatSkill next) {
    onChanged(
      ChatSkillCatalog([
        for (final skill in catalog.skills)
          if (skill.id == next.id) next else skill,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final skill in catalog.skills)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ChatSkillCard(
              key: ValueKey(skill.id),
              skill: skill,
              onChanged: (next) {
                if (!next.enabled && skill.fallback && skill.enabled) {
                  final otherFallback = catalog.skills.any(
                    (item) =>
                        item.id != skill.id && item.fallback && item.enabled,
                  );
                  if (!otherFallback) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('至少保留一个回退任务类型')),
                    );
                    return;
                  }
                }
                _replace(next);
              },
              onDelete: skill.builtIn
                  ? null
                  : () => onChanged(
                      ChatSkillCatalog([
                        for (final item in catalog.skills)
                          if (item.id != skill.id) item,
                      ]),
                    ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final created = await showDialog<ChatSkill>(
                context: context,
                builder: (_) => const _AddChatSkillDialog(),
              );
              if (created == null) return;
              onChanged(ChatSkillCatalog([...catalog.skills, created]));
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加任务类型'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '分类器只根据「何时选用」选择种类；提示词只在选中后注入。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _ChatSkillCard extends StatefulWidget {
  const _ChatSkillCard({
    super.key,
    required this.skill,
    required this.onChanged,
    this.onDelete,
  });

  final ChatSkill skill;
  final ValueChanged<ChatSkill> onChanged;
  final VoidCallback? onDelete;

  @override
  State<_ChatSkillCard> createState() => _ChatSkillCardState();
}

class _ChatSkillCardState extends State<_ChatSkillCard> {
  late final TextEditingController _name;
  late final TextEditingController _when;
  late final TextEditingController _prefix;
  late final TextEditingController _prompt;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.skill.name);
    _when = TextEditingController(text: widget.skill.when);
    _prefix = TextEditingController(text: widget.skill.prefix);
    _prompt = TextEditingController(text: widget.skill.prompt);
  }

  @override
  void dispose() {
    _name.dispose();
    _when.dispose();
    _prefix.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _emit({bool? enabled}) {
    widget.onChanged(
      widget.skill.copyWith(
        name: _name.text,
        when: _when.text,
        prefix: _prefix.text,
        prompt: _prompt.text,
        enabled: enabled ?? widget.skill.enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final skill = widget.skill;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text(skill.name.isEmpty ? '未命名' : skill.name),
        subtitle: Text(
          skill.when.isEmpty ? skill.prefix : skill.when,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch.adaptive(
              value: skill.enabled,
              onChanged: (value) => _emit(enabled: value),
            ),
            if (widget.onDelete != null)
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: widget.onDelete,
              ),
            const Icon(Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _when,
            decoration: const InputDecoration(labelText: '何时选用'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prefix,
            decoration: const InputDecoration(labelText: '前缀'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '提示词',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _emit(),
          ),
        ],
      ),
    );
  }
}

class _AddChatSkillDialog extends StatefulWidget {
  const _AddChatSkillDialog();

  @override
  State<_AddChatSkillDialog> createState() => _AddChatSkillDialogState();
}

class _AddChatSkillDialogState extends State<_AddChatSkillDialog> {
  final _name = TextEditingController();
  final _when = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _when.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final when = _when.text.trim();
    if (name.isEmpty || when.isEmpty) return;
    Navigator.of(context).pop(
      ChatSkill(
        id: 'custom_${const Uuid().v4()}',
        name: name,
        when: when,
        prompt: '',
        prefix: '/$name',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加任务类型'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _when,
            decoration: const InputDecoration(labelText: '何时选用'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty || _when.text.trim().isEmpty
              ? null
              : _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

class _MemorySettingsCard extends ConsumerWidget {
  const _MemorySettingsCard({
    required this.enabled,
    required this.onEnabledChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryControllerProvider);
    final count = memory.value?.entries.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.psychology_alt_outlined),
            title: const Text('启用长期记忆'),
            subtitle: const Text('从本地 Markdown 文件召回用户明确保存的事实和偏好；默认不自动记忆。'),
            value: enabled,
            onChanged: onEnabledChanged,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('管理记忆'),
            subtitle: Text(
              count == null ? '查看本地记忆文件' : '已保存 $count 条 · 可查看、编辑和删除',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MemoryPage())),
          ),
        ],
      ),
    );
  }
}

/// Creation hub toggle under 能力 → 实验功能 (mirrors research mode hide/show).
class _StudyModeCard extends StatelessWidget {
  const _StudyModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenStudy,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenStudy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.school_rounded,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '学习模式',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '启用底部「学习」入口：导师、课程、刷题与间隔复习。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭后隐藏学习入口；课程、卡片与错题本仍保留在本机。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (enabled && onOpenStudy != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenStudy,
              icon: const Icon(Icons.school_outlined, size: 18),
              label: const Text('进入学习中心'),
            ),
          ),
        ],
      ],
    );
  }
}

class _CreationModeCard extends StatelessWidget {
  const _CreationModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenStudio,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onOpenStudio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.menu_book_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '创作模式',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '启用底部「创作」入口：导演故事、角色库、世界书。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭后导航更干净；角色与草稿仍保留。聊天里仍可直接开导演故事。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (enabled && onOpenStudio != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onOpenStudio,
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('进入创作中心'),
            ),
          ),
        ],
      ],
    );
  }
}

/// M7 experimental research-mode card under 能力 → 实验功能.
class _ResearchModeCard extends StatefulWidget {
  const _ResearchModeCard({
    required this.enabled,
    required this.onChanged,
    this.onOpenTerminal,
  });

  final bool enabled;

  /// [originGlobal] is the switch center in global coordinates (ripple source).
  final void Function(bool enabled, Offset? originGlobal) onChanged;
  final VoidCallback? onOpenTerminal;

  @override
  State<_ResearchModeCard> createState() => _ResearchModeCardState();
}

class _ResearchModeCardState extends State<_ResearchModeCard> {
  final _switchKey = GlobalKey();

  Offset? _switchCenterGlobal() {
    final box = _switchKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final webBlocked = kIsWeb;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.terminal_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '科研模式',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '实验性',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        webBlocked
                            ? '浏览器无法直接建立原生 SSH 连接。'
                            : '启用 SSH 终端、tmux 会话和 AI 命令审批。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                KeyedSubtree(
                  key: _switchKey,
                  child: Switch.adaptive(
                    value: widget.enabled && !webBlocked,
                    onChanged: webBlocked
                        ? null
                        : (v) => widget.onChanged(v, _switchCenterGlobal()),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '关闭时，终端入口不会显示，服务器配置也不会进入普通 AI 会话。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (widget.enabled && !webBlocked && widget.onOpenTerminal != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: widget.onOpenTerminal,
              icon: const Icon(Icons.terminal_rounded, size: 18),
              label: const Text('进入科研终端'),
            ),
          ),
        ],
      ],
    );
  }
}
