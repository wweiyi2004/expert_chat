import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/ui_prefs.dart';
import '../../../domain/html/html_snippet.dart';
import 'html_preview_page.dart';

/// Code fence UI with optional HTML preview action.
class PreviewableCodeBlock extends StatefulWidget {
  const PreviewableCodeBlock({
    super.key,
    required this.name,
    required this.code,
    this.closed = true,
    this.markdownStyle = MarkdownStylePref.standard,
  });

  final String name;
  final String code;
  final bool closed;
  final MarkdownStylePref markdownStyle;

  @override
  State<PreviewableCodeBlock> createState() => _PreviewableCodeBlockState();
}

class _PreviewableCodeBlockState extends State<PreviewableCodeBlock> {
  var _copied = false;

  bool get _canPreview {
    final lang = widget.name.trim().toLowerCase();
    if (lang == 'html' ||
        lang == 'htm' ||
        lang == 'xhtml' ||
        lang.startsWith('html')) {
      return true;
    }
    if (lang.isNotEmpty) return false;
    // Untitled fences are previewable only when the raw body looks like HTML.
    return extractHtmlSnippets('```\n${widget.code}\n```').isNotEmpty;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  void _preview() {
    final lang = widget.name.trim().toLowerCase();
    final fenceLanguage =
        lang == 'html' ||
            lang == 'htm' ||
            lang == 'xhtml' ||
            lang.startsWith('html')
        ? 'html'
        : '';
    final snippets = extractHtmlSnippets(
      '```$fenceLanguage\n${widget.code}\n```',
    );
    if (snippets.isEmpty) return;
    HtmlPreviewPage.open(context, snippets: snippets);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.name.trim().isEmpty ? 'code' : widget.name.trim();
    final skin = widget.markdownStyle;
    final (Color fill, Color codeColor, double radius) = switch (skin) {
      MarkdownStylePref.standard => (
        scheme.onInverseSurface,
        scheme.onSurface,
        10.0,
      ),
      MarkdownStylePref.github => (
        scheme.surfaceContainerHigh,
        scheme.onSurface,
        8.0,
      ),
      MarkdownStylePref.notion => (
        scheme.surfaceContainerLow,
        scheme.onSurface,
        12.0,
      ),
      MarkdownStylePref.terminal => (
        scheme.inverseSurface,
        const Color(0xFF7EE787),
        4.0,
      ),
    };

    return Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_canPreview && widget.closed)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.primary,
                    ),
                    onPressed: _preview,
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: const Text('预览'),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.onSurface,
                  ),
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.done : Icons.content_paste,
                    size: 15,
                  ),
                  label: Text(_copied ? '已复制' : '复制'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: skin == MarkdownStylePref.terminal ? 12.5 : 13,
                height: 1.45,
                color: codeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
