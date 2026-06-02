import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/provider_profile.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/tools/search_provider.dart';
import '../../state/settings_controller.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

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
      appBar: AppBar(title: const Text('设置')),
      body: asyncSettings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (s) {
          final active = s.active;
          // Keep the key field in sync when the active profile changes.
          if (_syncedForProfile != active?.id) {
            _apiKey.text = s.apiKey;
            _syncedForProfile = active?.id;
          }
          if (!_searchKeySynced) {
            _searchKey.text = s.searchApiKey;
            _searchKeySynced = true;
          }
          if (!_systemPromptSynced) {
            _systemPrompt.text = s.systemPrompt;
            _systemPromptSynced = true;
          }
          return ListView(
            padding: const EdgeInsets.all(20),
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
                    : () => controller.deleteProfile(active.id),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKey,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                  helperText: active == null
                      ? null
                      : '用于 ${active.name}（${active.baseUrl}）',
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
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
                      child: Text(m +
                          (KnownModels.isReasoner(m) ? '（深度思考）' : '')),
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
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode)),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode)),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (set) =>
                    controller.apply(themeMode: set.first),
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
                decoration: InputDecoration(
                  labelText: '搜索 API Key',
                  helperText: '在输入框上方开启"联网"后生效；留空则不联网。',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureSearch
                        ? Icons.visibility
                        : Icons.visibility_off),
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
            ],
          );
        },
      ),
    );
  }

  Future<void> _editProfile(
      BuildContext context, ProviderProfile? existing) async {
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
                final preset = ProviderPreset.presets
                    .firstWhere((p) => p.name == value);
                onAddPreset(preset);
            }
          },
          itemBuilder: (context) => [
            if (onEdit != null)
              const PopupMenuItem(value: 'edit', child: Text('编辑当前服务商')),
            if (onDelete != null)
              const PopupMenuItem(value: 'delete', child: Text('删除当前服务商')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'custom', child: Text('+ 自定义服务商')),
            for (final preset in ProviderPreset.presets)
              PopupMenuItem(
                  value: preset.name, child: Text('+ ${preset.name} 预设')),
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
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
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
            decoration: const InputDecoration(
                labelText: 'Base URL', hintText: 'https://api.example.com/v1'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _models,
            decoration: const InputDecoration(
                labelText: '模型列表（逗号分隔）', hintText: 'model-a, model-b'),
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
                labelText: '深度思考模型', hintText: '没有则与对话模型相同'),
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
    final profile = (base ??
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      );
}
