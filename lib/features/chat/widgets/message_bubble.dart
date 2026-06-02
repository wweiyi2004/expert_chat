import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/models.dart';
import 'attachment_chip.dart';
import 'citations_bar.dart';
import 'thinking_panel.dart';

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isStreaming,
    this.onRegenerate,
    this.onEdit,
    this.branchIndex = 0,
    this.branchCount = 1,
    this.onPrevBranch,
    this.onNextBranch,
  });

  final ChatMessage message;

  /// Whether THIS message is the one currently being streamed.
  final bool isStreaming;

  /// Assistant only: regenerate as a new branch.
  final VoidCallback? onRegenerate;

  /// User only: commit an edit (creates a new branch).
  final ValueChanged<String>? onEdit;

  /// 0-based position of this node among its sibling branches, and total count.
  final int branchIndex;
  final int branchCount;
  final VoidCallback? onPrevBranch;
  final VoidCallback? onNextBranch;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _editing = false;
  late final TextEditingController _editCtrl =
      TextEditingController(text: widget.message.content);

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  void _startEdit() {
    _editCtrl.text = widget.message.content;
    setState(() => _editing = true);
  }

  void _commitEdit() {
    final text = _editCtrl.text.trim();
    setState(() => _editing = false);
    if (text.isNotEmpty && text != widget.message.content) {
      widget.onEdit?.call(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = widget.message;
    final isUser = m.role == MessageRole.user;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (m.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in m.attachments) AttachmentChip(attachment: a),
                  ],
                ),
              ),
            if (_editing)
              _EditBox(
                controller: _editCtrl,
                onCancel: () => setState(() => _editing = false),
                onSave: _commitEdit,
              )
            else if (m.content.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                constraints: const BoxConstraints(maxWidth: 560),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  m.content,
                  style:
                      TextStyle(color: scheme.onPrimaryContainer, height: 1.5),
                ),
              ),
            if (!_editing)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _branchNav(scheme),
                  if (widget.onEdit != null && !widget.isStreaming)
                    IconButton(
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      tooltip: '编辑',
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: _startEdit,
                    ),
                ],
              ),
          ],
        ),
      );
    }

    // Assistant message: optional thinking panel + markdown body + actions.
    final hasReasoning = m.reasoning.trim().isNotEmpty;
    final stillThinking = widget.isStreaming && m.content.isEmpty;
    final showCursor =
        widget.isStreaming && m.content.isEmpty && !hasReasoning;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasReasoning)
              ThinkingPanel(
                reasoning: m.reasoning,
                isStreaming: stillThinking,
                thinkingMillis: m.thinkingMillis,
              ),
            if (showCursor)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (m.content.isNotEmpty)
              SelectionArea(
                child: GptMarkdown(
                  m.content,
                  useDollarSignsForLatex: true,
                  onLinkTap: (url, _) => _openUrl(url),
                  // Always handle [n] ourselves: render a tappable badge only
                  // when it maps to a real citation, otherwise keep it as plain
                  // text (gpt_markdown's default would badge ANY [number]).
                  sourceTagBuilder: (context, content, style) {
                    final n = int.tryParse(content.trim());
                    final isCitation =
                        m.citations.any((c) => c.index == n);
                    if (!isCitation) {
                      return Text('[$content]', style: style);
                    }
                    return _CitationBadge(
                        number: content, citations: m.citations);
                  },
                ),
              ),
            if (m.citations.isNotEmpty && !widget.isStreaming)
              CitationsBar(
                citations: m.citations,
                onTap: (c) => _openUrl(c.url),
              ),
            if (!widget.isStreaming && m.content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    _branchNav(scheme),
                    IconButton(
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制',
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: m.content));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制'),
                              duration: Duration(seconds: 1),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                    ),
                    if (widget.onRegenerate != null)
                      IconButton(
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        tooltip: '重新生成（新分支）',
                        color: scheme.onSurfaceVariant,
                        icon: const Icon(Icons.refresh),
                        onPressed: widget.onRegenerate,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// ‹ i/n › branch switcher, shown only when this node has siblings.
  Widget _branchNav(ColorScheme scheme) {
    if (widget.branchCount <= 1) return const SizedBox.shrink();
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          tooltip: '上一个回复',
          color: scheme.onSurfaceVariant,
          icon: const Icon(Icons.chevron_left),
          onPressed: widget.branchIndex > 0 ? widget.onPrevBranch : null,
        ),
        Text('${widget.branchIndex + 1}/${widget.branchCount}', style: style),
        IconButton(
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          tooltip: '下一个回复',
          color: scheme.onSurfaceVariant,
          icon: const Icon(Icons.chevron_right),
          onPressed: widget.branchIndex < widget.branchCount - 1
              ? widget.onNextBranch
              : null,
        ),
      ],
    );
  }
}

/// Inline editor that replaces a user bubble while editing (non-occluding).
class _EditBox extends StatelessWidget {
  const _EditBox({
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  final TextEditingController controller;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 8,
            decoration: const InputDecoration(isDense: true),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(onPressed: onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                ),
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Inline tappable `[n]` badge rendered inside the markdown body.
class _CitationBadge extends StatelessWidget {
  const _CitationBadge({required this.number, required this.citations});

  final String number;
  final List<Citation> citations;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = int.tryParse(number.trim());
    final match = citations.where((c) => c.index == n);
    final url = match.isEmpty ? null : match.first.url;
    return GestureDetector(
      onTap: url == null ? null : () => _openUrl(url),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            number,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
