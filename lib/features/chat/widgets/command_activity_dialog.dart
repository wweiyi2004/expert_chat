import 'package:expert_chat/core/app_toast.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/models.dart';

/// Only unwrap formats produced by the command runner. Unrecognized output is
/// preserved verbatim; it must not acquire a fabricated exit code or stream.
class CommandActivityDetails {
  const CommandActivityDetails({
    this.command,
    this.exitCode,
    this.stdout,
    this.stderr,
    this.output,
    this.otherArguments,
    this.rawArguments,
  });
  final String? command, stdout, stderr, output, rawArguments;
  final Object? exitCode;
  final Map<String, dynamic>? otherArguments;

  factory CommandActivityDetails.fromActivity(SearchActivity activity) {
    String? command, rawArguments;
    Map<String, dynamic>? arguments;
    try {
      final decoded = jsonDecode(activity.toolArguments ?? '{}');
      if (decoded is Map<String, dynamic>) {
        arguments = Map.of(decoded);
        if (arguments['command'] is String) {
          command = arguments.remove('command') as String;
        }
      } else {
        rawArguments = activity.toolArguments;
      }
    } on FormatException {
      rawArguments = activity.toolArguments;
    }
    final result = activity.resultText;
    if (result == null) {
      return CommandActivityDetails(
        command: command,
        otherArguments: arguments,
        rawArguments: rawArguments,
      );
    }
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map<String, dynamic> &&
          (decoded['stdout'] is String ||
              decoded['stderr'] is String ||
              decoded['output'] is String)) {
        final exit = decoded['exit_code'] ?? decoded['exitCode'];
        return CommandActivityDetails(
          command: command,
          exitCode: exit is num || exit is String ? exit : null,
          stdout: decoded['stdout'] is String
              ? decoded['stdout'] as String
              : null,
          stderr: decoded['stderr'] is String
              ? decoded['stderr'] as String
              : null,
          output: decoded['output'] is String
              ? decoded['output'] as String
              : null,
          otherArguments: arguments,
          rawArguments: rawArguments,
        );
      }
    } on FormatException {
      /* Native and SSH runners return plain text. */
    }
    final header = RegExp(r'^退出码：([^\r\n]+)\r?\n').firstMatch(result);
    if (header != null) {
      final body = result.substring(header.end);
      final errorMarker = RegExp(r'\r?\n标准错误：\r?\n').firstMatch(body);
      return CommandActivityDetails(
        command: command,
        exitCode: header[1],
        stdout: errorMarker == null
            ? body
            : body.substring(0, errorMarker.start),
        stderr: errorMarker == null ? null : body.substring(errorMarker.end),
        otherArguments: arguments,
        rawArguments: rawArguments,
      );
    }
    return CommandActivityDetails(
      command: command,
      output: result,
      otherArguments: arguments,
      rawArguments: rawArguments,
    );
  }

  String get copyOutput => [?stdout, ?stderr, ?output].join('\n');
}

Future<void> showCommandActivityDialog(
  BuildContext context,
  SearchActivity activity, {
  required String title,
}) => showDialog<void>(
  context: context,
  builder: (_) => CommandActivityDialog(activity: activity, title: title),
);

class CommandActivityDialog extends StatefulWidget {
  const CommandActivityDialog({
    super.key,
    required this.activity,
    required this.title,
  });
  final SearchActivity activity;
  final String title;
  @override
  State<CommandActivityDialog> createState() => _CommandActivityDialogState();
}

class _CommandActivityDialogState extends State<CommandActivityDialog> {
  bool _wrap = false;
  Future<void> _copy(String text, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        AppToastMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('已复制$label')));
      }
    } catch (_) {
      if (mounted) {
        AppToastMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('复制失败，请选择文本复制')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = CommandActivityDetails.fromActivity(widget.activity);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final media = MediaQuery.of(context);
    final height = math.max(
      0.0,
      media.size.height - media.viewInsets.bottom - media.padding.vertical - 40,
    );
    final args =
        data.rawArguments ??
        (data.otherArguments?.isNotEmpty == true
            ? const JsonEncoder.withIndent('  ').convert(data.otherArguments)
            : null);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 820,
          maxHeight: math.min(680, height),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 20, color: colors.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭命令详情',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (data.exitCode != null)
                    Text(
                      '退出码 ${data.exitCode}',
                      style: theme.textTheme.labelMedium,
                    ),
                  if (widget.activity.startedAt != null &&
                      widget.activity.finishedAt != null)
                    Text(
                      '${(widget.activity.finishedAt!.difference(widget.activity.startedAt!).inMilliseconds / 1000).toStringAsFixed(1)} 秒',
                      style: theme.textTheme.labelSmall,
                    ),
                  FilterChip(
                    key: const ValueKey('command-wrap-toggle'),
                    selected: _wrap,
                    onSelected: (value) => setState(() => _wrap = value),
                    avatar: const Icon(Icons.wrap_text, size: 16),
                    label: const Text('自动换行'),
                    visualDensity: VisualDensity.compact,
                  ),
                  if (data.copyOutput.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _copy(data.copyOutput, '输出'),
                      icon: const Icon(Icons.copy_outlined, size: 15),
                      label: const Text('复制输出'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  if (data.command != null)
                    _section(
                      '命令',
                      data.command!,
                      'command',
                      copy: () => _copy(data.command!, '命令'),
                    ),
                  if (widget.activity.error?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SelectableText(
                        widget.activity.error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                  if (data.stdout != null)
                    _section('标准输出', data.stdout!, 'stdout'),
                  if (data.stderr != null)
                    _section('标准错误', data.stderr!, 'stderr'),
                  if (data.output != null)
                    _section('输出', data.output!, 'output'),
                  if (data.stdout == null &&
                      data.stderr == null &&
                      data.output == null)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('尚无命令输出'),
                    ),
                  if (args != null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        data.rawArguments == null ? '其他参数' : '原始参数',
                        style: theme.textTheme.labelMedium,
                      ),
                      children: [
                        _CommandCodeBlock(
                          text: args,
                          wrap: true,
                          blockKey: 'parameters',
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(
    String title,
    String text,
    String key, {
    VoidCallback? copy,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            if (copy != null)
              IconButton(
                tooltip: '复制$title',
                visualDensity: VisualDensity.compact,
                onPressed: copy,
                icon: const Icon(Icons.copy_outlined, size: 16),
              ),
          ],
        ),
        _CommandCodeBlock(text: text, wrap: _wrap, blockKey: key),
      ],
    ),
  );
}

class _CommandCodeBlock extends StatefulWidget {
  const _CommandCodeBlock({
    required this.text,
    required this.wrap,
    required this.blockKey,
  });
  final String text, blockKey;
  final bool wrap;
  @override
  State<_CommandCodeBlock> createState() => _CommandCodeBlockState();
}

class _CommandCodeBlockState extends State<_CommandCodeBlock> {
  final _horizontal = ScrollController(), _vertical = ScrollController();
  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Cascadia Mono', 'monospace'],
      fontSize: 12,
      height: 1.55,
      color: colors.onSurface,
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(9),
      ),
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          var width = constraints.maxWidth;
          if (!widget.wrap) {
            final painter = TextPainter(
              text: TextSpan(text: widget.text, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            width = math.max(width, painter.width + 2);
            painter.dispose();
          }
          final text = SizedBox(
            width: width,
            child: SelectableText(
              widget.text.isEmpty ? '（无输出）' : widget.text,
              key: ValueKey('command-detail-${widget.blockKey}'),
              style: style,
            ),
          );
          final vertical = ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height * .28).clamp(
                100.0,
                240.0,
              ),
            ),
            child: Scrollbar(
              controller: _vertical,
              child: SingleChildScrollView(controller: _vertical, child: text),
            ),
          );
          if (widget.wrap) return vertical;
          return Scrollbar(
            controller: _horizontal,
            thumbVisibility: width > constraints.maxWidth,
            notificationPredicate: (event) =>
                event.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 8),
              child: vertical,
            ),
          );
        },
      ),
    );
  }
}
