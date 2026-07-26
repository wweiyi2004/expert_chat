import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/world_info_controller.dart';
import 'studio_page.dart';

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
  late final TextEditingController _outline;
  late final TextEditingController _authorNote;
  late final TextEditingController _venue;
  Set<String> _selectedWi = {};
  var _inited = false;
  String? _boundId;
  Timer? _debounce;
  String _status = '自动保存';

  @override
  void dispose() {
    _debounce?.cancel();
    if (_inited) {
      _flushSave();
      _outline.dispose();
      _authorNote.dispose();
      _venue.dispose();
    }
    super.dispose();
  }

  void _ensureControllers(Conversation convo) {
    if (_inited && _boundId == convo.id) return;
    if (_inited) {
      _outline.dispose();
      _authorNote.dispose();
      _venue.dispose();
    }
    _outline = TextEditingController(text: convo.outline);
    _authorNote = TextEditingController(text: convo.authorNote);
    _venue = TextEditingController(text: convo.venue);
    _selectedWi = convo.worldInfoIds.toSet();
    _outline.addListener(_scheduleSave);
    _authorNote.addListener(_scheduleSave);
    _venue.addListener(_scheduleSave);
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

  void _flushSave() {
    if (!_inited) return;
    ref
        .read(chatControllerProvider.notifier)
        .updateStoryMeta(
          conversationId: widget.conversationId,
          outline: _outline.text,
          authorNote: _authorNote.text,
          worldInfoIds: _selectedWi.toList(),
          venue: _venue.text,
        );
    // Meta is read when the next model turn starts — make that explicit.
    if (mounted) setState(() => _status = '已保存 · 下轮生效');
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
    await ref.read(characterCardsProvider.notifier).save(card);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('“${card.name}”已保存到角色库'),
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
                    onChanged: e.enabled ? (v) => _toggleWi(e.id, v) : null,
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
