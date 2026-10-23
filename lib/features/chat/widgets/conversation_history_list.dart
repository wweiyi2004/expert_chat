import 'package:flutter/material.dart';
import 'conversation_execution_indicator.dart';

import '../../../core/mode_style.dart';
import '../../../data/conversation_repository.dart';
import '../../../data/models.dart';
import '../../../state/conversation_previews.dart';

/// History rows and inline rename UI; mutations are delegated to the owner.
class ConversationHistoryList extends StatelessWidget {
  const ConversationHistoryList({
    super.key,
    this.asSliver = false,
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
    Widget row(BuildContext context, int index) {
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
      return Padding(
        key: ValueKey('conversation-row-${c.id}'),
        padding: EdgeInsets.symmetric(vertical: mobileStyle ? 3 : 4),
        child: Material(
          color: mobileStyle
              ? (selected
                    ? scheme.primary.withValues(alpha: .1)
                    : Colors.transparent)
              : selected
              ? (compactRows
                    ? scheme.primaryContainer.withValues(alpha: .8)
                    : scheme.primaryContainer.withValues(alpha: 0.52))
              : scheme.surface.withValues(alpha: .42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: mobileStyle
                ? BorderSide.none
                : BorderSide(
                    color: selected
                        ? scheme.primary.withValues(alpha: .45)
                        : scheme.outlineVariant.withValues(alpha: .5),
                  ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () =>
                selecting ? onToggleSelection?.call(c) : onOpen(c, hit),
            onLongPress: onStartSelection == null
                ? null
                : () => onStartSelection!(c),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                mobileStyle ? 12 : 8,
                2,
                mobileStyle ? 12 : 8,
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
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : compactRows
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                              ),
                        ),
                        if (preview.isNotEmpty) ...[
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
                    icon: const Icon(Icons.more_horiz, size: 19),
                    padding: EdgeInsets.zero,
                    onSelected: (v) {
                      if (v == 'rename') onRename(c);
                      if (v == 'delete') onDelete(c);
                      if (v == 'archive') onArchive?.call(c);
                    },
                    itemBuilder: (_) => [
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
    }

    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text('没有匹配的会话', style: Theme.of(context).textTheme.bodySmall),
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
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            itemCount: visible.length + (limited ? 1 : 0),
            itemBuilder: row,
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
