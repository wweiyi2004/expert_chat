import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/work_task_runtime.dart';

/// Fits either the workbench detail pane or a modal sheet on smaller screens.
class WorkTaskPanel extends ConsumerWidget {
  const WorkTaskPanel({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref
        .watch(workTaskRuntimeProvider)
        .where((r) => r.conversationId == conversationId)
        .toList();
    if (records.isEmpty) {
      return const Center(child: Text('开始工作后，这里会显示任务状态和命令日志'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: records.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _TaskCard(record: records[index]),
    );
  }
}

class WorkTaskStatusBar extends ConsumerWidget {
  const WorkTaskStatusBar({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref
        .watch(workTaskRuntimeProvider)
        .where((r) => r.conversationId == conversationId)
        .toList();
    if (records.isEmpty) return const SizedBox.shrink();
    final active = records.where((r) => r.status.isActive).toList();
    final record = active.isNotEmpty ? active.first : records.first;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          constraints: const BoxConstraints(maxWidth: 960),
          builder: (context) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text('任务与命令日志'),
                ),
                Expanded(child: WorkTaskPanel(conversationId: conversationId)),
              ],
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _TaskStatusIcon(status: record.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${record.stopRequested ? '正在停止' : record.status.label} · ${record.detail ?? record.title}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (active.length > 1)
                Text(
                  '${active.length} 项运行中',
                  style: theme.textTheme.labelSmall,
                ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskStatusIcon extends StatelessWidget {
  const _TaskStatusIcon({required this.status});
  final WorkTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Icon(
      switch (status) {
        WorkTaskStatus.running => Icons.play_circle_outline,
        WorkTaskStatus.waitingForApproval => Icons.pending_actions,
        WorkTaskStatus.completed => Icons.check_circle_outline,
        WorkTaskStatus.failed => Icons.error_outline,
        WorkTaskStatus.cancelled => Icons.cancel_outlined,
        WorkTaskStatus.interrupted => Icons.pause_circle_outline,
      },
      size: 18,
      color: status == WorkTaskStatus.failed ? colors.error : colors.primary,
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.record});
  final WorkTaskRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final runtime = ref.read(workTaskRuntimeProvider.notifier);
    final started = record.startedAt.toLocal();
    final time =
        '${started.month}/${started.day} '
        '${started.hour.toString().padLeft(2, '0')}:'
        '${started.minute.toString().padLeft(2, '0')}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _TaskStatusIcon(status: record.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (record.status.isActive && runtime.canStop(record.id))
                  TextButton.icon(
                    onPressed: record.stopRequested
                        ? null
                        : () => runtime.stop(record.id),
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: Text(record.stopRequested ? '正在停止' : '停止'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${record.status.label} · $time'
              '${record.exitCode == null ? '' : ' · 退出码 ${record.exitCode}'}',
              style: theme.textTheme.bodySmall,
            ),
            if (record.detail case final detail?) ...[
              const SizedBox(height: 6),
              Text(
                detail,
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (record.message case final message?) ...[
              const SizedBox(height: 6),
              Text(message, style: theme.textTheme.bodySmall),
            ],
            if (record.logs.isNotEmpty) ...[
              const SizedBox(height: 10),
              if (record.logsTruncated)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('仅显示最近的输出', style: TextStyle(fontSize: 11)),
                ),
              _LiveLog(logs: record.logs),
            ] else if (!record.status.isActive) ...[
              const SizedBox(height: 8),
              Text(
                '完整工具结果可在会话中查看；实时日志不跨重启保留。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LiveLog extends StatefulWidget {
  const _LiveLog({required this.logs});
  final List<WorkTaskLog> logs;

  @override
  State<_LiveLog> createState() => _LiveLogState();
}

class _LiveLogState extends State<_LiveLog> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LiveLog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final follow =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 48;
    if (follow && oldWidget.logs != widget.logs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          child: SelectableText.rich(
            TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
              children: [
                for (final log in widget.logs)
                  TextSpan(
                    text: log.text,
                    style: TextStyle(
                      color: log.isStderr
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
