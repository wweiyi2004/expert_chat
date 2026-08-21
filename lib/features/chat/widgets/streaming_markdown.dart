import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../domain/chat/markdown_blocks.dart';

/// Renders Markdown as frozen completed blocks plus a live last block.
///
/// [GptMarkdown] already skips re-parsing when its `data` string is unchanged.
/// Splitting the document makes that cache actually hit during streaming:
/// earlier headings, lists and closed fences keep the same string while only
/// the last open block is fed a growing tail.
class StreamingGptMarkdown extends StatelessWidget {
  const StreamingGptMarkdown(
    this.content, {
    super.key,
    this.style,
    this.onLinkTap,
    this.codeBuilder,
    this.sourceTagBuilder,
  });

  final String content;
  final TextStyle? style;
  final void Function(String url, String title)? onLinkTap;
  final Widget Function(BuildContext context, String name, String code, bool closed)?
      codeBuilder;
  final Widget Function(BuildContext context, String content, TextStyle textStyle)?
      sourceTagBuilder;

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownBlocks(content);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in blocks) RepaintBoundary(child: _markdown(block)),
      ],
    );
  }

  Widget _markdown(String data) {
    return GptMarkdown(
      data,
      style: style,
      useDollarSignsForLatex: true,
      onLinkTap: onLinkTap,
      codeBuilder: codeBuilder,
      sourceTagBuilder: sourceTagBuilder,
    );
  }
}
