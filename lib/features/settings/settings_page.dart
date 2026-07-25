import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:package_info_plus/package_info_plus.dart';

import '../../data/provider_profile.dart';
import '../../data/ui_prefs.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/tools/search_provider.dart';
import '../../domain/update/update_ui.dart';
import '../../state/settings_controller.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.asRootTab = false});

  /// When true (bottom-nav「我的」), hide the back affordance and use tab title.
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

  @override
  void initState() {
    super.initState();
    // Sync text fields outside build: writing controllers during build can
    // assert or fight focus when the provider rebuilds mid-frame.
    ref.listenManual<AsyncValue<SettingsState>>(
      settingsControllerProvider,
      (previous, next) {
        next.whenData(_syncFieldsFromState);
      },
      fireImmediately: true,
    );
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
        title: Text(widget.asRootTab ? '我的' : '设置'),
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
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                  children: [
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
                          tooltip: _obscure ? '显示 API Key' : '隐藏 API Key',
                          icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
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
                      decoration: const InputDecoration(labelText: '模型'),
                      items: [
                        for (final m in s.availableModels)
                          DropdownMenuItem(
                            value: m,
                            child: Text(
                              m + (KnownModels.isReasoner(m) ? '（深度思考）' : ''),
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          v == null ? null : controller.apply(selectedModel: v),
                    ),
                    const SizedBox(height: 32),
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
                            ButtonSegment(value: v, label: Text(v.label)),
                        ],
                        selected: {s.ui.textScale},
                        onSelectionChanged: (set) => controller.setUiPrefs(
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
                            ButtonSegment(value: v, label: Text(v.label)),
                        ],
                        selected: {s.ui.density},
                        onSelectionChanged: (set) => controller.setUiPrefs(
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
                            ButtonSegment(value: v, label: Text(v.label)),
                        ],
                        selected: {s.ui.messageStyle},
                        onSelectionChanged: (set) => controller.setUiPrefs(
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
                            ButtonSegment(value: v, label: Text(v.label)),
                        ],
                        selected: {s.ui.contentWidth},
                        onSelectionChanged: (set) => controller.setUiPrefs(
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
                      onChanged: (v) =>
                          controller.setUiPrefs(s.ui.copyWith(liveMarkdown: v)),
                    ),
                    const SizedBox(height: 32),
                    const _SectionTitle('联网搜索'),
                    DropdownButtonFormField<SearchBackend>(
                      initialValue: s.searchBackend,
                      decoration: const InputDecoration(labelText: '搜索服务'),
                      items: [
                        for (final b in SearchBackend.values)
                          DropdownMenuItem(value: b, child: Text(b.label)),
                      ],
                      onChanged: (v) =>
                          v == null ? null : controller.setSearchBackend(v),
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
                        suffixIcon: IconButton(
                          tooltip: _obscureSearch
                              ? '显示搜索 API Key'
                              : '隐藏搜索 API Key',
                          icon: Icon(
                            _obscureSearch
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () =>
                              setState(() => _obscureSearch = !_obscureSearch),
                        ),
                      ),
                      onChanged: controller.setSearchApiKey,
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

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = 'v${info.version} (${info.buildNumber})');
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
            subtitle: Text('当前版本 $_version'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查更新'),
            subtitle: const Text('从 GitHub Releases 获取最新安装包'),
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
