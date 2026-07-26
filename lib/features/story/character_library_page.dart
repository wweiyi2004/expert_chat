import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../domain/story/story_ai_assist.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import 'ai_assist_widgets.dart';

class CharacterLibraryPage extends ConsumerWidget {
  const CharacterLibraryPage({super.key, this.pickForChat = false});

  /// When true, tapping a card starts a story chat and pops.
  final bool pickForChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(pickForChat ? '选择角色开聊' : '角色库')),
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
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.person_add_alt_1_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 12),
                const Text('还没有角色卡'),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => editCharacterCard(context, ref, null),
                  icon: const Icon(Icons.add),
                  label: const Text('创建第一个角色'),
                ),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final card = cards[i];
            final scheme = Theme.of(context).colorScheme;
            final initial = card.name.isEmpty
                ? '?'
                : String.fromCharCode(card.name.runes.first);
            return Card(
              child: ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
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
                title: Text(card.name),
                subtitle: Text(
                  card.description.isEmpty
                      ? (card.personality.isEmpty ? '无简介' : card.personality)
                      : card.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: pickForChat
                    ? FilledButton.tonal(
                        onPressed: () => startStoryChat(context, ref, card),
                        child: const Text('开聊'),
                      )
                    : PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await editCharacterCard(context, ref, card);
                          } else if (v == 'chat') {
                            await startStoryChat(context, ref, card);
                          } else if (v == 'delete') {
                            await deleteCharacterCard(context, ref, card);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'chat', child: Text('用此角色开聊')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                onTap: () async {
                  if (pickForChat) {
                    await startStoryChat(context, ref, card);
                  } else {
                    await editCharacterCard(context, ref, card);
                  }
                },
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> startStoryChat(
  BuildContext context,
  WidgetRef ref,
  CharacterCard card,
) async {
  await ref.read(chatControllerProvider.notifier).newStoryConversation(card);
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
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

  Widget _field({
    required String label,
    required TextEditingController controller,
    int minLines = 1,
    int maxLines = 1,
    String? helper,
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
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新建角色' : '编辑角色'),
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
                      '一句话描述角色，AI 可生成完整角色卡；各字段也可单独润色。',
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
          _field(label: '名称', controller: _name, polishable: false),
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
        ],
      ),
    );
  }
}
