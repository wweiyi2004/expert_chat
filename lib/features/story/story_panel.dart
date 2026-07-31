import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../domain/story/story_length_budget.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/world_info_controller.dart';
import 'studio_page.dart';

/// Preserve structured setup constraints when the free-form editor is cleared.
///
/// Kept as a pure function so the accidental-wipe behavior can be regression
/// tested without pumping the full story panel.
String protectStoryAuthorNote({
  required String previous,
  required String edited,
}) {
  final prev = previous.trim();
  final next = edited.trim();
  if (prev.isEmpty) return edited;
  final protectedHeader = RegExp(r'【(?:硬性[^】]*|故事原始情节)】');
  if (!protectedHeader.hasMatch(prev)) return edited;
  if (next.isEmpty) return prev;
  if (!protectedHeader.hasMatch(next)) {
    return '$prev\n\n【情节面板补充】\n$next';
  }

  // An edit that keeps one protected header must not be allowed to
  // accidentally erase the other (for example keeping hard constraints while
  // deleting the original premise). Restore only the missing structured blocks
  // and leave explicitly edited blocks untouched.
  final missing = <String>[];
  final allHeaders = RegExp(r'【[^】]+】').allMatches(prev).toList();
  for (var i = 0; i < allHeaders.length; i++) {
    final match = allHeaders[i];
    final header = match.group(0)!;
    if (!protectedHeader.hasMatch(header) || next.contains(header)) continue;
    final end = i + 1 < allHeaders.length
        ? allHeaders[i + 1].start
        : prev.length;
    missing.add(prev.substring(match.start, end).trim());
  }
  if (missing.isEmpty) return edited;
  return '${missing.join('\n\n')}\n\n$next';
}

/// Bottom sheet host for story outline / author note / world-info picks.
Future<void> showStoryPanel(BuildContext context, Conversation convo) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.45,
        maxChildSize: 0.96,
        builder: (context, scrollController) {
          return StoryPanelBody(
            conversationId: convo.id,
            scrollController: scrollController,
            embedded: false,
          );
        },
      ),
    ),
  );
}

/// Story / ensemble tools — usable in a bottom sheet or a pinned side pane.
class StoryPanelBody extends ConsumerStatefulWidget {
  const StoryPanelBody({
    super.key,
    required this.conversationId,
    this.scrollController,
    this.embedded = false,
    this.onClose,
  });

  final String conversationId;
  final ScrollController? scrollController;

  /// When true, "管理世界书" does not try to pop a sheet first.
  final bool embedded;

  /// Optional close control for the side pane.
  final VoidCallback? onClose;

  @override
  ConsumerState<StoryPanelBody> createState() => _StoryPanelBodyState();
}

class _StoryPanelBodyState extends ConsumerState<StoryPanelBody> {
  // Not final: re-bound (disposed + recreated) when the panel switches to a
  // different conversation.
  late TextEditingController _outline;
  late TextEditingController _authorNote;
  late TextEditingController _venue;
  Set<String> _selectedWi = {};
  var _inited = false;
  String? _boundId;
  Timer? _debounce;
  String _status = '自动保存';

  /// Author note when the panel bound this conversation — used to protect hard
  /// constraint blocks from accidental wipe.
  String _baselineAuthorNote = '';

  /// Cached while the panel is alive: `ref` is unusable from [dispose], which
  /// still has to flush a pending debounced edit.
  ChatController? _chatNotifier;

  @override
  void dispose() {
    _debounce?.cancel();
    if (_inited) {
      // An edit may still sit inside the debounce window when the panel goes
      // away. Capture it now and write it back after the current frame: the
      // panel's own provider subscription is gone by then, so notifying the
      // chat controller mid-unmount cannot mark a defunct element dirty.
      final conversationId = widget.conversationId;
      final outline = _outline.text;
      final note = protectStoryAuthorNote(
        previous: _baselineAuthorNote,
        edited: _authorNote.text,
      );
      final venue = _venue.text;
      final wiIds = _selectedWi.toList();
      _deferredFlush(
        conversationId: conversationId,
        outline: outline,
        authorNote: note,
        venue: venue,
        worldInfoIds: wiIds,
      );
      _outline.dispose();
      _authorNote.dispose();
      _venue.dispose();
    }
    super.dispose();
  }

  /// Writes story meta after the current frame, used when the controllers are
  /// being torn down (session switch or panel close). A synchronous write
  /// would notify the chat provider while the panel is either mid-build or
  /// already unmounted — both illegal for its own listener.
  void _deferredFlush({
    required String conversationId,
    required String outline,
    required String authorNote,
    required String venue,
    required List<String> worldInfoIds,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _chatNotifier?.updateStoryMeta(
          conversationId: conversationId,
          outline: outline,
          authorNote: authorNote,
          worldInfoIds: worldInfoIds,
          venue: venue,
        );
      } on Object {
        // The whole tree — container included — may already be torn down
        // (app exit / test teardown); there is nothing left to notify.
      }
    });
  }

  void _ensureControllers(Conversation convo) {
    if (_inited && _boundId == convo.id) return;
    if (_inited) {
      // Cancel the pending debounce before anything else: its closure reads
      // the controllers, which are about to be disposed, and would write the
      // *new* session's text after the swap.
      _debounce?.cancel();
      // The old session may have an edit still sitting in the debounce
      // window. Flush it against the id these controllers are bound to —
      // during this rebuild `widget.conversationId` is already the new
      // session.
      _deferredFlush(
        conversationId: _boundId!,
        outline: _outline.text,
        authorNote: protectStoryAuthorNote(
          previous: _baselineAuthorNote,
          edited: _authorNote.text,
        ),
        venue: _venue.text,
        worldInfoIds: _selectedWi.toList(),
      );
      _status = '已保存 · 下轮生效';
      _outline.dispose();
      _authorNote.dispose();
      _venue.dispose();
    }
    _outline = TextEditingController(text: convo.outline);
    _authorNote = TextEditingController(text: convo.authorNote);
    _venue = TextEditingController(text: convo.venue);
    _baselineAuthorNote = convo.authorNote;
    _selectedWi = convo.worldInfoIds.toSet();
    _outline.addListener(_scheduleSave);
    _authorNote.addListener(_scheduleSave);
    _venue.addListener(_scheduleSave);
    _chatNotifier = ref.read(chatControllerProvider.notifier);
    _boundId = convo.id;
    _inited = true;
  }

  Conversation? _convo() {
    final state = ref.watch(chatControllerProvider).value;
    if (state == null) return null;
    for (final c in state.conversations) {
      if (c.id == widget.conversationId) return c;
    }
    return null;
  }

  void _scheduleSave() {
    _debounce?.cancel();
    if (mounted) setState(() => _status = '正在保存…');
    _debounce = Timer(const Duration(milliseconds: 450), _flushSave);
  }

  /// Persists the current controllers (debounce timer path).
  void _flushSave() {
    if (!_inited) return;
    final edited = _authorNote.text;
    final note = protectStoryAuthorNote(
      previous: _baselineAuthorNote,
      edited: edited,
    );
    final restored = note != edited;
    if (restored) {
      _authorNote.removeListener(_scheduleSave);
      _authorNote.value = TextEditingValue(
        text: note,
        selection: TextSelection.collapsed(offset: note.length),
      );
      _authorNote.addListener(_scheduleSave);
      _baselineAuthorNote = note;
    } else if (note.trim().contains('【硬性')) {
      _baselineAuthorNote = note;
    }
    _chatNotifier?.updateStoryMeta(
      conversationId: widget.conversationId,
      outline: _outline.text,
      authorNote: note,
      worldInfoIds: _selectedWi.toList(),
      venue: _venue.text,
    );
    // Meta is read when the next model turn starts — make that explicit.
    if (mounted) {
      setState(() {
        _status = restored ? '已保存 · 已保留硬性约束 · 下轮生效' : '已保存 · 下轮生效';
      });
    }
  }

  void _toggleWi(String id, bool? selected) {
    setState(() {
      if (selected == true) {
        _selectedWi.add(id);
      } else {
        _selectedWi.remove(id);
      }
    });
    _scheduleSave();
  }

  void _openWorldInfoManager() {
    if (!widget.embedded && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    Navigator.of(
      context,
      // Tab 2 = 世界书（0 开始 · 1 角色 · 2 世界书）
    ).push(MaterialPageRoute(builder: (_) => const StudioPage(initialTab: 2)));
  }

  Future<void> _saveLocalCharacter(CharacterCard card) async {
    // Re-saving under the same name must update the library row instead of
    // piling up infinite same-name duplicates. Await the load first — the
    // panel does not watch the library, so `.value` may still be null.
    final cards = await ref.read(characterCardsProvider.future);
    CharacterCard? existing;
    for (final c in cards) {
      if (c.name.trim() == card.name.trim()) {
        existing = c;
        break;
      }
    }
    final target = existing == null
        ? card
        : existing.copyWith(
            name: card.name,
            description: card.description,
            personality: card.personality,
            scenario: card.scenario,
            firstMes: card.firstMes,
            exampleDialogs: card.exampleDialogs,
            systemPrompt: card.systemPrompt,
          );
    await ref.read(characterCardsProvider.notifier).save(target);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          existing == null
              ? '“${card.name}”已保存到角色库'
              : '“${card.name}”已更新角色库中的同名卡片',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final convo = _convo();
    if (convo == null) {
      return const SizedBox(height: 200, child: Center(child: Text('会话不存在')));
    }
    _ensureControllers(convo);

    final wiAsync = ref.watch(worldInfoProvider);
    final beats = convo.outlineBeats;
    final scheme = Theme.of(context).colorScheme;
    final cursorLabel = beats.isEmpty
        ? '进度 ${convo.plotCursor}'
        : '进度 ${convo.plotCursor.clamp(0, beats.length)} / ${beats.length}';
    final currentBeat = beats.isEmpty
        ? '暂无大纲节拍（每行一条即可）'
        : convo.plotCursor < beats.length
        ? '当前：${beats[convo.plotCursor.clamp(0, beats.length - 1)]}'
        : '大纲已走完，可自由续写';

    final content = ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 16 : 20,
        widget.embedded ? 12 : 0,
        widget.embedded ? 16 : 20,
        28,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '情节设置',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text(
              _status,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: '收起',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          convo.localCast.isNotEmpty
              ? '大纲、导演指令与世界书修改会自动保存，并在下一轮生成时生效；点「继续下一节」按当前节拍演绎。'
              : '大纲、导演指令与世界书修改会自动保存，并在下一轮生成时生效；点「推进情节」按当前节拍续写。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.flag_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cursorLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '回退一拍',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .adjustPlotCursor(-1),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  IconButton(
                    tooltip: '前进一拍',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .adjustPlotCursor(1),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              Text(currentBeat, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (convo.isStory) ...[
          const SizedBox(height: 14),
          Text('小说总字数', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '0 表示不限。有目标时，下一轮生成会注入动态篇幅约束。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in StoryLengthBudget.presets)
                ChoiceChip(
                  label: Text(preset.label),
                  selected: convo.targetTotalChars == preset.chars,
                  onSelected: (_) {
                    ref
                        .read(chatControllerProvider.notifier)
                        .updateStoryMeta(
                          conversationId: widget.conversationId,
                          targetTotalChars: preset.chars,
                        );
                    setState(() => _status = '已保存 · 下轮生效');
                  },
                ),
            ],
          ),
          if (StoryLengthBudget.forConversation(convo) case final budget?) ...[
            const SizedBox(height: 8),
            Text(
              budget.sessionLabel(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
        const SizedBox(height: 18),
        if (convo.localCast.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '本故事角色卡',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                '${convo.localCast.length} 位 · AI 创建',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '这些角色只属于当前故事；需要复用时可单独保存到角色库。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (final card in convo.localCast)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                leading: CircleAvatar(
                  child: Text(
                    card.name.trim().isEmpty
                        ? '?'
                        : String.fromCharCode(card.name.runes.first),
                  ),
                ),
                title: Text(card.name),
                subtitle: card.description.trim().isEmpty
                    ? null
                    : Text(
                        card.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  if (card.personality.trim().isNotEmpty)
                    _CharacterDetail(label: '性格与动机', value: card.personality),
                  if (card.scenario.trim().isNotEmpty)
                    _CharacterDetail(label: '剧情定位', value: card.scenario),
                  if (card.systemPrompt.trim().isNotEmpty)
                    _CharacterDetail(label: '演绎约束', value: card.systemPrompt),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _saveLocalCharacter(card),
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: const Text('保存到角色库'),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
        ],
        Text('大纲', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _outline,
          minLines: 4,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: '每行一拍，例如：\n开端：客栈相遇\n冲突：身份暴露\n高潮：对决',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Text('导演指令', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _authorNote,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '节奏、禁忌、文风…（每次发送/推进都会注入）',
            border: OutlineInputBorder(),
          ),
        ),
        if (convo.isEnsemble) ...[
          const SizedBox(height: 16),
          Text('场地 / 情境', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _venue,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: '他们在哪里对峙 / 闲聊？',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                '本会话世界书',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton(
              onPressed: _openWorldInfoManager,
              child: const Text('管理世界书'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        wiAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('加载失败：$e'),
          data: (entries) {
            if (entries.isEmpty) {
              return Text(
                '世界书为空。可先在创作中心添加设定，再回到这里勾选。',
                style: Theme.of(context).textTheme.bodySmall,
              );
            }
            return Column(
              children: [
                for (final e in entries)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _selectedWi.contains(e.id),
                    title: Text(e.title.isEmpty ? '未命名' : e.title),
                    subtitle: Text(
                      [
                        if (!e.enabled) '库中已禁用',
                        if (e.alwaysOn) '常驻',
                        if (e.keys.isNotEmpty) e.keys.join('、'),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // A library-disabled entry may not be newly checked, but a
                    // session that already selected it must still be able to
                    // uncheck it — a permanently greyed checkbox would pin the
                    // stale opt-in forever.
                    onChanged: (e.enabled || _selectedWi.contains(e.id))
                        ? (v) => _toggleWi(e.id, v)
                        : null,
                  ),
              ],
            );
          },
        ),
      ],
    );

    if (!widget.embedded) return content;

    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.96),
      child: content,
    );
  }
}

class _CharacterDetail extends StatelessWidget {
  const _CharacterDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label：',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: value),
            ],
          ),
        ),
      ),
    );
  }
}
