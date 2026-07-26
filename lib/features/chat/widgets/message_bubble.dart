import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/models.dart';
import '../../../data/ui_prefs.dart';
import '../../../domain/html/html_snippet.dart';
import 'attachment_chip.dart';
import 'citations_bar.dart';
import 'html_preview_page.dart';
import 'previewable_code_block.dart';
import 'search_activity_panel.dart';
import 'thinking_panel.dart';

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  final scheme = uri?.scheme.toLowerCase();
  // Content and citations can be model-generated, so never hand arbitrary
  // schemes (file:, intent:, javascript:, ...) to the operating system.
  if (uri == null ||
      uri.host.isEmpty ||
      (scheme != 'https' && scheme != 'http')) {
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isStreaming,
    this.speakerName,
    this.userLabel,
    this.onRegenerate,
    this.onEdit,
    this.branchIndex = 0,
    this.branchCount = 1,
    this.onPrevBranch,
    this.onNextBranch,
    this.messageStyle = MessageStylePref.bubble,
    this.liveMarkdown = true,
    this.onSpeak,
    this.isSpeechLoading = false,
    this.isSpeaking = false,
  });

  final ChatMessage message;

  /// Whether THIS message is the one currently being streamed.
  final bool isStreaming;

  /// Optional label above assistant bubbles (e.g. character card name).
  final String? speakerName;

  /// Optional label above user messages in document mode (e.g. "导演").
  final String? userLabel;

  /// Assistant only: regenerate as a new branch.
  final VoidCallback? onRegenerate;

  /// User only: commit an edit (creates a new branch).
  final ValueChanged<String>? onEdit;

  /// 0-based position of this node among its sibling branches, and total count.
  final int branchIndex;
  final int branchCount;
  final VoidCallback? onPrevBranch;
  final VoidCallback? onNextBranch;

  final MessageStylePref messageStyle;
  final bool liveMarkdown;
  final Future<void> Function()? onSpeak;
  final bool isSpeechLoading;
  final bool isSpeaking;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _editing = false;
  late final TextEditingController _editCtrl = TextEditingController(
    text: widget.message.content,
  );

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

  Future<void> _copyMessage(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  bool get _document => widget.messageStyle == MessageStylePref.document;

  Widget _assistantMarkdown(ChatMessage m) {
    final useMarkdown = !widget.isStreaming || widget.liveMarkdown;
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        // Must set [color] explicitly. gpt_markdown caches parsed spans and only
        // rebuilds them when config changes; without a theme-tied style, LaTeX
        // (flutter_math) keeps the light-mode black glyphs after a theme switch.
        final baseStyle = Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(height: 1.65, color: scheme.onSurface);
        if (!useMarkdown) {
          return SelectableText(m.content, style: baseStyle);
        }
        return SelectionArea(
          // Key by brightness so the whole markdown tree is recreated on theme
          // change (covers any internal cache that ignores TextStyle equality).
          key: ValueKey(Theme.of(context).brightness),
          child: GptMarkdown(
            m.content,
            style: baseStyle,
            useDollarSignsForLatex: true,
            onLinkTap: (url, _) => _openUrl(url),
            codeBuilder: (context, name, code, closed) =>
                PreviewableCodeBlock(name: name, code: code, closed: closed),
            sourceTagBuilder: (context, content, style) {
              final n = int.tryParse(content.trim());
              final isCitation = m.citations.any((c) => c.index == n);
              if (!isCitation) {
                return Text('[$content]', style: style);
              }
              return _CitationBadge(number: content, citations: m.citations);
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = widget.message;
    final isUser = m.role == MessageRole.user;
    final doc = _document;

    if (isUser) {
      return Align(
        alignment: doc ? Alignment.centerLeft : Alignment.centerRight,
        child: Column(
          crossAxisAlignment: doc
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            if (m.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final a in m.attachments)
                      AttachmentChip(attachment: a),
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
                margin: EdgeInsets.symmetric(vertical: doc ? 8 : 6),
                padding: EdgeInsets.symmetric(
                  horizontal: doc ? 4 : 16,
                  vertical: doc ? 8 : 12,
                ),
                constraints: BoxConstraints(maxWidth: doc ? 900 : 560),
                width: doc ? double.infinity : null,
                decoration: doc
                    ? BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: scheme.primary.withValues(alpha: 0.45),
                            width: 3,
                          ),
                        ),
                      )
                    : BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primary,
                            Color.lerp(scheme.primary, scheme.secondary, 0.22)!,
                          ],
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(6),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.18),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (doc)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          widget.userLabel ?? '你',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    SelectableText(
                      m.content,
                      style: TextStyle(
                        color: doc ? scheme.onSurface : scheme.onPrimary,
                        height: 1.55,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_editing)
              Row(
                mainAxisAlignment: doc
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.end,
                children: [
                  _branchNav(scheme),
                  if (m.content.isNotEmpty)
                    IconButton(
                      iconSize: 16,
                      tooltip: '复制',
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => _copyMessage(m.content),
                    ),
                  if (widget.onEdit != null && !widget.isStreaming)
                    IconButton(
                      iconSize: 16,
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
    final showCursor = widget.isStreaming && m.content.isEmpty && !hasReasoning;
    final speaker = widget.speakerName?.trim();

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: doc ? 12 : 10),
        constraints: BoxConstraints(maxWidth: doc ? 900 : 760),
        width: doc ? double.infinity : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (speaker != null && speaker.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Text(
                    speaker,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            if (m.searchActivities.isNotEmpty)
              SearchActivityPanel(
                activities: m.searchActivities,
                isStreaming: widget.isStreaming,
              ),
            if (hasReasoning)
              ThinkingPanel(
                reasoning: m.reasoning,
                isStreaming: stillThinking,
                thinkingMillis: m.thinkingMillis,
              ),
            if (showCursor)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '正在书写…',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              if (m.attachments.any((a) => a.isImage && a.hasImageData))
                Padding(
                  padding: EdgeInsets.only(
                    top: hasReasoning ? 10 : 0,
                    bottom: m.content.isNotEmpty ? 10 : 0,
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final a in m.attachments)
                        if (a.isImage && a.hasImageData)
                          AttachmentImage(key: ValueKey(a.id), attachment: a),
                    ],
                  ),
                ),
              if (m.content.isNotEmpty)
                Container(
                  margin: EdgeInsets.only(top: hasReasoning ? 10 : 0),
                  padding: EdgeInsets.symmetric(
                    horizontal: doc ? 2 : 16,
                    vertical: doc ? 4 : 14,
                  ),
                  decoration: doc
                      ? null
                      : BoxDecoration(
                          color: scheme.surfaceContainer,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(6),
                            topRight: Radius.circular(20),
                            bottomLeft: Radius.circular(20),
                            bottomRight: Radius.circular(20),
                          ),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.95,
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.shadow.withValues(alpha: 0.05),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                  child: _assistantMarkdown(m),
                ),
            ],
            if (m.citations.isNotEmpty)
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
                      tooltip: '复制',
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => _copyMessage(m.content),
                    ),
                    if (messageHasHtmlPreview(m.content))
                      IconButton(
                        iconSize: 18,
                        tooltip: '预览网页',
                        color: scheme.primary,
                        icon: const Icon(Icons.visibility_outlined),
                        onPressed: () {
                          final snippets = extractHtmlSnippets(m.content);
                          HtmlPreviewPage.open(context, snippets: snippets);
                        },
                      ),
                    if (widget.onSpeak != null)
                      IconButton(
                        iconSize: 18,
                        tooltip: widget.isSpeaking ? '停止朗读' : '朗读',
                        color: widget.isSpeaking
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        icon: widget.isSpeechLoading
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                widget.isSpeaking
                                    ? Icons.stop_circle_outlined
                                    : Icons.volume_up_outlined,
                              ),
                        onPressed: widget.isSpeechLoading
                            ? null
                            : widget.onSpeak,
                      ),
                    if (widget.onRegenerate != null)
                      IconButton(
                        iconSize: 18,
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
          tooltip: '上一个回复',
          color: scheme.onSurfaceVariant,
          icon: const Icon(Icons.chevron_left),
          onPressed: widget.branchIndex > 0 ? widget.onPrevBranch : null,
        ),
        Text('${widget.branchIndex + 1}/${widget.branchCount}', style: style),
        IconButton(
          iconSize: 16,
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
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 8,
            decoration: const InputDecoration(isDense: true, filled: false),
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
    return Semantics(
      button: url != null,
      label: url == null ? '引用 $number' : '打开引用 $number',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: url == null ? null : () => _openUrl(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
