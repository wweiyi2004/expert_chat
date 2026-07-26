import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers.dart';
import '../../data/context_prefs.dart';
import '../../data/provider_profile.dart';
import '../../data/media_api_config.dart';
import '../../data/ui_prefs.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/tools/search_provider.dart';
import '../../domain/update/shorebird_patch.dart';
import '../../domain/update/shorebird_ui.dart';
import '../../domain/update/update_ui.dart';
import '../../state/settings_controller.dart';

enum _SettingsCategory {
  model('模型', Icons.memory_outlined),
  capabilities('能力', Icons.auto_awesome_outlined),
  appearance('外观', Icons.palette_outlined),
  data('数据', Icons.storage_outlined);

  const _SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

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
  final _systemPrompt = TextEditingController();
  bool _obscure = true;
  bool _obscureSearch = true;
  String? _syncedForProfile; // profile id whose key is in the field
  bool _searchKeySynced = false;
  bool _systemPromptSynced = false;
  bool _clearingCache = false;
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
    if (!_systemPromptSynced) {
      _systemPrompt.text = s.systemPrompt;
      _systemPromptSynced = true;
    }
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _searchKey.dispose();
    _systemPrompt.dispose();
    super.dispose();
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
                                    child: Text(
                                      m +
                                          (KnownModels.isReasoner(m)
                                              ? '（深度思考）'
                                              : ''),
                                    ),
                                  ),
                              ],
                              onChanged: (v) => v == null
                                  ? null
                                  : controller.apply(selectedModel: v),
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
                              '视觉和生图使用彼此独立的 OpenAI 兼容 API。'
                              '只有 Base URL、模型和 API Key 全部填写后，对应功能才会出现在聊天界面。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            _OptionalApiCard(
                              title: '视觉理解',
                              description: '上传图片时改用此服务的 /chat/completions',
                              icon: Icons.visibility_outlined,
                              config: s.visionApi,
                              apiKey: s.visionApiKey,
                              configured: s.visionConfigured,
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
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.model) ...[
                            const _SectionTitle('预设提示词'),
                            TextField(
                              controller: _systemPrompt,
                              minLines: 3,
                              maxLines: 8,
                              decoration: const InputDecoration(
                                labelText: '系统提示词（人设）',
                                alignLabelWithHint: true,
                                hintText: '例如：你是一位资深的中文写作助手，回答简洁专业，必要时给出例子。',
                                helperText: '每次对话都会作为第一条系统消息发送。留空则使用模型默认行为。',
                                helperMaxLines: 2,
                                border: OutlineInputBorder(),
                              ),
                              onChanged: controller.setSystemPrompt,
                            ),
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.appearance) ...[
                            const _SectionTitle('外观'),
                            SegmentedButton<ThemeMode>(
                              segments: const [
                                ButtonSegment(
                                  value: ThemeMode.system,
                                  label: Text('跟随'),
                                  icon: Icon(Icons.brightness_auto),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.light,
                                  label: Text('浅色'),
                                  icon: Icon(Icons.light_mode),
                                ),
                                ButtonSegment(
                                  value: ThemeMode.dark,
                                  label: Text('深色'),
                                  icon: Icon(Icons.dark_mode),
                                ),
                              ],
                              selected: {s.themeMode},
                              onSelectionChanged: (set) =>
                                  controller.apply(themeMode: set.first),
                            ),
                            const SizedBox(height: 16),
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
                                helperText:
                                    'DuckDuckGo 免费后端可留空；Tavily / Exa / 博查需要填写 Key。',
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
                            const SizedBox(height: 32),
                          ],
                          if (_category == _SettingsCategory.data) ...[
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
      prefs.contextWindowTokens,
    }.toList()..sort();
    final outputOptions = <int>{
      1024,
      2048,
      4096,
      8192,
      16384,
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

  @override
  State<_OptionalApiCard> createState() => _OptionalApiCardState();
}

class _OptionalApiCardState extends State<_OptionalApiCard> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: widget.config.baseUrl);
    _model = TextEditingController(text: widget.config.model);
    _apiKey = TextEditingController(text: widget.apiKey);
  }

  @override
  void didUpdateWidget(_OptionalApiCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(_baseUrl, widget.config.baseUrl);
    _sync(_model, widget.config.model);
    _sync(_apiKey, widget.apiKey);
  }

  void _sync(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _patch({String? baseUrl, String? model, String? imageSize}) {
    widget.onConfigChanged(
      widget.config.copyWith(
        baseUrl: baseUrl,
        model: model,
        imageSize: imageSize,
      ),
    );
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
            onChanged: widget.onApiKeyChanged,
          ),
        ],
      ),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
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
          onSelected: (value) {
            switch (value) {
              case 'edit':
                onEdit?.call();
              case 'delete':
                onDelete?.call();
              case 'custom':
                onAddCustom();
              default:
                final preset = ProviderPreset.presets.firstWhere(
                  (p) => p.name == value,
                );
                onAddPreset(preset);
            }
          },
          itemBuilder: (context) => [
            if (onEdit != null)
              const PopupMenuItem(value: 'edit', child: Text('编辑当前服务商')),
            if (onDelete != null)
              PopupMenuItem(
                value: 'delete',
                child: Text('删除当前服务商', style: TextStyle(color: scheme.error)),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'custom', child: Text('+ 自定义服务商')),
            for (final preset in ProviderPreset.presets)
              PopupMenuItem(
                value: preset.name,
                child: Text('+ ${preset.name} 预设'),
              ),
          ],
        ),
      ],
    );
  }
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
            subtitle: const Text('Shorebird OTA：免重装，下次冷启动生效'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkShorebirdPatchInteractive(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查整包更新'),
            subtitle: const Text('从 GitHub Releases 下载 APK / zip 安装包'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => checkForUpdatesInteractive(context),
          ),
        ],
      ),
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
