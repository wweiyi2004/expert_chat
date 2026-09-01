import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../data/ui_prefs.dart';
import '../../../domain/chat/markdown_blocks.dart';

/// Renders Markdown as frozen completed blocks plus a live last block.
///
/// [GptMarkdown] already skips re-parsing when its `data` string is unchanged.
/// Splitting the document makes that cache actually hit during streaming:
/// earlier headings, lists and closed fences keep the same string while only
/// the last open block is fed a growing tail.
class StreamingGptMarkdown extends StatefulWidget {
  const StreamingGptMarkdown(
    this.content, {
    super.key,
    this.isFinal = true,
    this.style,
    this.markdownStyle = MarkdownStylePref.standard,
    this.onLinkTap,
    this.codeBuilder,
    this.sourceTagBuilder,
  });

  final String content;
  final bool isFinal;
  final TextStyle? style;
  final MarkdownStylePref markdownStyle;
  final void Function(String url, String title)? onLinkTap;
  final Widget Function(
    BuildContext context,
    String name,
    String code,
    bool closed,
  )?
  codeBuilder;
  final Widget Function(
    BuildContext context,
    String content,
    TextStyle textStyle,
  )?
  sourceTagBuilder;

  @override
  State<StreamingGptMarkdown> createState() => _StreamingGptMarkdownState();
}

class _StreamingGptMarkdownState extends State<StreamingGptMarkdown> {
  late final StreamingMarkdownDocument _document;

  @override
  void initState() {
    super.initState();
    _document = StreamingMarkdownDocument()
      ..updateSnapshot(widget.content, isFinal: widget.isFinal);
  }

  @override
  void didUpdateWidget(covariant StreamingGptMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.content, widget.content) &&
        oldWidget.isFinal == widget.isFinal) {
      return;
    }

    final assumeAppendOnly =
        !oldWidget.isFinal &&
        _looksLikeStreamAppend(oldWidget.content, widget.content);
    if (assumeAppendOnly ||
        oldWidget.content != widget.content ||
        oldWidget.isFinal != widget.isFinal) {
      _document.updateSnapshot(
        widget.content,
        isFinal: widget.isFinal,
        // The active assistant message is append-only. Check two short guards
        // around the old snapshot instead of comparing an ever-growing prefix
        // on every frame; replacement content still takes the reset path.
        assumeAppendOnly: assumeAppendOnly,
      );
    }
  }

  bool _looksLikeStreamAppend(String before, String after) {
    if (before.isEmpty) return true;
    if (after.length < before.length) return false;
    const guardLength = 64;
    final headLength = before.length < guardLength
        ? before.length
        : guardLength;
    final tailStart = before.length > guardLength
        ? before.length - guardLength
        : 0;
    return after.startsWith(before.substring(0, headLength)) &&
        after.startsWith(before.substring(tailStart), tailStart);
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _document.blocks;
    if (blocks.isEmpty) return const SizedBox.shrink();

    return GptMarkdownTheme(
      gptThemeData: widget.markdownStyle.themeData(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final block in blocks)
            RepaintBoundary(
              key: ValueKey(block.id),
              child: _markdown(context, block.source),
            ),
        ],
      ),
    );
  }

  Widget _markdown(BuildContext context, String data) {
    return GptMarkdown(
      data,
      style: widget.style ?? widget.markdownStyle.bodyStyle(context),
      useDollarSignsForLatex: true,
      onLinkTap: widget.onLinkTap,
      codeBuilder: widget.codeBuilder,
      sourceTagBuilder: widget.sourceTagBuilder,
      highlightBuilder: widget.markdownStyle.highlightBuilder,
      tableBuilder: widget.markdownStyle.tableBuilder,
    );
  }
}

extension MarkdownStylePrefTheme on MarkdownStylePref {
  TextStyle? bodyStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return switch (this) {
      MarkdownStylePref.standard => text.bodyLarge?.copyWith(
        height: 1.65,
        color: scheme.onSurface,
      ),
      MarkdownStylePref.github => text.bodyLarge?.copyWith(
        height: 1.7,
        color: scheme.onSurface,
      ),
      MarkdownStylePref.notion => text.bodyLarge?.copyWith(
        height: 1.75,
        color: scheme.onSurface,
      ),
      MarkdownStylePref.terminal => text.bodyMedium?.copyWith(
        height: 1.5,
        fontFamily: 'monospace',
        color: scheme.onSurface,
      ),
    };
  }

  GptMarkdownThemeData themeData(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final onSurface = scheme.onSurface;
    return switch (this) {
      MarkdownStylePref.standard => GptMarkdownThemeData(
        brightness: theme.brightness,
        h1: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
        h2: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
        h3: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        highlightColor: scheme.onSurfaceVariant.withValues(alpha: 0.18),
        linkColor: scheme.primary,
        linkHoverColor: scheme.tertiary,
        hrLineColor: scheme.outlineVariant,
        autoAddDividerLineAfterH1: true,
      ),
      MarkdownStylePref.github => GptMarkdownThemeData(
        brightness: theme.brightness,
        h1: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
        h2: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        h3: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        highlightColor: scheme.surfaceContainerHighest,
        linkColor: theme.brightness == Brightness.dark
            ? const Color(0xFF58A6FF)
            : const Color(0xFF0969DA),
        linkHoverColor: scheme.primary,
        hrLineColor: scheme.outlineVariant,
        hrLinePadding: const EdgeInsets.only(top: 4, bottom: 8),
        autoAddDividerLineAfterH1: true,
      ),
      MarkdownStylePref.notion => GptMarkdownThemeData(
        brightness: theme.brightness,
        h1: text.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.2,
          color: onSurface,
        ),
        h2: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        h3: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        highlightColor: const Color(0x22EB5757),
        linkColor: scheme.primary,
        linkHoverColor: scheme.tertiary,
        hrLineColor: scheme.outlineVariant,
        autoAddDividerLineAfterH1: false,
      ),
      MarkdownStylePref.terminal => GptMarkdownThemeData(
        brightness: theme.brightness,
        h1: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          color: scheme.primary,
        ),
        h2: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
          color: onSurface,
        ),
        h3: text.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
          color: onSurface,
        ),
        highlightColor: scheme.inverseSurface,
        linkColor: const Color(0xFF7EE787),
        linkHoverColor: const Color(0xFF3FB950),
        hrLineColor: scheme.outline,
        hrLineThickness: 0.6,
        autoAddDividerLineAfterH1: false,
      ),
    };
  }

  Widget highlightBuilder(BuildContext context, String text, TextStyle style) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg, double radius) = switch (this) {
      MarkdownStylePref.standard => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        4.0,
      ),
      MarkdownStylePref.github => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        6.0,
      ),
      MarkdownStylePref.notion => (
        const Color(0x22EB5757),
        const Color(0xFFEB5757),
        4.0,
      ),
      MarkdownStylePref.terminal => (
        scheme.inverseSurface,
        const Color(0xFF7EE787),
        2.0,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        text,
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 14) * 0.92,
          fontWeight: FontWeight.w500,
          color: fg,
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }

  Widget tableBuilder(
    BuildContext context,
    List<CustomTableRow> rows,
    TextStyle textStyle,
    GptMarkdownConfig config,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final headerBg = switch (this) {
      MarkdownStylePref.standard => scheme.surfaceContainerHighest,
      MarkdownStylePref.github => scheme.surfaceContainerHigh,
      MarkdownStylePref.notion => scheme.surfaceContainerLow,
      MarkdownStylePref.terminal => scheme.inverseSurface,
    };
    final borderColor = switch (this) {
      MarkdownStylePref.notion => scheme.outlineVariant.withValues(alpha: 0.5),
      MarkdownStylePref.terminal => scheme.outline,
      _ => scheme.outlineVariant,
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder.all(width: 1, color: borderColor),
        children: [
          for (final row in rows)
            TableRow(
              decoration: row.isHeader ? BoxDecoration(color: headerBg) : null,
              children: [
                for (final field in row.fields)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      field.data,
                      textAlign: field.alignment,
                      style: textStyle.copyWith(
                        fontWeight: row.isHeader
                            ? FontWeight.w700
                            : FontWeight.w400,
                        fontFamily: this == MarkdownStylePref.terminal
                            ? 'monospace'
                            : textStyle.fontFamily,
                        color:
                            this == MarkdownStylePref.terminal && row.isHeader
                            ? const Color(0xFF7EE787)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
