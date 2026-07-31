import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../domain/story/story_ai_assist.dart';
import '../../state/world_info_controller.dart';
import 'ai_assist_widgets.dart';
import 'studio_asset_actions.dart';

class WorldInfoPage extends ConsumerWidget {
  const WorldInfoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('世界书'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '导入 / 导出',
            onSelected: (v) async {
              if (v == 'import') {
                await importWorldInfoAction(context, ref);
              } else if (v == 'export') {
                await exportAllWorldInfoAction(context, ref);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('导入 JSON')),
              PopupMenuItem(value: 'export', child: Text('导出全部 JSON')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: '新建条目',
        onPressed: () => editWorldInfoEntry(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('新建条目'),
      ),
      body: const WorldInfoBody(),
    );
  }
}

/// List body without Scaffold — embeddable in Studio tabs.
class WorldInfoBody extends ConsumerWidget {
  const WorldInfoBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(worldInfoProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (entries) {
        if (entries.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.public_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 12),
                const Text('还没有世界书条目'),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => editWorldInfoEntry(context, ref, null),
                  icon: const Icon(Icons.add),
                  label: const Text('创建第一条设定'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => importWorldInfoAction(context, ref),
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('导入 JSON'),
                ),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final e = entries[i];
            final scheme = Theme.of(context).colorScheme;
            return Card(
              child: ListTile(
                leading: Icon(
                  e.alwaysOn ? Icons.push_pin : Icons.auto_stories_outlined,
                  color: e.enabled ? scheme.primary : scheme.outline,
                ),
                title: Text(e.title.isEmpty ? '未命名条目' : e.title),
                subtitle: Text(
                  [
                    if (!e.enabled) '已禁用',
                    if (e.alwaysOn) '常驻',
                    if (e.keys.isNotEmpty) '关键词：${e.keys.join('、')}',
                    if (e.content.isNotEmpty) e.content,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await editWorldInfoEntry(context, ref, e);
                    } else if (v == 'export') {
                      await exportOneWorldInfoAction(context, ref, e);
                    } else if (v == 'delete') {
                      await deleteWorldInfoEntry(context, ref, e);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'export', child: Text('导出 JSON')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () => editWorldInfoEntry(context, ref, e),
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> deleteWorldInfoEntry(
  BuildContext context,
  WidgetRef ref,
  WorldInfoEntry entry,
) async {
  final title = entry.title.trim().isEmpty ? '未命名条目' : entry.title.trim();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除世界书条目？'),
      content: Text('“$title”将被删除，已注入到会话中的内容不会自动移除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await ref.read(worldInfoProvider.notifier).delete(entry.id);
  }
}

Future<void> editWorldInfoEntry(
  BuildContext context,
  WidgetRef ref,
  WorldInfoEntry? existing,
) async {
  final result = await Navigator.of(context).push<WorldInfoEntry>(
    MaterialPageRoute(builder: (_) => WorldInfoEditPage(existing: existing)),
  );
  if (result != null) {
    await ref.read(worldInfoProvider.notifier).save(result);
  }
}

class WorldInfoEditPage extends ConsumerStatefulWidget {
  const WorldInfoEditPage({super.key, this.existing});
  final WorldInfoEntry? existing;

  @override
  ConsumerState<WorldInfoEditPage> createState() => _WorldInfoEditPageState();
}

class _WorldInfoEditPageState extends ConsumerState<WorldInfoEditPage> {
  late final TextEditingController _title;
  late final TextEditingController _keys;
  late final TextEditingController _content;
  late final TextEditingController _priority;
  late bool _alwaysOn;
  late bool _enabled;

  bool _busy = false;
  String? _busyField;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _keys = TextEditingController(text: e?.keys.join(', ') ?? '');
    _content = TextEditingController(text: e?.content ?? '');
    _priority = TextEditingController(text: '${e?.priority ?? 0}');
    _alwaysOn = e?.alwaysOn ?? false;
    _enabled = e?.enabled ?? true;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _title.dispose();
    _keys.dispose();
    _content.dispose();
    _priority.dispose();
    super.dispose();
  }

  WorldInfoDraft _draftFromFields() => WorldInfoDraft(
    title: _title.text,
    keys: _keys.text
        .split(RegExp(r'[,，、]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    content: _content.text,
    alwaysOn: _alwaysOn,
    priority: int.tryParse(_priority.text.trim()) ?? 0,
  );

  void _applyDraft(WorldInfoDraft d) {
    if (d.title.trim().isNotEmpty) _title.text = d.title;
    if (d.keys.isNotEmpty) _keys.text = d.keys.join(', ');
    if (d.content.trim().isNotEmpty) _content.text = d.content;
    _alwaysOn = d.alwaysOn;
    _priority.text = '${d.priority}';
    setState(() {});
  }

  Future<void> _generateAll() async {
    if (_busy) return;
    final ready = await requireLlmReady(ref, context);
    if (ready == null || !mounted) return;

    final idea = await showAiIdeaDialog(
      context,
      title: 'AI 生成世界书',
      hint: '例如：北境魔法学院的禁忌书库，关键词要能被对话触发',
      initial: _title.text.trim().isNotEmpty
          ? _title.text.trim()
          : _content.text.trim(),
    );
    if (idea == null || idea.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _busyField = 'all';
    });
    _cancel = CancelToken();
    try {
      final draft = await ready.assist.generateWorldInfo(
        config: ready.config,
        idea: idea,
        seed: _draftFromFields(),
        cancelToken: _cancel,
      );
      if (!mounted) return;
      _applyDraft(draft);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已填入 AI 生成内容，可再改后保存'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      await showAiError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyField = null;
        });
      }
      _cancel = null;
    }
  }

  Future<void> _polishContent() async {
    if (_busy) return;
    final ready = await requireLlmReady(ref, context);
    if (ready == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyField = 'content';
    });
    _cancel = CancelToken();
    try {
      final polished = await ready.assist.polishText(
        config: ready.config,
        fieldLabel: '世界书设定正文',
        text: _content.text,
        context: '标题：${_title.text}\n关键词：${_keys.text}',
        cancelToken: _cancel,
      );
      if (!mounted) return;
      _content.text = polished;
    } catch (e) {
      await showAiError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyField = null;
        });
      }
      _cancel = null;
    }
  }

  void _save() {
    final keys = _keys.text
        .split(RegExp(r'[,，、]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final base = widget.existing;
    final entry =
        (base ??
                WorldInfoEntry(
                  title: _title.text.trim().isEmpty
                      ? '未命名条目'
                      : _title.text.trim(),
                ))
            .copyWith(
              title: _title.text.trim().isEmpty ? '未命名条目' : _title.text.trim(),
              keys: keys,
              content: _content.text,
              alwaysOn: _alwaysOn,
              enabled: _enabled,
              priority: int.tryParse(_priority.text.trim()) ?? 0,
            );
    Navigator.of(context).pop(entry);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新建世界书条目' : '编辑世界书条目'),
        actions: [
          if (_busy)
            TextButton(
              onPressed: () => _cancel?.cancel(),
              child: const Text('取消生成'),
            ),
          TextButton(onPressed: _busy ? null : _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Card(
            color: scheme.primaryContainer.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '描述设定概念，AI 生成标题、关键词与正文；正文也可单独润色。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _generateAll,
                    icon: _busy && _busyField == 'all'
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('AI 生成'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keys,
            decoration: const InputDecoration(
              labelText: '关键词（逗号分隔）',
              helperText: '对话中出现关键词时注入；常驻条目忽略关键词',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '设定内容',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              AiAssistChip(
                label: '润色',
                busy: _busy && _busyField == 'content',
                onPressed: _busy ? null : _polishContent,
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _content,
            minLines: 5,
            maxLines: 14,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _priority,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '优先级（越大越靠前）',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('常驻注入'),
            subtitle: const Text('只要本会话勾选了此条目就会注入'),
            value: _alwaysOn,
            onChanged: (v) => setState(() => _alwaysOn = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      ),
    );
  }
}
