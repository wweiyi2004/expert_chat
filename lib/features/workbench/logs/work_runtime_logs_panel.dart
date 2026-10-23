import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/work_runtime_logs.dart';

/// A snapshot export uses the same sanitized entries that are visible in the UI.
String formatWorkRuntimeLogs(Iterable<WorkRuntimeLogEntry> entries) =>
    entries.map((entry) => jsonEncode(entry.toJson())).join('\n');

class WorkRuntimeLogsPanel extends ConsumerStatefulWidget {
  const WorkRuntimeLogsPanel({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<WorkRuntimeLogsPanel> createState() =>
      _WorkRuntimeLogsPanelState();
}

class _WorkRuntimeLogsPanelState extends ConsumerState<WorkRuntimeLogsPanel> {
  final _scroll = ScrollController();
  final _expanded = <String>{};
  bool _errorsOnly = false,
      _follow = true,
      _followScheduled = false,
      _exporting = false;
  String? _lastEntryId;

  @override
  void didUpdateWidget(WorkRuntimeLogsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _expanded.clear();
      _lastEntryId = null;
      _follow = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _followLatest() {
    if (!_follow || _followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_follow || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _copy(List<WorkRuntimeLogEntry> entries) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: formatWorkRuntimeLogs(entries)),
      );
      _notice('已复制 ${entries.length} 条日志');
    } catch (_) {
      _notice('复制失败，请使用导出日志');
    }
  }

  Future<void> _export(List<WorkRuntimeLogEntry> entries) async {
    if (_exporting) return;
    // Freeze the selection before opening a platform dialog; incoming entries
    // and a session change must not silently alter the exported file.
    final bytes = Uint8List.fromList(
      utf8.encode(formatWorkRuntimeLogs(entries)),
    );
    final id = widget.conversationId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final name =
        'expert-chat-${_errorsOnly ? 'errors' : 'work'}-$id-$stamp.jsonl';
    setState(() => _exporting = true);
    try {
      final mobile =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final path = await FilePicker.saveFile(
        dialogTitle: '导出工作日志',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['jsonl'],
        bytes: kIsWeb || mobile ? bytes : null,
      );
      if (kIsWeb) {
        _notice('已开始下载日志');
      } else if (path != null) {
        if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
        _notice('已导出 ${entries.length} 条日志');
      }
    } catch (error) {
      // Do not echo platform errors which may contain private filesystem data.
      _notice('日志导出失败，请检查保存位置后重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref
        .watch(workRuntimeLogsProvider)
        .where((entry) => entry.conversationId == widget.conversationId)
        .toList();
    final errors = all
        .where((entry) => entry.level == WorkRuntimeLogLevel.error)
        .length;
    final entries = _errorsOnly
        ? all
              .where((entry) => entry.level == WorkRuntimeLogLevel.error)
              .toList()
        : all;
    final lastId = entries.lastOrNull?.id;
    if (_lastEntryId != lastId) {
      _lastEntryId = lastId;
      _followLatest();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      key: const ValueKey('work-runtime-logs-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  ButtonSegment(value: false, label: Text('全部 ${all.length}')),
                  ButtonSegment(value: true, label: Text('错误 $errors')),
                ],
                selected: {_errorsOnly},
                onSelectionChanged: (selection) {
                  setState(() {
                    _errorsOnly = selection.first;
                    _follow = true;
                    _lastEntryId = null;
                  });
                },
              ),
              IconButton(
                tooltip: '复制当前日志',
                onPressed: entries.isEmpty
                    ? null
                    : () => _copy(List.of(entries)),
                icon: const Icon(Icons.copy_outlined, size: 18),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '导出当前日志',
                onPressed: entries.isEmpty || _exporting
                    ? null
                    : () => _export(List.of(entries)),
                icon: _exporting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 18),
                visualDensity: VisualDensity.compact,
              ),
              Tooltip(
                message: _follow ? '新日志到达时跟随到底部；向上滚动会暂停跟随' : '继续跟随最新日志',
                child: FilterChip(
                  label: const Text('跟随'),
                  avatar: const Icon(Icons.vertical_align_bottom, size: 15),
                  selected: _follow,
                  onSelected: (value) {
                    setState(() => _follow = value);
                    _followLatest();
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '实时更新 · 保留最近 7 天，最多 200 条',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant.withValues(alpha: .6)),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _errorsOnly ? '暂无错误日志' : '开始工作后，这里会记录模型请求、工具执行与错误',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : NotificationListener<UserScrollNotification>(
                  onNotification: (event) {
                    final next = event.metrics.extentAfter <= 24;
                    if (next != _follow) setState(() => _follow = next);
                    return false;
                  },
                  child: Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      key: const ValueKey('work-runtime-log-list'),
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return _RuntimeLogCard(
                          key: ValueKey(entry.id),
                          entry: entry,
                          expanded: _expanded.contains(entry.id),
                          onToggle: () => setState(() {
                            if (!_expanded.add(entry.id)) {
                              _expanded.remove(entry.id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RuntimeLogCard extends StatelessWidget {
  const _RuntimeLogCard({
    super.key,
    required this.entry,
    required this.expanded,
    required this.onToggle,
  });
  final WorkRuntimeLogEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  String get _phase => switch (entry.phase) {
    'model' || 'request' || 'model_request' => '模型请求',
    'tool' || 'tool_call' => '工具执行',
    'task' || 'session' => '工作任务',
    'background' || 'process' => '后台进程',
    'agent' || 'subagent' => '子代理',
    'network' => '网络',
    'generation' => '生成答复',
    'translation' => '思考翻译',
    _ => entry.phase,
  };

  String get _status => switch (entry.status) {
    'queued' => '排队中',
    'awaiting_response' => '等待响应',
    'routed' => '已选择渠道',
    'response_started' => '开始接收',
    'started' || 'running' => '执行中',
    'completed' => '已完成',
    'failed' => '失败',
    'cancelled' => '已停止',
    'interrupted' => '已中断',
    'waiting' => '等待后台任务',
    'skipped' => '已跳过',
    _ => entry.status,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = switch (entry.level) {
      WorkRuntimeLogLevel.error => colors.error,
      WorkRuntimeLogLevel.warning =>
        theme.brightness == Brightness.dark
            ? Colors.orange.shade300
            : Colors.orange.shade800,
      WorkRuntimeLogLevel.info => colors.primary,
    };
    final time = entry.timestamp.toLocal();
    String two(int value) => '$value'.padLeft(2, '0');
    final timeText =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final duration = entry.durationMs == null
        ? null
        : entry.durationMs! < 1000
        ? '${entry.durationMs} ms'
        : '${(entry.durationMs! / 1000).toStringAsFixed(1)} s';
    final metadata = [
      if (entry.model?.isNotEmpty == true) entry.model!,
      if (entry.toolName?.isNotEmpty == true) entry.toolName!,
      ?duration,
      if (entry.httpStatus != null) 'HTTP ${entry.httpStatus}',
      if (entry.timeoutSeconds != null) '超时 ${entry.timeoutSeconds}s',
    ];
    final details = <String>[
      if (entry.detail?.isNotEmpty == true) entry.detail!,
      if (entry.errorType?.isNotEmpty == true) '类型：${entry.errorType}',
      if (entry.host?.isNotEmpty == true) '服务：${entry.host}',
      if (entry.taskId?.isNotEmpty == true) '任务：${entry.taskId}',
      if (entry.requestId?.isNotEmpty == true) '请求：${entry.requestId}',
      if (entry.toolCallId?.isNotEmpty == true) '工具调用：${entry.toolCallId}',
      '时间：${entry.timestamp.toIso8601String()}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: entry.level == WorkRuntimeLogLevel.error
            ? colors.errorContainer.withValues(alpha: .3)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          switch (entry.level) {
                            WorkRuntimeLogLevel.error => Icons.error_outline,
                            WorkRuntimeLogLevel.warning =>
                              Icons.warning_amber_rounded,
                            WorkRuntimeLogLevel.info =>
                              Icons.receipt_long_outlined,
                          },
                          size: 16,
                          color: color,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '$_phase · $_status',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                    if (metadata.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        metadata.join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (!expanded && entry.detail?.isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      Text(
                        entry.detail!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SelectableText(
                  details.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.55,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
