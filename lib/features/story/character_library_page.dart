import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../domain/story/story_ai_assist.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../shell/shell_tab.dart';
import 'ai_assist_widgets.dart';
import 'director_story_setup_page.dart';
import 'studio_asset_actions.dart';

class CharacterLibraryPage extends ConsumerWidget {
  const CharacterLibraryPage({super.key, this.pickForChat = false});

  /// When true, tapping a card starts a story chat and pops.
  final bool pickForChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pickForChat ? '选择角色开聊' : '角色库'),
        actions: [
          if (!pickForChat)
            PopupMenuButton<String>(
              tooltip: '导入 / 导出',
              onSelected: (v) async {
                if (v == 'import') {
                  await importCharactersAction(context, ref);
                } else if (v == 'export') {
                  await exportAllCharactersAction(context, ref);
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
        tooltip: '新建角色',
        onPressed: () => editCharacterCard(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('新建角色'),
      ),
      body: CharacterLibraryBody(pickForChat: pickForChat),
    );
  }
}

/// List body without Scaffold — embeddable in Studio tabs.
class CharacterLibraryBody extends ConsumerWidget {
  const CharacterLibraryBody({super.key, this.pickForChat = false});

  final bool pickForChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(characterCardsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (cards) {
        if (cards.isEmpty) {
          return _CharacterEmptyState(
            pickForChat: pickForChat,
            onCreate: () => editCharacterCard(context, ref, null),
            onImport: pickForChat
                ? null
                : () => importCharactersAction(context, ref),
            onDirector: pickForChat
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DirectorStorySetupPage(),
                      ),
                    );
                  },
          );
        }
        return ListView.separated(
          key: const ValueKey('character-library-list'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final card = cards[i];
            final scheme = Theme.of(context).colorScheme;
            final initial = card.name.isEmpty
                ? '?'
                : String.fromCharCode(card.name.runes.first);
            final summary = _characterSummary(card);
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                // Primary path: start a story chat with this card.
                onTap: () => startStoryChat(context, ref, card),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              scheme.primaryContainer,
                              Color.lerp(
                                scheme.primaryContainer,
                                scheme.secondaryContainer,
                                0.45,
                              )!,
                            ],
                          ),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(alpha: 0.8),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          initial,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              card.name.isEmpty ? '未命名角色' : card.name,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    height: 1.3,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.tonal(
                        onPressed: () => startStoryChat(context, ref, card),
                        child: const Text('开聊'),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await editCharacterCard(context, ref, card);
                          } else if (v == 'chat') {
                            await startStoryChat(context, ref, card);
                          } else if (v == 'export') {
                            await exportOneCharacterAction(context, ref, card);
                          } else if (v == 'delete') {
                            await deleteCharacterCard(context, ref, card);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'chat', child: Text('用此角色开聊')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'export', child: Text('导出 JSON')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
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

String _characterSummary(CharacterCard card) {
  for (final candidate in [
    card.description,
    card.personality,
    card.scenario,
    card.firstMes,
  ]) {
    final text = candidate.trim();
    if (text.isNotEmpty) return text;
  }
  return '暂无简介 · 点「开聊」开始故事';
}

class _CharacterEmptyState extends StatelessWidget {
  const _CharacterEmptyState({
    required this.pickForChat,
    required this.onCreate,
    this.onImport,
    this.onDirector,
  });

  final bool pickForChat;
  final VoidCallback onCreate;
  final VoidCallback? onImport;
  final VoidCallback? onDirector;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_add_alt_1_outlined,
              size: 48,
              color: scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              pickForChat ? '还没有可选的角色卡' : '还没有角色卡',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              pickForChat
                  ? '创建一张角色卡后即可开聊；也可以返回用「导演故事」免卡开写。'
                  : '三步新建、导入 JSON，或用「导演故事」免卡开写。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('创建第一个角色'),
            ),
            if (onImport != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.file_upload_outlined, size: 18),
                label: const Text('导入 JSON'),
              ),
            ],
            if (onDirector != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onDirector,
                icon: const Icon(Icons.auto_stories_outlined, size: 18),
                label: const Text('或直接开导演故事'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> startStoryChat(
  BuildContext context,
  WidgetRef ref,
  CharacterCard card,
) async {
  await ref.read(chatControllerProvider.notifier).newStoryConversation(card);
  if (!context.mounted) return;
  // Shell tabs use IndexedStack — also switch to 会话 so the new chat is visible.
  openShellTab(ref, 0);
  Navigator.of(context).popUntil((route) => route.isFirst);
}

Future<void> deleteCharacterCard(
  BuildContext context,
  WidgetRef ref,
  CharacterCard card,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除角色卡？'),
      content: Text('“${card.name}”将被删除，已绑定的故事会话不会自动删除。'),
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
    await ref.read(characterCardsProvider.notifier).delete(card.id);
  }
}

Future<void> editCharacterCard(
  BuildContext context,
  WidgetRef ref,
  CharacterCard? existing,
) async {
  final result = await Navigator.of(context).push<CharacterCard>(
    MaterialPageRoute(builder: (_) => CharacterEditPage(existing: existing)),
  );
  if (result != null) {
    await ref.read(characterCardsProvider.notifier).save(result);
  }
}

class CharacterEditPage extends ConsumerStatefulWidget {
  const CharacterEditPage({super.key, this.existing});
  final CharacterCard? existing;

  @override
  ConsumerState<CharacterEditPage> createState() => _CharacterEditPageState();
}

class _CharacterEditPageState extends ConsumerState<CharacterEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _personality;
  late final TextEditingController _scenario;
  late final TextEditingController _firstMes;
  late final TextEditingController _example;
  late final TextEditingController _system;

  bool _busy = false;
  String? _busyField;
  CancelToken? _cancel;

  /// Create flow: 0 名称 · 1 人设 · 2 开场白. Edit mode ignores steps.
  int _step = 0;
  bool _showAdvanced = false;

  bool get _isCreate => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    _personality = TextEditingController(text: e?.personality ?? '');
    _scenario = TextEditingController(text: e?.scenario ?? '');
    _firstMes = TextEditingController(text: e?.firstMes ?? '');
    _example = TextEditingController(text: e?.exampleDialogs ?? '');
    _system = TextEditingController(text: e?.systemPrompt ?? '');
    // Existing cards open fully expanded for editing.
    _showAdvanced = !_isCreate;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _name.dispose();
    _description.dispose();
    _personality.dispose();
    _scenario.dispose();
    _firstMes.dispose();
    _example.dispose();
    _system.dispose();
    super.dispose();
  }

  CharacterCardDraft _draftFromFields() => CharacterCardDraft(
    name: _name.text,
    description: _description.text,
    personality: _personality.text,
    scenario: _scenario.text,
    firstMes: _firstMes.text,
    exampleDialogs: _example.text,
    systemPrompt: _system.text,
  );

  void _applyDraft(CharacterCardDraft d) {
    void setIf(TextEditingController c, String v) {
      if (v.trim().isNotEmpty) c.text = v;
    }

    setIf(_name, d.name);
    setIf(_description, d.description);
    setIf(_personality, d.personality);
    setIf(_scenario, d.scenario);
    setIf(_firstMes, d.firstMes);
    setIf(_example, d.exampleDialogs);
    setIf(_system, d.systemPrompt);
  }

  Future<void> _generateAll() async {
    if (_busy) return;
    final ready = await requireLlmReady(ref, context);
    if (ready == null || !mounted) return;

    final idea = await showAiIdeaDialog(
      context,
      title: 'AI 生成角色卡',
      hint: '例如：冷淡的剑客少女，客栈相遇，说话简短带刀意',
      initial: _name.text.trim().isNotEmpty
          ? _name.text.trim()
          : _description.text.trim(),
    );
    if (idea == null || idea.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _busyField = 'all';
    });
    _cancel = CancelToken();
    try {
      final draft = await ready.assist.generateCharacter(
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

  Future<void> _polishField(
    String label,
    TextEditingController controller,
  ) async {
    if (_busy) return;
    final ready = await requireLlmReady(ref, context);
    if (ready == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyField = label;
    });
    _cancel = CancelToken();
    try {
      final polished = await ready.assist.polishText(
        config: ready.config,
        fieldLabel: label,
        text: controller.text,
        context: '角色名：${_name.text}\n简介：${_description.text}',
        cancelToken: _cancel,
      );
      if (!mounted) return;
      controller.text = polished;
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
    final base = widget.existing;
    final name = _name.text.trim().isEmpty ? '未命名角色' : _name.text.trim();
    final card = (base ?? CharacterCard(name: name)).copyWith(
      name: name,
      description: _description.text,
      personality: _personality.text,
      scenario: _scenario.text,
      firstMes: _firstMes.text,
      exampleDialogs: _example.text,
      systemPrompt: _system.text,
    );
    Navigator.of(context).pop(card);
  }

  bool _canAdvanceFrom(int step) {
    switch (step) {
      case 0:
        return _name.text.trim().isNotEmpty;
      case 1:
        return true; // personality optional
      default:
        return true;
    }
  }

  void _nextStep() {
    if (_step >= 2) {
      _save();
      return;
    }
    if (!_canAdvanceFrom(_step)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先填写角色名称'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _step += 1);
  }

  void _prevStep() {
    if (_step <= 0) return;
    setState(() => _step -= 1);
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    int minLines = 1,
    int maxLines = 1,
    String? helper,
    String? hint,
    bool polishable = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (polishable)
              AiAssistChip(
                label: '润色',
                busy: _busy && _busyField == label,
                onPressed: _busy ? null : () => _polishField(label, controller),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          minLines: minLines,
          maxLines: maxLines,
          decoration: InputDecoration(
            helperText: helper,
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _stepHeader(ColorScheme scheme) {
    const labels = ['名称', '人设', '开场白'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Container(
                    height: 2,
                    color: i <= _step
                        ? scheme.primary.withValues(alpha: 0.55)
                        : scheme.outlineVariant,
                  ),
                ),
              CircleAvatar(
                radius: 14,
                backgroundColor: i <= _step
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                foregroundColor: i <= _step
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '第 ${_step + 1}/3 步 · ${labels[_step]}（约 30 秒可开聊）',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  List<Widget> _wizardFields() {
    switch (_step) {
      case 0:
        return [
          _field(
            label: '名称 *',
            controller: _name,
            polishable: false,
            hint: '例如：林晚',
            helper: '角色在列表与故事中显示的名字',
          ),
        ];
      case 1:
        return [
          _field(
            label: '一句话人设',
            controller: _personality,
            minLines: 2,
            maxLines: 4,
            hint: '例如：冷淡的剑客，话少，护短',
            helper: '写入「性格与说话语气」；可稍后在高级字段补充外貌与场景',
          ),
        ];
      default:
        return [
          _field(
            label: '开场白（可选）',
            controller: _firstMes,
            minLines: 2,
            maxLines: 6,
            hint: '新故事开始时角色说的第一句话',
            helper: '可留空；保存后即可开聊',
          ),
        ];
    }
  }

  List<Widget> _advancedFields() => [
    _field(
      label: '简介 / 外貌',
      controller: _description,
      minLines: 2,
      maxLines: 5,
    ),
    _field(
      label: '性格与说话语气',
      controller: _personality,
      minLines: 2,
      maxLines: 5,
    ),
    _field(label: '场景', controller: _scenario, minLines: 2, maxLines: 4),
    _field(
      label: '开场白',
      controller: _firstMes,
      minLines: 2,
      maxLines: 6,
      helper: '新故事会话时作为角色的第一条消息',
    ),
    _field(
      label: '示例对话（可选）',
      controller: _example,
      minLines: 2,
      maxLines: 6,
    ),
    _field(
      label: '额外系统提示（可选）',
      controller: _system,
      minLines: 2,
      maxLines: 5,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isCreate ? '新建角色' : '编辑角色'),
        actions: [
          if (_busy)
            TextButton(
              onPressed: () => _cancel?.cancel(),
              child: const Text('取消生成'),
            ),
          if (!_isCreate || _step >= 2 || _showAdvanced)
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
                      _isCreate
                          ? '三步填完即可开聊；也可用 AI 一键生成完整角色卡。'
                          : '一句话描述角色，AI 可生成完整角色卡；各字段也可单独润色。',
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
          if (_isCreate && !_showAdvanced) ...[
            _stepHeader(scheme),
            ..._wizardFields(),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_step > 0)
                  TextButton(onPressed: _prevStep, child: const Text('上一步')),
                const Spacer(),
                FilledButton(
                  onPressed: _busy ? null : _nextStep,
                  child: Text(_step >= 2 ? '保存并完成' : '下一步'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = true),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('展开全部高级字段'),
            ),
          ] else ...[
            if (_isCreate)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _showAdvanced = false;
                    _step = 0;
                  }),
                  icon: const Icon(Icons.view_week_outlined, size: 18),
                  label: const Text('回到三步向导'),
                ),
              ),
            if (!_isCreate)
              _field(label: '名称', controller: _name, polishable: false),
            if (_isCreate && _showAdvanced)
              _field(label: '名称', controller: _name, polishable: false),
            ..._advancedFields(),
          ],
        ],
      ),
    );
  }
}
