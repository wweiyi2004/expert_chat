import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../domain/chat/conversation_outline.dart';

/// Jump list for the current conversation: user turns and reply headings.
class ConversationOutlinePanel extends StatelessWidget {
  const ConversationOutlinePanel({
    super.key,
    required this.entries,
    required this.onJump,
    this.onClose,
    this.asSheet = false,
  });

  final List<ConversationOutlineEntry> entries;
  final ValueChanged<String> onJump;
  final VoidCallback? onClose;
  final bool asSheet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: asSheet
          ? scheme.surface
          : scheme.surfaceContainerLow.withValues(alpha: 0.92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Icon(
                  Icons.list_alt_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '大纲',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '点条目跳转到对应消息',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.85),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '还没有可跳转的条目。\n用户提问和回复里的标题会出现在这里。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final isUser = entry.role == MessageRole.user;
                      final indent = isUser ? 0.0 : 10.0 + (entry.depth - 1) * 12;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          child: InkWell(
                            key: ValueKey(
                              'outline-${entry.messageId}-$index',
                            ),
                            borderRadius: BorderRadius.circular(11),
                            onTap: () => onJump(entry.messageId),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                10 + indent,
                                8,
                                10,
                                8,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isUser
                                        ? Icons.chat_bubble_outline
                                        : Icons.tag,
                                    size: isUser ? 15 : 14,
                                    color: isUser
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      entry.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: isUser
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            height: 1.35,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
