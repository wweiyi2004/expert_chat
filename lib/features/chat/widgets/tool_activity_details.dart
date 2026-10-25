import 'dart:convert';
import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/models.dart';

Object? _decode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

Future<void> showToolActivityDetails(
  BuildContext context,
  SearchActivity activity, {
  required String title,
}) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (activity.toolName != null)
              SelectableText(
                activity.toolName!,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            if (activity.toolArguments case final raw?)
              _DetailSection(title: '参数', raw: raw),
            if (activity.error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (activity.resultText case final raw?)
              _DetailSection(
                title: '结果',
                raw: raw,
                directory: activity.toolName == 'coding_list_directory',
              ),
            if (activity.toolArguments == null &&
                activity.resultText == null &&
                activity.error == null)
              const Text('此步骤尚未返回结果'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialog),
        child: const Text('关闭'),
      ),
    ],
  ),
);

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.raw,
    this.directory = false,
  });
  final String title, raw;
  final bool directory;
  @override
  Widget build(BuildContext context) {
    final decoded = _decode(raw);
    final pretty = decoded == null
        ? raw
        : const JsonEncoder.withIndent('  ').convert(decoded);
    final entries = decoded is Map
        ? (decoded['entries'] ?? decoded['items'] ?? decoded['files'])
        : decoded;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  try {
                    await Clipboard.setData(ClipboardData(text: raw));
                    if (context.mounted) {
                      AppToastMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已复制原始数据')));
                    }
                  } catch (_) {
                    if (context.mounted) {
                      AppToastMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('复制失败，请选择文本复制')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('复制原始数据'),
              ),
            ],
          ),
          if (directory && entries is List)
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      entry is Map &&
                              (entry['kind'] == 'directory' ||
                                  entry['type'] == 'directory' ||
                                  entry['isDirectory'] == true)
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        entry is Map
                            ? '${entry['name'] ?? entry['path'] ?? entry}'
                            : '$entry',
                      ),
                    ),
                    if (entry is Map && entry['access'] != null)
                      Text(
                        '${entry['access']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (entry is Map && entry['size'] != null)
                      Text(
                        '${entry['size']} B',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          if (directory && entries is List) ...[
            if (entries.isEmpty) const Text('此目录为空'),
            if (decoded is Map && decoded['truncated'] == true)
              const Text('结果有截断，可继续查看子目录。'),
            ExpansionTile(
              title: const Text('JSON 详情'),
              tilePadding: EdgeInsets.zero,
              children: [_JsonText(text: pretty, structured: decoded != null)],
            ),
          ] else
            _JsonText(text: pretty, structured: decoded != null),
        ],
      ),
    );
  }
}

class _JsonText extends StatelessWidget {
  const _JsonText({required this.text, required this.structured});
  final String text;
  final bool structured;
  static final _tokens = RegExp(
    r'"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?',
  );
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final spans = <TextSpan>[];
    var offset = 0;
    if (structured) {
      for (final match in _tokens.allMatches(text)) {
        if (match.start > offset) {
          spans.add(TextSpan(text: text.substring(offset, match.start)));
        }
        final token = match.group(0)!;
        var next = match.end;
        while (next < text.length && text.codeUnitAt(next) <= 32) {
          next++;
        }
        final key =
            token.startsWith('"') && next < text.length && text[next] == ':';
        spans.add(
          TextSpan(
            text: token,
            style: TextStyle(
              color: key
                  ? colors.primary
                  : token.startsWith('"')
                  ? colors.tertiary
                  : colors.secondary,
            ),
          ),
        );
        offset = match.end;
      }
    }
    if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
    return Align(
      alignment: Alignment.centerLeft,
      child: SelectableText.rich(
        TextSpan(children: spans),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.6,
          color: colors.onSurface,
        ),
      ),
    );
  }
}
