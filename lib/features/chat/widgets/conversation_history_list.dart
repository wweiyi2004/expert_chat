import 'package:flutter/material.dart';
import 'conversation_execution_indicator.dart';
import 'sidebar_reorder_motion.dart';
import '../../../core/prototype_widgets.dart';

import '../../../core/mode_style.dart';
import '../../../data/conversation_repository.dart';
import '../../../data/models.dart';
import '../../../state/conversation_previews.dart';

/// History rows and inline rename UI; mutations are delegated to the owner.
class ConversationHistoryList extends StatelessWidget {
  const ConversationHistoryList({
    super.key,
    this.asSliver = false,
    this.shrinkWrap = false,
    this.prototypeRows = false,
    this.currentSessionActive = true,
    this.compactRows = false,
    this.mobileStyle = false,
    this.onStartSelection,
    this.previews = const {},
    this.selecting = false,
    this.selectedIds = const {},
    this.onToggleSelection,
    this.onArchive,
    this.archived = false,
    required this.visible,
    required this.currentId,
    required this.query,
    required this.searchHits,
    required this.renamingId,
    required this.renameController,
    required this.onCommitRename,
    required this.onRename,
    required this.onDelete,
    required this.onOpen,
  });

  final bool asSliver;
  final bool shrinkWrap;
  final bool prototypeRows;
  final bool currentSessionActive;
  final bool compactRows;
  final bool mobileStyle;
  final ValueChanged<Conversation>? onStartSelection;
  final Map<String, String> previews;
  final bool selecting, archived;
  final Set<String> selectedIds;
  final ValueChanged<Conversation>? onToggleSelection, onArchive;
  final List<Conversation> visible;
  final String? currentId;
  final String query;
  final List<SearchHit> searchHits;
  final String? renamingId;
  final TextEditingController renameController;
  final VoidCallback onCommitRename;
  final ValueChanged<Conversation> onRename;
  final ValueChanged<Conversation> onDelete;
  final void Function(Conversation, SearchHit) onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final limited =
        query.isNotEmpty && searchHits.length >= conversationSearchLimit;
    Widget rowContent(BuildContext context, int index) {
      if (limited && index == 0) {
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '已显示前 $conversationSearchLimit 条匹配消息，请细化关键词。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      final c = visible[index - (limited ? 1 : 0)];
      final modeColor = ModeStyle.color(c.mode);
      if (c.id == renamingId) {
        return Padding(
          key: ValueKey('conversation-row-${c.id}'),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            tileColor: scheme.surfaceContainer,
            leading: compactRows
                ? null
                : Icon(ModeStyle.icon(c.mode), color: modeColor),
            title: TextField(
              key: ValueKey('conversation-rename-${c.id}'),
              controller: renameController,
              autofocus: true,
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (_) => onCommitRename(),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.check, size: 20),
              tooltip: '保存',
              onPressed: onCommitRename,
            ),
          ),
        );
      }
      final selected = c.id == currentId;
      final hit = query.isEmpty
          ? const SearchHit(convoId: '', messageId: '', snippet: '')
          : searchHits.firstWhere(
              (h) => h.convoId == c.id,
              orElse: () =>
                  const SearchHit(convoId: '', messageId: '', snippet: ''),
            );
      final preview = hit.snippet.isNotEmpty
          ? hit.snippet
          : previews[c.id] ?? _conversationPreview(c);
      final rowWidget = Padding(
        key: ValueKey('conversation-row-${c.id}'),
        padding: EdgeInsets.symmetric(
          vertical: prototypeRows
              ? .5
              : mobileStyle
              ? 3
              : 4,
        ),
        child: Material(
          key: prototypeRows ? ValueKey('prototype-sidebar-row-${c.id}') : null,
          color: prototypeRows
              ? (selected
                    ? PrototypeColors.of(context).surface.withValues(
                        alpha: currentSessionActive ? 1 : .55,
                      )
                    : Colors.transparent)
              : mobileStyle
              ? (selected
                    ? scheme.primary.withValues(
                        alpha: currentSessionActive ? .16 : .06,
                      )
                    : Colors.transparent)
              : selected
              ? (compactRows
                    ? scheme.primaryContainer.withValues(alpha: .8)
                    : scheme.primaryContainer.withValues(alpha: 0.52))
              : scheme.surface.withValues(alpha: .42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(prototypeRows ? 8 : 11),
            side: prototypeRows || mobileStyle
                ? BorderSide.none
                : BorderSide(
                    color: selected
                        ? scheme.primary.withValues(alpha: .45)
                        : scheme.outlineVariant.withValues(alpha: .5),
                  ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(prototypeRows ? 8 : 11),
            onTap: () =>
                selecting ? onToggleSelection?.call(c) : onOpen(c, hit),
            onLongPress: onStartSelection == null
                ? null
                : () => onStartSelection!(c),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                prototypeRows ? 26 : 12,
                prototypeRows
                    ? (mobileStyle ? 0 : 6)
                    : mobileStyle
                    ? 12
                    : 8,
                prototypeRows ? 4 : 2,
                prototypeRows
                    ? (mobileStyle ? 0 : 6)
                    : mobileStyle
                    ? 12
                    : 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (selecting)
                    Checkbox(
                      value: selectedIds.contains(c.id),
                      onChanged: (_) => onToggleSelection?.call(c),
                    ),
                  if (!compactRows)
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: modeColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        ModeStyle.icon(c.mode),
                        size: 16,
                        color: modeColor,
                      ),
                    ),
                  if (!compactRows) const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontSize: prototypeRows ? 14 : null,
                                height: prototypeRows ? 1.4 : null,
                                fontWeight: selected
                                    ? (prototypeRows
                                          ? FontWeight.w500
                                          : FontWeight.w600)
                                    : compactRows
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                              ),
                        ),
                        if (preview.isNotEmpty &&
                            (!prototypeRows || query.isNotEmpty)) ...[
                          SizedBox(height: mobileStyle ? 5 : 3),
                          Text(
                            hit.snippet.isNotEmpty ? '匹配：$preview' : preview,
                            maxLines: mobileStyle
                                ? 1
                                : compactRows
                                ? 2
                                : 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: hit.snippet.isNotEmpty
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: hit.snippet.isNotEmpty
                                      ? FontWeight.w600
                                      : null,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ConversationExecutionIndicator(conversation: c),
                  PopupMenuButton<String>(
                    tooltip: '会话操作',
                    style: prototypeRows
                        ? ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(
                              Size(
                                mobileStyle ? 44 : 24,
                                mobileStyle ? 44 : 24,
                              ),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.zero,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          )
                        : null,
                    icon: Icon(
                      Icons.more_horiz,
                      size: prototypeRows ? 16 : 19,
                      color: prototypeRows
                          ? PrototypeColors.of(context).faint
                          : null,
                    ),
                    padding: EdgeInsets.zero,
                    onSelected: (v) {
                      if (v == 'preview') {
                        if (mobileStyle) {
                          showModalBottomSheet<void>(
                            context: context,
                            builder: (_) => SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      c.title,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    SelectableText(preview),
                                  ],
                                ),
                              ),
                            ),
                          );
                        } else {
                          showDialog<void>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              title: Text(c.title),
                              content: SelectableText(preview),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          );
                        }
                      }
                      if (v == 'rename') onRename(c);
                      if (v == 'delete') onDelete(c);
                      if (v == 'archive') onArchive?.call(c);
                    },
                    itemBuilder: (_) => [
                      if (prototypeRows)
                        const PopupMenuItem(
                          value: 'preview',
                          child: Text('预览最近消息'),
                        ),
                      if (onArchive != null)
                        PopupMenuItem(
                          value: 'archive',
                          child: Text(archived ? '取消归档' : '归档'),
                        ),
                      const PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          '删除',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return prototypeRows && !mobileStyle && query.isEmpty
          ? Tooltip(message: preview, child: rowWidget)
          : rowWidget;
    }

    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text('没有匹配的会话', style: Theme.of(context).textTheme.bodySmall),
    );
    Widget row(BuildContext context, int index) => SidebarReorderMotion(
      key: ValueKey(
        limited && index == 0
            ? 'search-limit'
            : 'motion-${visible[index - (limited ? 1 : 0)].id}',
      ),
      child: rowContent(context, index),
    );
    if (asSliver) {
      return visible.isEmpty
          ? SliverToBoxAdapter(child: empty)
          : SliverList.builder(
              itemCount: visible.length + (limited ? 1 : 0),
              itemBuilder: row,
            );
    }
    return visible.isEmpty
        ? Center(child: empty)
        : ListView(
            shrinkWrap: shrinkWrap,
            physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
            padding: prototypeRows
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(8, 8, 8, 16),
            children: [
              for (var i = 0; i < visible.length + (limited ? 1 : 0); i++)
                row(context, i),
            ],
          );
  }
}

String _conversationPreview(Conversation c) {
  final path = c.activePath;
  for (var i = path.length - 1; i >= 0; i--) {
    if (path[i].role != MessageRole.assistant) continue;
    final text = conversationExcerpt(path[i].content);
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '尚无完成的回复';
}
