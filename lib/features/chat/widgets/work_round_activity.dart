import 'dart:convert';
import 'execution_ring.dart';
import 'command_activity_dialog.dart';
import 'tool_activity_details.dart';
import 'thinking_translation_host.dart';
import 'package:flutter/material.dart';
import '../../../data/models.dart';
import '../../../domain/chat/thinking_timeline.dart';

class WorkRoundActivity extends StatefulWidget {
  const WorkRoundActivity({
    super.key,
    this.conversationId,
    this.messageId,
    required this.reasoning,
    required this.activities,
    required this.running,
    this.onExpandedChanged,
    this.onStop,
    this.onRetry,
  });
  final String? conversationId, messageId;
  final String reasoning;
  final List<SearchActivity> activities;
  final bool running;
  final ValueChanged<bool>? onExpandedChanged;
  final VoidCallback? onStop;
  final ValueChanged<SearchActivity>? onRetry;
  @override
  State<WorkRoundActivity> createState() => _WorkRoundActivityState();
}

class _WorkRoundActivityState extends State<WorkRoundActivity> {
  late bool _expanded = widget.running;
  final _scroll = ScrollController();
  bool _follow = true;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  void didUpdateWidget(WorkRoundActivity old) {
    super.didUpdateWidget(old);
    if (_expanded && widget.running && _follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _follow) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    if (old.running != widget.running) {
      _expanded = widget.running;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onExpandedChanged?.call(_expanded);
      });
    }
  }

  String get _label {
    if (widget.running) return '正在处理 · ${widget.activities.length} 个步骤';
    final elapsed = widget.activities
        .map((a) => a.roundElapsedMillis)
        .whereType<int>()
        .lastOrNull;
    final seconds = elapsed == null ? null : (elapsed / 1000).round();
    final duration = seconds == null
        ? '执行记录'
        : seconds >= 60
        ? '用时 ${seconds ~/ 60}m ${seconds % 60}s'
        : '用时 ${seconds}s';
    final failed = widget.activities
        .where((a) => a.status != SearchActivityStatus.done)
        .length;
    return '$duration${failed > 0 ? ' · $failed 步未完成' : ''}';
  }

  String _stepLabel(SearchActivity activity) {
    final action = switch (activity.toolName) {
      'coding_workspace_info' => '查看工作区',
      'coding_list_directory' => '查看文件目录',
      'coding_read_file' => '读取文件',
      'coding_write_file' => '修改文件',
      'coding_create_directory' => '创建目录',
      'work_run_command' => '运行命令',
      'work_deliver_files' => '登记交付文件',
      'work_ask_user' => '向你提问',
      _ => switch (activity.kind) {
        SearchActivityKind.search => '搜索网页',
        SearchActivityKind.fetch => '读取网页',
        SearchActivityKind.image => '处理图片',
        SearchActivityKind.document => '处理文档',
        _ => activity.toolName ?? '调用工具',
      },
    };
    String path = '';
    try {
      final args = jsonDecode(activity.toolArguments ?? '{}');
      if (args is Map) {
        path = '${args['path'] ?? args['command'] ?? args['query'] ?? ''}';
      }
    } on FormatException {
      /* An interrupted call can have partial arguments. */
    }
    if (path.isEmpty) path = activity.query;
    final status = switch (activity.status) {
      SearchActivityStatus.done => '已',
      SearchActivityStatus.failed => '未完成：',
      SearchActivityStatus.running => widget.running ? '正在' : '已中断：',
    };
    return '$status$action${path.isEmpty ? '' : ' · $path'}';
  }

  bool _cancelled(SearchActivity activity) => RegExp(
    r'取消|中断|cancel|interrupt',
    caseSensitive: false,
  ).hasMatch(activity.error ?? '');

  void _details(SearchActivity activity) {
    if (activity.toolName == 'work_run_command') {
      showCommandActivityDialog(context, activity, title: _stepLabel(activity));
      return;
    }
    showToolActivityDetails(context, activity, title: _stepLabel(activity));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final segments = _expanded
        ? buildThinkingTimeline(
            reasoning: widget.reasoning,
            activities: widget.activities,
          )
        : const <ThinkingTimelineSegment>[];
    final prose = segments.where((segment) => segment.isReasoning).toList();
    return ThinkingTranslationHost(
      conversationId: widget.conversationId,
      messageId: widget.messageId,
      segments: prose.map((segment) => segment.text!).toList(),
      isStreaming: widget.running,
      expanded: _expanded,
      builder: (translationControls, renderReasoning) => Column(
        key: const ValueKey('work-tool-timeline'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_expanded)
            InkWell(
              key: const ValueKey('work-round-toggle'),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
            ),
          if (_expanded) ...[
            translationControls,
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height * .38).clamp(
                  120.0,
                  360.0,
                ),
              ),
              child: NotificationListener<UserScrollNotification>(
                onNotification: (event) {
                  _follow = event.metrics.extentAfter <= 20;
                  return false;
                },
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    key: const ValueKey('work-round-scroll'),
                    controller: _scroll,
                    child: Container(
                      padding: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: colors.outlineVariant),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final segment in segments)
                            if (segment.isReasoning)
                              renderReasoning(
                                prose.indexOf(segment),
                                segment.text!,
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: SelectableText(
                                    segment.text!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(height: 1.6),
                                  ),
                                ),
                              )
                            else ...[
                              InkWell(
                                onTap: () => _details(segment.activity!),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    children: [
                                      if (segment.activity!.status ==
                                              SearchActivityStatus.running &&
                                          widget.running)
                                        const ExecutionRing(size: 15)
                                      else
                                        Icon(
                                          _cancelled(segment.activity!)
                                              ? Icons.cancel_outlined
                                              : segment.activity!.status ==
                                                    SearchActivityStatus.done
                                              ? Icons.check_circle_outline
                                              : segment.activity!.status ==
                                                    SearchActivityStatus.failed
                                              ? Icons.error_outline
                                              : Icons.cancel_outlined,
                                          size: 16,
                                          color:
                                              segment.activity!.status ==
                                                  SearchActivityStatus.failed
                                              ? colors.error
                                              : colors.onSurfaceVariant,
                                        ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text.rich(
                                          TextSpan(
                                            children: [
                                              TextSpan(
                                                text: _stepLabel(
                                                  segment.activity!,
                                                ).split(' · ').first,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (_stepLabel(
                                                segment.activity!,
                                              ).contains(' · '))
                                                TextSpan(
                                                  text:
                                                      ' · ${_stepLabel(segment.activity!).split(' · ').skip(1).join(' · ')}',
                                                ),
                                            ],
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                                height: 1.6,
                                              ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right,
                                        size: 14,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (segment.activity!.canRetry &&
                                  widget.onRetry != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton(
                                    onPressed: () =>
                                        widget.onRetry!(segment.activity!),
                                    child: const Text('重试此步骤'),
                                  ),
                                ),
                            ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: [
                  if (widget.running) ...[
                    const ExecutionRing(size: 12),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      _label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    key: const ValueKey('work-round-collapse-bottom'),
                    onPressed: _toggle,
                    icon: const Icon(Icons.expand_less, size: 16),
                    label: const Text('收起'),
                  ),
                  const Spacer(),
                  if (widget.onStop != null)
                    TextButton(
                      onPressed: widget.onStop,
                      child: const Text('停止任务'),
                    ),
                ],
              ),
            ),
          ],
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: .6),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
